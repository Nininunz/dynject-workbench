// Concurrency smoke tests: concurrent installs on distinct classes, and hooked
// methods called concurrently while their group is toggled.

#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>
#import "DynjectHook.h"

#define DHT_CONC_CLASSES 48

static DHHook *gConcHooks[DHT_CONC_CLASSES];

@interface DHTConcToggle : NSObject
- (NSInteger)value;
@end
@implementation DHTConcToggle
- (NSInteger)value { return 1; }
@end

@interface DHTConcInhBase : NSObject
- (NSInteger)value;
@end
@implementation DHTConcInhBase
- (NSInteger)value { return 1; }
@end
@interface DHTConcInhChild : DHTConcInhBase
@end
@implementation DHTConcInhChild
@end

static DHHook *gToggleHook;
static NSInteger DHTConcToggle_value(id self, SEL _cmd) {
    return DH_CALL_ORIG(gToggleHook, NSInteger (*)(id, SEL), self, _cmd) + 10;
}
static DHHook *gToggleInhHook;
static NSInteger DHTConcInhChild_value(id self, SEL _cmd) {
    return DH_CALL_ORIG(gToggleInhHook, NSInteger (*)(id, SEL), self, _cmd) + 10;
}

// Hooks installed while other threads call the method (see testInstallWhileMethodIsBeingCalled).
#define DHT_LIVE_CLASSES 256
static Class gLiveClasses[DHT_LIVE_CLASSES];
static DHHook *gLiveHooks[DHT_LIVE_CLASSES];   // written by DHHookMessageEx
static _Atomic long gLiveNullHandles;
static _Atomic long gLiveCurrent;

static NSInteger DHTLive_original(__unused id self, __unused SEL _cmd) { return 1; }

// One replacement for all the classes; a class's index is in its extra bytes.
static NSInteger DHTLive_value(id self, SEL _cmd) {
    NSInteger index = *(NSInteger *)object_getIndexedIvars(object_getClass(self));
    DHHook *hook = __atomic_load_n(&gLiveHooks[index], __ATOMIC_ACQUIRE);
    if (!hook) {
        // DH_CALL_ORIG would call a NULL function pointer here.
        atomic_fetch_add(&gLiveNullHandles, 1);
        return 11;
    }
    return DH_CALL_ORIG(hook, NSInteger (*)(id, SEL), self, _cmd) + 10;
}

// Waits until more than `seen` calls have completed. NO if none does for 10 seconds.
static BOOL DHTWaitForCalls(_Atomic long *calls, long seen) {
    uint64_t deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 10 * NSEC_PER_SEC;
    while (atomic_load(calls) <= seen) {
        if (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) > deadline) return NO;
        usleep(20);
    }
    return YES;
}

@interface DynjectHookTestsConcurrency : XCTestCase
@end

@implementation DynjectHookTestsConcurrency

- (void)testConcurrentInstallsOnDistinctClasses {
    SEL sel = sel_registerName("dhtConcValue");
    static Class classes[DHT_CONC_CLASSES]; // static: blocks cannot capture C arrays
    for (NSInteger i = 0; i < DHT_CONC_CLASSES; i++) {
        char name[64];
        snprintf(name, sizeof(name), "DHTConcClass_%ld", (long)i);
        Class cls = objc_allocateClassPair([NSObject class], name, 0);
        XCTAssertTrue(cls != Nil);
        NSInteger value = i;
        class_addMethod(cls, sel, imp_implementationWithBlock(^NSInteger(__unused id self) { return value; }), "q@:");
        objc_registerClassPair(cls);
        classes[i] = cls;
    }
    // Half the hooks join groups created concurrently as well.
    dispatch_apply(DHT_CONC_CLASSES, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
        DHGroup *group = NULL;
        if (i % 2 == 0) {
            char groupName[64];
            snprintf(groupName, sizeof(groupName), "dht.conc.%zu", i);
            group = DHGroupCreate(groupName);
        }
        IMP replacement = imp_implementationWithBlock(^NSInteger(id self) {
            NSInteger orig = ((NSInteger (*)(id, SEL))DHOriginal(gConcHooks[i]))(self, sel);
            return orig + 1000;
        });
        gConcHooks[i] = DHHookMessage(classes[i], sel, replacement, group);
    });

    for (NSInteger i = 0; i < DHT_CONC_CLASSES; i++) {
        XCTAssertTrue(gConcHooks[i] != NULL, @"hook %ld", (long)i);
        XCTAssertTrue(DHHookIsActive(gConcHooks[i]));
        for (NSInteger j = 0; j < i; j++) XCTAssertTrue(gConcHooks[i] != gConcHooks[j]);
        id obj = [[classes[i] alloc] init];
        XCTAssertEqual(((NSInteger (*)(id, SEL))objc_msgSend)(obj, sel), i + 1000, @"class %ld", (long)i);
    }

    // And call them all concurrently.
    static _Atomic long bad;
    atomic_store(&bad, 0);
    dispatch_apply(DHT_CONC_CLASSES * 8, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t k) {
        size_t i = k % DHT_CONC_CLASSES;
        id obj = [[classes[i] alloc] init];
        if (((NSInteger (*)(id, SEL))objc_msgSend)(obj, sel) != (NSInteger)i + 1000) atomic_fetch_add(&bad, 1);
    });
    XCTAssertEqual(atomic_load(&bad), 0);
}

// A hook installed after launch (from a DHWhenClassLoads block, say) goes onto a
// method other threads may be calling at that very moment. DHHookMessage can
// only return the handle after the replacement is live, so such a call can find
// the replacement's handle variable still NULL; DHHookMessageEx writes the
// handle first.
- (void)testInstallWhileMethodIsBeingCalled {
    SEL sel = sel_registerName("dhtLiveValue");
    for (NSInteger i = 0; i < DHT_LIVE_CLASSES; i++) {
        char name[64];
        snprintf(name, sizeof(name), "DHTLiveClass_%ld", (long)i);
        Class cls = objc_allocateClassPair([NSObject class], name, sizeof(NSInteger));
        XCTAssertTrue(cls != Nil);
        class_addMethod(cls, sel, (IMP)DHTLive_original, "q@:");
        objc_registerClassPair(cls);
        *(NSInteger *)object_getIndexedIvars(cls) = i;
        gLiveClasses[i] = cls;
    }

    static _Atomic long bad;
    static _Atomic long calls;
    static _Atomic int stop;
    atomic_store(&bad, 0);
    atomic_store(&calls, 0);
    atomic_store(&stop, 0);
    atomic_store(&gLiveNullHandles, 0);
    atomic_store(&gLiveCurrent, 0);

    // The callers stay on the class that is about to be hooked.
    dispatch_group_t workers = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    for (int t = 0; t < 4; t++) {
        dispatch_group_async(workers, queue, ^{
            long index = -1;
            id obj = nil;
            while (!atomic_load(&stop)) {
                long current = atomic_load(&gLiveCurrent);
                if (current != index) {
                    index = current;
                    obj = [[gLiveClasses[index] alloc] init];
                }
                NSInteger value = ((NSInteger (*)(id, SEL))objc_msgSend)(obj, sel);
                if (value != 1 && value != 11) atomic_fetch_add(&bad, 1);
                atomic_fetch_add(&calls, 1);
            }
        });
    }
    XCTAssertTrue(DHTWaitForCalls(&calls, 0), @"the callers never started");
    for (NSInteger i = 0; i < DHT_LIVE_CLASSES; i++) {
        atomic_store(&gLiveCurrent, i);
        XCTAssertTrue(DHTWaitForCalls(&calls, atomic_load(&calls) + 8), @"the callers stalled");
        DHHook *hook = DHHookMessageEx(gLiveClasses[i], sel, (IMP)DHTLive_value, NULL, &gLiveHooks[i]);
        XCTAssertTrue(hook != NULL && hook == gLiveHooks[i], @"class %ld", (long)i);
    }
    XCTAssertTrue(DHTWaitForCalls(&calls, atomic_load(&calls)));
    atomic_store(&stop, 1);
    XCTAssertEqual(dispatch_group_wait(workers, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)), 0);

    XCTAssertEqual(atomic_load(&gLiveNullHandles), 0,
                   @"a call reached the replacement before its handle was stored");
    XCTAssertEqual(atomic_load(&bad), 0, @"results must be 1 (original) or 11 (hooked)");
    for (NSInteger i = 0; i < DHT_LIVE_CLASSES; i++) {
        id obj = [[gLiveClasses[i] alloc] init];
        XCTAssertEqual(((NSInteger (*)(id, SEL))objc_msgSend)(obj, sel), 11, @"class %ld", (long)i);
    }
}

// Callers only ever see the hooked or the original result while other threads
// toggle the group; afterwards the final state is exact.
- (void)testCallsWhileGroupIsToggled {
    DHGroup *group = DHGroupCreate("dht.conc.toggle");
    gToggleHook = DHHookMessage([DHTConcToggle class], @selector(value), (IMP)DHTConcToggle_value, group);
    gToggleInhHook = DHHookMessage([DHTConcInhChild class], @selector(value), (IMP)DHTConcInhChild_value, group);
    XCTAssertTrue(gToggleHook != NULL && gToggleInhHook != NULL);
    XCTAssertEqual([[DHTConcToggle new] value], 11);
    XCTAssertEqual([[DHTConcInhChild new] value], 11);

    static _Atomic long bad;
    static _Atomic long calls;
    static _Atomic long stalls;
    static _Atomic int stop;
    atomic_store(&bad, 0);
    atomic_store(&calls, 0);
    atomic_store(&stalls, 0);
    atomic_store(&stop, 0);

    dispatch_group_t workers = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    for (int t = 0; t < 6; t++) {
        dispatch_group_async(workers, queue, ^{
            DHTConcToggle *own = [DHTConcToggle new];
            DHTConcInhChild *inherited = [DHTConcInhChild new];
            while (!atomic_load(&stop)) {
                NSInteger a = [own value];
                NSInteger b = [inherited value];
                if ((a != 1 && a != 11) || (b != 1 && b != 11)) atomic_fetch_add(&bad, 1);
                atomic_fetch_add(&calls, 1);
            }
        });
    }
    // Two togglers at once, then one; the group must end up consistent.
    //
    // Every toggle changes method implementations, which makes the runtime flush
    // method caches under its lock; the callers need that lock for their next
    // lookup, and a tight toggle loop can keep it from them for the whole test.
    // So the togglers regularly let a call through: toggles and calls interleave
    // however long one toggle takes.
    XCTAssertTrue(DHTWaitForCalls(&calls, 0), @"the callers never started");
    dispatch_apply(2, queue, ^(size_t which) {
        for (int i = 0; i < 300; i++) {
            long seen = atomic_load(&calls);
            DHGroupSetEnabled(group, (i + (int)which) % 2 == 0);
            if (i % 4 == 3 && !DHTWaitForCalls(&calls, seen)) atomic_fetch_add(&stalls, 1);
        }
    });
    for (int i = 0; i < 300; i++) {
        long seen = atomic_load(&calls);
        DHGroupSetEnabled(group, i % 2 == 0);
        if (i % 4 == 3 && !DHTWaitForCalls(&calls, seen)) atomic_fetch_add(&stalls, 1);
    }
    atomic_store(&stop, 1);
    XCTAssertEqual(dispatch_group_wait(workers, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)), 0);
    XCTAssertEqual(atomic_load(&bad), 0, @"results must be 1 (original) or 11 (hooked)");
    XCTAssertEqual(atomic_load(&stalls), 0, @"calls must keep completing while the group is toggled");
    XCTAssertGreaterThan(atomic_load(&calls), 0);

    DHGroupSetEnabled(group, NO);
    XCTAssertFalse(DHHookIsActive(gToggleHook));
    XCTAssertEqual([[DHTConcToggle new] value], 1);
    XCTAssertEqual([[DHTConcInhChild new] value], 1);

    DHGroupSetEnabled(group, YES);
    XCTAssertTrue(DHGroupIsEnabled(group));
    XCTAssertTrue(DHHookIsActive(gToggleHook));
    XCTAssertTrue(DHHookIsActive(gToggleInhHook));
    XCTAssertEqual([[DHTConcToggle new] value], 11);
    XCTAssertEqual([[DHTConcInhChild new] value], 11);
}

@end
