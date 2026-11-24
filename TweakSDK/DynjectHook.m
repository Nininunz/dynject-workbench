// DynjectHook.m — implementation of DynjectHook.h. Compile with -fobjc-arc.
//
// Design notes
// - No Objective-C classes are defined here and every external symbol is hidden (DH_HIDDEN in the
//   header), so several tweaks in one process can each compile this file.
// - One os_unfair_lock (sLock) guards the registry. While it is held this file only calls runtime
//   functions that cannot run foreign code: method_getImplementation, class_replaceMethod (on methods the
//   class defines), class_addMethod, class_copyMethodList, class_getSuperclass, sel_getName, and
//   class_getInstanceMethod for methods already known to exist (it consults the method resolver only
//   when the lookup fails, and never sends +initialize). Lookups that may run +initialize or a
//   resolver, user blocks and logging all happen outside the lock.
// - A second os_unfair_lock is shared by every copy of this file in the process (DHProcessLock) and
//   held, outside sLock, wherever a method's implementation is read and then written, so that two
//   tweaks toggling hooks on the same method cannot overwrite each other's replacement.
// - Every hooked method has a site record with all hooks this registry has on it, in install order.
//   That is what lets a hook that was disabled go back to its place among them whatever happened to
//   the others meanwhile (DHEnableLocked), and what tells an override that merely holds a copy of
//   the superclass implementation from a method the class defines (DHPutOnTopLocked).
// - The fields of a hook that a replacement reads on every call (original, kind, active) are
//   atomics, so DHOriginal() and DHHookIsActive() never take the lock.
// - Hooks, groups and hook-class records are never freed: handed-out handles stay valid for the
//   life of the process.
#import "DynjectHook.h"

#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <objc/objc-sync.h>
#import <os/lock.h>
#import <os/log.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <notify.h>
#import <stdarg.h>
#import <string.h>

#if !__has_feature(objc_arc)
#error DynjectHook.m must be compiled with -fobjc-arc
#endif

#pragma mark - Logging

static os_unfair_lock sLogLock = OS_UNFAIR_LOCK_INIT;
static char *sLogSubsystem;   // NULL: the default subsystem. Guarded by sLogLock.
static os_log_t sLogHandle;   // Created lazily for sLogSubsystem. Guarded by sLogLock.

void DHSetLogSubsystem(const char *subsystem) {
    char *copy = (subsystem && subsystem[0]) ? strdup(subsystem) : NULL;
    os_unfair_lock_lock(&sLogLock);
    char *previous = sLogSubsystem;
    sLogSubsystem = copy;
    sLogHandle = nil;
    os_unfair_lock_unlock(&sLogLock);
    free(previous);
}

static os_log_t DHLogHandle(void) {
    os_unfair_lock_lock(&sLogLock);
    if (!sLogHandle) sLogHandle = os_log_create(sLogSubsystem ?: "dynject.hook", "hook");
    os_log_t handle = sLogHandle;
    os_unfair_lock_unlock(&sLogLock);
    return handle;
}

void DHLogFormat(NSString *format, ...) {
    if (!format) return;
    NSString *message = nil;
    va_list arguments;
    va_start(arguments, format);
    @try {
        message = [[NSString alloc] initWithFormat:format arguments:arguments];
    } @catch (...) {
        message = nil;   // A -description that raises must not take the host app down.
    }
    va_end(arguments);
    os_log_with_type(DHLogHandle(), OS_LOG_TYPE_DEFAULT, "%{public}@",
                     message ?: @"(log message could not be formatted)");
}

// Arguments for a "%c[%s %s]" format describing a method of `cls` (a metaclass for class methods).
#define DH_METHOD_ARGS(cls, sel) (class_isMetaClass(cls) ? '+' : '-'), class_getName(cls), sel_getName(sel)

#pragma mark - Registry types

// What lies directly beneath a hook in its method's chain of implementations.
enum {
    DHHookKindNone = 0,        // not installed yet (created while its group was disabled)
    DHHookKindOwn = 1,         // `original`: the implementation the hook was put on top of
    DHHookKindInherited = 2,   // the superclass's implementation, resolved per call: the hook is the
                               // bottom of a method this registry added to a class that only inherited it
};

// Where a hook's replacement currently is. Guarded by sLock.
typedef enum {
    DHHookStatePending = 0,   // never installed
    DHHookStateInstalled,     // the replacement is in the method (possibly beneath later hooks)
    DHHookStateRestored,      // group disabled: the method was set back to `restored`
    DHHookStateBuried,        // group disabled, but a later hook sits on top: left installed
} DHHookState;

typedef struct DHSite DHSite;

struct DHHook {
    // Immutable after creation.
    __unsafe_unretained Class cls;
    SEL sel;
    IMP replacement;
    const char *types;        // type encoding of the method found at creation
    DHGroup *group;           // NULL: ungrouped
    DHSite *site;
    // Read without the lock by DHOriginal() and DHHookIsActive(); written under sLock.
    _Atomic(IMP) original;
    _Atomic(int) kind;
    atomic_bool active;
    // Guarded by sLock.
    DHHookState state;
    IMP restored;             // what the method was set to when the hook was disabled
    uint64_t order;           // place in this registry's install sequence; 0 until first installed
    DHHook **handle;          // DHHookMessageEx: where the handle goes before the replacement is live
    struct DHHook *nextAtSite;
};

// One hooked method: what this registry knows about the implementation of `sel` in `cls`.
struct DHSite {
    __unsafe_unretained Class cls;
    SEL sel;
    DHHook *hooks;            // every hook of this registry on the method, newest first
    IMP top;                  // the implementation this registry last wrote into the method
    IMP superCopy;            // not NULL while the method is an override this registry added whose hooks
                              // are all out: the copy of the superclass implementation written into it
    DHSite *next;
};

struct DHGroup {
    char *name;
    atomic_bool enabled;      // written under sLock
    DHHook **hooks;           // install order; guarded by sLock
    size_t count;
    size_t capacity;
    struct DHImportHook **imports;   // install order; guarded by sImportLock
    size_t importCount;
    size_t importCapacity;
};

// A class passed to DHHookClass as `source`.
typedef struct DHSource {
    __unsafe_unretained Class cls;
    const char *name;                  // class_getName(cls)
    size_t nameLength;
    CFMutableDictionaryRef hooks[2];   // SEL -> DHHook *; [0] instance methods, [1] class methods
    struct DHSource *next;
} DHSource;

// Which of a hook class's two tables a function's hook is in. A C++ lambda's name does not say:
// then the receiver decides (a class object: the class-method table).
enum { DHMethodKindInstance = 0, DHMethodKindClass = 1, DHMethodKindByReceiver = 2 };

// A parsed __PRETTY_FUNCTION__, cached by the string's address.
typedef struct {
    char *text;                        // copy of the string, to detect a reused address
    DHSource *source;
    int methodKind;                    // DHMethodKind...
    size_t selectorOffset;             // where `text` spells the selector the method was compiled for
    size_t selectorLength;
    SEL selector;                      // that selector, once a hook of `source` for it has been seen
} DHParsedFunction;

// A DHWhenClassLoads registration whose class does not exist yet.
typedef struct DHPending {
    uint64_t serial;
    char *name;
    void *block;                       // retained copy of a void (^)(Class)
    struct DHPending *next;
} DHPending;

static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
// All guarded by sLock.
static DHSource *sSources;
static DHSite *sSites;
static size_t sSuperCopyCount;                    // how many sites have a superCopy
static uint64_t sInstallOrder;
static CFMutableDictionaryRef sParsedFunctions;   // const char * -> DHParsedFunction *
static DHPending *sPending;                       // registration order
static uint64_t sPendingSerial;
static BOOL sImageCallbackRegistered;
static char *sTestPreferencesDomain;
static char *sTestBundleIdentifier;
static char *sTestSystemVersion;

static const CFIndex kDHParsedFunctionLimit = 4096;

static void DHReportRegister(void);   // Hook reports, below
static void DHLogHookMap(void *replacement, const char *target);   // Hook reports, below

#pragma mark - The process-wide lock

// sLock serializes one copy of this file, but every tweak has its own copy, and installing, disabling
// and enabling a hook all read a method's implementation and then write it. Two copies doing that to
// the same method at once would overwrite each other's replacement, so all copies in a process share
// one more lock, held around every such read-and-write (always taken before sLock, and like sLock
// never while foreign code runs). The copies cannot share a symbol; they meet at an associated object
// of the NSObject class, under a key that is a selector (selectors are unique per process), holding
// the address of a heap-allocated os_unfair_lock.
static os_unfair_lock sLocalProcessLock = OS_UNFAIR_LOCK_INIT;   // stand-in if the shared lock cannot be set up
static _Atomic(os_unfair_lock *) sProcessLock;

static os_unfair_lock *DHProcessLock(void) {
    os_unfair_lock *lock = atomic_load(&sProcessLock);
    if (lock) return lock;
    id host = (id)objc_getClass("NSObject");
    const void *key = sel_registerName("dynject.hook.process-lock.v1");
    if (host && key && objc_sync_enter(host) == OBJC_SYNC_SUCCESS) {
        id boxed = objc_getAssociatedObject(host, key);
        CFTypeRef box = (__bridge CFTypeRef)boxed;
        if (!box) {
            os_unfair_lock *fresh = malloc(sizeof(os_unfair_lock));
            CFDataRef created = fresh ? CFDataCreate(kCFAllocatorDefault, (const UInt8 *)&fresh, sizeof(fresh)) : NULL;
            if (created) {
                *fresh = OS_UNFAIR_LOCK_INIT;
                objc_setAssociatedObject(host, key, (__bridge id)created, OBJC_ASSOCIATION_RETAIN);
                CFRelease(created);
                lock = fresh;   // never freed: other copies hold its address
            } else {
                free(fresh);
            }
        } else if (CFGetTypeID(box) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)box) == (CFIndex)sizeof(lock)) {
            memcpy(&lock, CFDataGetBytePtr((CFDataRef)box), sizeof(lock));
        }
        objc_sync_exit(host);
    }
    if (!lock) lock = &sLocalProcessLock;
    atomic_store(&sProcessLock, lock);
    return lock;
}

#pragma mark - Installing

typedef enum { DHInstallDone, DHInstallMissing, DHInstallDuplicate } DHInstallResult;

// Whether `cls` itself (not a superclass) has a method for `sel`. Never runs foreign code.
static BOOL DHClassDefinesMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count && !found; i++) found = (method_getName(methods[i]) == sel);
    free(methods);
    return found;
}

// The implementation `cls` would inherit for `sel`, i.e. class_getMethodImplementation(superclass,
// sel), found without running +initialize. The method is known to exist, so no resolver runs.
static IMP DHSuperImplementationLocked(Class cls, SEL sel) {
    Class superclass = class_getSuperclass(cls);
    Method method = superclass ? class_getInstanceMethod(superclass, sel) : NULL;
    return method ? method_getImplementation(method) : NULL;
}

static DHSite *DHSiteLocked(Class cls, SEL sel) {
    for (DHSite *site = sSites; site; site = site->next) {
        if (site->cls == cls && site->sel == sel) return site;
    }
    return NULL;
}

// DHHookMessageEx: the caller's handle variable is written before the replacement can be reached.
static void DHStoreHandleLocked(DHHook *hook) {
    if (hook->handle) __atomic_store_n(hook->handle, hook, __ATOMIC_RELEASE);
}

static void DHSiteSetSuperCopyLocked(DHSite *site, IMP copy) {
    if (copy && !site->superCopy) sSuperCopyCount++;
    if (!copy && site->superCopy) sSuperCopyCount--;
    site->superCopy = copy;
}

// Sets the implementation of `method`, which `cls` itself defines, and returns the previous one.
// class_replaceMethod rather than method_setImplementation: given the class, the runtime flushes only
// that class's method caches (and its subclasses'), instead of every realized class's in the process,
// which made group toggles take seconds in class-heavy apps. Every caller passes a method its hook's
// class defines (the class had it, or this file added it, and methods are never removed), so this
// never adds a method.
static IMP DHSetImplementationLocked(Class cls, Method method, IMP imp) {
    return class_replaceMethod(cls, method_getName(method), imp, method_getTypeEncoding(method));
}

// Makes the hook's replacement the method's implementation, on top of `current` (the implementation
// read just before). `kind` and `original` are published before the replacement becomes reachable,
// so a call racing in from another thread already finds them.
static void DHPutOnTopLocked(DHHook *hook, Method method, IMP current) {
    DHSite *site = hook->site;
    // On top of our own copy of the superclass implementation the hook is the bottom of an added
    // method, just like the hook that added it: its original is the superclass's, looked up per call.
    BOOL bottom = (site->superCopy && current == site->superCopy);
    if (bottom) {
        atomic_store(&hook->kind, DHHookKindInherited);
    } else {
        atomic_store(&hook->original, current);
        atomic_store(&hook->kind, DHHookKindOwn);
    }
    DHStoreHandleLocked(hook);
    IMP previous = DHSetImplementationLocked(site->cls, method, hook->replacement);
    if (previous && previous != current && previous != hook->replacement) {
        // Code outside every DynjectHook copy changed the method between the read and the write:
        // what was really there is the original.
        atomic_store(&hook->original, previous);
        atomic_store(&hook->kind, DHHookKindOwn);
    }
    if (bottom) DHSiteSetSuperCopyLocked(site, NULL);
    site->top = hook->replacement;
    hook->state = DHHookStateInstalled;
}

// Installs a hook for the first time.
static DHInstallResult DHInstallLocked(DHHook *hook) {
    Class cls = hook->cls;
    SEL sel = hook->sel;
    if (!DHClassDefinesMethod(cls, sel)) {
        // The class already runs this replacement through inheritance: as an override it would look
        // its original up in the superclass and find itself.
        if (DHSuperImplementationLocked(cls, sel) == hook->replacement) return DHInstallDuplicate;
        atomic_store(&hook->kind, DHHookKindInherited);
        DHStoreHandleLocked(hook);
        if (class_addMethod(cls, sel, hook->replacement, hook->types ?: "")) {
            hook->site->top = hook->replacement;
            hook->state = DHHookStateInstalled;
            hook->order = ++sInstallOrder;
            return DHInstallDone;
        }
        // Somebody outside this registry added the method in the meantime: hook it as cls's own.
    }
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        atomic_store(&hook->kind, DHHookKindNone);
        return DHInstallMissing;
    }
    IMP current = method_getImplementation(method);
    if (current == hook->replacement) {
        atomic_store(&hook->kind, DHHookKindNone);
        return DHInstallDuplicate;   // would make the replacement its own original
    }
    DHPutOnTopLocked(hook, method, current);
    hook->order = ++sInstallOrder;
    return DHInstallDone;
}

// An override we added cannot be removed again, so while all its hooks are out it holds a copy of
// the superclass implementation (the site's superCopy). Call this after changing any implementation:
// it brings those copies up to date, so that such an override keeps behaving like no override at all
// when hooks above it come and go (including hooks of the same group, which are disabled after it).
static void DHRefreshSuperCopiesLocked(void) {
    BOOL changed = (sSuperCopyCount > 0);
    // Overrides can sit above one another, so repeat until nothing moves (bounded by their number).
    for (size_t pass = 0; changed && pass <= sSuperCopyCount; pass++) {
        changed = NO;
        for (DHSite *site = sSites; site; site = site->next) {
            IMP copy = site->superCopy;
            if (!copy) continue;
            Method method = class_getInstanceMethod(site->cls, site->sel);
            IMP inherited = DHSuperImplementationLocked(site->cls, site->sel);
            if (!method || !inherited || inherited == copy) continue;
            if (method_getImplementation(method) != copy) continue;   // hooked over by someone else
            IMP previous = DHSetImplementationLocked(site->cls, method, inherited);
            if (previous != copy) {
                // Changed under our hands by code outside every DynjectHook copy: leave it theirs.
                DHSetImplementationLocked(site->cls, method, previous);
                continue;
            }
            for (DHHook *hook = site->hooks; hook; hook = hook->nextAtSite) {
                if (hook->state == DHHookStateRestored && hook->restored == copy) hook->restored = inherited;
            }
            site->superCopy = inherited;
            site->top = inherited;
            changed = YES;
        }
    }
}

static BOOL DHGroupReserveLocked(DHGroup *group) {
    if (group->count < group->capacity) return YES;
    size_t capacity = group->capacity ? group->capacity * 2 : 8;
    DHHook **hooks = realloc(group->hooks, capacity * sizeof(DHHook *));
    if (!hooks) return NO;
    group->hooks = hooks;
    group->capacity = capacity;
    return YES;
}

// DHHookMessageEx, plus the hook-class bookkeeping when `source` is not NULL. The hook is entered in
// the source's table before it is installed, so DH_ORIG works from the very first call.
static DHHook *DHHookCreate(Class cls, SEL sel, IMP replacement, DHGroup *group, DHHook **handle,
                            DHSource *source, BOOL isClassMethod) {
    DHReportRegister();   // a copy that hooks something answers dw hooks, DH_CTOR or not
    if (!cls || !sel || !replacement) {
        DHLog(@"DHHookMessage: class, selector and replacement must not be NULL (class %s, selector %s, replacement %p)",
              cls ? class_getName(cls) : "NULL", sel ? sel_getName(sel) : "NULL", (void *)replacement);
        return NULL;
    }
    // Outside the lock: this may run a method resolver.
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        DHLog(@"DHHookMessage: %c[%s %s] not hooked: the class does not respond to the selector",
              DH_METHOD_ARGS(cls, sel));
        return NULL;
    }
    DHHook *hook = calloc(1, sizeof(DHHook));
    DHSite *spareSite = calloc(1, sizeof(DHSite));   // used if this is the method's first hook
    if (!hook || !spareSite) {
        free(hook);
        free(spareSite);
        DHLog(@"DHHookMessage: %c[%s %s] not hooked: out of memory", DH_METHOD_ARGS(cls, sel));
        return NULL;
    }
    hook->cls = cls;
    hook->sel = sel;
    hook->replacement = replacement;
    hook->types = method_getTypeEncoding(method);
    hook->group = group;
    hook->handle = handle;
    atomic_init(&hook->original, NULL);
    atomic_init(&hook->kind, DHHookKindNone);
    atomic_init(&hook->active, false);
    hook->state = DHHookStatePending;

    const char *failure = NULL;
    CFMutableDictionaryRef table = source ? source->hooks[isClassMethod ? 1 : 0] : NULL;
    os_unfair_lock *processLock = DHProcessLock();
    os_unfair_lock_lock(processLock);
    os_unfair_lock_lock(&sLock);
    DHHook *previousHandle = handle ? *handle : NULL;
    if (group && !DHGroupReserveLocked(group)) {
        failure = "out of memory";
    } else if (table && CFDictionaryContainsKey(table, sel)) {
        failure = "the hook class defines this method more than once";
    } else {
        DHSite *site = DHSiteLocked(cls, sel);
        if (!site) {
            site = spareSite;
            spareSite = NULL;
            site->cls = cls;
            site->sel = sel;
            site->next = sSites;
            sSites = site;
        }
        hook->site = site;
        if (table) CFDictionarySetValue(table, sel, hook);
        if (group && !atomic_load(&group->enabled)) {
            // Registered only; DHGroupSetEnabled(group, YES) installs it.
            DHStoreHandleLocked(hook);
        } else {
            switch (DHInstallLocked(hook)) {
                case DHInstallDone:
                    atomic_store(&hook->active, true);
                    DHRefreshSuperCopiesLocked();
                    break;
                case DHInstallMissing:
                    failure = "the class does not respond to the selector";
                    break;
                case DHInstallDuplicate:
                    failure = "the replacement already is the method's implementation";
                    break;
            }
        }
        if (failure) {
            if (table) CFDictionaryRemoveValue(table, sel);
        } else {
            hook->nextAtSite = site->hooks;
            site->hooks = hook;
            if (group) group->hooks[group->count++] = hook;
        }
    }
    if (failure && handle && *handle == hook) __atomic_store_n(handle, previousHandle, __ATOMIC_RELEASE);
    hook->handle = NULL;
    os_unfair_lock_unlock(&sLock);
    os_unfair_lock_unlock(processLock);

    free(spareSite);
    if (failure) {
        free(hook);
        DHLog(@"DHHookMessage: %c[%s %s] not hooked: %s", DH_METHOD_ARGS(cls, sel), failure);
        return NULL;
    }
    char target[512];
    snprintf(target, sizeof target, "%c[%s %s]", DH_METHOD_ARGS(cls, sel));
    DHLogHookMap((void *)replacement, target);
    return hook;
}

#pragma mark - Hooking one method

DHHook *DHHookMessage(Class cls, SEL sel, IMP replacement, DHGroup *group) {
    return DHHookCreate(cls, sel, replacement, group, NULL, NULL, NO);
}

DHHook *DHHookMessageEx(Class cls, SEL sel, IMP replacement, DHGroup *group, DHHook **outHook) {
    return DHHookCreate(cls, sel, replacement, group, outHook, NULL, NO);
}

IMP DHOriginal(DHHook *hook) {
    if (!hook) return NULL;
    switch (atomic_load(&hook->kind)) {
        case DHHookKindOwn: {
            IMP original = atomic_load(&hook->original);
            if (original) return original;
            break;
        }
        case DHHookKindInherited: {
            // Resolved on every call so that hooks placed on the superclass later are honoured.
            Class superclass = class_getSuperclass(hook->cls);
            if (superclass) return class_getMethodImplementation(superclass, hook->sel);
            break;
        }
        default:
            break;
    }
    // Not installed yet: the method as it stands is what the hook would call.
    return class_getMethodImplementation(hook->cls, hook->sel);
}

BOOL DHHookIsActive(DHHook *hook) {
    return (hook && atomic_load(&hook->active)) ? YES : NO;
}

#pragma mark - Groups

static void DHImportsApplyGroup(DHGroup *group);   // Import hooks, below

DHGroup *DHGroupCreate(const char *name) {
    DHGroup *group = calloc(1, sizeof(DHGroup));
    char *copy = strdup(name ?: "unnamed");
    if (!group || !copy) {
        free(group);
        free(copy);
        DHLog(@"DHGroupCreate: out of memory");
        return NULL;
    }
    group->name = copy;
    atomic_init(&group->enabled, true);
    return group;
}

BOOL DHGroupIsEnabled(DHGroup *group) {
    return (!group || atomic_load(&group->enabled)) ? YES : NO;
}

// Returns YES if the hook had to be left installed beneath a later hook.
static BOOL DHDisableLocked(DHHook *hook) {
    atomic_store(&hook->active, false);
    if (hook->state != DHHookStateInstalled) return NO;
    DHSite *site = hook->site;
    Method method = class_getInstanceMethod(hook->cls, hook->sel);
    BOOL isBottom = (atomic_load(&hook->kind) == DHHookKindInherited);
    IMP restore = NULL;
    if (method && method_getImplementation(method) == hook->replacement) {
        restore = isBottom ? DHSuperImplementationLocked(hook->cls, hook->sel) : atomic_load(&hook->original);
    }
    if (!restore) {
        hook->state = DHHookStateBuried;
        return YES;
    }
    IMP previous = DHSetImplementationLocked(hook->cls, method, restore);
    if (previous != hook->replacement) {
        // Code outside every DynjectHook copy hooked the method between the check and the write.
        // Its hook goes back on top, and ours stays in the chain beneath it.
        DHSetImplementationLocked(hook->cls, method, previous);
        hook->state = DHHookStateBuried;
        return YES;
    }
    hook->restored = restore;
    hook->state = DHHookStateRestored;
    site->top = restore;
    if (isBottom) DHSiteSetSuperCopyLocked(site, restore);
    return NO;
}

// The hook of this registry that belongs directly above `hook` in their method's chain: the one
// installed soonest after it among those whose replacements are in the chain now.
static DHHook *DHHookAboveLocked(DHHook *hook) {
    DHHook *above = NULL;
    for (DHHook *other = hook->site->hooks; other; other = other->nextAtSite) {
        if (other->state != DHHookStateInstalled && other->state != DHHookStateBuried) continue;
        if (other->order > hook->order && (!above || other->order < above->order)) above = other;
    }
    return above;
}

// Returns YES if the hook is active again but its replacement could not be put (back) in place.
static BOOL DHEnableLocked(DHHook *hook) {
    BOOL notInstalled = NO;
    switch (hook->state) {
        case DHHookStatePending:
            notInstalled = (DHInstallLocked(hook) != DHInstallDone);
            break;
        case DHHookStateRestored: {
            DHSite *site = hook->site;
            Method method = class_getInstanceMethod(hook->cls, hook->sel);
            IMP current = method ? method_getImplementation(method) : NULL;
            DHHook *above = NULL;
            if (!current) {
                notInstalled = YES;
            } else if (current == hook->replacement) {
                hook->state = DHHookStateInstalled;   // somebody put it back for us
            } else if (current == hook->restored) {
                DHPutOnTopLocked(hook, method, current);
            } else if ((above = DHHookAboveLocked(hook))) {
                // A hook of this registry that was installed after this one is in the chain (it was
                // installed, or enabled, while this one was out). Go back in directly beneath it:
                // take over what it had beneath it and become its original.
                int kind = atomic_load(&above->kind);
                atomic_store(&hook->original, atomic_load(&above->original));
                atomic_store(&hook->kind, kind);
                atomic_store(&above->original, hook->replacement);
                atomic_store(&above->kind, DHHookKindOwn);
                hook->state = DHHookStateInstalled;
            } else if (current == site->top) {
                // Only this registry changed the method since (hooks beneath this one were disabled
                // or enabled): put the replacement back on top of what is there now.
                DHPutOnTopLocked(hook, method, current);
            } else {
                notInstalled = YES;   // code outside this registry changed the method; stay out
            }
            break;
        }
        case DHHookStateBuried:
            hook->state = DHHookStateInstalled;   // it never left the chain
            break;
        case DHHookStateInstalled:
            break;
    }
    atomic_store(&hook->active, true);
    return notInstalled;
}

void DHGroupSetEnabled(DHGroup *group, BOOL enabled) {
    if (!group) {
        if (!enabled) DHLog(@"DHGroupSetEnabled: a NULL group stands for ungrouped hooks, which cannot be disabled");
        return;
    }
    bool enable = enabled ? true : false;
    size_t exceptions = 0;
    os_unfair_lock *processLock = DHProcessLock();
    os_unfair_lock_lock(processLock);
    os_unfair_lock_lock(&sLock);
    if (atomic_load(&group->enabled) == enable) {
        os_unfair_lock_unlock(&sLock);
        os_unfair_lock_unlock(processLock);
        return;
    }
    atomic_store(&group->enabled, enable);
    if (enable) {
        for (size_t i = 0; i < group->count; i++) exceptions += DHEnableLocked(group->hooks[i]) ? 1 : 0;
    } else {
        for (size_t i = group->count; i > 0; i--) exceptions += DHDisableLocked(group->hooks[i - 1]) ? 1 : 0;
    }
    DHRefreshSuperCopiesLocked();
    size_t count = group->count;
    os_unfair_lock_unlock(&sLock);
    os_unfair_lock_unlock(processLock);
    DHImportsApplyGroup(group);

    if (!exceptions) return;
    if (enable) {
        DHLog(@"group '%s' enabled: %zu of %zu hooks are active but not installed: their methods were changed by code outside this copy of DynjectHook while the group was disabled, or their replacement already is the method's implementation",
              group->name, exceptions, count);
    } else {
        DHLog(@"group '%s' disabled: %zu of %zu hooks stay installed (marked inactive) because other hooks were placed on top of them",
              group->name, exceptions, count);
    }
}

#pragma mark - Hook classes

static BOOL DHSelectorIsNeverHooked(SEL sel, BOOL isClassMethod) {
    const char *name = sel_getName(sel);
    if (strcmp(name, ".cxx_construct") == 0 || strcmp(name, ".cxx_destruct") == 0) return YES;
    return isClassMethod && (strcmp(name, "load") == 0 || strcmp(name, "initialize") == 0);
}

// Hooks `onto` with the methods `from` defines (both classes, or both metaclasses).
static NSUInteger DHHookMethods(DHSource *source, Class from, Class onto, DHGroup *group, BOOL isClassMethod) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(from, &count);
    NSUInteger hooked = 0;
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        if (DHSelectorIsNeverHooked(sel, isClassMethod)) continue;
        if (!isClassMethod && strcmp(sel_getName(sel), "dealloc") == 0) {
            // Under ARC the compiler ends every -dealloc with [super dealloc], bound to the hook
            // class's superclass: installed on the target it would skip the target's own dealloc
            // chain, or (after DH_ORIG) deallocate the object a second time.
            DHLog(@"DHHookClass: skipped -[%s dealloc]: a hook class cannot hook dealloc; use DHHookMessage with a C function (self declared __unsafe_unretained, selector from sel_registerName(\"dealloc\"))",
                  source->name);
            continue;
        }
        if (!class_getInstanceMethod(onto, sel)) {
            DHLog(@"DHHookClass: skipped %c[%s %s]: %s does not respond to it",
                  isClassMethod ? '+' : '-', source->name, sel_getName(sel), class_getName(onto));
            continue;
        }
        if (DHHookCreate(onto, sel, method_getImplementation(methods[i]), group, NULL, source, isClassMethod)) hooked++;
    }
    free(methods);
    return hooked;
}

NSUInteger DHHookClass(Class source, Class target, DHGroup *group) {
    if (!source || !target || source == target) {
        DHLog(@"DHHookClass: source and target must be two classes (source %s, target %s)",
              source ? class_getName(source) : "NULL", target ? class_getName(target) : "NULL");
        return 0;
    }
    if (class_isMetaClass(source) || class_isMetaClass(target)) {
        DHLog(@"DHHookClass: pass the classes themselves, not metaclasses (source %s, target %s)",
              class_getName(source), class_getName(target));
        return 0;
    }
    DHSource *record = calloc(1, sizeof(DHSource));
    CFMutableDictionaryRef instanceHooks = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    CFMutableDictionaryRef classHooks = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
    BOOL alreadyUsed = NO;
    if (record && instanceHooks && classHooks) {
        record->cls = source;
        record->name = class_getName(source);
        record->nameLength = strlen(record->name);
        record->hooks[0] = instanceHooks;
        record->hooks[1] = classHooks;
        os_unfair_lock_lock(&sLock);
        for (DHSource *other = sSources; other && !alreadyUsed; other = other->next) alreadyUsed = (other->cls == source);
        if (!alreadyUsed) {
            record->next = sSources;
            sSources = record;
        }
        os_unfair_lock_unlock(&sLock);
    }
    if (!record || !instanceHooks || !classHooks || alreadyUsed) {
        free(record);
        if (instanceHooks) CFRelease(instanceHooks);
        if (classHooks) CFRelease(classHooks);
        if (alreadyUsed) {
            DHLog(@"DHHookClass: %s already hooks a class; a hook class can have only one target (%s not hooked)",
                  class_getName(source), class_getName(target));
        } else {
            DHLog(@"DHHookClass: out of memory");
        }
        return 0;
    }
    NSUInteger hooked = DHHookMethods(record, source, target, group, NO);
    hooked += DHHookMethods(record, object_getClass(source), object_getClass(target), group, YES);
    if (hooked == 0) {
        DHLog(@"DHHookClass: %s hooked no methods of %s", class_getName(source), class_getName(target));
    }
    return hooked;
}

static DHSource *DHSourceNamedLocked(const char *name, size_t length) {
    for (DHSource *source = sSources; source; source = source->next) {
        if (source->nameLength == length && memcmp(source->name, name, length) == 0) return source;
    }
    return NULL;
}

typedef struct {
    const char *name;
    size_t length;
    SEL found;
} DHSelectorSearch;

static void DHSelectorSearchApply(const void *key, const void *value, void *context) {
    (void)value;
    DHSelectorSearch *search = context;
    if (search->found) return;
    const char *name = sel_getName((SEL)key);
    if (strlen(name) == search->length && memcmp(name, search->name, search->length) == 0) search->found = (SEL)key;
}

// The selector spelled `name` if `table` (SEL -> DHHook *) has a hook for it, else NULL. Comparing
// names keeps the selector spelled in a function name from having to be registered.
static SEL DHSelectorNamedLocked(CFDictionaryRef table, const char *name, size_t length) {
    DHSelectorSearch search = { name, length, NULL };
    if (length) CFDictionaryApplyFunction(table, DHSelectorSearchApply, &search);
    return search.found;
}

// A parse of a function name: where it names the class and the selector.
typedef struct {
    DHSource *source;
    int methodKind;
    size_t selectorOffset;
    size_t selectorLength;
    SEL selector;
} DHFunctionName;

// Finds "-[Class selector]" / "+[Class(Category) selector]" in `text` (it is preceded and followed
// by other characters inside blocks) for a registered hook class.
static BOOL DHParseMethodNameLocked(const char *text, DHFunctionName *result) {
    const char *start = text;
    while (*start && !((start[0] == '-' || start[0] == '+') && start[1] == '[')) start++;
    if (!*start) return NO;
    const char *begin = start + 2;
    const char *end = begin;
    while (*end && *end != ' ' && *end != '(' && *end != ']') end++;
    if (end == begin || (*end != ' ' && *end != '(')) return NO;
    DHSource *source = DHSourceNamedLocked(begin, (size_t)(end - begin));
    if (!source) return NO;
    const char *selector = end;
    if (*selector == '(') {
        while (*selector && *selector != ')') selector++;
        if (*selector == ')') selector++;
    }
    const char *selectorEnd = selector;
    if (*selector == ' ') {
        selector++;
        selectorEnd = selector;
        while (*selectorEnd && *selectorEnd != ']') selectorEnd++;
        if (*selectorEnd != ']') selectorEnd = selector;
    }
    result->source = source;
    result->methodKind = (start[0] == '+') ? DHMethodKindClass : DHMethodKindInstance;
    result->selectorOffset = (size_t)(selector - text);
    result->selectorLength = (size_t)(selectorEnd - selector);
    result->selector = NULL;
    return YES;
}

static BOOL DHIsIdentifierCharacter(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$';
}

// Finds clang's name for a C++ lambda written inside a method (Objective-C++),
// "auto Class::selector::(anonymous class)::operator()() const", for a registered hook class that
// hooks that selector. The name does not say whether the method is an instance or a class method.
static BOOL DHParseLambdaNameLocked(const char *text, DHFunctionName *result) {
    for (const char *colons = strstr(text, "::"); colons; colons = strstr(colons + 2, "::")) {
        const char *begin = colons;
        while (begin > text && DHIsIdentifierCharacter(begin[-1])) begin--;
        const char *selector = colons + 2;
        const char *selectorEnd = strstr(selector, "::(");
        if (begin == colons || !selectorEnd || selectorEnd == selector) continue;
        DHSource *source = DHSourceNamedLocked(begin, (size_t)(colons - begin));
        if (!source) continue;
        size_t length = (size_t)(selectorEnd - selector);
        SEL instanceSelector = DHSelectorNamedLocked(source->hooks[0], selector, length);
        SEL classSelector = DHSelectorNamedLocked(source->hooks[1], selector, length);
        if (!instanceSelector && !classSelector) continue;
        result->source = source;
        result->methodKind = DHMethodKindByReceiver;
        result->selectorOffset = (size_t)(selector - text);
        result->selectorLength = length;
        result->selector = instanceSelector ?: classSelector;
        return YES;
    }
    return NO;
}

static void DHFreeParsedFunction(const void *key, const void *value, void *context) {
    (void)key;
    (void)context;
    DHParsedFunction *parsed = (DHParsedFunction *)value;
    free(parsed->text);
    free(parsed);
}

// The parse of `prettyFunction`, cached by its address. NULL if it does not name a method of a
// registered hook class (that outcome is not cached).
static DHParsedFunction *DHParsedFunctionLocked(const char *prettyFunction) {
    DHParsedFunction *parsed = sParsedFunctions
        ? (DHParsedFunction *)CFDictionaryGetValue(sParsedFunctions, prettyFunction) : NULL;
    if (parsed && strcmp(parsed->text, prettyFunction) == 0) return parsed;

    DHFunctionName name = { NULL, DHMethodKindInstance, 0, 0, NULL };
    BOOL known = DHParseMethodNameLocked(prettyFunction, &name) || DHParseLambdaNameLocked(prettyFunction, &name);
    char *text = known ? strdup(prettyFunction) : NULL;
    if (!text) {
        // Unknown, or out of memory. A stale entry for a reused address must not survive either.
        if (parsed) {
            CFDictionaryRemoveValue(sParsedFunctions, prettyFunction);
            DHFreeParsedFunction(NULL, parsed, NULL);
        }
        return NULL;
    }
    if (parsed) {
        free(parsed->text);   // the address now holds a different string
    } else {
        if (!sParsedFunctions) sParsedFunctions = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, NULL, NULL);
        parsed = sParsedFunctions ? calloc(1, sizeof(DHParsedFunction)) : NULL;
        if (!parsed) {
            free(text);
            return NULL;
        }
        if (CFDictionaryGetCount(sParsedFunctions) >= kDHParsedFunctionLimit) {
            // Only callers that pass temporary strings get here; start over rather than grow.
            CFDictionaryApplyFunction(sParsedFunctions, DHFreeParsedFunction, NULL);
            CFDictionaryRemoveAllValues(sParsedFunctions);
        }
        CFDictionarySetValue(sParsedFunctions, prettyFunction, parsed);
    }
    parsed->text = text;
    parsed->source = name.source;
    parsed->methodKind = name.methodKind;
    parsed->selectorOffset = name.selectorOffset;
    parsed->selectorLength = name.selectorLength;
    parsed->selector = name.selector;
    return parsed;
}

// The hook behind the function `parsed` in the given table of its hook class. The function is
// identified by the selector its name spells, the one its method was compiled for and installed
// under. `sel`, the selector it was called with, is only the fallback: the two differ once other
// code moves the installed replacement to another selector (method_exchangeImplementations and
// other alias-selector swizzling), and then `sel` names somebody else's method.
static DHHook *DHHookForFunctionLocked(DHParsedFunction *parsed, int methodKind, SEL sel) {
    CFDictionaryRef table = parsed->source->hooks[methodKind];
    if (!parsed->selector) {
        parsed->selector = DHSelectorNamedLocked(table, parsed->text + parsed->selectorOffset, parsed->selectorLength);
    }
    DHHook *hook = parsed->selector ? (DHHook *)CFDictionaryGetValue(table, parsed->selector) : NULL;
    return hook ?: (DHHook *)CFDictionaryGetValue(table, sel);
}

IMP DHOriginalForSource(const char *prettyFunction, SEL sel, id self) {
    if (!prettyFunction || !sel) {
        DHLog(@"DH_ORIG: function name and selector must not be NULL");
        return NULL;
    }
    DHHook *hook = NULL;
    DHHook *classHook = NULL;   // only for a function whose name does not tell the two kinds apart
    BOOL byReceiver = NO;
    os_unfair_lock_lock(&sLock);
    DHParsedFunction *parsed = DHParsedFunctionLocked(prettyFunction);
    if (parsed) {
        byReceiver = (parsed->methodKind == DHMethodKindByReceiver);
        hook = DHHookForFunctionLocked(parsed, byReceiver ? DHMethodKindInstance : parsed->methodKind, sel);
        if (byReceiver) classHook = DHHookForFunctionLocked(parsed, DHMethodKindClass, sel);
    }
    os_unfair_lock_unlock(&sLock);
    if (byReceiver) {
        BOOL receiverIsClass = (self && class_isMetaClass(object_getClass(self)));
        DHHook *other = receiverIsClass ? hook : classHook;
        hook = (receiverIsClass ? classHook : hook) ?: other;
    }
    if (!hook) {
        DHLog(@"DH_ORIG: no hook is registered for %s with selector %s (receiver class %s). Was its class passed to DHHookClass? DH_ORIG finds the hook class by the name in __PRETTY_FUNCTION__, so the class must not use objc_runtime_name, and DH_ORIG must be in the method body or a block inside it",
              prettyFunction, sel_getName(sel), self ? object_getClassName(self) : "nil");
        return NULL;
    }
    return DHOriginal(hook);
}

#pragma mark - Class lookup

Class DHClass(const char *name) {
    return name ? objc_getClass(name) : Nil;
}

Class DHSwiftClass(const char *module, const char *name) {
    if (!module || !name || !module[0] || !name[0]) return Nil;
    size_t moduleLength = strlen(module);
    size_t nameLength = strlen(name);
    size_t size = moduleLength + nameLength + 64;
    char *buffer = malloc(size);
    if (!buffer) return Nil;
    snprintf(buffer, size, "%s.%s", module, name);
    Class cls = objc_getClass(buffer);
    if (!cls) {
        snprintf(buffer, size, "_TtC%zu%s%zu%s", moduleLength, module, nameLength, name);
        cls = objc_getClass(buffer);
    }
    free(buffer);
    return cls;
}

Class DHFindClassWithSuffix(const char *imagePath, const char *suffix) {
    if (!suffix || !suffix[0]) {
        DHLog(@"DHFindClassWithSuffix: the suffix must not be NULL or empty");
        return Nil;
    }
    const char *image = imagePath ?: _dyld_get_image_name(0);
    if (!image) return Nil;
    unsigned int count = 0;
    const char **names = objc_copyClassNamesForImage(image, &count);
    size_t suffixLength = strlen(suffix);
    Class found = Nil;
    for (unsigned int i = 0; names && i < count && !found; i++) {
        size_t length = strlen(names[i]);
        if (length < suffixLength || memcmp(names[i] + length - suffixLength, suffix, suffixLength) != 0) continue;
        found = objc_getClass(names[i]);
    }
    free(names);
    return found;
}

// Runs a DHWhenClassLoads block; an exception it raises is logged, not propagated.
static void DHRunClassBlock(void (^block)(Class), Class cls) {
    @try {
        block(cls);
    } @catch (NSException *exception) {
        DHLog(@"DHWhenClassLoads: the block for %s raised %@: %@", class_getName(cls), exception.name, exception.reason);
    } @catch (...) {
        DHLog(@"DHWhenClassLoads: the block for %s raised an unknown exception", class_getName(cls));
    }
}

// Unlinks the pending registration `serial`; NULL if another thread already took it.
static DHPending *DHPendingTake(uint64_t serial) {
    DHPending *taken = NULL;
    os_unfair_lock_lock(&sLock);
    for (DHPending **link = &sPending; *link; link = &(*link)->next) {
        if ((*link)->serial != serial) continue;
        taken = *link;
        *link = taken->next;
        break;
    }
    os_unfair_lock_unlock(&sLock);
    return taken;
}

void DHCheckPendingClasses(void) {
    // Snapshot the names, look the classes up without the lock, then claim each ready registration
    // individually so that concurrent checks run every block exactly once.
    typedef struct { uint64_t serial; char *name; } DHCandidate;
    DHCandidate *candidates = NULL;
    size_t count = 0;
    os_unfair_lock_lock(&sLock);
    size_t pending = 0;
    for (DHPending *entry = sPending; entry; entry = entry->next) pending++;
    if (pending) candidates = calloc(pending, sizeof(DHCandidate));
    if (candidates) {
        for (DHPending *entry = sPending; entry; entry = entry->next) {
            char *name = strdup(entry->name);
            if (name) candidates[count++] = (DHCandidate){ entry->serial, name };
        }
    }
    os_unfair_lock_unlock(&sLock);

    for (size_t i = 0; i < count; i++) {
        Class cls = objc_getClass(candidates[i].name);
        free(candidates[i].name);
        if (!cls) continue;
        DHPending *entry = DHPendingTake(candidates[i].serial);
        if (!entry) continue;
        void (^block)(Class) = (__bridge_transfer void (^)(Class))entry->block;
        free(entry->name);
        free(entry);
        DHRunClassBlock(block, cls);
    }
    free(candidates);
}

static BOOL DHHasPendingClasses(void) {
    os_unfair_lock_lock(&sLock);
    BOOL any = (sPending != NULL);
    os_unfair_lock_unlock(&sLock);
    return any;
}

static atomic_bool sMainRecheckScheduled;

static void DHMainRecheck(void *context) {
    (void)context;
    atomic_store(&sMainRecheckScheduled, false);
    DHCheckPendingClasses();
}

static void DHScheduleMainRecheck(void) {
    if (!atomic_exchange(&sMainRecheckScheduled, true)) {
        dispatch_async_f(dispatch_get_main_queue(), NULL, DHMainRecheck);
    }
}

// Set on the thread that is inside _dyld_register_func_for_add_image, which replays every image
// that is already loaded; those cannot bring new classes.
static _Thread_local BOOL tReplayingLoadedImages;

static void DHImageAdded(const struct mach_header *header, intptr_t slide) {
    (void)header;
    (void)slide;
    if (tReplayingLoadedImages || !DHHasPendingClasses()) return;
    DHCheckPendingClasses();
    // dyld may tell us before the Objective-C runtime has registered the image's classes.
    if (DHHasPendingClasses()) DHScheduleMainRecheck();
}

void DHWhenClassLoads(const char *name, void (^block)(Class cls)) {
    if (!name || !name[0] || !block) {
        DHLog(@"DHWhenClassLoads: class name and block must not be NULL");
        return;
    }
    Class cls = objc_getClass(name);
    if (cls) {
        DHRunClassBlock(block, cls);
        return;
    }
    DHPending *entry = calloc(1, sizeof(DHPending));
    char *copy = strdup(name);
    if (!entry || !copy) {
        free(entry);
        free(copy);
        DHLog(@"DHWhenClassLoads: out of memory; the block for %s will not run", name);
        return;
    }
    entry->name = copy;
    entry->block = (void *)CFBridgingRetain([block copy]);

    os_unfair_lock_lock(&sLock);
    entry->serial = ++sPendingSerial;
    DHPending **tail = &sPending;
    while (*tail) tail = &(*tail)->next;
    *tail = entry;
    BOOL registerCallback = !sImageCallbackRegistered;
    sImageCallbackRegistered = YES;
    os_unfair_lock_unlock(&sLock);

    if (registerCallback) {
        tReplayingLoadedImages = YES;
        _dyld_register_func_for_add_image(DHImageAdded);
        tReplayingLoadedImages = NO;
    }
    // The class may have appeared between the lookup above and the registration.
    DHCheckPendingClasses();
}

#pragma mark - Import hooks

// Design notes
// - An image calls into other libraries through pointers in its own imports: the indirect symbol table names the
//   symbol behind each entry of the __got, __auth_got and __la_symbol_ptr sections. A hook rewrites the entries for
//   its symbol in every image outside the shared cache, except the image holding the replacement (the tweak).
// - The image list comes only from dyld's add-image and remove-image callbacks, which run with dyld's own lock held.
//   So nothing here calls dyld (dladdr, dlsym, the image list) while sImportLock is held; dlsym and dladdr run before
//   it is taken. sImportLock is separate from sLock so that callbacks never wait on a method hook in progress.
// - Writing an entry may need its page made writable for a moment. Two tweaks' copies doing that to one page at once
//   could fault, so every write holds the process-wide lock (taken after sImportLock, never the other way), and the
//   entry is replaced with a compare-and-swap so a writer outside DynjectHook is never overwritten blindly.
// - arm64e: an arm64e image's __auth_got entries are signed with the IA key and their own address as discriminator
//   (an arm64 image in the same process, such as the main executable of an arm64 app, has plain ones). Before writing, the
//   current value is checked to be signed that way (signing doesn't fault; authenticating a wrong guess would); an
//   entry signed any other way is left alone and logged. The replacement is re-signed for the entry, the original
//   re-signed as a plain C function pointer.
// - Hook records and their entries are never freed (handles stay valid); entries of an unloaded image are dropped.

#import <dlfcn.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

#ifndef MH_DYLIB_IN_CACHE
#define MH_DYLIB_IN_CACHE 0x80000000
#endif

typedef struct DHImportSite {
    const struct mach_header *image;
    void **entry;
    void *previous;           // what the entry held before this hook wrote it (as stored: signed for the entry)
    void *mine;               // what this hook wrote
    void *callable;           // `previous` as a plain C function pointer (dlsym's answer for an unbound lazy import)
    BOOL installed;           // the entry holds `mine` as far as this hook knows
    BOOL authenticated;       // an __auth_got entry (signed values)
    struct DHImportSite *next;
} DHImportSite;

struct DHImportHook {
    // Immutable after creation.
    char *symbol;             // as in the symbol table: "_" + the C name
    char *library;            // NULL: any
    void *replacement;        // as passed (a signed C function pointer on arm64e)
    void *fallback;           // dlsym's answer at creation
    const struct mach_header *ownImage;
    DHGroup *group;
    DHImportHook **handle;
    // Read without the lock by DHImportOriginal() and DHImportHookIsActive().
    _Atomic(void *) original;
    atomic_bool active;
    // Guarded by sImportLock.
    DHImportSite *sites;
    struct DHImportHook *next;
};

typedef struct DHImportImage {
    const struct mach_header *header;
    intptr_t slide;
    struct DHImportImage *next;
} DHImportImage;

static os_unfair_lock sImportLock = OS_UNFAIR_LOCK_INIT;
// Guarded by sImportLock.
static DHImportHook *sImportHooks;       // install order
static DHImportImage *sImportImages;     // load order
static atomic_bool sImportCallbacksRegistered;

// Sums logged after the lock is released.
typedef struct {
    size_t patched;
    size_t oddlySigned;
    size_t locked;            // macOS keeps the page read-only (Apple's own apps and their libraries)
    size_t unwritable;        // making it writable failed some other way
    kern_return_t lastError;
} DHImportTally;

static void *DHImportStrip(void *value) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(value, ptrauth_key_asia);
#else
    return value;
#endif
}

// Whether the entry holds a value signed the way an __auth_got entry is (always YES without pointer authentication).
static BOOL DHImportEntrySignedAsExpected(void **entry, void *value, BOOL authenticated) {
#if __has_feature(ptrauth_calls)
    if (!authenticated) return YES;
    return ptrauth_sign_unauthenticated(ptrauth_strip(value, ptrauth_key_asia), ptrauth_key_asia, (uintptr_t)entry) == value;
#else
    (void)entry; (void)value; (void)authenticated;
    return YES;
#endif
}

// `function` (any signature) signed for storing in `entry`.
static void *DHImportValueForEntry(void **entry, void *function, BOOL authenticated) {
#if __has_feature(ptrauth_calls)
    if (authenticated) return ptrauth_sign_unauthenticated(ptrauth_strip(function, ptrauth_key_asia), ptrauth_key_asia, (uintptr_t)entry);
    return ptrauth_strip(function, ptrauth_key_asia);
#else
    (void)entry; (void)authenticated;
    return function;
#endif
}

// An entry's value as a plain C function pointer.
static void *DHImportCallable(void *value) {
#if __has_feature(ptrauth_calls)
    return value ? ptrauth_sign_unauthenticated(ptrauth_strip(value, ptrauth_key_asia), ptrauth_key_asia, 0) : NULL;
#else
    return value;
#endif
}

// Compare-and-swap on an import entry, making its page writable for the write if it isn't. Caller holds sImportLock.
static BOOL DHImportWrite(void **entry, void *expected, void *value, DHImportTally *tally) {
    os_unfair_lock *processLock = DHProcessLock();
    os_unfair_lock_lock(processLock);
    mach_vm_address_t address = (mach_vm_address_t)entry;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    kern_return_t kr = mach_vm_region(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
                                      &count, &object);
    vm_prot_t protection = kr == KERN_SUCCESS ? info.protection : VM_PROT_READ;
    mach_vm_address_t page = (mach_vm_address_t)entry & ~((mach_vm_address_t)vm_page_size - 1);
    BOOL madeWritable = NO;
    if (!(protection & VM_PROT_WRITE)) {
        kr = mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
        if (kr != KERN_SUCCESS) {
            kr = mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        }
        if (kr != KERN_SUCCESS) {
            os_unfair_lock_unlock(processLock);
            if (tally) {
                // The page allows writing at most, yet can't be made writable: the kernel holds it read-only for good. On
                // macOS 27 that is the __DATA_CONST of Apple's platform binaries once dyld is done (seen in Calculator).
                if (kr == KERN_PROTECTION_FAILURE && (info.max_protection & VM_PROT_WRITE)) tally->locked++;
                else tally->unwritable++;
                tally->lastError = kr;
            }
            return NO;
        }
        madeWritable = YES;
    }
    BOOL swapped = atomic_compare_exchange_strong((_Atomic(void *) *)entry, &expected, value) ? YES : NO;
    if (madeWritable) mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, protection);
    os_unfair_lock_unlock(processLock);
    return swapped;
}

// Whether the load command `name` (a dylib's install name) is `library`: the full path or its last component.
static BOOL DHImportLibraryMatches(const char *name, const char *library) {
    if (!library) return YES;
    if (!name) return NO;
    if (strcmp(name, library) == 0) return YES;
    const char *slash = strrchr(name, '/');
    return slash && strcmp(slash + 1, library) == 0;
}

static BOOL DHImportHasSite(DHImportHook *hook, void **entry) {
    for (DHImportSite *s = hook->sites; s; s = s->next) {
        if (s->entry == entry) return YES;
    }
    return NO;
}

// Patches `hook` into every import of its symbol in `image` it doesn't have yet. Caller holds sImportLock.
static void DHImportPatchImageLocked(DHImportHook *hook, DHImportImage *image, DHImportTally *tally) {
    const struct mach_header *mh = image->header;
    if (mh == hook->ownImage || (mh->flags & MH_DYLIB_IN_CACHE) || mh->magic != MH_MAGIC_64) return;
    if (mh->filetype != MH_EXECUTE && mh->filetype != MH_DYLIB && mh->filetype != MH_BUNDLE) return;
    const struct mach_header_64 *header = (const struct mach_header_64 *)mh;
#if __has_feature(ptrauth_calls)
    BOOL arm64e = mh->cputype == CPU_TYPE_ARM64 && (mh->cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E;
#else
    BOOL arm64e = NO;   // code without pointer authentication never shares a process with arm64e images
#endif
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const char *libraries[256];
    size_t libraryCount = 0;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        switch (lc->cmd) {
            case LC_SEGMENT_64:
                if (strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT) == 0) {
                    linkedit = (const struct segment_command_64 *)lc;
                }
                break;
            case LC_SYMTAB: symtab = (const struct symtab_command *)lc; break;
            case LC_DYSYMTAB: dysymtab = (const struct dysymtab_command *)lc; break;
            case LC_LOAD_DYLIB:
            case LC_LOAD_WEAK_DYLIB:
            case LC_REEXPORT_DYLIB:
            case LC_LAZY_LOAD_DYLIB:
            case LC_LOAD_UPWARD_DYLIB:
                if (libraryCount < 256) {
                    const struct dylib_command *d = (const struct dylib_command *)lc;
                    libraries[libraryCount++] = (const char *)lc + d->dylib.name.offset;
                }
                break;
        }
        cursor += lc->cmdsize;
    }
    if (!linkedit || !symtab || !dysymtab || !dysymtab->nindirectsyms) return;
    uintptr_t base = (uintptr_t)image->slide + (uintptr_t)(linkedit->vmaddr - linkedit->fileoff);
    const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtab->indirectsymoff);

    // __TEXT,__stub_helper: where a lazy import points before its first call.
    uintptr_t helperStart = 0, helperEnd = 0;
    cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        cursor += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        const struct section_64 *sections = (const struct section_64 *)(seg + 1);
        for (uint32_t k = 0; k < seg->nsects; k++) {
            if (strcmp(sections[k].sectname, "__stub_helper") == 0) {
                helperStart = (uintptr_t)image->slide + (uintptr_t)sections[k].addr;
                helperEnd = helperStart + (uintptr_t)sections[k].size;
            }
        }
    }

    cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        cursor += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        const struct section_64 *sections = (const struct section_64 *)(seg + 1);
        for (uint32_t k = 0; k < seg->nsects; k++) {
            const struct section_64 *sect = &sections[k];
            uint32_t type = sect->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            // An arm64e image keeps its function imports in __auth_got, signed; its plain __got holds data. Other images
            // (arm64, x86_64) hold plain pointers, also when this code is arm64e: dyld loads a tweak's arm64e slice into
            // an arm64 process too.
            BOOL authenticated = arm64e && strncmp(sect->sectname, "__auth", 6) == 0;
            if (arm64e && !authenticated) continue;
            void **entries = (void **)((uintptr_t)image->slide + (uintptr_t)sect->addr);
            uint64_t n = sect->size / sizeof(void *);
            for (uint64_t e = 0; e < n; e++) {
                if (sect->reserved1 + e >= dysymtab->nindirectsyms) break;
                uint32_t index = indirect[sect->reserved1 + e];
                if (index == INDIRECT_SYMBOL_ABS || index == INDIRECT_SYMBOL_LOCAL ||
                    index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS) || index >= symtab->nsyms) continue;
                uint32_t strx = symbols[index].n_un.n_strx;
                if (strx >= symtab->strsize || strcmp(strings + strx, hook->symbol) != 0) continue;
                if (hook->library) {
                    int ordinal = GET_LIBRARY_ORDINAL(symbols[index].n_desc);
                    if (ordinal < 1 || (size_t)ordinal > libraryCount ||
                        !DHImportLibraryMatches(libraries[ordinal - 1], hook->library)) continue;
                }
                void **entry = &entries[e];
                if (DHImportHasSite(hook, entry)) continue;
                void *value = atomic_load((_Atomic(void *) *)entry);
                if (!value) continue;   // a weak import that isn't there
                if (!DHImportEntrySignedAsExpected(entry, value, authenticated)) {
                    tally->oddlySigned++;
                    continue;
                }
                uintptr_t raw = (uintptr_t)DHImportStrip(value);
                BOOL unbound = type == S_LAZY_SYMBOL_POINTERS && raw >= helperStart && raw < helperEnd;
                void *callable = unbound ? hook->fallback : DHImportCallable(value);
                if (!callable) continue;
                void *mine = DHImportValueForEntry(entry, hook->replacement, authenticated);
                if (!DHImportWrite(entry, value, mine, tally)) continue;
                DHImportSite *site = calloc(1, sizeof(DHImportSite));
                if (!site) {   // can't record it: undo
                    DHImportWrite(entry, mine, value, NULL);
                    continue;
                }
                site->image = mh;
                site->entry = entry;
                site->previous = value;
                site->mine = mine;
                site->callable = callable;
                site->installed = YES;
                site->authenticated = authenticated;
                DHImportSite **tail = &hook->sites;
                while (*tail) tail = &(*tail)->next;
                *tail = site;
                if (!atomic_load(&hook->original) || hook->sites == site) atomic_store(&hook->original, callable);
                tally->patched++;
            }
        }
    }
}

// Removes `hook` from every import it holds. Returns how many it had to leave (another hook sits on top). Caller
// holds sImportLock.
static size_t DHImportUninstallLocked(DHImportHook *hook) {
    size_t buried = 0;
    for (DHImportSite *s = hook->sites; s; s = s->next) {
        if (!s->installed) continue;
        if (DHImportWrite(s->entry, s->mine, s->previous, NULL)) {
            s->installed = NO;
        } else {
            buried++;
        }
    }
    return buried;
}

// Puts `hook` back on every import it was removed from, on top of what each holds now, and onto imports of images
// that appeared meanwhile. Caller holds sImportLock.
static void DHImportInstallLocked(DHImportHook *hook, DHImportTally *tally) {
    BOOL first = YES;
    for (DHImportSite *s = hook->sites; s; s = s->next, first = NO) {
        if (s->installed) continue;
        void *value = atomic_load((_Atomic(void *) *)s->entry);
        if (!value || !DHImportEntrySignedAsExpected(s->entry, value, s->authenticated)) continue;
        if (DHImportWrite(s->entry, value, s->mine, tally)) {
            if (value != s->previous) s->callable = DHImportCallable(value);   // something else is beneath it now
            s->previous = value;
            s->installed = YES;
            if (first) atomic_store(&hook->original, s->callable);
        }
    }
    for (DHImportImage *image = sImportImages; image; image = image->next) DHImportPatchImageLocked(hook, image, tally);
}

static BOOL DHImportGroupEnabled(DHImportHook *hook) {
    return !hook->group || atomic_load(&hook->group->enabled);
}

static void DHImportLogTally(const char *what, const DHImportTally *tally) {
    if (tally->oddlySigned) {
        DHLog(@"%s: left %zu import(s) alone: not signed the way an __auth_got entry is", what, tally->oddlySigned);
    }
    if (tally->locked) {
        DHLog(@"%s: %zu import(s) are in pages macOS keeps read-only (Apple's own apps and libraries lock their imports after launch); not hooked there",
              what, tally->locked);
    }
    if (tally->unwritable) {
        DHLog(@"%s: %zu import(s) could not be made writable (%s)", what, tally->unwritable, mach_error_string(tally->lastError));
    }
}

static void DHImportImageAdded(const struct mach_header *header, intptr_t slide) {
    DHImportImage *image = calloc(1, sizeof(DHImportImage));
    if (!image) return;
    image->header = header;
    image->slide = slide;
    DHImportTally tally = {0};
    os_unfair_lock_lock(&sImportLock);
    BOOL known = NO;
    for (DHImportImage *i = sImportImages; i && !known; i = i->next) known = (i->header == header);
    if (known) {
        os_unfair_lock_unlock(&sImportLock);
        free(image);
        return;
    }
    DHImportImage **tail = &sImportImages;
    while (*tail) tail = &(*tail)->next;
    *tail = image;
    for (DHImportHook *hook = sImportHooks; hook; hook = hook->next) {
        if (DHImportGroupEnabled(hook)) DHImportPatchImageLocked(hook, image, &tally);
    }
    os_unfair_lock_unlock(&sImportLock);
    DHImportLogTally("image loaded", &tally);
}

static void DHImportImageRemoved(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    os_unfair_lock_lock(&sImportLock);
    for (DHImportImage **i = &sImportImages; *i; i = &(*i)->next) {
        if ((*i)->header != header) continue;
        DHImportImage *gone = *i;
        *i = gone->next;
        free(gone);
        break;
    }
    for (DHImportHook *hook = sImportHooks; hook; hook = hook->next) {
        for (DHImportSite **s = &hook->sites; *s;) {
            if ((*s)->image != header) { s = &(*s)->next; continue; }
            DHImportSite *gone = *s;
            *s = gone->next;
            free(gone);
        }
        atomic_store(&hook->original, hook->sites ? hook->sites->callable : hook->fallback);
    }
    os_unfair_lock_unlock(&sImportLock);
}

static void DHImportsApplyGroup(DHGroup *group) {
    size_t buried = 0, count = 0;
    DHImportTally tally = {0};
    os_unfair_lock_lock(&sImportLock);
    bool enabled = atomic_load(&group->enabled);
    for (size_t i = 0; i < group->importCount; i++) {
        DHImportHook *hook = group->imports[i];
        count++;
        if (enabled) {
            DHImportInstallLocked(hook, &tally);
            atomic_store(&hook->active, true);
        } else {
            atomic_store(&hook->active, false);
        }
    }
    if (!enabled) {
        for (size_t i = group->importCount; i > 0; i--) buried += DHImportUninstallLocked(group->imports[i - 1]);
    }
    os_unfair_lock_unlock(&sImportLock);
    DHImportLogTally(group->name, &tally);
    if (buried) {
        DHLog(@"group '%s' disabled: %zu import(s) of its %zu import hook(s) stay patched (marked inactive) because other hooks were placed on top of them",
              group->name, buried, count);
    }
}

DHImportHook *DHHookImportEx(const char *symbol, const char *library, void *replacement, DHGroup *group,
                             DHImportHook **outHook) {
    DHReportRegister();
    if (!symbol || !symbol[0] || !replacement) {
        DHLog(@"DHHookImport: %s is NULL; not hooking", !symbol || !symbol[0] ? "the symbol" : "the replacement");
        return NULL;
    }
    // dyld calls, outside sImportLock (see the design notes).
    Dl_info info;
    const struct mach_header *ownImage = dladdr(DHImportStrip(replacement), &info) ? (const struct mach_header *)info.dli_fbase : NULL;
    void *fallback = dlsym(RTLD_DEFAULT, symbol);
    if (!atomic_exchange(&sImportCallbacksRegistered, true)) {
        _dyld_register_func_for_add_image(DHImportImageAdded);   // replays every image already loaded
        _dyld_register_func_for_remove_image(DHImportImageRemoved);
    }

    DHImportHook *hook = calloc(1, sizeof(DHImportHook));
    size_t length = strlen(symbol);
    char *name = malloc(length + 2);
    char *libraryCopy = library ? strdup(library) : NULL;
    if (!hook || !name || (library && !libraryCopy)) {
        free(hook); free(name); free(libraryCopy);
        DHLog(@"DHHookImport: out of memory");
        return NULL;
    }
    name[0] = '_';
    memcpy(name + 1, symbol, length + 1);
    hook->symbol = name;
    hook->library = libraryCopy;
    hook->replacement = replacement;
    hook->fallback = fallback;
    hook->ownImage = ownImage;
    hook->group = group;
    hook->handle = outHook;
    atomic_init(&hook->original, fallback);
    atomic_init(&hook->active, DHGroupIsEnabled(group) ? true : false);

    DHImportTally tally = {0};
    os_unfair_lock_lock(&sImportLock);
    if (group) {
        if (group->importCount == group->importCapacity) {
            size_t capacity = group->importCapacity ? group->importCapacity * 2 : 4;
            DHImportHook **grown = realloc(group->imports, capacity * sizeof(DHImportHook *));
            if (!grown) {
                os_unfair_lock_unlock(&sImportLock);
                free(name); free(libraryCopy); free(hook);
                DHLog(@"DHHookImport: out of memory");
                return NULL;
            }
            group->imports = grown;
            group->importCapacity = capacity;
        }
        group->imports[group->importCount++] = hook;
    }
    DHImportHook **tail = &sImportHooks;
    while (*tail) tail = &(*tail)->next;
    *tail = hook;
    if (outHook) *outHook = hook;
    if (DHImportGroupEnabled(hook)) {
        for (DHImportImage *image = sImportImages; image; image = image->next) DHImportPatchImageLocked(hook, image, &tally);
    }
    os_unfair_lock_unlock(&sImportLock);

    DHImportLogTally(symbol, &tally);
    char target[512];
    snprintf(target, sizeof target, "import %s%s%s", symbol, library ? " from " : "", library ?: "");
    DHLogHookMap(replacement, target);
    if (tally.patched) {
        DHLog(@"hooked %s%s%s in %zu import(s)", symbol, library ? " from " : "", library ?: "", tally.patched);
    } else if (DHImportGroupEnabled(hook)) {
        DHLog(@"DHHookImport: no loaded image imports %s%s%s yet (calls inside the shared cache and the tweak's own calls are not covered); images loaded later will be patched",
              symbol, library ? " from " : "", library ?: "");
    }
    return hook;
}

DHImportHook *DHHookImport(const char *symbol, const char *library, void *replacement, DHGroup *group) {
    return DHHookImportEx(symbol, library, replacement, group, NULL);
}

void *DHImportOriginal(DHImportHook *hook) {
    return hook ? atomic_load(&hook->original) : NULL;
}

BOOL DHImportHookIsActive(DHImportHook *hook) {
    return (hook && atomic_load(&hook->active)) ? YES : NO;
}

NSUInteger DHImportHookSiteCount(DHImportHook *hook) {
    if (!hook) return 0;
    NSUInteger n = 0;
    os_unfair_lock_lock(&sImportLock);
    for (DHImportSite *s = hook->sites; s; s = s->next) n += s->installed ? 1 : 0;
    os_unfair_lock_unlock(&sImportLock);
    return n;
}

#pragma mark - Function hooks (inline)

// DHHookFunction. Layout of one hook, all in one page of its own (made r-x once written):
//
//   gate (the function's first 16 bytes jump here):
//     ldr x16, flag ; ldrb w16, [x16] ; cbz w16, original ; ldr x16, replacement ; br x16
//     original: ldr x16, trampoline ; br x16 ; nop ; flag: .quad ; replacement: .quad ; trampoline: .quad
//   trampoline (the original): the function's first four instructions, moved, then a jump to function + 16
//
// `flag` is the group's `enabled` byte (a constant 1 for ungrouped hooks), so a group is switched without touching
// code. The function's first 16 bytes become `ldr x17, #8 ; br x17 ; .quad gate`.

#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

struct DHFunctionHook {
    void *function;       // stripped address
    void *replacement;    // as passed
    void *original;       // the trampoline, signed for calling on arm64e
    DHGroup *group;
    char *name;           // "image`symbol+offset", for dw hooks
    bool stacked;         // went on top of another inline hook
    DHFunctionHook *next; // sFunctionHooks
};

// The function hooks this copy installed, for hook reports (dw hooks). Never removed: hooks aren't undone.
static DHFunctionHook *sFunctionHooks;
static os_unfair_lock sFunctionHooksLock = OS_UNFAIR_LOCK_INIT;

static void *DHStrip(void *p) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(p, ptrauth_key_function_pointer);
#else
    return p;
#endif
}


static NSString *DHDescribeAddress(void *address) {
    Dl_info info;
    if (dladdr(address, &info) && info.dli_fname) {
        const char *image = strrchr(info.dli_fname, '/');
        image = image ? image + 1 : info.dli_fname;
        if (info.dli_sname && info.dli_saddr)
            return [NSString stringWithFormat:@"%s`%s+%ld", image, info.dli_sname,
                                              (long)((char *)address - (char *)DHStrip(info.dli_saddr))];
        return [NSString stringWithFormat:@"%s+0x%lx", image, (unsigned long)((char *)address - (char *)info.dli_fbase)];
    }
    return [NSString stringWithFormat:@"%p", address];
}

#if defined(__arm64__)

static const atomic_bool kDHAlwaysEnabled = true;

static void *DHSignFunction(void *p) {
#if __has_feature(ptrauth_calls)
    return ptrauth_sign_unauthenticated(p, ptrauth_key_function_pointer, 0);
#else
    return p;
#endif
}

/// Writes `length` bytes at `address` in executable memory: copies the page(s), changes the copy, makes it r-x
/// and maps it over the original, so the code there never stops being executable. Returns the failing kernel
/// call's message, or NULL.
static const char *DHWriteCode(void *address, const void *bytes, size_t length) {
    mach_vm_size_t pageSize = vm_page_size;
    mach_vm_address_t start = (mach_vm_address_t)address & ~(pageSize - 1);
    mach_vm_address_t end = ((mach_vm_address_t)address + length + pageSize - 1) & ~(pageSize - 1);
    mach_vm_size_t size = end - start;
    mach_vm_address_t scratch = 0;
    kern_return_t kr = mach_vm_allocate(mach_task_self(), &scratch, size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) return mach_error_string(kr);
    memcpy((void *)scratch, (void *)start, size);
    memcpy((void *)(scratch + ((mach_vm_address_t)address - start)), bytes, length);
    kr = mach_vm_protect(mach_task_self(), scratch, size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr == KERN_SUCCESS) {
        mach_vm_address_t target = start;
        vm_prot_t cur = 0, max = 0;
        kr = mach_vm_remap(mach_task_self(), &target, size, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                           scratch, TRUE, &cur, &max, VM_INHERIT_COPY);
    }
    mach_vm_deallocate(mach_task_self(), scratch, size);
    if (kr != KERN_SUCCESS) return mach_error_string(kr);
    sys_icache_invalidate(address, length);
    return NULL;
}

// Instruction encodings.
static uint32_t DHLdrLiteral(uint32_t rt, int32_t offset) { return 0x58000000u | ((((uint32_t)offset >> 2) & 0x7ffff) << 5) | rt; }
static uint32_t DHBr(uint32_t rn) { return 0xd61f0000u | (rn << 5); }
static uint32_t DHBlr(uint32_t rn) { return 0xd63f0000u | (rn << 5); }
static uint32_t DHB(int32_t offset) { return 0x14000000u | (((uint32_t)offset >> 2) & 0x3ffffff); }
static int64_t DHSignExtend(uint64_t value, int bits) { return (int64_t)(value << (64 - bits)) >> (64 - bits); }

typedef struct { uint32_t words[64]; size_t count; } DHCode;
static void DHEmit(DHCode *c, uint32_t w) { if (c->count < 64) c->words[c->count++] = w; }
static void DHEmit64(DHCode *c, uint64_t v) { DHEmit(c, (uint32_t)v); DHEmit(c, (uint32_t)(v >> 32)); }

/// The patch DHHookFunction writes: `ldr x17, #8 ; br x17 ; .quad destination`.
static BOOL DHIsOurJump(const uint32_t *code) { return code[0] == DHLdrLiteral(17, 8) && code[1] == DHBr(17); }

/// May end the function: a return or an unconditional branch (b, br, braa…), but not a call.
static BOOL DHEndsFlow(uint32_t insn) {
    if ((insn & 0xfc000000u) == 0x14000000u) return YES;                     // b
    if ((insn & 0xfe000000u) == 0xd6000000u) {                               // branch (register)
        if ((insn & 0xfffffc1fu) == 0xd63f0000u) return NO;                  // blr
        if ((insn & 0xfefff800u) == 0xd63f0800u) return NO;                  // blraa, blrab, blraaz, blrabz
        return YES;                                                          // ret, br, retaa, braa…, eret
    }
    return NO;
}

/// Where a b, bl, b.cond, cbz, cbnz, tbz or tbnz at `pc` branches to; NO for other instructions.
static BOOL DHBranchTarget(uint32_t insn, uint64_t pc, uint64_t *target) {
    if ((insn & 0x7c000000u) == 0x14000000u) { *target = pc + (uint64_t)(DHSignExtend(insn & 0x3ffffff, 26) << 2); return YES; }
    if ((insn & 0xff000010u) == 0x54000000u || (insn & 0x7e000000u) == 0x34000000u) {
        *target = pc + (uint64_t)(DHSignExtend((insn >> 5) & 0x7ffff, 19) << 2);
        return YES;
    }
    if ((insn & 0x7e000000u) == 0x36000000u) { *target = pc + (uint64_t)(DHSignExtend((insn >> 5) & 0x3fff, 14) << 2); return YES; }
    return NO;
}

/// Moves one instruction that was at `pc` into `out`, rewriting those that depend on where they are. `inside`
/// tells whether an address is in the bytes being overwritten (whose contents change).
static void DHRelocate(uint32_t insn, uint64_t pc, const uint32_t *original, uint64_t function, DHCode *out) {
    uint32_t rt = insn & 0x1f;
    if ((insn & 0x9f000000u) == 0x10000000u || (insn & 0x9f000000u) == 0x90000000u) {   // adr, adrp
        int64_t imm = DHSignExtend((((insn >> 5) & 0x7ffff) << 2) | ((insn >> 29) & 3), 21);
        uint64_t value = (insn & 0x80000000u) ? (pc & ~0xfffull) + (uint64_t)(imm << 12) : pc + (uint64_t)imm;
        DHEmit(out, DHLdrLiteral(rt, 8)); DHEmit(out, DHB(12)); DHEmit64(out, value);
        return;
    }
    if ((insn & 0x3b000000u) == 0x18000000u) {                                          // ldr (literal)
        uint64_t address = pc + (uint64_t)(DHSignExtend((insn >> 5) & 0x7ffff, 19) << 2);
        uint32_t opc = insn >> 30, simd = (insn >> 26) & 1;
        if (!simd && opc == 3) { DHEmit(out, 0xd503201fu); return; }                     // prfm: nop
        if (!simd && address >= function && address + 8 <= function + 16) {
            // the literal is in the overwritten bytes: load its value now
            uint64_t value = 0;
            memcpy(&value, (const uint8_t *)original + (address - function), opc == 1 ? 8 : 4);
            if (opc == 0) value = (uint32_t)value;
            if (opc == 2) value = (uint64_t)(int64_t)(int32_t)value;
            DHEmit(out, DHLdrLiteral(rt, 8)); DHEmit(out, DHB(12)); DHEmit64(out, value);
            return;
        }
        uint32_t base = simd ? 17 : rt;
        DHEmit(out, DHLdrLiteral(base, 8)); DHEmit(out, DHB(12)); DHEmit64(out, address);
        uint32_t load;
        if (simd) load = opc == 0 ? 0xbd400000u : opc == 1 ? 0xfd400000u : 0x3dc00000u;   // ldr s/d/q, [x17]
        else load = opc == 0 ? 0xb9400000u : opc == 1 ? 0xf9400000u : 0xb9800000u;        // ldr w/x, ldrsw x, [xt]
        DHEmit(out, load | (base << 5) | rt);
        return;
    }
    if ((insn & 0x7c000000u) == 0x14000000u) {                                          // b, bl
        uint64_t target = pc + (uint64_t)(DHSignExtend(insn & 0x3ffffff, 26) << 2);
        if (insn & 0x80000000u) {   // bl: ldr x17, #12 ; blr x17 ; b #12 ; .quad target
            DHEmit(out, DHLdrLiteral(17, 12)); DHEmit(out, DHBlr(17)); DHEmit(out, DHB(12)); DHEmit64(out, target);
        } else {
            DHEmit(out, DHLdrLiteral(17, 8)); DHEmit(out, DHBr(17)); DHEmit64(out, target);
        }
        return;
    }
    uint64_t target = 0;
    uint32_t moved = 0;
    if ((insn & 0xff000010u) == 0x54000000u) {                                          // b.cond
        target = pc + (uint64_t)(DHSignExtend((insn >> 5) & 0x7ffff, 19) << 2);
        moved = (insn & ~(0x7ffffu << 5)) | (2u << 5);
    } else if ((insn & 0x7e000000u) == 0x34000000u) {                                   // cbz, cbnz
        target = pc + (uint64_t)(DHSignExtend((insn >> 5) & 0x7ffff, 19) << 2);
        moved = (insn & ~(0x7ffffu << 5)) | (2u << 5);
    } else if ((insn & 0x7e000000u) == 0x36000000u) {                                   // tbz, tbnz
        target = pc + (uint64_t)(DHSignExtend((insn >> 5) & 0x3fff, 14) << 2);
        moved = (insn & ~(0x3fffu << 5)) | (2u << 5);
    }
    if (moved) {   // the same test, now to +8: [test → +8] [b +20] [ldr x17, #8] [br x17] [.quad target]
        DHEmit(out, moved); DHEmit(out, DHB(20)); DHEmit(out, DHLdrLiteral(17, 8)); DHEmit(out, DHBr(17));
        DHEmit64(out, target);
        return;
    }
    DHEmit(out, insn);
}

static DHFunctionHook *DHInstallFunctionHook(void *function, void *replacement, DHGroup *group,
                                             DHFunctionHook **outHook) {
    uint8_t *target = DHStrip(function);
    NSString *name = DHDescribeAddress(target);
    uint32_t code[4];
    memcpy(code, target, sizeof code);

    // The original: the first four instructions moved, then back into the function.
    DHCode trampoline = {.count = 0};
    if (DHIsOurJump(code)) {
        uint64_t previous = (uint64_t)code[2] | ((uint64_t)code[3] << 32);   // an earlier hook's gate
        DHEmit(&trampoline, DHLdrLiteral(17, 8)); DHEmit(&trampoline, DHBr(17)); DHEmit64(&trampoline, previous);
    } else {
        for (int i = 0; i < 3; i++) {
            if (DHEndsFlow(code[i])) {
                DHLog(@"DHHookFunction %@: not hooked: instruction %d of its first four returns or branches away, so it "
                      @"may be shorter than the 16 bytes the jump needs", name, i + 1);
                return NULL;
            }
        }
        for (int i = 0; i < 4; i++) {
            uint64_t to = 0;
            if (DHBranchTarget(code[i], (uint64_t)target + 4 * i, &to) && to > (uint64_t)target && to < (uint64_t)target + 16) {
                DHLog(@"DHHookFunction %@: not hooked: instruction %d branches into the first 16 bytes, which the jump "
                      @"overwrites", name, i + 1);
                return NULL;
            }
        }
        for (int i = 0; i < 4; i++) DHRelocate(code[i], (uint64_t)target + 4 * i, code, (uint64_t)target, &trampoline);
        DHEmit(&trampoline, DHLdrLiteral(17, 8)); DHEmit(&trampoline, DHBr(17)); DHEmit64(&trampoline, (uint64_t)target + 16);
    }

    // The hook's page: gate at 0, trampoline at 64.
    mach_vm_address_t page = 0;
    kern_return_t kr = mach_vm_allocate(mach_task_self(), &page, vm_page_size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        DHLog(@"DHHookFunction %@: not hooked: allocate: %s", name, mach_error_string(kr));
        return NULL;
    }
    uint32_t *gate = (uint32_t *)page;
    uint32_t *tramp = (uint32_t *)(page + 64);
    const atomic_bool *flag = group ? &group->enabled : &kDHAlwaysEnabled;
    gate[0] = DHLdrLiteral(16, 32);                  // ldr x16, flag
    gate[1] = 0x39400000u | (16u << 5) | 16u;        // ldrb w16, [x16]
    gate[2] = 0x34000000u | (3u << 5) | 16u;         // cbz w16, +12 (gate[5])
    gate[3] = DHLdrLiteral(16, 28);                  // ldr x16, replacement
    gate[4] = DHBr(16);
    gate[5] = DHLdrLiteral(16, 28);                  // ldr x16, trampoline
    gate[6] = DHBr(16);
    gate[7] = 0xd503201fu;                           // nop (keeps the literals 8-byte aligned)
    uint64_t literals[3] = {(uint64_t)flag, (uint64_t)DHStrip(replacement), (uint64_t)tramp};
    memcpy(&gate[8], literals, sizeof literals);
    memcpy(tramp, trampoline.words, trampoline.count * 4);
    kr = mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        DHLog(@"DHHookFunction %@: not hooked: this process may not run code it made (%s)", name, mach_error_string(kr));
        mach_vm_deallocate(mach_task_self(), page, vm_page_size);
        return NULL;
    }
    sys_icache_invalidate((void *)page, vm_page_size);

    DHFunctionHook *hook = calloc(1, sizeof *hook);
    hook->function = target;
    hook->replacement = replacement;
    hook->original = DHSignFunction(tramp);
    hook->group = group;
    if (outHook) *outHook = hook;

    // Log before the jump goes in: once it's there, any call to the function goes to the replacement, which may call
    // the original through a handle its caller hasn't received yet. Logging formats strings, and the function may be
    // strlen or anything else formatting uses. Nothing after the write calls out (a failed write changed nothing).
    hook->stacked = DHIsOurJump(code);
    hook->name = strdup(name.UTF8String);
    DHLog(@"DHHookFunction %@: hooking%s", name, hook->stacked ? " (on top of another hook)" : "");
    DHLogHookMap(replacement, name.UTF8String);
    DHReportRegister();
    uint32_t jump[4] = {DHLdrLiteral(17, 8), DHBr(17), (uint32_t)page, (uint32_t)((uint64_t)page >> 32)};
    const char *error = DHWriteCode(target, jump, sizeof jump);
    if (error) {
        DHLog(@"DHHookFunction %@: not hooked: patching its code failed (%s)", name, error);
        return NULL;   // hook and page are left: *outHook may already point at the hook
    }
    os_unfair_lock_lock(&sFunctionHooksLock);
    hook->next = sFunctionHooks;
    sFunctionHooks = hook;
    os_unfair_lock_unlock(&sFunctionHooksLock);
    return hook;
}

#endif

DHFunctionHook *DHHookFunctionEx(void *function, void *replacement, DHGroup *group, DHFunctionHook **outHook) {
    if (!function || !replacement) {
        DHLog(@"DHHookFunction: %s is NULL", function ? "replacement" : "function");
        return NULL;
    }
#if defined(__arm64__)
    os_unfair_lock *processLock = DHProcessLock();   // the same function patched by two copies at once
    os_unfair_lock_lock(processLock);
    DHFunctionHook *hook = DHInstallFunctionHook(function, replacement, group, outHook);
    os_unfair_lock_unlock(processLock);
    return hook;
#else
    (void)group; (void)outHook;
    DHLog(@"DHHookFunction %@: not hooked: inline hooks are arm64 only", DHDescribeAddress(function));
    return NULL;
#endif
}

DHFunctionHook *DHHookFunction(void *function, void *replacement, DHGroup *group) {
    return DHHookFunctionEx(function, replacement, group, NULL);
}

void *DHFunctionOriginal(DHFunctionHook *hook) { return hook ? hook->original : NULL; }

BOOL DHFunctionHookIsActive(DHFunctionHook *hook) {
    if (!hook) return NO;
    return hook->group ? atomic_load(&hook->group->enabled) : YES;
}

#pragma mark - Hook reports (dw hooks)

// `dw hooks <app>` asks every DynjectHook copy in a process what it has hooked. It sets the state of the Darwin
// notification "dynject.hooks.report.<pid>" to a request (low 32 bits: an ID; bit 32: also scan for methods replaced
// from tweak dylibs by other means) and posts it. Every copy that is active (DHShouldLoad said yes, or it installed a
// hook) answers with lines in the unified log, subsystem "dynject.hooks": begin, one line per method hook and per
// import hook, end. One copy per request, elected through an associated object of NSObject, also runs the scan.
// Darwin notifications and logging both work in sandboxed apps. dw parses the lines (DynjectCore/HookReport.swift):
// keep their format and the "dynject.hooks:" marker below as they are.
__attribute__((used)) static const char *const DHHookReportCapability = "dynject.hooks:report-v1";

static atomic_bool sReportRegistered;
static int sReportToken = -1;
static void (*sReportSinkForTesting)(const char *line);

static os_log_t DHReportLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("dynject.hooks", "report"); });
    return log;
}

// A crash report names the function a tweak crashed in, not the method that function replaces. So each hook says
// once, when it's made, which method its replacement stands for: "dynject.hooks:map <image file> 0x<the
// replacement's offset in it> <-[Class selector] | import symbol>", subsystem "dynject.hooks", category "map".
// Safe Mode reads them back for a crashed process (DynjectCore/CrashSymbols.swift): keep the format.
static os_log_t DHMapLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("dynject.hooks", "map"); });
    return log;
}

static void DHLogHookMap(void *replacement, const char *target) {
    void *code = DHImportStrip(replacement);
    Dl_info info;
    if (!code || !dladdr(code, &info) || !info.dli_fbase || !info.dli_fname) return;
    const char *file = strrchr(info.dli_fname, '/');
    char line[700];
    snprintf(line, sizeof line, "dynject.hooks:map %s 0x%llx %s", file ? file + 1 : info.dli_fname,
             (unsigned long long)((uintptr_t)code - (uintptr_t)info.dli_fbase), target);
    if (sReportSinkForTesting) sReportSinkForTesting(line);
    os_log(DHMapLog(), "%{public}s", line);
}

static void DHReportLine(const char *format, ...) __attribute__((format(printf, 1, 2)));
static void DHReportLine(const char *format, ...) {
    char line[960];
    va_list args;
    va_start(args, format);
    vsnprintf(line, sizeof line, format, args);
    va_end(args);
    if (sReportSinkForTesting) sReportSinkForTesting(line);
    else os_log(DHReportLog(), "%{public}s", line);
}

static const char *DHReportStateName(DHHookState state) {
    switch (state) {
        case DHHookStatePending: return "pending";
        case DHHookStateInstalled: return "installed";
        case DHHookStateRestored: return "restored";
        case DHHookStateBuried: return "buried";
    }
    return "?";
}

typedef struct {
    __unsafe_unretained Class cls;
    SEL sel;
    DHHookState state;
    IMP replacement;
    const char *group;
    BOOL active;
} DHReportHook;

typedef struct {
    char *symbol;
    const char *library;
    size_t sites;
    BOOL active;
} DHReportImport;

// Whether this copy is the one that scans for request `request` (the first to ask).
static BOOL DHReportElected(uint32_t request) {
    id host = (id)objc_getClass("NSObject");
    char name[64];
    snprintf(name, sizeof name, "dynject.hooks.scan.%u", request);
    const void *key = sel_registerName(name);
    BOOL mine = NO;
    if (host && objc_sync_enter(host) == OBJC_SYNC_SUCCESS) {
        if (!objc_getAssociatedObject(host, key)) {
            objc_setAssociatedObject(host, key, @YES, OBJC_ASSOCIATION_RETAIN);
            mine = YES;
        }
        objc_sync_exit(host);
    }
    return mine;
}

// Methods of classes from other images whose implementation is in a tweak dylib (one in a "lib/tweaks/" folder):
// what every hooking library leaves behind, DynjectHook's own hooks included (dw sets those apart), and categories.
static void DHReportScan(uint32_t request) {
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    typedef struct { uintptr_t start, end; const char *path; } DHRange;
    DHRange ranges[64];
    size_t rangeCount = 0;
    uint32_t images = _dyld_image_count();
    for (uint32_t i = 0; i < images && rangeCount < 64; i++) {
        const char *path = _dyld_get_image_name(i);
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!path || !strstr(path, "/lib/tweaks/") || !mh || mh->magic != MH_MAGIC_64) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const uint8_t *cursor = (const uint8_t *)((const struct mach_header_64 *)mh + 1);
        for (uint32_t c = 0; c < mh->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cursor;
            cursor += lc->cmdsize;
            if (lc->cmd != LC_SEGMENT_64 || strcmp(((const struct segment_command_64 *)lc)->segname, SEG_TEXT) != 0) continue;
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            ranges[rangeCount++] = (DHRange){(uintptr_t)(seg->vmaddr + slide), (uintptr_t)(seg->vmaddr + slide + seg->vmsize), path};
            break;
        }
    }
    DHReportLine("R %u scan-begin tweak-images=%zu", request, rangeCount);
    size_t found = 0;
    if (rangeCount) {
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        for (unsigned int i = 0; i < classCount && found < 500; i++) {
            const char *classImage = class_getImageName(classes[i]) ?: "?";
            for (int meta = 0; meta < 2; meta++) {
                Class k = meta ? object_getClass(classes[i]) : classes[i];
                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList(k, &methodCount);
                for (unsigned int m = 0; m < methodCount && found < 500; m++) {
                    uintptr_t imp = (uintptr_t)DHImportStrip((void *)method_getImplementation(methods[m]));
                    for (size_t r = 0; r < rangeCount; r++) {
                        if (imp < ranges[r].start || imp >= ranges[r].end || strcmp(ranges[r].path, classImage) == 0) continue;
                        DHReportLine("R %u foreign %c %s %s imp=%s class=%s", request, meta ? '+' : '-', class_getName(classes[i]),
                                     sel_getName(method_getName(methods[m])), ranges[r].path, classImage);
                        found++;
                        break;
                    }
                }
                free(methods);
            }
        }
        free(classes);
    }
    DHReportLine("R %u scan-end found=%zu ms=%.0f", request, found, (CFAbsoluteTimeGetCurrent() - start) * 1000);
}

static void DHReportAnswer(uint64_t state) {
    uint32_t request = (uint32_t)state;
    if (!request) return;
    BOOL scan = ((state >> 32) & 1) != 0;
    char tweak[256];
    os_unfair_lock_lock(&sLogLock);
    snprintf(tweak, sizeof tweak, "%s", sLogSubsystem ?: "-");
    os_unfair_lock_unlock(&sLogLock);
    Dl_info info;
    const char *image = dladdr((const void *)&DHReportAnswer, &info) && info.dli_fname ? info.dli_fname : "?";

    os_unfair_lock_lock(&sLock);
    size_t hookCount = 0;
    for (DHSite *s = sSites; s; s = s->next) for (DHHook *h = s->hooks; h; h = h->nextAtSite) hookCount++;
    DHReportHook *hooks = calloc(hookCount ? hookCount : 1, sizeof *hooks);
    size_t n = 0;
    for (DHSite *s = sSites; s && hooks; s = s->next) {
        for (DHHook *h = s->hooks; h; h = h->nextAtSite) {
            hooks[n++] = (DHReportHook){h->cls, h->sel, h->state, h->replacement, h->group ? h->group->name : NULL,
                                        atomic_load(&h->active) ? YES : NO};
        }
    }
    os_unfair_lock_unlock(&sLock);

    os_unfair_lock_lock(&sImportLock);
    size_t importCount = 0;
    for (DHImportHook *h = sImportHooks; h; h = h->next) importCount++;
    DHReportImport *imports = calloc(importCount ? importCount : 1, sizeof *imports);
    size_t m = 0;
    for (DHImportHook *h = sImportHooks; h && imports; h = h->next) {
        size_t sites = 0;
        for (DHImportSite *s = h->sites; s; s = s->next) sites += s->installed ? 1 : 0;
        imports[m++] = (DHReportImport){h->symbol, h->library, sites, atomic_load(&h->active) ? YES : NO};
    }
    os_unfair_lock_unlock(&sImportLock);

    DHReportLine("R %u begin %s sdk=%s image=%s", request, tweak, DH_SDK_VERSION, image);
    for (size_t i = 0; i < n; i++) {
        Method method = class_getInstanceMethod(hooks[i].cls, hooks[i].sel);
        BOOL top = method && method_getImplementation(method) == hooks[i].replacement;
        DHReportLine("R %u hook %s %c %s %s %s %s group=%s", request, tweak, class_isMetaClass(hooks[i].cls) ? '+' : '-',
                     class_getName(hooks[i].cls), sel_getName(hooks[i].sel), DHReportStateName(hooks[i].state),
                     top ? "top" : "beneath", hooks[i].group ?: "-");
    }
    for (size_t i = 0; i < m; i++) {
        DHReportLine("R %u import %s %s lib=%s sites=%zu %s", request, tweak, imports[i].symbol + 1, imports[i].library ?: "-",
                     imports[i].sites, imports[i].active ? "active" : "inactive");
    }
    // Function hooks (DHHookFunction): the name has no spaces ("image`symbol+offset" or an address).
    os_unfair_lock_lock(&sFunctionHooksLock);
    size_t functionCount = 0;
    for (DHFunctionHook *f = sFunctionHooks; f; f = f->next) {
        DHReportLine("R %u function %s 0x%llx %s %s %s group=%s", request, tweak, (unsigned long long)(uintptr_t)f->function,
                     f->name ?: "?", DHFunctionHookIsActive(f) ? "active" : "inactive", f->stacked ? "stacked" : "first",
                     f->group ? f->group->name : "-");
        functionCount++;
    }
    os_unfair_lock_unlock(&sFunctionHooksLock);
    DHReportLine("R %u end %s hooks=%zu imports=%zu functions=%zu", request, tweak, n, m, functionCount);
    free(hooks);
    free(imports);
    if (scan && DHReportElected(request)) DHReportScan(request);
}

// Called when the copy becomes active: DHShouldLoad says yes, or a hook is installed.
static void DHReportRegister(void) {
    if (atomic_exchange(&sReportRegistered, true)) return;
    char name[64];
    snprintf(name, sizeof name, "dynject.hooks.report.%d", getpid());
    notify_register_dispatch(name, &sReportToken, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(int token) {
        uint64_t state = 0;
        notify_get_state(token, &state);
        DHReportAnswer(state);
    });
}

void DHSetReportSinkForTesting(void (*sink)(const char *line)) { sReportSinkForTesting = sink; }

void DHReportForTesting(uint64_t request) {
    DHReportRegister();
    DHReportAnswer(request);
}

#pragma mark - Load policy

void DHSetPreferencesDomainForTesting(CFStringRef domain) {
    char *copy = NULL;
    if (domain) {
        CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(domain), kCFStringEncodingUTF8) + 1;
        copy = malloc((size_t)size);
        if (copy && !CFStringGetCString(domain, copy, size, kCFStringEncodingUTF8)) {
            free(copy);
            copy = NULL;
        }
        if (!copy) DHLog(@"DHSetPreferencesDomainForTesting: could not copy the domain; using the default");
    }
    os_unfair_lock_lock(&sLock);
    char *previous = sTestPreferencesDomain;
    sTestPreferencesDomain = copy;
    os_unfair_lock_unlock(&sLock);
    free(previous);
}

void DHSetBundleIdentifierForTesting(const char *bundleID) {
    char *copy = bundleID ? strdup(bundleID) : NULL;
    os_unfair_lock_lock(&sLock);
    char *previous = sTestBundleIdentifier;
    sTestBundleIdentifier = copy;
    os_unfair_lock_unlock(&sLock);
    free(previous);
}

// A copy of one of the testing overrides (the caller frees it), or NULL if it is not set.
static char *DHCopyOverride(char *const *override) {
    os_unfair_lock_lock(&sLock);
    char *copy = *override ? strdup(*override) : NULL;
    os_unfair_lock_unlock(&sLock);
    return copy;
}

// The identifier DHShouldLoad compares against (the caller releases it); NULL if the process has none.
static CFStringRef DHCopyBundleIdentifier(void) {
    char *override = DHCopyOverride(&sTestBundleIdentifier);
    if (override) {
        CFStringRef identifier = CFStringCreateWithCString(kCFAllocatorDefault, override, kCFStringEncodingUTF8);
        free(override);
        return identifier;
    }
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFStringRef identifier = bundle ? CFBundleGetIdentifier(bundle) : NULL;
    return identifier ? CFStringCreateCopy(kCFAllocatorDefault, identifier) : NULL;
}

static BOOL DHStringEqualsCString(CFStringRef string, const char *cString) {
    if (!string || !cString) return NO;
    CFStringRef other = CFStringCreateWithCString(kCFAllocatorDefault, cString, kCFStringEncodingUTF8);
    if (!other) return NO;
    BOOL equal = CFEqual(string, other) ? YES : NO;
    CFRelease(other);
    return equal;
}

// Whether `apps` (any CF value) is an array that contains "*" or `bundleID`. Elements that are not
// strings are skipped; any other kind of value counts as absent.
static BOOL DHSafeModeListMatches(CFTypeRef apps, CFStringRef bundleID) {
    if (!apps || CFGetTypeID(apps) != CFArrayGetTypeID()) return NO;
    CFIndex count = CFArrayGetCount((CFArrayRef)apps);
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef app = CFArrayGetValueAtIndex((CFArrayRef)apps, i);
        if (!app || CFGetTypeID(app) != CFStringGetTypeID()) continue;
        if (CFEqual(app, CFSTR("*")) || (bundleID && CFEqual(app, bundleID))) return YES;
    }
    return NO;
}

typedef enum {
    DHSafeModeOff = 0,
    DHSafeModeForTweak,   // the tweak's own entry lists this app (or "*")
    DHSafeModeForAll,     // the "*" entry (the panic switch) lists this app (or "*")
} DHSafeModeMatch;

// Whether "dynject.safemode" lists this app (or "*") for the tweak, either under the tweak's ID or
// under "*", which applies to every tweak. Values of the wrong type anywhere count as absent.
static DHSafeModeMatch DHSafeModeApplies(const char *tweakID, CFStringRef bundleID) {
    CFStringRef domain = NULL;
    char *override = DHCopyOverride(&sTestPreferencesDomain);
    if (override) {
        domain = CFStringCreateWithCString(kCFAllocatorDefault, override, kCFStringEncodingUTF8);
        free(override);
        if (!domain) return DHSafeModeOff;
    } else {
        domain = CFRetain(kCFPreferencesAnyApplication);
    }
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPropertyListRef value = CFPreferencesCopyValue(CFSTR("dynject.safemode"), domain,
                                                     kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(domain);
    DHSafeModeMatch match = DHSafeModeOff;
    CFStringRef key = CFStringCreateWithCString(kCFAllocatorDefault, tweakID, kCFStringEncodingUTF8);
    if (value && CFGetTypeID(value) == CFDictionaryGetTypeID()) {
        CFDictionaryRef entries = (CFDictionaryRef)value;
        if (key && DHSafeModeListMatches(CFDictionaryGetValue(entries, key), bundleID)) {
            match = DHSafeModeForTweak;
        } else if (DHSafeModeListMatches(CFDictionaryGetValue(entries, CFSTR("*")), bundleID)) {
            match = DHSafeModeForAll;
        }
    }
    if (key) CFRelease(key);
    if (value) CFRelease(value);
    return match;
}

static BOOL DHShiftKeyIsDown(void) {
    if (getenv("DH_DISABLE_SHIFT_BYPASS")) return NO;
    CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    return (flags & kCGEventFlagMaskShift) ? YES : NO;
}

#pragma mark - Safe Mode capabilities

// Read by Dynject Workbench's Safe Mode support check (SafeModeSupportChecker.panicMarker): this build honours
// the "*" entry of "dynject.safemode" (the panic switch, or every tweak in one app). Builds without it honour
// only the tweak's own entry. Keep the string exactly as it is.
__attribute__((used)) static const char *const DHSafeModeCapabilities = "dynject.safemode:all-tweaks";

BOOL DHShouldLoad(const char *tweakID, const char *const *bundleIDs) {
    if (!tweakID || !tweakID[0]) {
        DHLog(@"DHShouldLoad: the tweak ID must not be NULL or empty; not loading");
        return NO;
    }
    CFStringRef bundleID = DHCopyBundleIdentifier();
    NSString *reason = nil;
    if (bundleIDs && bundleIDs[0]) {
        BOOL listed = NO;
        for (const char *const *candidate = bundleIDs; *candidate && !listed; candidate++) {
            listed = DHStringEqualsCString(bundleID, *candidate);
        }
        if (!listed) reason = @"this app is not one of the tweak's target apps";
    }
    if (!reason) {
        switch (DHSafeModeApplies(tweakID, bundleID)) {
            case DHSafeModeForTweak: reason = @"Safe Mode is on for this tweak in this app (dynject.safemode)"; break;
            case DHSafeModeForAll: reason = @"Safe Mode is on for all tweaks in this app (dynject.safemode \"*\")"; break;
            case DHSafeModeOff: break;
        }
    }
    if (!reason && DHShiftKeyIsDown()) reason = @"the Shift key is held down";
    if (reason) {
        DHLog(@"%s: not loading into %@: %@", tweakID, bundleID ? (__bridge NSString *)bundleID : @"(no bundle identifier)", reason);
    }
    if (bundleID) CFRelease(bundleID);
    if (!reason) DHReportRegister();
    return reason ? NO : YES;
}

#pragma mark - SDK version

// Read by Dynject Workbench's SDK version check (SDKVersionChecker): which DynjectHook built this dylib.
// DH_SDK_VERSION equals WorkbenchInfo.version (a test checks). Keep the "dynject.sdk:" prefix exactly as it is.
__attribute__((used)) static const char *const DHSDKVersionMarker = "dynject.sdk:" DH_SDK_VERSION;

#pragma mark - System version

// Parses "27", "27.0" or "27.2.1" into three numbers (missing ones 0). NO for anything else.
static BOOL DHParseSystemVersion(const char *string, NSInteger out[3]) {
    if (!string || !string[0]) return NO;
    out[0] = out[1] = out[2] = 0;
    int index = 0;
    const char *p = string;
    while (1) {
        if (*p < '0' || *p > '9') return NO;
        NSInteger value = 0;
        int digits = 0;
        while (*p >= '0' && *p <= '9') {
            if (++digits > 6) return NO;
            value = value * 10 + (*p - '0');
            p++;
        }
        out[index++] = value;
        if (*p == '\0') return YES;
        if (*p != '.' || index == 3) return NO;
        p++;
    }
}

void DHSetSystemVersionForTesting(const char *version) {
    char *copy = version ? strdup(version) : NULL;
    os_unfair_lock_lock(&sLock);
    char *previous = sTestSystemVersion;
    sTestSystemVersion = copy;
    os_unfair_lock_unlock(&sLock);
    free(previous);
}

// The running macOS (or the testing override) into `out`. NO when it can't be known: the 10.16 an app
// built against an old SDK is told, or a malformed override.
static BOOL DHRunningSystemVersion(NSInteger out[3]) {
    char *override = DHCopyOverride(&sTestSystemVersion);
    if (override) {
        BOOL ok = DHParseSystemVersion(override, out);
        free(override);
        if (!ok) return NO;
    } else {
        NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
        out[0] = v.majorVersion;
        out[1] = v.minorVersion;
        out[2] = v.patchVersion;
    }
    return (out[0] == 10 && out[1] == 16) ? NO : YES;
}

static NSComparisonResult DHCompareSystemVersions(const NSInteger a[3], const NSInteger b[3]) {
    for (int i = 0; i < 3; i++) {
        if (a[i] < b[i]) return NSOrderedAscending;
        if (a[i] > b[i]) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

BOOL DHSystemVersionAtLeast(const char *version) {
    NSInteger wanted[3];
    if (!DHParseSystemVersion(version, wanted)) {
        DHLog(@"DHSystemVersionAtLeast: \"%s\" is not a macOS version such as \"27.0\"", version ?: "(NULL)");
        return NO;
    }
    NSInteger running[3];
    if (!DHRunningSystemVersion(running)) return YES;
    return DHCompareSystemVersions(running, wanted) != NSOrderedAscending ? YES : NO;
}

BOOL DHRequireSystemVersion(const char *version) {
    if (DHSystemVersionAtLeast(version)) return YES;
    NSInteger running[3] = {0, 0, 0};
    DHRunningSystemVersion(running);
    DHLog(@"requires macOS %s or later, this is %ld.%ld.%ld: not loading", version ?: "(NULL)",
          (long)running[0], (long)running[1], (long)running[2]);
    return NO;
}
