// Inspector: runtime introspection. Lists methods, properties, ivars and protocols, turns type encodings into
// readable (and compilable) C types, writes DynjectHook skeletons and describes values. Nothing here calls a method
// of an inspected object except DYIEvaluateProperty (one getter, on request) and DYIDescriptionOf (explicit actions).
#import "DYIInternal.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/message.h>

#pragma mark - Images

NSString *DYIShortImageName(NSString *path) {
    if (path.length == 0) return @"(unknown image)";
    NSArray<NSString *> *parts = path.pathComponents;
    for (NSString *part in parts.reverseObjectEnumerator) {   // innermost framework wins (Versions/A/X)
        if ([part hasSuffix:@".framework"]) return part.stringByDeletingPathExtension;
    }
    return path.lastPathComponent;
}

NSString *DYIImageOfClass(Class cls) {
    const char *name = cls ? class_getImageName(cls) : NULL;
    return name ? @(name) : @"";
}

NSString *DYIImageOfIMP(IMP imp) {
    Dl_info info;
    if (imp && dladdr((const void *)imp, &info) && info.dli_fname) return @(info.dli_fname);
    return @"";
}

NSArray<Class> *DYIClassChain(Class cls) {
    NSMutableArray *chain = [NSMutableArray array];
    for (Class c = cls; c && chain.count < 64; c = class_getSuperclass(c)) [chain addObject:c];
    return chain;
}

#pragma mark - Type encodings

/// Well-known structs, passed by value: encoding name -> C type name (all in Foundation, CoreGraphics, AppKit or
/// QuartzCore).
static NSDictionary<NSString *, NSString *> *DYIKnownStructs(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{@"CGRect": @"CGRect", @"CGPoint": @"CGPoint", @"CGSize": @"CGSize", @"CGVector": @"CGVector",
                @"CGAffineTransform": @"CGAffineTransform", @"CATransform3D": @"CATransform3D",
                @"_NSRange": @"NSRange", @"NSEdgeInsets": @"NSEdgeInsets",
                @"NSDirectionalEdgeInsets": @"NSDirectionalEdgeInsets",
                @"NSAffineTransformStruct": @"NSAffineTransformStruct",
                @"_NSOperatingSystemVersion": @"NSOperatingSystemVersion"};
    });
    return map;
}

/// Opaque structs usually seen behind a pointer: encoding name -> C type of the pointer.
static NSDictionary<NSString *, NSString *> *DYIKnownPointers(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{@"CGColor": @"CGColorRef", @"CGPath": @"CGPathRef", @"CGImage": @"CGImageRef",
                @"CGContext": @"CGContextRef", @"CGColorSpace": @"CGColorSpaceRef", @"CGFont": @"CGFontRef",
                @"CGGradient": @"CGGradientRef", @"__CFString": @"CFStringRef", @"__CFArray": @"CFArrayRef",
                @"__CFDictionary": @"CFDictionaryRef", @"__CFData": @"CFDataRef", @"__CFRunLoop": @"CFRunLoopRef",
                @"_NSZone": @"NSZone *", @"__IOSurface": @"IOSurfaceRef", @"__CVBuffer": @"void *",
                @"CGRect": @"CGRect *", @"CGPoint": @"CGPoint *", @"CGSize": @"CGSize *",
                @"_NSRange": @"NSRange *", @"CGAffineTransform": @"CGAffineTransform *"};
    });
    return map;
}

/// Turns one type encoding into a C type. In code mode the result is something the compiler accepts with exactly the
/// same calling convention: objects become `id`, unknown structs by value get a typedef (collected in `typedefs`),
/// unknown pointers become `void *`. What can't be written exactly (unions, bitfields, C arrays outside structs,
/// complex numbers, structs without a layout) sets `problem`.
@interface DYITypeWriter : NSObject
@property (nonatomic) BOOL code;
@property (nonatomic, copy) NSString *prefix;
@property (nonatomic, strong) NSMutableArray<NSString *> *typedefs;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *typedefNames;
@property (nonatomic, copy, nullable) NSString *problem;
@end

@implementation DYITypeWriter

- (instancetype)init {
    if ((self = [super init])) {
        _prefix = @"MY";
        _typedefs = [NSMutableArray array];
        _typedefNames = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)fail:(NSString *)why {
    if (!self.problem) self.problem = why;
}

/// Skips one complete type at *p (balanced brackets, quoted names), without interpreting it.
static void DYISkipType(const char **pp) {
    const char *p = *pp;
    while (*p && strchr("rnNoORVAj", *p)) p++;
    if (!*p) { *pp = p; return; }
    char c = *p++;
    if (c == '^') { if (*p) DYISkipType(&p); }
    else if (c == '@') {
        if (*p == '?') p++;
        else if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p) p++; }
    } else if (c == 'b') { while (isdigit((unsigned char)*p)) p++; }
    else if (c == '{' || c == '(' || c == '[') {
        int depth = 1;
        while (*p && depth > 0) {
            if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p) p++; continue; }
            if (*p == '{' || *p == '(' || *p == '[') depth++;
            else if (*p == '}' || *p == ')' || *p == ']') depth--;
            p++;
        }
    }
    *pp = p;
}

/// Reads a struct/union name after '{' or '(' up to '=' or the closing bracket.
static NSString *DYIReadAggregateName(const char **pp, char close) {
    const char *p = *pp, *start = p;
    while (*p && *p != '=' && *p != close) p++;
    NSString *name = [[NSString alloc] initWithBytes:start length:(NSUInteger)(p - start) encoding:NSUTF8StringEncoding];
    *pp = p;
    return name ?: @"?";
}

static NSString *DYISanitize(NSString *s) {
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar ch = [s characterAtIndex:i];
        BOOL ok = (ch < 128) && (isalnum((int)ch) || ch == '_');
        [out appendString:ok ? [NSString stringWithCharacters:&ch length:1] : @"_"];
    }
    return out.length ? out : @"_";
}

/// One type. `field`: inside a struct (objects need an ownership qualifier, arrays are allowed: *arraySuffix).
- (NSString *)typeAt:(const char **)pp field:(BOOL)field arraySuffix:(NSString **)arraySuffix {
    const char *p = *pp;
    BOOL isConst = NO;
    while (*p && strchr("rnNoORVA", *p)) { if (*p == 'r') isConst = YES; p++; }
    if (*p == 'j') { [self fail:@"complex number"]; DYISkipType(&p); *pp = p; return @"_Complex"; }
    if (!*p) { [self fail:@"empty type encoding"]; *pp = p; return @"?"; }
    char c = *p++;
    NSString *t = nil;
    switch (c) {
        case 'c': t = @"char"; break;
        case 'C': t = @"unsigned char"; break;
        case 's': t = @"short"; break;
        case 'S': t = @"unsigned short"; break;
        case 'i': t = @"int"; break;
        case 'I': t = @"unsigned int"; break;
        case 'l': t = @"int"; break;            // 'l' is a 32-bit long in these encodings
        case 'L': t = @"unsigned int"; break;
        case 'q': t = @"NSInteger"; break;      // long / long long: same size and passing
        case 'Q': t = @"NSUInteger"; break;
        case 'f': t = @"float"; break;
        case 'd': t = @"double"; break;
        case 'D': t = @"long double"; break;
        case 'B': t = @"BOOL"; break;
        case 'v': t = @"void"; break;
        case '*': t = isConst ? @"const char *" : @"char *"; break;
        case '#': t = @"Class"; break;
        case ':': t = @"SEL"; break;
        case '?': [self fail:@"unknown type"]; t = @"void *"; break;
        case '@':
            if (*p == '?') { p++; t = self.code ? @"id" : @"id /* block */"; }
            else if (*p == '"') {
                p++;
                const char *start = p;
                while (*p && *p != '"') p++;
                NSString *cls = [[NSString alloc] initWithBytes:start length:(NSUInteger)(p - start)
                                                       encoding:NSUTF8StringEncoding] ?: @"";
                if (*p) p++;
                if (self.code) t = @"id";
                else if (cls.length == 0) t = @"id";
                else if ([cls hasPrefix:@"<"]) t = [@"id " stringByAppendingString:cls];
                else t = [cls stringByAppendingString:@" *"];
            } else t = @"id";
            if (self.code && field) t = [@"__unsafe_unretained " stringByAppendingString:t];
            break;
        case '^': {
            if (*p == '?') { p++; t = self.code ? @"void *" : @"void * /* function */"; break; }
            const char *q = p;
            while (*q && strchr("rnNoORVA", *q)) q++;
            if (*q == '{' || *q == '(' || *q == '[') {
                char open = *q;
                const char *nameStart = q + 1;
                NSString *name = DYIReadAggregateName(&nameStart, open == '{' ? '}' : ')');
                DYISkipType(&p);
                NSString *known = open == '{' ? DYIKnownPointers()[name] : nil;
                if (!known && open == '{' && DYIKnownStructs()[name]) known = [DYIKnownStructs()[name] stringByAppendingString:@" *"];
                if (known) t = known;
                else if (self.code) t = @"void *";
                else if (open == '{') t = [NSString stringWithFormat:@"struct %@ *", name];
                else if (open == '(') t = [NSString stringWithFormat:@"union %@ *", name];
                else t = @"void * /* array */";
                break;
            }
            NSString *saved = self.problem;
            NSString *pointee = [self typeAt:&p field:NO arraySuffix:NULL];
            self.problem = saved;   // anything behind a pointer can at least be passed as a pointer
            if (self.code && [pointee isEqualToString:@"id"]) t = field ? @"__unsafe_unretained id *" : @"id __autoreleasing *";
            else if (self.code && [pointee isEqualToString:@"Class"]) t = @"__unsafe_unretained Class *";
            else if (self.code && ([pointee hasPrefix:@"__unsafe_unretained"] || [pointee hasSuffix:@"__autoreleasing *"]))
                t = @"void *";
            else if ([pointee hasSuffix:@"*"]) t = [pointee stringByAppendingString:@"*"];
            else t = [pointee stringByAppendingString:@" *"];
            if (isConst && ![t hasPrefix:@"const "] && ![t hasSuffix:@"Ref"]) t = [@"const " stringByAppendingString:t];
            break;
        }
        case '{': {
            NSString *name = DYIReadAggregateName(&p, '}');
            NSMutableArray<NSString *> *fields = [NSMutableArray array];
            BOOL hasLayout = NO;
            if (*p == '=') {
                p++;
                hasLayout = YES;
                NSUInteger index = 0;
                while (*p && *p != '}') {
                    if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p) p++; continue; }   // field name
                    NSString *suffix = nil;
                    NSString *ft = [self typeAt:&p field:YES arraySuffix:&suffix];
                    NSString *sep = [ft hasSuffix:@"*"] ? @"" : @" ";
                    [fields addObject:[NSString stringWithFormat:@"%@%@f%lu%@;", ft, sep, (unsigned long)index++, suffix ?: @""]];
                }
            }
            if (*p == '}') p++;
            NSString *known = DYIKnownStructs()[name];
            if (known) { t = known; break; }
            if (!self.code) { t = [name isEqualToString:@"?"] ? @"struct {...}" : [@"struct " stringByAppendingString:name]; break; }
            if (!hasLayout || fields.count == 0) { [self fail:[NSString stringWithFormat:@"struct %@ without a known layout", name]]; t = @"void"; break; }
            NSString *body = [fields componentsJoinedByString:@" "];
            NSString *existing = self.typedefNames[body];
            if (existing) { t = existing; break; }
            NSString *tname = [name isEqualToString:@"?"]
                ? [NSString stringWithFormat:@"%@_Struct%lu", self.prefix, (unsigned long)self.typedefs.count + 1]
                : [NSString stringWithFormat:@"%@_%@", self.prefix, DYISanitize(name)];
            [self.typedefs addObject:[NSString stringWithFormat:@"typedef struct { %@ } %@;   // %@, same layout",
                                      body, tname, [name isEqualToString:@"?"] ? @"anonymous struct" : name]];
            self.typedefNames[body] = tname;
            t = tname;
            break;
        }
        case '(': {
            const char *q = p;
            NSString *name = DYIReadAggregateName(&q, ')');
            p--;   // back to '(' and skip the whole union
            DYISkipType(&p);
            [self fail:@"union"];
            t = [NSString stringWithFormat:@"union %@", name];
            break;
        }
        case '[': {
            unsigned long n = strtoul(p, (char **)&p, 10);
            NSString *elem = [self typeAt:&p field:field arraySuffix:NULL];
            if (*p == ']') p++;
            if (field && arraySuffix) { *arraySuffix = [NSString stringWithFormat:@"[%lu]", n]; t = elem; }
            else { [self fail:@"C array"]; t = [NSString stringWithFormat:@"%@[%lu]", elem, n]; }
            break;
        }
        case 'b': {
            unsigned long n = strtoul(p, (char **)&p, 10);
            [self fail:@"bitfield"];
            t = [NSString stringWithFormat:@"bitfield:%lu", n];
            break;
        }
        default:
            [self fail:[NSString stringWithFormat:@"unknown encoding '%c'", c]];
            t = @"?";
            break;
    }
    if (isConst && c != '*' && c != '^' && !self.code) t = [@"const " stringByAppendingString:t];
    *pp = p;
    return t;
}

- (NSString *)type:(const char *)encoding {
    if (!encoding || !*encoding) { [self fail:@"no type encoding"]; return @"?"; }
    const char *p = encoding;
    return [self typeAt:&p field:NO arraySuffix:NULL];
}

@end

NSString *DYIReadableType(const char *encoding) {
    if (!encoding || !*encoding) return @"?";
    DYITypeWriter *w = [DYITypeWriter new];
    return [w type:encoding];
}

#pragma mark - Methods, properties, ivars

@interface DYIMethodInfo ()
@property (nonatomic, readwrite) Class cls;
@property (nonatomic, readwrite) BOOL classMethod;
@property (nonatomic, readwrite) SEL selector;
@property (nonatomic, readwrite, copy) NSString *encoding;
@property (nonatomic, readwrite, copy) NSString *signature;
@property (nonatomic, readwrite, copy) NSString *image;
@property (nonatomic, readwrite, copy) NSString *imagePath;
@property (nonatomic, strong) NSArray<NSString *> *argEncodings;
@property (nonatomic, copy) NSString *returnEncoding;
@end
@implementation DYIMethodInfo
@end

@interface DYIPropertyInfo ()
@property (nonatomic, readwrite) Class cls;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite, copy) NSString *typeEncoding;
@property (nonatomic, readwrite, copy) NSString *readableType;
@property (nonatomic, readwrite, copy) NSString *attributes;
@property (nonatomic, readwrite) SEL getter;
@property (nonatomic, readwrite, copy) NSString *declaration;
@end
@implementation DYIPropertyInfo
@end

@interface DYIIvarInfo ()
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite, copy) NSString *readableType;
@property (nonatomic, readwrite) ptrdiff_t offset;
@end
@implementation DYIIvarInfo
@end

static NSString *DYICopyString(char *s) {
    if (!s) return @"";
    NSString *r = @(s);
    free(s);
    return r ?: @"";
}

static NSArray<NSString *> *DYISelectorParts(NSString *sel) {
    NSMutableArray *parts = [[sel componentsSeparatedByString:@":"] mutableCopy];
    if (parts.count > 1 && [parts.lastObject length] == 0) [parts removeLastObject];
    return parts;
}

static NSString *DYISignature(BOOL classMethod, NSString *sel, NSString *ret, NSArray<NSString *> *args) {
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@ (%@)", classMethod ? @"+" : @"-", ret];
    if (args.count == 0) { [s appendString:sel]; return s; }
    NSArray *parts = DYISelectorParts(sel);
    if (parts.count != args.count) {   // selector and encoding disagree; show both as they are
        [s appendFormat:@"%@ /* %lu args */", sel, (unsigned long)args.count];
        return s;
    }
    for (NSUInteger i = 0; i < args.count; i++) {
        [s appendFormat:@"%@%@:(%@)arg%lu", i ? @" " : @"", parts[i], args[i], (unsigned long)i + 1];
    }
    return s;
}

NSArray<DYIMethodInfo *> *DYIMethodsOfClass(Class cls, BOOL classMethods) {
    if (!cls) return @[];
    Class target = classMethods ? object_getClass(cls) : cls;
    unsigned int count = 0;
    Method *list = class_copyMethodList(target, &count);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int i = 0; i < count; i++) {
        Method m = list[i];
        DYIMethodInfo *info = [DYIMethodInfo new];
        info.cls = cls;
        info.classMethod = classMethods;
        info.selector = method_getName(m);
        const char *enc = method_getTypeEncoding(m);
        info.encoding = enc ? @(enc) : @"";
        info.returnEncoding = DYICopyString(method_copyReturnType(m));
        unsigned int nargs = method_getNumberOfArguments(m);
        NSMutableArray *argEnc = [NSMutableArray array];
        NSMutableArray *argTypes = [NSMutableArray array];
        for (unsigned int a = 2; a < nargs; a++) {
            NSString *e = DYICopyString(method_copyArgumentType(m, a));
            [argEnc addObject:e];
            [argTypes addObject:DYIReadableType(e.UTF8String)];
        }
        info.argEncodings = argEnc;
        info.signature = DYISignature(classMethods, NSStringFromSelector(info.selector),
                                      DYIReadableType(info.returnEncoding.UTF8String), argTypes);
        info.imagePath = DYIImageOfIMP(method_getImplementation(m));
        info.image = DYIShortImageName(info.imagePath);
        [out addObject:info];
    }
    free(list);
    [out sortUsingComparator:^NSComparisonResult(DYIMethodInfo *a, DYIMethodInfo *b) {
        return [NSStringFromSelector(a.selector) compare:NSStringFromSelector(b.selector)];
    }];
    return out;
}

NSArray<DYIPropertyInfo *> *DYIPropertiesOfClass(Class cls) {
    if (!cls) return @[];
    unsigned int count = 0;
    objc_property_t *list = class_copyPropertyList(cls, &count);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int i = 0; i < count; i++) {
        objc_property_t prop = list[i];
        DYIPropertyInfo *info = [DYIPropertyInfo new];
        info.cls = cls;
        info.name = @(property_getName(prop)) ?: @"?";
        char *type = property_copyAttributeValue(prop, "T");
        info.typeEncoding = type ? @(type) : @"";
        info.readableType = DYIReadableType(type);
        free(type);
        char *getter = property_copyAttributeValue(prop, "G");
        info.getter = getter ? sel_registerName(getter) : sel_registerName(property_getName(prop));
        free(getter);
        NSMutableArray *attrs = [NSMutableArray array];
        struct { const char *key; NSString *word; } flags[] = {
            {"R", @"readonly"}, {"C", @"copy"}, {"&", @"strong"}, {"W", @"weak"}, {"N", @"nonatomic"}, {"D", @"dynamic"}};
        for (size_t f = 0; f < sizeof flags / sizeof flags[0]; f++) {
            char *v = property_copyAttributeValue(prop, flags[f].key);
            if (v) { [attrs addObject:flags[f].word]; free(v); }
        }
        char *g = property_copyAttributeValue(prop, "G");
        if (g) { [attrs addObject:[NSString stringWithFormat:@"getter=%s", g]]; free(g); }
        info.attributes = [attrs componentsJoinedByString:@", "];
        NSString *t = info.readableType;
        info.declaration = [NSString stringWithFormat:@"@property %@%@%@%@", attrs.count ? [NSString stringWithFormat:@"(%@) ", info.attributes] : @"",
                            t, [t hasSuffix:@"*"] ? @"" : @" ", info.name];
        [out addObject:info];
    }
    free(list);
    [out sortUsingComparator:^NSComparisonResult(DYIPropertyInfo *a, DYIPropertyInfo *b) { return [a.name compare:b.name]; }];
    return out;
}

NSArray<DYIIvarInfo *> *DYIIvarsOfClass(Class cls) {
    if (!cls) return @[];
    unsigned int count = 0;
    Ivar *list = class_copyIvarList(cls, &count);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int i = 0; i < count; i++) {
        DYIIvarInfo *info = [DYIIvarInfo new];
        const char *name = ivar_getName(list[i]);
        info.name = name ? @(name) : @"?";
        const char *type = ivar_getTypeEncoding(list[i]);
        info.readableType = (type && *type) ? DYIReadableType(type) : @"(no encoding: swift)";
        info.offset = ivar_getOffset(list[i]);
        [out addObject:info];
    }
    free(list);
    return out;
}

NSArray<NSString *> *DYIProtocolsOfClass(Class cls) {
    if (!cls) return @[];
    unsigned int count = 0;
    Protocol *__unsafe_unretained *list = class_copyProtocolList(cls, &count);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:count];
    for (unsigned int i = 0; i < count; i++) [out addObject:@(protocol_getName(list[i]))];
    free(list);
    [out sortUsingSelector:@selector(compare:)];
    return out;
}

#pragma mark - Hook skeletons

typedef NS_ENUM(NSInteger, DYIFamily) { DYIFamilyNone, DYIFamilyRetained, DYIFamilyInit };

/// ARC's method family of a selector: the first camel-case word after leading underscores.
static DYIFamily DYIMethodFamily(NSString *sel, BOOL classMethod) {
    NSUInteger i = 0;
    while (i < sel.length && [sel characterAtIndex:i] == '_') i++;
    NSString *s = [sel substringFromIndex:i];
    NSArray *words = @[@"alloc", @"copy", @"mutableCopy", @"new", @"init"];
    for (NSString *w in words) {
        if (![s hasPrefix:w]) continue;
        if (s.length > w.length) {
            unichar next = [s characterAtIndex:w.length];
            if (next >= 'a' && next <= 'z') continue;   // "newline", "copyright", "initiate" are not in the family
        }
        if ([w isEqualToString:@"init"]) return classMethod ? DYIFamilyNone : DYIFamilyInit;
        return DYIFamilyRetained;
    }
    return DYIFamilyNone;
}

/// A guess: methods that take a format or a nil-terminated list are variadic, which an encoding doesn't show.
static BOOL DYILooksVariadic(NSString *sel, NSArray<NSString *> *argEncodings) {
    NSArray *parts = DYISelectorParts(sel);
    if (argEncodings.count == 0 || ![argEncodings.lastObject hasPrefix:@"@"]) return NO;
    NSString *last = parts.lastObject;
    if ([sel hasPrefix:@"set"] && parts.count == 1) return NO;   // setDateFormat:, setObjects:
    return [last hasSuffix:@"Format"] || [last isEqualToString:@"format"] || [last hasSuffix:@"WithObjects"] ||
           [last hasSuffix:@"ObjectsAndKeys"] || [last isEqualToString:@"arrayWithObjects"];
}

static BOOL DYIIsIdentifier(NSString *s) {
    if (s.length == 0) return NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar ch = [s characterAtIndex:i];
        BOOL ok = ch < 128 && (isalnum((int)ch) || ch == '_');
        if (!ok || (i == 0 && isdigit((int)ch))) return NO;
    }
    return YES;
}

/// The hook class's superclass: the target's nearest public superclass (a class from a public system framework
/// whose name doesn't start with '_'), so `self.frame` and friends compile in the hook; otherwise NSObject.
static NSString *DYIHookSuperclass(Class target) {
    for (Class c = class_getSuperclass(target); c; c = class_getSuperclass(c)) {
        NSString *name = NSStringFromClass(c);
        NSString *image = DYIImageOfClass(c);
        BOOL publicImage = [image hasPrefix:@"/System/Library/Frameworks/"] || [image hasPrefix:@"/usr/lib/"];
        if (publicImage && DYIIsIdentifier(name) && ![name hasPrefix:@"_"] && ![name hasPrefix:@"NSKVONotifying"])
            return name;
    }
    return @"NSObject";
}

NSString *DYIHookSkeleton(DYIMethodInfo *m) {
    NSString *targetName = NSStringFromClass(m.cls) ?: @"?";
    NSString *sel = NSStringFromSelector(m.selector);
    NSString *hookName = [NSString stringWithFormat:@"MY%@Hook", DYISanitize(targetName)];
    NSString *mark = m.classMethod ? @"+" : @"-";
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"// %@[%@ %@]   %@   encoding %@\n", mark, targetName, sel, m.image, m.encoding];

    NSString *why = nil;
    NSArray *parts = DYISelectorParts(sel);
    BOOL partsOK = YES;
    for (NSString *part in parts) if (!DYIIsIdentifier(part) && !(part.length == 0 && parts.count > 1)) partsOK = NO;
    if (!partsOK) why = @"the selector isn't an Objective-C identifier";
    else if (parts.count > 1 || [sel hasSuffix:@":"]) { if (parts.count != m.argEncodings.count) why = @"the selector and the type encoding disagree on the number of arguments"; }
    else if (m.argEncodings.count != 0) why = @"the selector and the type encoding disagree on the number of arguments";
    if (!why && [@[@"dealloc"] containsObject:sel] && !m.classMethod)
        why = @"a hook class can't hook -dealloc; use DHHookMessage with a C function (docs/hooking.md, ARC ownership)";
    if (!why && [@[@"retain", @"release", @"autorelease", @"retainCount"] containsObject:sel])
        why = @"ARC doesn't allow implementing retain/release methods";
    if (!why && m.classMethod && [@[@"load", @"initialize"] containsObject:sel])
        why = @"DHHookClass never installs +load or +initialize";
    if (!why && DYILooksVariadic(sel, m.argEncodings))
        why = @"it looks variadic (a format or a nil-terminated list), which a type encoding can't show; a fixed signature would read garbage on arm64";

    DYITypeWriter *w = [DYITypeWriter new];
    w.code = YES;
    w.prefix = hookName;
    NSString *ret = [w type:m.returnEncoding.UTF8String];
    NSMutableArray<NSString *> *args = [NSMutableArray array];
    for (NSString *e in m.argEncodings) [args addObject:[w type:e.UTF8String]];
    if (!why && w.problem) why = [NSString stringWithFormat:@"its types can't be written exactly in C (%@)", w.problem];

    if (why) {
        [out appendFormat:@"// no hook class for this method: %@.\n", why];
        [out appendFormat:@"// signature: %@\n", m.signature];
        return out;
    }

    for (NSString *t in w.typedefs) [out appendFormat:@"%@\n", t];
    NSString *superName = DYIHookSuperclass(m.cls);
    // The superclass may declare the method with more precise pointer types (NSError ** for id *, Foo * for void *).
    BOOL pointers = [ret hasSuffix:@"*"];
    for (NSString *a in args) if ([a hasSuffix:@"*"]) pointers = YES;
    [out appendFormat:@"@interface %@ : %@ @end\n", hookName, superName];
    if (pointers) [out appendString:@"#pragma clang diagnostic push\n#pragma clang diagnostic ignored \"-Wmismatched-parameter-types\"\n"
                                    @"#pragma clang diagnostic ignored \"-Wmismatched-return-types\"\n"];
    [out appendFormat:@"@implementation %@\n", hookName];

    // - (ret)part1:(T1)arg1 part2:(T2)arg2
    NSMutableString *decl = [NSMutableString stringWithFormat:@"%@ (%@)", mark, ret];
    if (args.count == 0) [decl appendString:sel];
    for (NSUInteger i = 0; i < args.count; i++)
        [decl appendFormat:@"%@%@:(%@)arg%lu", i ? @" " : @"", parts[i], args[i], (unsigned long)i + 1];

    NSMutableArray *fnArgs = [NSMutableArray arrayWithObjects:@"id", @"SEL", nil];
    [fnArgs addObjectsFromArray:args];
    NSMutableArray *callArgs = [NSMutableArray array];
    for (NSUInteger i = 0; i < args.count; i++) [callArgs addObject:[NSString stringWithFormat:@"arg%lu", (unsigned long)i + 1]];
    NSString *callTail = callArgs.count ? [@", " stringByAppendingString:[callArgs componentsJoinedByString:@", "]] : @"";

    BOOL objectReturn = [ret isEqualToString:@"id"];
    DYIFamily family = objectReturn ? DYIMethodFamily(sel, m.classMethod) : DYIFamilyNone;
    BOOL isVoid = [ret isEqualToString:@"void"];
    NSString *fnType;
    [out appendFormat:@"%@ {\n", decl];
    if (family != DYIFamilyNone) {
        // +1 result (and a consumed self for init): docs/hooking.md#arc-ownership-methods-that-return-a-retained-object
        NSMutableArray *typedArgs = [fnArgs mutableCopy];
        if (family == DYIFamilyInit) typedArgs[0] = @"id __attribute__((ns_consumed))";
        [out appendFormat:@"    typedef id (*OrigFn)(%@) __attribute__((ns_returns_retained));\n",
                          [typedArgs componentsJoinedByString:@", "]];
        fnType = @"OrigFn";
    } else {
        fnType = [NSString stringWithFormat:@"%@ (*)(%@)", ret, [fnArgs componentsJoinedByString:@", "]];
    }
    if (isVoid) {
        [out appendFormat:@"    DH_ORIG(%@%@);\n", fnType, callTail];
    } else {
        NSString *sep = [ret hasSuffix:@"*"] ? @"" : @" ";
        [out appendFormat:@"    %@%@r = DH_ORIG(%@%@);\n    return r;\n", ret, sep, fnType, callTail];
    }
    [out appendString:@"}\n@end\n"];
    if (pointers) [out appendString:@"#pragma clang diagnostic pop\n"];
    [out appendFormat:@"// in your DH_CTOR body:\n//   DHHookClass([%@ class], DHClass(\"%@\"), NULL);\n", hookName, targetName];
    return out;
}

#pragma mark - Values

NSString *DYIPointerString(id object) {
    if (!object) return @"nil";
    return [NSString stringWithFormat:@"<%s %p>", object_getClassName(object), (__bridge void *)object];
}

NSString *DYIDescribeCGColor(CGColorRef color) {
    if (!color) return @"(none)";
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef c = CGColorCreateCopyByMatchingToColorSpace(srgb, kCGRenderingIntentDefault, color, NULL);
    CGColorSpaceRelease(srgb);
    NSString *out;
    if (c && CGColorGetNumberOfComponents(c) >= 4) {
        const CGFloat *k = CGColorGetComponents(c);
        int r = (int)lround(fmin(fmax(k[0], 0), 1) * 255), g = (int)lround(fmin(fmax(k[1], 0), 1) * 255);
        int b = (int)lround(fmin(fmax(k[2], 0), 1) * 255);
        out = [NSString stringWithFormat:@"#%02X%02X%02X alpha %.2f", r, g, b, k[3]];
    } else {
        out = [NSString stringWithFormat:@"CGColor (%zu components, not convertible to sRGB)", CGColorGetNumberOfComponents(color)];
    }
    if (c) CGColorRelease(c);
    return out;
}

static NSString *DYITruncate(NSString *s, NSUInteger max) {
    s = [[s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
    return s.length > max ? [[s substringToIndex:max] stringByAppendingString:@"…"] : s;
}

NSString *DYIDescriptionOf(id object, NSUInteger maxLength) {
    if (!object) return @"nil";
    __block NSString *d = nil;
    NSString *err = DYITry(^{ d = [object description]; });
    if (err) return [NSString stringWithFormat:@"%@ (description raised %@)", DYIPointerString(object), err];
    return DYITruncate(d ?: @"(nil description)", maxLength);
}

NSString *DYIDescribe(id v) {
    if (!v) return @"nil";
    if (object_isClass(v)) return [NSString stringWithFormat:@"Class %s", class_getName((Class)v)];
    __block NSString *out = nil;
    NSString *err = DYITry(^{
        if ([v isKindOfClass:[NSString class]]) { out = [NSString stringWithFormat:@"\"%@\"", DYITruncate(v, 300)]; return; }
        if ([v isKindOfClass:[NSAttributedString class]]) {
            out = [NSString stringWithFormat:@"attributed \"%@\"", DYITruncate([(NSAttributedString *)v string], 300)];
            return;
        }
        if ([v isKindOfClass:[NSNumber class]]) {
            if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID()) out = [v boolValue] ? @"YES" : @"NO";
            else out = [(NSNumber *)v stringValue];
            return;
        }
        if ([v isKindOfClass:[NSValue class]]) {
            NSValue *val = v;
            const char *t = val.objCType;
            if (strncmp(t, "{CGRect=", 8) == 0) out = NSStringFromRect(val.rectValue);
            else if (strncmp(t, "{CGPoint=", 9) == 0) out = NSStringFromPoint(val.pointValue);
            else if (strncmp(t, "{CGSize=", 8) == 0) out = NSStringFromSize(val.sizeValue);
            else if (strncmp(t, "{_NSRange=", 10) == 0) out = NSStringFromRange(val.rangeValue);
            else if (strncmp(t, "{CATransform3D=", 15) == 0) {
                CATransform3D m = val.CATransform3DValue;
                out = CATransform3DIsIdentity(m) ? @"identity" : [NSString stringWithFormat:@"[%g %g %g %g; %g %g %g %g; %g %g %g %g; %g %g %g %g]",
                    m.m11, m.m12, m.m13, m.m14, m.m21, m.m22, m.m23, m.m24, m.m31, m.m32, m.m33, m.m34, m.m41, m.m42, m.m43, m.m44];
            } else if (strncmp(t, "{CGAffineTransform=", 19) == 0) {
                CGAffineTransform a;
                [val getValue:&a size:sizeof a];
                out = [NSString stringWithFormat:@"[%g %g %g %g %g %g]", a.a, a.b, a.c, a.d, a.tx, a.ty];
            } else if (strncmp(t, "{NSEdgeInsets=", 14) == 0) {
                NSEdgeInsets e = val.edgeInsetsValue;
                out = [NSString stringWithFormat:@"{top %g, left %g, bottom %g, right %g}", e.top, e.left, e.bottom, e.right];
            } else out = [NSString stringWithFormat:@"%@ (%s)", DYIReadableType(t), t];
            return;
        }
        if ([v isKindOfClass:[NSArray class]] || [v isKindOfClass:[NSSet class]] || [v isKindOfClass:[NSOrderedSet class]] ||
            [v isKindOfClass:[NSDictionary class]]) {
            out = [NSString stringWithFormat:@"%s (%lu items)", object_getClassName(v), (unsigned long)[v count]];
            return;
        }
        if ([v isKindOfClass:[NSColor class]]) { out = DYITruncate([v description], 200); return; }
        if ([v isKindOfClass:[NSFont class]]) { out = [NSString stringWithFormat:@"%@ %gpt", [v fontName], [(NSFont *)v pointSize]]; return; }
        if ([v isKindOfClass:[NSImage class]]) { out = [NSString stringWithFormat:@"NSImage %@", NSStringFromSize([(NSImage *)v size])]; return; }
        if ([v isKindOfClass:[NSAppearance class]]) { out = [NSString stringWithFormat:@"NSAppearance %@", [(NSAppearance *)v name]]; return; }
        if ([v isKindOfClass:[NSURL class]]) { out = DYITruncate([(NSURL *)v absoluteString], 300); return; }
        if ([v isKindOfClass:[NSDate class]]) { out = [v description]; return; }
        if (CFGetTypeID((__bridge CFTypeRef)v) == CGColorGetTypeID()) { out = DYIDescribeCGColor((__bridge CGColorRef)v); return; }
    });
    if (err) return [NSString stringWithFormat:@"%@ (%@)", DYIPointerString(v), err];
    return out ?: DYIPointerString(v);
}

/// The first type character after qualifiers.
static char DYITypeChar(const char *enc) {
    while (enc && *enc && strchr("rnNoORVA", *enc)) enc++;
    return enc ? *enc : 0;
}

NSString *DYIEvaluateProperty(id object, DYIPropertyInfo *property, id *outValue) {
    if (outValue) *outValue = nil;
    if (!object) return @"(no instance)";
    SEL getter = property.getter;
    NSString *getterName = NSStringFromSelector(getter);
    __block BOOL responds = NO;
    NSString *err = DYITry(^{ responds = [object respondsToSelector:getter]; });
    if (err || !responds) return @"(no getter)";
    if ([getterName containsString:@":"]) return @"(getter takes arguments)";
    const char *enc = property.typeEncoding.UTF8String;
    char c = DYITypeChar(enc);
    __block id value = nil;
    __block NSString *text = nil;
    if (c == '@' || c == '#') {
        err = DYITry(^{ value = ((id (*)(id, SEL))objc_msgSend)(object, getter); });
        if (!err) { text = DYIDescribe(value); if (outValue) *outValue = value; }
    } else if (c == '^' || c == '*') {
        __block void *ptr = NULL;
        err = DYITry(^{ ptr = ((void *(*)(id, SEL))objc_msgSend)(object, getter); });
        if (!err) {
            // CGColor is common enough (CALayer, CASDF effects) to show its components.
            if (ptr && strncmp(enc + (enc[0] == 'r'), "^{CGColor=", 10) == 0) text = DYIDescribeCGColor((CGColorRef)ptr);
            else text = ptr ? [NSString stringWithFormat:@"%p (%@)", ptr, property.readableType] : @"NULL";
        }
    } else if (c == ':') {
        __block SEL s = NULL;
        err = DYITry(^{ s = ((SEL (*)(id, SEL))objc_msgSend)(object, getter); });
        if (!err) text = s ? [@"@selector " stringByAppendingString:NSStringFromSelector(s)] : @"NULL";
    } else if (c && strchr("cCsSiIlLqQfdB{", c)) {
        if (c == '{') {   // KVC boxes any struct in an NSValue, but only one it can describe the layout of
            DYITypeWriter *w = [DYITypeWriter new];
            w.code = YES;
            [w type:enc];
            if (w.problem) return [NSString stringWithFormat:@"(can't read: %@)", w.problem];
        }
        err = DYITry(^{ value = [object valueForKey:getterName]; });
        if (!err) text = DYIDescribe(value);
    } else {
        return [NSString stringWithFormat:@"(can't read %@)", property.readableType];
    }
    if (err) return [@"exception: " stringByAppendingString:err];
    return text ?: @"nil";
}

#pragma mark - Class list

void DYILoadClassNames(void (^done)(NSArray<NSString *> *names)) {
    static NSArray<NSString *> *cache;
    static NSMutableArray *waiting;
    if (cache) { done(cache); return; }
    if (waiting) { [waiting addObject:[done copy]]; return; }
    waiting = [NSMutableArray arrayWithObject:[done copy]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Names per image: unlike objc_copyClassList this doesn't realize every class in the process.
        NSMutableSet<NSString *> *names = [NSMutableSet set];
        unsigned int imageCount = 0;
        const char **images = objc_copyImageNames(&imageCount);
        for (unsigned int i = 0; i < imageCount; i++) {
            unsigned int n = 0;
            const char **classes = objc_copyClassNamesForImage(images[i], &n);
            for (unsigned int k = 0; k < n; k++) [names addObject:@(classes[k])];
            free(classes);
        }
        free(images);
        NSArray *sorted = [names.allObjects sortedArrayUsingSelector:@selector(compare:)];
        dispatch_async(dispatch_get_main_queue(), ^{
            cache = sorted;
            NSArray *blocks = waiting;
            waiting = nil;
            for (void (^b)(NSArray *) in blocks) b(cache);
        });
    });
}
