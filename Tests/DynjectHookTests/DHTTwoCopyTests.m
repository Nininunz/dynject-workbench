// Two copies of DynjectHook in one process, as when two tweaks are injected
// into the same app: the bundle's own copy (DHTLibrary.m) and a second one
// with DHT2_-prefixed symbols (DHTSecondCopy.m). Each has its own registry.
//
// Covered: stacking on the same method in either order (own and inherited
// methods), group disable/enable across the copies in both orders, hook classes
// of both copies with a third party's exchange on top, and concurrent group
// toggles by the two copies.

#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <pthread.h>
#import <stdatomic.h>
#import "DynjectHook.h"

// The second copy's functions (see DHTSecondCopy.m).
DH_HIDDEN DHGroup *DHT2_DHGroupCreate(const char *name);
DH_HIDDEN void DHT2_DHGroupSetEnabled(DHGroup *group, BOOL enabled);
DH_HIDDEN BOOL DHT2_DHGroupIsEnabled(DHGroup *group);
DH_HIDDEN DHHook *DHT2_DHHookMessage(Class cls, SEL sel, IMP replacement, DHGroup *group);
DH_HIDDEN IMP DHT2_DHOriginal(DHHook *hook);
DH_HIDDEN BOOL DHT2_DHHookIsActive(DHHook *hook);
DH_HIDDEN NSUInteger DHT2_DHHookClass(Class source, Class target, DHGroup *group);
DH_HIDDEN IMP DHT2_DHOriginalForSource(const char *prettyFunction, SEL sel, id self);

// DH_ORIG for a hook class that belongs to the second copy.
#define DHT2_ORIG(FN_TYPE, ...) \
    ((FN_TYPE)DHT2_DHOriginalForSource(__PRETTY_FUNCTION__, _cmd, self))(self, _cmd, ##__VA_ARGS__)

typedef NSString * (*DHTTraceFn)(id, SEL);

#define DHT_TRACE_FIXTURE(NAME, VALUE)                                                                     \
    @interface NAME : NSObject                                                                             \
    -(NSString *)trace;                                                                                    \
    @end                                                                                                   \
    @implementation NAME                                                                                   \
    -(NSString *)trace { return VALUE; }                                                                   \
    @end

// A replacement that appends TAG to the original's result; ORIGINAL is DHOriginal
// or DHT2_DHOriginal, depending on the copy the hook belongs to.
#define DHT_TRACE_REPLACEMENT(NAME, ORIGINAL, TAG)                                                         \
    static DHHook *NAME##Hook;                                                                             \
    static NSString *NAME(id self, SEL _cmd) {                                                             \
        return [((DHTTraceFn)ORIGINAL(NAME##Hook))(self, _cmd) stringByAppendingString:TAG];               \
    }

DHT_TRACE_FIXTURE(DHTTwoFirstSecond, @"orig")
DHT_TRACE_FIXTURE(DHTTwoSecondFirst, @"orig")
DHT_TRACE_FIXTURE(DHTTwoInhBase, @"base")
DHT_TRACE_FIXTURE(DHTTwoLastOff, @"orig")
DHT_TRACE_FIXTURE(DHTTwoFirstOff, @"orig")
DHT_TRACE_FIXTURE(DHTTwoRace, @"orig")
DHT_TRACE_FIXTURE(DHTTwoLockOne, @"orig")
DHT_TRACE_FIXTURE(DHTTwoLockTwo, @"orig")
DHT_TRACE_FIXTURE(DHTTwoLockThree, @"orig")

@interface DHTTwoInhChild : DHTTwoInhBase
@end
@implementation DHTTwoInhChild
@end

DHT_TRACE_REPLACEMENT(DHTTwoFS_one, DHOriginal, @">one")
DHT_TRACE_REPLACEMENT(DHTTwoFS_two, DHT2_DHOriginal, @">two")
DHT_TRACE_REPLACEMENT(DHTTwoSF_one, DHOriginal, @">one")
DHT_TRACE_REPLACEMENT(DHTTwoSF_two, DHT2_DHOriginal, @">two")
DHT_TRACE_REPLACEMENT(DHTTwoInh_one, DHOriginal, @">one")
DHT_TRACE_REPLACEMENT(DHTTwoInh_two, DHT2_DHOriginal, @">two")
DHT_TRACE_REPLACEMENT(DHTTwoInh_base, DHT2_DHOriginal, @">base2")
DHT_TRACE_REPLACEMENT(DHTTwoLastOff_one, DHOriginal, @">one")
DHT_TRACE_REPLACEMENT(DHTTwoLastOff_two, DHT2_DHOriginal, @">two")
DHT_TRACE_REPLACEMENT(DHTTwoFirstOff_one, DHOriginal, @">one")
DHT_TRACE_REPLACEMENT(DHTTwoFirstOff_two, DHT2_DHOriginal, @">two")
DHT_TRACE_REPLACEMENT(DHTTwoRace_one, DHOriginal, @">one")
DHT_TRACE_REPLACEMENT(DHTTwoRace_two, DHT2_DHOriginal, @">two")
DHT_TRACE_REPLACEMENT(DHTTwoLock_one, DHOriginal, @">one")
DHT_TRACE_REPLACEMENT(DHTTwoLock_two, DHT2_DHOriginal, @">two")
DHT_TRACE_REPLACEMENT(DHTTwoLock_three, DHT2_DHOriginal, @">three")

#pragma mark - Hook classes of both copies

@interface DHTTwoClassTarget : NSObject
- (NSString *)title;
@end
@implementation DHTTwoClassTarget
- (NSString *)title { return @"orig"; }
@end
@interface DHTTwoClassTarget (ThirdParty)
- (NSString *)tp_title;
@end
@implementation DHTTwoClassTarget (ThirdParty)
- (NSString *)tp_title { return [[self tp_title] stringByAppendingString:@">tp"]; }
@end

@interface DHTTwoClassSourceOne : NSObject
@end
@implementation DHTTwoClassSourceOne
- (NSString *)title {
    IMP original = DHOriginalForSource(__PRETTY_FUNCTION__, _cmd, self);
    if (!original) return @"one:NULL";
    return [((DHTTraceFn)original)(self, _cmd) stringByAppendingString:@">one"];
}
@end
@interface DHTTwoClassSourceTwo : NSObject
@end
@implementation DHTTwoClassSourceTwo
- (NSString *)title {
    IMP original = DHT2_DHOriginalForSource(__PRETTY_FUNCTION__, _cmd, self);
    if (!original) return @"two:NULL";
    return [((DHTTraceFn)original)(self, _cmd) stringByAppendingString:@">two"];
}
@end

#pragma mark - Concurrent toggles

typedef struct {
    DHGroup *group;
    void (*setEnabled)(DHGroup *, BOOL);
    int toggles;
} DHTTwoToggleJob;

static void *DHTTwoToggleThread(void *context) {
    DHTTwoToggleJob *job = context;
    for (int i = 0; i < job->toggles; i++) {
        job->setEnabled(job->group, NO);
        job->setEnabled(job->group, YES);
    }
    return NULL;
}

@interface DynjectHookTestsTwoCopies : XCTestCase
@end

@implementation DynjectHookTestsTwoCopies

- (void)testCopiesAreSeparate {
    XCTAssertTrue((void *)DHHookMessage != (void *)DHT2_DHHookMessage);
    // A handle of one copy means nothing to the other copy's registry: a hook
    // class registered with one copy is unknown to the other.
    XCTAssertTrue(DHT2_DHOriginalForSource("-[DHTTwoClassSourceOne title]", @selector(title), nil) == NULL);
}

- (void)testCopiesStackOnOwnMethodInEitherOrder {
    SEL sel = @selector(trace);
    DHTTwoFS_oneHook = DHHookMessage([DHTTwoFirstSecond class], sel, (IMP)DHTTwoFS_one, NULL);
    DHTTwoFS_twoHook = DHT2_DHHookMessage([DHTTwoFirstSecond class], sel, (IMP)DHTTwoFS_two, NULL);
    XCTAssertTrue(DHTTwoFS_oneHook != NULL && DHTTwoFS_twoHook != NULL);
    XCTAssertEqual(DHT2_DHOriginal(DHTTwoFS_twoHook), (IMP)DHTTwoFS_one);
    XCTAssertEqualObjects([[DHTTwoFirstSecond new] trace], @"orig>one>two");

    DHTTwoSF_twoHook = DHT2_DHHookMessage([DHTTwoSecondFirst class], sel, (IMP)DHTTwoSF_two, NULL);
    DHTTwoSF_oneHook = DHHookMessage([DHTTwoSecondFirst class], sel, (IMP)DHTTwoSF_one, NULL);
    XCTAssertTrue(DHTTwoSF_oneHook != NULL && DHTTwoSF_twoHook != NULL);
    XCTAssertEqual(DHOriginal(DHTTwoSF_oneHook), (IMP)DHTTwoSF_two);
    XCTAssertEqualObjects([[DHTTwoSecondFirst new] trace], @"orig>two>one");
}

- (void)testCopiesStackOnInheritedMethod {
    SEL sel = @selector(trace);
    Class child = [DHTTwoInhChild class];
    // The first copy adds the override; for the second copy the class then defines the method.
    DHTTwoInh_oneHook = DHHookMessage(child, sel, (IMP)DHTTwoInh_one, NULL);
    DHTTwoInh_twoHook = DHT2_DHHookMessage(child, sel, (IMP)DHTTwoInh_two, NULL);
    XCTAssertTrue(DHTTwoInh_oneHook != NULL && DHTTwoInh_twoHook != NULL);
    XCTAssertEqualObjects([[DHTTwoInhChild new] trace], @"base>one>two");
    XCTAssertEqualObjects([[DHTTwoInhBase new] trace], @"base");

    // A hook the other copy puts on the superclass later is seen through the override.
    DHTTwoInh_baseHook = DHT2_DHHookMessage([DHTTwoInhBase class], sel, (IMP)DHTTwoInh_base, NULL);
    XCTAssertTrue(DHTTwoInh_baseHook != NULL);
    XCTAssertEqualObjects([[DHTTwoInhBase new] trace], @"base>base2");
    XCTAssertEqualObjects([[DHTTwoInhChild new] trace], @"base>base2>one>two");
}

// The second copy's hook is on top: it goes off first and comes back last.
- (void)testGroupsAcrossCopiesLastOffFirstOn {
    SEL sel = @selector(trace);
    DHGroup *one = DHGroupCreate("dht.two.lastoff.one");
    DHGroup *two = DHT2_DHGroupCreate("dht.two.lastoff.two");
    DHTTwoLastOff_oneHook = DHHookMessage([DHTTwoLastOff class], sel, (IMP)DHTTwoLastOff_one, one);
    DHTTwoLastOff_twoHook = DHT2_DHHookMessage([DHTTwoLastOff class], sel, (IMP)DHTTwoLastOff_two, two);
    DHTTwoLastOff *obj = [DHTTwoLastOff new];
    XCTAssertEqualObjects([obj trace], @"orig>one>two");

    // The lower hook cannot be unlinked beneath the other copy's hook.
    DHGroupSetEnabled(one, NO);
    XCTAssertFalse(DHHookIsActive(DHTTwoLastOff_oneHook));
    XCTAssertEqualObjects([obj trace], @"orig>one>two");
    DHGroupSetEnabled(one, YES);
    XCTAssertTrue(DHHookIsActive(DHTTwoLastOff_oneHook));

    DHT2_DHGroupSetEnabled(two, NO);
    XCTAssertEqualObjects([obj trace], @"orig>one");
    DHGroupSetEnabled(one, NO);
    XCTAssertEqualObjects([obj trace], @"orig");
    DHGroupSetEnabled(one, YES);
    XCTAssertEqualObjects([obj trace], @"orig>one");
    DHT2_DHGroupSetEnabled(two, YES);
    XCTAssertEqualObjects([obj trace], @"orig>one>two");
    XCTAssertTrue(DHHookIsActive(DHTTwoLastOff_oneHook));
    XCTAssertTrue(DHT2_DHHookIsActive(DHTTwoLastOff_twoHook));
}

// Documented limit ("Several tweaks in one process"): a copy only follows its own
// changes. When the other copy's hook beneath a disabled hook is removed as well,
// the method no longer holds what the upper hook restored, so enabling it marks
// it active without installing it. Switching its group off and on once the lower
// hook is back brings it back.
- (void)testGroupsAcrossCopiesFirstOffFirstOn {
    SEL sel = @selector(trace);
    DHGroup *one = DHGroupCreate("dht.two.firstoff.one");
    DHGroup *two = DHT2_DHGroupCreate("dht.two.firstoff.two");
    DHTTwoFirstOff_oneHook = DHHookMessage([DHTTwoFirstOff class], sel, (IMP)DHTTwoFirstOff_one, one);
    DHTTwoFirstOff_twoHook = DHT2_DHHookMessage([DHTTwoFirstOff class], sel, (IMP)DHTTwoFirstOff_two, two);
    DHTTwoFirstOff *obj = [DHTTwoFirstOff new];
    XCTAssertEqualObjects([obj trace], @"orig>one>two");

    DHT2_DHGroupSetEnabled(two, NO);
    DHGroupSetEnabled(one, NO);
    XCTAssertEqualObjects([obj trace], @"orig");
    DHT2_DHGroupSetEnabled(two, YES);
    XCTAssertTrue(DHT2_DHHookIsActive(DHTTwoFirstOff_twoHook));
    XCTAssertEqualObjects([obj trace], @"orig", @"the chain is never corrupted");
    DHGroupSetEnabled(one, YES);
    XCTAssertEqualObjects([obj trace], @"orig>one");

    DHT2_DHGroupSetEnabled(two, NO);
    DHT2_DHGroupSetEnabled(two, YES);
    XCTAssertEqualObjects([obj trace], @"orig>one>two");
}

// Hook classes of both copies on one method, then a third party's exchange on top.
- (void)testHookClassesOfBothCopiesAndForeignExchange {
    Class target = [DHTTwoClassTarget class];
    XCTAssertEqual(DHHookClass([DHTTwoClassSourceOne class], target, NULL), (NSUInteger)1);
    XCTAssertEqual(DHT2_DHHookClass([DHTTwoClassSourceTwo class], target, NULL), (NSUInteger)1);
    DHTTwoClassTarget *obj = [DHTTwoClassTarget new];
    XCTAssertEqualObjects([obj title], @"orig>one>two");

    method_exchangeImplementations(class_getInstanceMethod(target, @selector(title)),
                                   class_getInstanceMethod(target, @selector(tp_title)));
    XCTAssertEqualObjects([obj title], @"orig>one>two>tp");
}

// Disabling, enabling and installing a hook read the method's implementation
// and then write it. Each copy has its own registry lock, so the copies also
// share one process-wide lock around that (docs/hooking.md, "Several tweaks in
// one process": it is published as an associated object of the NSObject class
// under the selector "dynject.hook.process-lock.v1", as the address of an
// os_unfair_lock). While this test holds that lock, neither copy may get past
// it; nothing else links the three methods used here.
- (void)testCopiesShareOneProcessLock {
    SEL sel = @selector(trace);
    DHGroup *one = DHGroupCreate("dht.two.lock.one");
    DHGroup *two = DHT2_DHGroupCreate("dht.two.lock.two");
    DHTTwoLock_oneHook = DHHookMessage([DHTTwoLockOne class], sel, (IMP)DHTTwoLock_one, one);
    DHTTwoLock_twoHook = DHT2_DHHookMessage([DHTTwoLockTwo class], sel, (IMP)DHTTwoLock_two, two);
    XCTAssertTrue(DHTTwoLock_oneHook != NULL && DHTTwoLock_twoHook != NULL);

    NSData *box = objc_getAssociatedObject([NSObject class], sel_registerName("dynject.hook.process-lock.v1"));
    XCTAssertTrue([box isKindOfClass:[NSData class]], @"the copies have no lock to share");
    XCTAssertEqual(box.length, sizeof(os_unfair_lock *));
    if (![box isKindOfClass:[NSData class]] || box.length != sizeof(os_unfair_lock *)) return;
    os_unfair_lock *lock = NULL;
    memcpy(&lock, box.bytes, sizeof(lock));
    XCTAssertTrue(lock != NULL);
    if (!lock) return;

    static _Atomic int doneOne, doneTwo, doneInstall;
    atomic_store(&doneOne, 0);
    atomic_store(&doneTwo, 0);
    atomic_store(&doneInstall, 0);
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_t workers = dispatch_group_create();

    os_unfair_lock_lock(lock);
    dispatch_group_async(workers, queue, ^{
        DHGroupSetEnabled(one, NO);
        atomic_store(&doneOne, 1);
    });
    dispatch_group_async(workers, queue, ^{
        DHT2_DHGroupSetEnabled(two, NO);
        atomic_store(&doneTwo, 1);
    });
    dispatch_group_async(workers, queue, ^{
        DHTTwoLock_threeHook = DHT2_DHHookMessage([DHTTwoLockThree class], sel, (IMP)DHTTwoLock_three, NULL);
        atomic_store(&doneInstall, 1);
    });
    usleep(300 * 1000);
    BOOL blockedOne = !atomic_load(&doneOne);
    BOOL blockedTwo = !atomic_load(&doneTwo);
    BOOL blockedInstall = !atomic_load(&doneInstall);
    NSString *traceOne = [[DHTTwoLockOne new] trace];   // calls are not held up, and nothing changed yet
    NSString *traceTwo = [[DHTTwoLockTwo new] trace];
    NSString *traceThree = [[DHTTwoLockThree new] trace];
    os_unfair_lock_unlock(lock);

    XCTAssertTrue(blockedOne, @"the first copy toggled a group without the shared lock");
    XCTAssertTrue(blockedTwo, @"the second copy toggled a group without the shared lock");
    XCTAssertTrue(blockedInstall, @"the second copy installed a hook without the shared lock");
    XCTAssertEqualObjects(traceOne, @"orig>one");
    XCTAssertEqualObjects(traceTwo, @"orig>two");
    XCTAssertEqualObjects(traceThree, @"orig");

    XCTAssertEqual(dispatch_group_wait(workers, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)), 0);
    XCTAssertEqualObjects([[DHTTwoLockOne new] trace], @"orig");
    XCTAssertEqualObjects([[DHTTwoLockTwo new] trace], @"orig");
    XCTAssertEqualObjects([[DHTTwoLockThree new] trace], @"orig>three");
    DHGroupSetEnabled(one, YES);
    DHT2_DHGroupSetEnabled(two, YES);
    XCTAssertEqualObjects([[DHTTwoLockOne new] trace], @"orig>one");
    XCTAssertEqualObjects([[DHTTwoLockTwo new] trace], @"orig>two");
}

// What the shared lock is for: without it, two copies toggling hooks on the
// same method from two threads can interleave between the read and the write
// and overwrite each other's replacement, and a hook is then lost for good
// while it reports active. Afterwards the groups are cycled in strict
// last-off-first-on order, which brings back every state the copies can reach
// one toggle at a time.
//
// The toggle counts are small on purpose: a toggle costs time in proportion to
// the number of classes the process has realized (method_setImplementation
// flushes method caches), which is large when the whole bundle runs.
- (void)testConcurrentTogglesByTwoCopiesKeepBothHooks {
    SEL sel = @selector(trace);
    DHGroup *one = DHGroupCreate("dht.two.race.one");
    DHGroup *two = DHT2_DHGroupCreate("dht.two.race.two");
    DHTTwoRace_oneHook = DHHookMessage([DHTTwoRace class], sel, (IMP)DHTTwoRace_one, one);
    DHTTwoRace_twoHook = DHT2_DHHookMessage([DHTTwoRace class], sel, (IMP)DHTTwoRace_two, two);
    XCTAssertTrue(DHTTwoRace_oneHook != NULL && DHTTwoRace_twoHook != NULL);
    DHTTwoRace *obj = [DHTTwoRace new];
    XCTAssertEqualObjects([obj trace], @"orig>one>two");

    for (int round = 0; round < 8; round++) {
        DHTTwoToggleJob jobOne = { one, DHGroupSetEnabled, 125 };
        DHTTwoToggleJob jobTwo = { two, DHT2_DHGroupSetEnabled, 125 };
        pthread_t threadOne, threadTwo;
        XCTAssertEqual(pthread_create(&threadOne, NULL, DHTTwoToggleThread, &jobOne), 0);
        XCTAssertEqual(pthread_create(&threadTwo, NULL, DHTTwoToggleThread, &jobTwo), 0);
        NSString *during = [obj trace];   // any chain is fine while they toggle, but it must be intact
        XCTAssertTrue([during hasPrefix:@"orig"], @"%@", during);
        pthread_join(threadOne, NULL);
        pthread_join(threadTwo, NULL);

        DHT2_DHGroupSetEnabled(two, NO);
        DHGroupSetEnabled(one, NO);
        DHGroupSetEnabled(one, YES);
        DHT2_DHGroupSetEnabled(two, YES);
        NSString *after = [obj trace];
        XCTAssertEqualObjects(after, @"orig>one>two", @"a hook was lost in round %d", round);
        if (![after isEqualToString:@"orig>one>two"]) break;
    }
    XCTAssertTrue(DHHookIsActive(DHTTwoRace_oneHook));
    XCTAssertTrue(DHT2_DHHookIsActive(DHTTwoRace_twoHook));
}

@end
