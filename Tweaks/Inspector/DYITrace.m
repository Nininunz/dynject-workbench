// Inspector: the method tracer. Logs every call of a traced method: receiver, arguments, return value, duration and
// thread, to the tweak's log (category "trace") and a buffer of recent lines.
//
// How: the method is pointed at _objc_msgForward through a DynjectHook group, and the class's forwardInvocation: is
// hooked once. A call then arrives in DYITraceForward as an NSInvocation, which knows every argument's type from the
// method's own signature; it is logged and the original implementation is called with invokeUsingIMP:. Frames stay
// ordinary C and Objective-C frames, so exceptions unwind through a traced method as before. Stopping a trace disables
// its group: the method gets its implementation back (or, beneath another tweak's hook, stays and passes straight
// through).
//
// Rules that keep it safe:
// - One owner per selector along a class chain: a method can't be traced on a class and on its superclass or subclass
//   at the same time, so a forwarded call always belongs to the first traced class in the receiver's chain (super
//   calls and recursion work without guessing).
// - Never traced: the methods forwarding and memory management themselves use, and classes that forward messages on
//   their own (they define forwardInvocation:, methodSignatureForSelector: or forwardingTargetForSelector:) or don't
//   descend from NSObject.
// - Traced calls made while a trace line is being written (formatting, logging) run untraced.
// - At most kDYITraceLinesPerSecond lines per method per second; the next line says how many were not shown.
// - Values are described without calling the objects (DYIDescribe): no -description of arbitrary objects.
#import "DYIInternal.h"
#import "DynjectHook.h"
#import <objc/message.h>
#import <os/lock.h>
#import <os/log.h>
#import <pthread.h>
#import <stdatomic.h>

@interface NSInvocation (DYIPrivate)
- (void)invokeUsingIMP:(IMP)imp;
@end

static const NSUInteger kDYITraceLinesPerSecond = 40;
static const NSUInteger kDYITraceRecentLimit = 500;
static const NSUInteger kDYITraceClassLimit = 400;
enum { kDYITraceMaxDepth = 64 };

@interface DYITraced : NSObject {
@public
    DHHook *_hook;   // written by DHHookMessageEx before the hook is reachable
}
@property (nonatomic) Class owner;                 // the class, or the metaclass for a class method
@property (nonatomic) Class cls;                   // the class (not the metaclass)
@property (nonatomic) SEL selector;
@property (nonatomic) BOOL classMethod;
@property (nonatomic, assign) DHGroup *group;
@property (nonatomic, copy) NSString *label;       // "-[NSView setFrame:]"
@property (nonatomic, strong) NSMethodSignature *signature;
@property (nonatomic) BOOL active;
// Rate limit, guarded by sTraceLock.
@property (nonatomic) CFAbsoluteTime windowStart;
@property (nonatomic) NSUInteger windowCount;
@property (nonatomic) NSUInteger suppressed;
@end

@implementation DYITraced
@end

static os_unfair_lock sTraceLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, DYITraced *> *sTraced;       // "owner pointer|selector" -> record; under sTraceLock
static NSMutableDictionary<NSValue *, NSValue *> *sForwardHooks;    // owner -> DHHook * of its forwardInvocation:
static NSMutableArray<NSString *> *sRecent;                          // the last lines; under sTraceLock
static atomic_bool sBacktraces;

// Per thread: inside the tracer's own work (calls run untraced), and the traced calls in progress.
static __thread BOOL tBusy;
static __thread int tDepth;
static __thread CFTypeRef tPending[kDYITraceMaxDepth];   // +1 NSString: a call whose line isn't written yet
static __thread BOOL tPendingWritten[kDYITraceMaxDepth];
// Fallback forwarding: the forwardInvocation: hook already passed for this invocation (see DYITraceForward).
static __thread void *tFallbackInvocation;
static __thread Class tFallbackOwner;

static NSString *DYITraceKey(Class owner, SEL sel) {
    return [NSString stringWithFormat:@"%p|%s", (__bridge void *)owner, sel_getName(sel)];
}

static os_log_t DYITraceLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create(DYI_ID_C, "trace"); });
    return log;
}

static void DYITraceEmit(NSString *line) {
    os_log(DYITraceLog(), "%{public}@", line);
    os_unfair_lock_lock(&sTraceLock);
    if (!sRecent) sRecent = [NSMutableArray array];
    [sRecent addObject:line];
    if (sRecent.count > kDYITraceRecentLimit) [sRecent removeObjectsInRange:NSMakeRange(0, sRecent.count - kDYITraceRecentLimit)];
    os_unfair_lock_unlock(&sTraceLock);
}

static NSString *DYITraceIndent(int depth) {
    return [@"" stringByPaddingToLength:(NSUInteger)MAX(depth, 0) * 2 withString:@" " startingAtIndex:0];
}

// Writes the "→ call" lines of outer calls that haven't got one yet: something is logged inside them.
static void DYITraceFlushPending(int upTo) {
    for (int d = 0; d < upTo && d < kDYITraceMaxDepth; d++) {
        if (!tPending[d] || tPendingWritten[d]) continue;
        DYITraceEmit([NSString stringWithFormat:@"%@→ %@", DYITraceIndent(d), (__bridge NSString *)tPending[d]]);
        tPendingWritten[d] = YES;
    }
}

#pragma mark Values

static const char *DYISkipQualifiers(const char *t) {
    while (*t && strchr("rnNoORVA", *t)) t++;
    return t;
}

static NSString *DYITraceValue(const char *type, const void *buf);

// The fields of "{name=fields}", decoded one by one with their alignment. nil if it can't be.
static NSString *DYITraceStruct(const char *type, const void *buf) {
    const char *eq = strchr(type, '=');
    if (!eq) return nil;
    const char *p = eq + 1;
    NSMutableArray *fields = [NSMutableArray array];
    NSUInteger offset = 0;
    while (*p && *p != '}' && fields.count < 12) {
        NSUInteger size = 0, align = 0;
        const char *next = NULL;
        @try { next = NSGetSizeAndAlignment(p, &size, &align); } @catch (__unused id e) { return nil; }
        if (!next || next == p || align == 0) return nil;
        offset = (offset + align - 1) / align * align;
        char field[256];
        size_t len = (size_t)(next - p);
        if (len >= sizeof field) return nil;
        memcpy(field, p, len);
        field[len] = 0;
        [fields addObject:DYITraceValue(field, (const uint8_t *)buf + offset)];
        offset += size;
        p = next;
        while (*p >= '0' && *p <= '9') p++;   // offsets some encodings carry
    }
    return [NSString stringWithFormat:@"{%@}", [fields componentsJoinedByString:@", "]];
}

static NSString *DYITraceValue(const char *rawType, const void *buf) {
    const char *t = DYISkipQualifiers(rawType);
    switch (*t) {
        case 'v': return @"void";
        case '@': {
            __unsafe_unretained id o = *(__unsafe_unretained id const *)buf;
            if (t[1] == '?') return o ? [NSString stringWithFormat:@"<block %p>", (__bridge void *)o] : @"nil";
            return DYIDescribe(o);
        }
        case '#': { Class c = *(const Class *)buf; return c ? NSStringFromClass(c) : @"Nil"; }
        case ':': { SEL s = *(const SEL *)buf; return s ? [NSString stringWithFormat:@"@selector(%s)", sel_getName(s)] : @"NULL"; }
        case 'B': return *(const bool *)buf ? @"YES" : @"NO";
        case 'c': {   // BOOL on x86_64
            signed char c = *(const signed char *)buf;
            return c == 0 ? @"NO" : c == 1 ? @"YES" : [NSString stringWithFormat:@"%d", c];
        }
        case 'C': return [NSString stringWithFormat:@"%u", *(const unsigned char *)buf];
        case 's': return [NSString stringWithFormat:@"%d", *(const short *)buf];
        case 'S': return [NSString stringWithFormat:@"%u", *(const unsigned short *)buf];
        case 'i': return [NSString stringWithFormat:@"%d", *(const int *)buf];
        case 'I': return [NSString stringWithFormat:@"%u", *(const unsigned int *)buf];
        case 'l': return [NSString stringWithFormat:@"%ld", (long)*(const int32_t *)buf];
        case 'L': return [NSString stringWithFormat:@"%lu", (unsigned long)*(const uint32_t *)buf];
        case 'q': return [NSString stringWithFormat:@"%lld", *(const long long *)buf];
        case 'Q': return [NSString stringWithFormat:@"%llu", *(const unsigned long long *)buf];
        case 'f': return [NSString stringWithFormat:@"%g", *(const float *)buf];
        case 'd': return [NSString stringWithFormat:@"%g", *(const double *)buf];
        case '*': case '^': case '?': {
            const void *ptr = *(const void *const *)buf;
            return ptr ? [NSString stringWithFormat:@"%p", ptr] : @"NULL";
        }
        case '{': {
            NSString *known = nil;
            if (!strncmp(t, "{CGRect=", 8) || !strncmp(t, "{CGPoint=", 9) || !strncmp(t, "{CGSize=", 8) || !strncmp(t, "{_NSRange=", 10) ||
                !strncmp(t, "{CGAffineTransform=", 19) || !strncmp(t, "{NSEdgeInsets=", 14) || !strncmp(t, "{CATransform3D=", 15)) {
                known = DYIDescribe([NSValue valueWithBytes:buf objCType:t]);
            }
            return known ?: DYITraceStruct(t, buf) ?: [NSString stringWithFormat:@"(%@)", DYIReadableType(t)];
        }
        default: return [NSString stringWithFormat:@"(%@)", DYIReadableType(t)];
    }
}

static NSString *DYITraceArgument(NSInvocation *inv, NSUInteger index) {
    const char *type = [inv.methodSignature getArgumentTypeAtIndex:index];
    NSUInteger size = 0;
    NSGetSizeAndAlignment(type, &size, NULL);
    if (size == 0 || size > 4096) return [NSString stringWithFormat:@"(%@)", DYIReadableType(type)];
    void *buf = calloc(1, size);
    [inv getArgument:buf atIndex:(NSInteger)index];
    NSString *s = DYITraceValue(type, buf);
    free(buf);
    return s;
}

static NSString *DYITraceReturnValue(NSInvocation *inv) {
    NSMethodSignature *sig = inv.methodSignature;
    const char *type = sig.methodReturnType;
    if (*DYISkipQualifiers(type) == 'v') return @"void";
    NSUInteger size = sig.methodReturnLength;
    if (size == 0 || size > 4096) return [NSString stringWithFormat:@"(%@)", DYIReadableType(type)];
    void *buf = calloc(1, size);
    [inv getReturnValue:buf];
    NSString *s = DYITraceValue(type, buf);
    free(buf);
    return s;
}

// "-[ITLeafView 0x6000… setPair:{1.5, 2} flag:YES]" / "+[ITLeafView classValue]"
static NSString *DYITraceCallText(DYITraced *t, __unsafe_unretained id self, NSInvocation *inv) {
    NSMutableString *s = [NSMutableString stringWithFormat:@"%c[%@", t.classMethod ? '+' : '-', NSStringFromClass(t.cls)];
    if (!t.classMethod) [s appendFormat:@" %p", (__bridge void *)self];
    NSArray<NSString *> *parts = [NSStringFromSelector(t.selector) componentsSeparatedByString:@":"];
    NSUInteger args = inv.methodSignature.numberOfArguments - 2;
    if (args == 0) {
        [s appendFormat:@" %@]", NSStringFromSelector(t.selector)];
        return s;
    }
    for (NSUInteger i = 0; i < args; i++) {
        NSString *part = i < parts.count ? parts[i] : @"";
        [s appendFormat:@" %@:%@", part, DYITraceArgument(inv, i + 2)];
    }
    [s appendString:@"]"];
    return s;
}

static NSString *DYITraceThreadName(void) {
    if (pthread_main_np()) return @"main";
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    return [NSString stringWithFormat:@"thread %llu", tid];
}

static NSString *DYITraceBacktrace(int depth) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *frame in [NSThread callStackSymbols]) {
        if ([frame containsString:@"libInspector.dylib"] || [frame containsString:@"___forwarding___"] ||
            [frame containsString:@"_CF_forwarding_prep"] || [frame containsString:@"invokeUsingIMP"]) continue;
        // "4   AppKit   0x00000001 -[NSView foo] + 12" -> "AppKit  -[NSView foo] + 12"
        NSArray *f = [frame componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        f = [f filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        NSString *text = f.count > 3 ? [NSString stringWithFormat:@"%@  %@", f[1], [[f subarrayWithRange:NSMakeRange(3, f.count - 3)] componentsJoinedByString:@" "]] : frame;
        [out addObject:[NSString stringWithFormat:@"%@    at %@", DYITraceIndent(depth), text]];
        if (out.count == 6) break;
    }
    return [out componentsJoinedByString:@"\n"];
}

#pragma mark Forwarding

// The record for a forwarded call: the first traced class in the receiver's chain (there is at most one per selector).
static DYITraced *DYITraceLookup(__unsafe_unretained id self, SEL sel) {
    DYITraced *found = nil;
    os_unfair_lock_lock(&sTraceLock);
    for (Class c = object_getClass(self); c && !found; c = class_getSuperclass(c)) found = sTraced[DYITraceKey(c, sel)];
    os_unfair_lock_unlock(&sTraceLock);
    return found;
}

// Whether a line may be written now (rate limit); `suppressed` gets the calls not shown since the last one.
static BOOL DYITraceAllow(DYITraced *t, NSUInteger *suppressed) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&sTraceLock);
    if (now - t.windowStart >= 1) {
        t.windowStart = now;
        t.windowCount = 0;
    }
    BOOL allow = t.windowCount < kDYITraceLinesPerSecond;
    if (allow) {
        t.windowCount++;
        *suppressed = t.suppressed;
        t.suppressed = 0;
    } else {
        t.suppressed++;
    }
    os_unfair_lock_unlock(&sTraceLock);
    return allow;
}

static void DYITraceForward(__unsafe_unretained id self, SEL _cmd, NSInvocation *inv) {
    SEL sel = inv.selector;
    DYITraced *t = DYITraceLookup(self, sel);
    IMP original = t ? DHOriginal(t->_hook) : NULL;
    if (!t || !original) {
        // Not a traced call: genuine forwarding (or an unknown selector). Hand it to the forwardInvocation: the hook
        // replaced, starting above the hook this invocation already passed through (several classes in the chain
        // may have one, and an inherited override's original leads back here).
        Class from = (tFallbackInvocation == (__bridge void *)inv && tFallbackOwner) ? class_getSuperclass(tFallbackOwner)
                                                                                    : object_getClass(self);
        DHHook *fh = NULL;
        Class owner = Nil;
        os_unfair_lock_lock(&sTraceLock);
        for (Class c = from; c && !fh; c = class_getSuperclass(c)) {
            NSValue *v = sForwardHooks[[NSValue valueWithPointer:(__bridge void *)c]];
            if (v) { fh = v.pointerValue; owner = c; }
        }
        os_unfair_lock_unlock(&sTraceLock);
        void *savedInv = tFallbackInvocation;
        Class savedOwner = tFallbackOwner;
        tFallbackInvocation = (__bridge void *)inv;
        tFallbackOwner = owner;
        @try {
            if (fh) DH_CALL_ORIG(fh, void (*)(id, SEL, NSInvocation *), self, _cmd, inv);
            else [self doesNotRecognizeSelector:sel];
        } @finally {
            tFallbackInvocation = savedInv;
            tFallbackOwner = savedOwner;
        }
        return;
    }
    if (tBusy || !t.active || !DHHookIsActive(t->_hook) || tDepth >= kDYITraceMaxDepth) {
        [inv invokeUsingIMP:original];
        return;
    }

    NSUInteger suppressed = 0;
    BOOL logged = DYITraceAllow(t, &suppressed);
    int depth = tDepth;
    if (logged) {
        tBusy = YES;
        NSString *call = DYITraceCallText(t, self, inv);
        if (suppressed) call = [call stringByAppendingFormat:@" (+%lu calls not shown)", (unsigned long)suppressed];
        tPending[depth] = CFBridgingRetain(call);
        tPendingWritten[depth] = NO;
        tBusy = NO;
    } else {
        tPending[depth] = NULL;
    }
    tDepth = depth + 1;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    @try {
        [inv invokeUsingIMP:original];
    } @catch (id exception) {
        tDepth = depth;
        if (tPending[depth]) {
            tBusy = YES;
            DYITraceFlushPending(depth);
            NSString *call = CFBridgingRelease(tPending[depth]);
            tPending[depth] = NULL;
            NSString *what = [exception isKindOfClass:[NSException class]] ? ((NSException *)exception).name : DYIPointerString(exception);
            DYITraceEmit([NSString stringWithFormat:@"%@%@%@ raised %@  (%@)", DYITraceIndent(depth),
                                                    tPendingWritten[depth] ? @"← " : @"", call, what, DYITraceThreadName()]);
            tBusy = NO;
        }
        @throw;
    }
    double ms = (CFAbsoluteTimeGetCurrent() - start) * 1000;
    tDepth = depth;
    if (!tPending[depth]) return;
    tBusy = YES;
    DYITraceFlushPending(depth);
    BOOL nested = tPendingWritten[depth];
    NSString *call = CFBridgingRelease(tPending[depth]);
    tPending[depth] = NULL;
    NSString *head = nested ? [NSString stringWithFormat:@"← %@", t.label] : call;
    NSMutableString *line = [NSMutableString stringWithFormat:@"%@%@ → %@  (%.3f ms, %@)", DYITraceIndent(depth), head,
                                                              DYITraceReturnValue(inv), ms, DYITraceThreadName()];
    if (atomic_load(&sBacktraces)) [line appendFormat:@"\n%@", DYITraceBacktrace(depth)];
    DYITraceEmit(line);
    tBusy = NO;
}

#pragma mark Installing

static BOOL DYIClassDefines(Class cls, SEL sel) {
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n && !found; i++) found = method_getName(list[i]) == sel;
    free(list);
    return found;
}

// Why the method can't be traced, or nil.
static NSString *DYITraceRefusal(Class cls, SEL sel, BOOL classMethod) {
    static NSSet<NSString *> *never;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        never = [NSSet setWithArray:@[
            @"forwardInvocation:", @"methodSignatureForSelector:", @"forwardingTargetForSelector:", @"respondsToSelector:",
            @"doesNotRecognizeSelector:", @"resolveInstanceMethod:", @"resolveClassMethod:", @"class", @"self", @"isProxy",
            @"retain", @"release", @"autorelease", @"retainCount", @"dealloc", @".cxx_destruct", @".cxx_construct",
            @"_tryRetain", @"_isDeallocating", @"allowsWeakReference", @"retainWeakReference", @"isKindOfClass:",
            @"isMemberOfClass:", @"conformsToProtocol:", @"initialize", @"load", @"instanceMethodSignatureForSelector:",
        ]];
    });
    if (![NSInvocation instancesRespondToSelector:@selector(invokeUsingIMP:)]) {
        return @"this macOS's NSInvocation can't call an implementation directly (invokeUsingIMP:)";
    }
    if ([never containsObject:NSStringFromSelector(sel)]) return @"the runtime itself uses this method (forwarding, memory management)";
    Class root = cls;
    while (class_getSuperclass(root)) root = class_getSuperclass(root);
    if (root != [NSObject class]) return [NSString stringWithFormat:@"%s doesn't descend from NSObject", class_getName(cls)];
    if ([NSStringFromClass(cls) hasPrefix:@"NSInvocation"] || [NSStringFromClass(cls) hasPrefix:@"NSMethodSignature"] ||
        [NSStringFromClass(cls) hasPrefix:@"__NSMethodSignature"]) return @"the tracer uses this class";
    // Up to, not including, NSObject (and its metaclass, whose superclass is NSObject): those forward for everyone.
    for (Class c = classMethod ? object_getClass(cls) : cls; c && c != root && c != object_getClass(root); c = class_getSuperclass(c)) {
        os_unfair_lock_lock(&sTraceLock);
        BOOL ours = sForwardHooks[[NSValue valueWithPointer:(__bridge void *)c]] != nil;   // the tracer's own override
        os_unfair_lock_unlock(&sTraceLock);
        for (NSString *name in @[@"forwardInvocation:", @"methodSignatureForSelector:", @"forwardingTargetForSelector:"]) {
            if (ours && [name isEqualToString:@"forwardInvocation:"]) continue;
            if (DYIClassDefines(c, NSSelectorFromString(name))) {
                return [NSString stringWithFormat:@"%s forwards messages itself (it defines %@)", class_getName(c), name];
            }
        }
    }
    Method m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return [NSString stringWithFormat:@"%s doesn't respond to it", class_getName(cls)];
    const char *types = method_getTypeEncoding(m);
    if (!types || strchr(types, '(') || strchr(types, 'b')) return @"its types include a union or a bitfield, which NSInvocation can't pass";
    return nil;
}

NSString *DYITraceMethod(Class cls, SEL sel, BOOL classMethod) {
    if (!cls || !sel) return @"no method";
    NSString *refusal = DYITraceRefusal(cls, sel, classMethod);
    if (refusal) return refusal;
    Class owner = classMethod ? object_getClass(cls) : cls;
    NSString *label = [NSString stringWithFormat:@"%c[%s %s]", classMethod ? '+' : '-', class_getName(cls), sel_getName(sel)];
    NSString *key = DYITraceKey(owner, sel);

    os_unfair_lock_lock(&sTraceLock);
    if (!sTraced) {
        sTraced = [NSMutableDictionary dictionary];
        sForwardHooks = [NSMutableDictionary dictionary];
    }
    DYITraced *existing = sTraced[key];
    DYITraced *conflict = nil;
    for (DYITraced *t in sTraced.allValues) {
        if (t == existing || !t.active || t.selector != sel || t.classMethod != classMethod) continue;
        for (Class c = owner; c && !conflict; c = class_getSuperclass(c)) if (c == t.owner) conflict = t;
        for (Class c = t.owner; c && !conflict; c = class_getSuperclass(c)) if (c == owner) conflict = t;
    }
    BOOL forwardHooked = sForwardHooks[[NSValue valueWithPointer:(__bridge void *)owner]] != nil;
    os_unfair_lock_unlock(&sTraceLock);
    if (conflict) {
        return [NSString stringWithFormat:@"%@ is traced already; stop that first (one class per method along a chain)", conflict.label];
    }
    if (existing) {
        if (existing.active) return [NSString stringWithFormat:@"%@ is traced already", label];
        existing.active = YES;
        DHGroupSetEnabled(existing.group, YES);
        DYILog(@"tracing %@ again", label);
        return nil;
    }

    NSMethodSignature *sig = nil;
    Method m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    @try { sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)]; } @catch (__unused id e) { sig = nil; }
    if (!sig) return @"NSInvocation can't handle its types";

    if (!forwardHooked) {
        DHHook *fh = DHHookMessage(owner, @selector(forwardInvocation:), (IMP)DYITraceForward, NULL);
        IMP current = method_getImplementation(class_getInstanceMethod(owner, @selector(forwardInvocation:)));
        if (!fh && current != (IMP)DYITraceForward) return @"couldn't hook forwardInvocation: (see the log)";
        if (fh) {
            os_unfair_lock_lock(&sTraceLock);
            sForwardHooks[[NSValue valueWithPointer:(__bridge void *)owner]] = [NSValue valueWithPointer:fh];
            os_unfair_lock_unlock(&sTraceLock);
        }
    }

    IMP forward = (IMP)_objc_msgForward;
#if defined(__x86_64__)
    // x86_64 returns a struct larger than 16 bytes in memory, through the _stret forwarder.
    if (*DYISkipQualifiers(sig.methodReturnType) == '{' && sig.methodReturnLength > 16) forward = (IMP)_objc_msgForward_stret;
#endif
    DYITraced *t = [DYITraced new];
    t.owner = owner;
    t.cls = cls;
    t.selector = sel;
    t.classMethod = classMethod;
    t.label = label;
    t.signature = sig;
    t.active = YES;
    t.group = DHGroupCreate(label.UTF8String);
    // Registered before the hook goes live, so a call racing in finds the record.
    os_unfair_lock_lock(&sTraceLock);
    sTraced[key] = t;
    os_unfair_lock_unlock(&sTraceLock);
    DHHook *hook = DHHookMessageEx(owner, sel, forward, t.group, &t->_hook);
    if (!hook) {
        os_unfair_lock_lock(&sTraceLock);
        [sTraced removeObjectForKey:key];
        os_unfair_lock_unlock(&sTraceLock);
        return @"DynjectHook couldn't hook it (see the log)";
    }
    DYILog(@"tracing %@", label);
    return nil;
}

void DYIUntraceMethod(Class cls, SEL sel, BOOL classMethod) {
    Class owner = classMethod ? object_getClass(cls) : cls;
    os_unfair_lock_lock(&sTraceLock);
    DYITraced *t = sTraced[DYITraceKey(owner, sel)];
    os_unfair_lock_unlock(&sTraceLock);
    if (!t || !t.active) return;
    t.active = NO;
    DHGroupSetEnabled(t.group, NO);
    DYILog(@"stopped tracing %@", t.label);
}

NSUInteger DYITraceClass(Class cls, BOOL classMethods, NSUInteger *outRefused) {
    NSUInteger traced = 0, refused = 0;
    unsigned int n = 0;
    Method *list = class_copyMethodList(classMethods ? object_getClass(cls) : cls, &n);
    for (unsigned int i = 0; i < n && traced < kDYITraceClassLimit; i++) {
        SEL sel = method_getName(list[i]);
        if (DYITraceIsActive(cls, sel, classMethods)) continue;
        if (DYITraceMethod(cls, sel, classMethods)) refused++;
        else traced++;
    }
    free(list);
    if (outRefused) *outRefused = refused;
    return traced;
}

void DYIUntraceAll(void) {
    os_unfair_lock_lock(&sTraceLock);
    NSArray<DYITraced *> *all = sTraced.allValues ?: @[];
    os_unfair_lock_unlock(&sTraceLock);
    for (DYITraced *t in all) if (t.active) DYIUntraceMethod(t.cls, t.selector, t.classMethod);
}

BOOL DYITraceIsActive(Class cls, SEL sel, BOOL classMethod) {
    Class owner = classMethod ? object_getClass(cls) : cls;
    os_unfair_lock_lock(&sTraceLock);
    BOOL active = sTraced[DYITraceKey(owner, sel)].active;
    os_unfair_lock_unlock(&sTraceLock);
    return active;
}

NSUInteger DYITraceActiveCount(void) {
    NSUInteger n = 0;
    os_unfair_lock_lock(&sTraceLock);
    for (DYITraced *t in sTraced.allValues) n += t.active ? 1 : 0;
    os_unfair_lock_unlock(&sTraceLock);
    return n;
}

NSArray<NSString *> *DYITraceRecentLines(void) {
    os_unfair_lock_lock(&sTraceLock);
    NSArray *lines = [sRecent copy] ?: @[];
    os_unfair_lock_unlock(&sTraceLock);
    return lines;
}

void DYITraceClearRecent(void) {
    os_unfair_lock_lock(&sTraceLock);
    [sRecent removeAllObjects];
    os_unfair_lock_unlock(&sTraceLock);
}

void DYITraceSetBacktraces(BOOL on) { atomic_store(&sBacktraces, on ? true : false); }
BOOL DYITraceBacktraces(void) { return atomic_load(&sBacktraces) ? YES : NO; }
