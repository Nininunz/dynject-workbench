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

static const CFIndex kDHParsedFunctionLimit = 4096;

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
    return reason ? NO : YES;
}
