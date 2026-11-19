// Hook groups: disable/enable semantics for own and inherited methods, stacking,
// hooks created while disabled, and idempotent toggling. Every test leaves its
// groups enabled.

#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "DynjectHook.h"

#define DHT_VALUE_FIXTURE(NAME, VALUE)                                                                     \
    @interface NAME : NSObject                                                                             \
    -(NSInteger)value;                                                                                     \
    @end                                                                                                   \
    @implementation NAME                                                                                   \
    -(NSInteger)value { return VALUE; }                                                                    \
    @end

DHT_VALUE_FIXTURE(DHTGroupBasic, 1)
DHT_VALUE_FIXTURE(DHTGroupStacked, 1)
DHT_VALUE_FIXTURE(DHTGroupLate, 1)
DHT_VALUE_FIXTURE(DHTGroupSame, 1)
DHT_VALUE_FIXTURE(DHTGroupUngrouped, 1)
DHT_VALUE_FIXTURE(DHTGroupInhBase, 1)
DHT_VALUE_FIXTURE(DHTGroupFamilyBase, 1)

@interface DHTGroupFamilyChild : DHTGroupFamilyBase
@end
@implementation DHTGroupFamilyChild
@end

@interface DHTGroupInhChild : DHTGroupInhBase
@end
@implementation DHTGroupInhChild
@end

static IMP DHTValueIMP(Class cls) {
    return method_getImplementation(class_getInstanceMethod(cls, @selector(value)));
}

static DHHook *gBasicHook;
static NSInteger DHTBasic_value(id self, SEL _cmd) {
    return DH_CALL_ORIG(gBasicHook, NSInteger (*)(id, SEL), self, _cmd) + 10;
}

static DHHook *gStackedGroupHook;
static NSInteger DHTStackedGroup_value(id self, SEL _cmd) {
    return DH_CALL_ORIG(gStackedGroupHook, NSInteger (*)(id, SEL), self, _cmd) + 10;
}
static DHHook *gStackedTopHook;
static NSInteger DHTStackedTop_value(id self, SEL _cmd) {
    return DH_CALL_ORIG(gStackedTopHook, NSInteger (*)(id, SEL), self, _cmd) + 100;
}

static DHHook *gLateHook;
static NSInteger DHTLate_value(id self, SEL _cmd) {
    return DH_CALL_ORIG(gLateHook, NSInteger (*)(id, SEL), self, _cmd) + 10;
}

static DHHook *gSameHook1;
static NSInteger DHTSame1_value(id self, SEL _cmd) {
    return DH_CALL_ORIG(gSameHook1, NSInteger (*)(id, SEL), self, _cmd) + 10;
}
static DHHook *gSameHook2;
static NSInteger DHTSame2_value(id self, SEL _cmd) {
    return DH_CALL_ORIG(gSameHook2, NSInteger (*)(id, SEL), self, _cmd) + 100;
}

static DHHook *gUngroupedHook;
static NSInteger DHTUngrouped_value(id self, SEL _cmd) {
    return DH_CALL_ORIG(gUngroupedHook, NSInteger (*)(id, SEL), self, _cmd) + 10;
}

static DHHook *gInhChildHook;
static NSInteger DHTGroupInhChild_value(id self, SEL _cmd) {
    return DH_CALL_ORIG(gInhChildHook, NSInteger (*)(id, SEL), self, _cmd) + 10;
}
static DHHook *gInhBaseHook;
static NSInteger DHTGroupInhBase_value(id self, SEL _cmd) {
    return DH_CALL_ORIG(gInhBaseHook, NSInteger (*)(id, SEL), self, _cmd) + 100;
}

static int gFamilyBaseCalls;
static DHHook *gFamilyBaseHook;
static NSInteger DHTGroupFamilyBase_value(id self, SEL _cmd) {
    gFamilyBaseCalls++;
    return DH_CALL_ORIG(gFamilyBaseHook, NSInteger (*)(id, SEL), self, _cmd) + 100;
}
static int gFamilyChildCalls;
static DHHook *gFamilyChildHook;
static NSInteger DHTGroupFamilyChild_value(id self, SEL _cmd) {
    gFamilyChildCalls++;
    return DH_CALL_ORIG(gFamilyChildHook, NSInteger (*)(id, SEL), self, _cmd) + 10;
}
static DHHook *gFamilyLateHook;
static NSInteger DHTGroupFamilyLate_value(id self, SEL _cmd) {
    return DH_CALL_ORIG(gFamilyLateHook, NSInteger (*)(id, SEL), self, _cmd) + 1000;
}

#pragma mark - Several groups on one method

typedef NSString * (*DHTGroupTraceFn)(id, SEL);

#define DHT_GROUP_TRACE_FIXTURE(NAME, VALUE)                                                               \
    @interface NAME : NSObject                                                                             \
    -(NSString *)trace;                                                                                    \
    @end                                                                                                   \
    @implementation NAME                                                                                   \
    -(NSString *)trace { return VALUE; }                                                                   \
    @end

// A replacement that appends TAG to the original's result, with its handle NAME##Hook.
#define DHT_GROUP_TRACE_REPLACEMENT(NAME, TAG)                                                             \
    static DHHook *NAME##Hook;                                                                             \
    static NSString *NAME(id self, SEL _cmd) {                                                             \
        return [DH_CALL_ORIG(NAME##Hook, DHTGroupTraceFn, self, _cmd) stringByAppendingString:TAG];        \
    }

DHT_GROUP_TRACE_FIXTURE(DHTGroupOrderA, @"orig")
DHT_GROUP_TRACE_FIXTURE(DHTGroupOrderB, @"orig")
DHT_GROUP_TRACE_FIXTURE(DHTGroupOrderC, @"orig")
DHT_GROUP_TRACE_FIXTURE(DHTGroupOrderInhBase, @"base")
DHT_GROUP_TRACE_FIXTURE(DHTGroupForeign, @"orig")
DHT_GROUP_TRACE_FIXTURE(DHTGroupFrozenBase, @"base")
DHT_GROUP_TRACE_FIXTURE(DHTGroupFrozenBase2, @"base")

@interface DHTGroupOrderInhChild : DHTGroupOrderInhBase
@end
@implementation DHTGroupOrderInhChild
@end
@interface DHTGroupFrozenChild : DHTGroupFrozenBase
@end
@implementation DHTGroupFrozenChild
@end
@interface DHTGroupFrozenChild2 : DHTGroupFrozenBase2
@end
@implementation DHTGroupFrozenChild2
@end

DHT_GROUP_TRACE_REPLACEMENT(DHTOrderA_1, @">h1")
DHT_GROUP_TRACE_REPLACEMENT(DHTOrderA_2, @">h2")
DHT_GROUP_TRACE_REPLACEMENT(DHTOrderB_1, @">h1")
DHT_GROUP_TRACE_REPLACEMENT(DHTOrderB_2, @">h2")
DHT_GROUP_TRACE_REPLACEMENT(DHTOrderC_1, @">h1")
DHT_GROUP_TRACE_REPLACEMENT(DHTOrderC_2, @">h2")
DHT_GROUP_TRACE_REPLACEMENT(DHTOrderC_3, @">h3")
DHT_GROUP_TRACE_REPLACEMENT(DHTOrderInh_1, @">h1")
DHT_GROUP_TRACE_REPLACEMENT(DHTOrderInh_2, @">h2")
DHT_GROUP_TRACE_REPLACEMENT(DHTForeign_hook, @">h")
DHT_GROUP_TRACE_REPLACEMENT(DHTFrozen_a, @">a")
DHT_GROUP_TRACE_REPLACEMENT(DHTFrozen_b, @">b")
DHT_GROUP_TRACE_REPLACEMENT(DHTFrozen_base, @">baseHook")
DHT_GROUP_TRACE_REPLACEMENT(DHTFrozen2_a, @">a")
DHT_GROUP_TRACE_REPLACEMENT(DHTFrozen2_b, @">b")
DHT_GROUP_TRACE_REPLACEMENT(DHTFrozen2_base, @">baseHook")

// Stands for a hook of some other library: it is not in DynjectHook's registry.
static IMP gForeignOriginal;
static NSString *DHTForeign_other(id self, SEL _cmd) {
    return [((DHTGroupTraceFn)gForeignOriginal)(self, _cmd) stringByAppendingString:@">foreign"];
}

static IMP DHTTraceIMP(Class cls) {
    return method_getImplementation(class_getInstanceMethod(cls, @selector(trace)));
}

@interface DynjectHookTestsGroups : XCTestCase
@end

@implementation DynjectHookTestsGroups

- (void)testNewGroupIsEnabled {
    DHGroup *group = DHGroupCreate("dht.group.new");
    XCTAssertTrue(group != NULL);
    XCTAssertTrue(DHGroupIsEnabled(group));
    DHGroup *other = DHGroupCreate("dht.group.new2");
    XCTAssertTrue(other != group, @"each DHGroupCreate returns a distinct group");
}

- (void)testDisableRestoresAndEnableReinstalls {
    Class cls = [DHTGroupBasic class];
    IMP original = DHTValueIMP(cls);
    DHGroup *group = DHGroupCreate("dht.group.basic");
    gBasicHook = DHHookMessage(cls, @selector(value), (IMP)DHTBasic_value, group);
    XCTAssertTrue(gBasicHook != NULL);
    DHTGroupBasic *obj = [DHTGroupBasic new];
    XCTAssertEqual([obj value], 11);
    XCTAssertTrue(DHHookIsActive(gBasicHook));

    DHGroupSetEnabled(group, NO);
    XCTAssertFalse(DHGroupIsEnabled(group));
    XCTAssertFalse(DHHookIsActive(gBasicHook));
    XCTAssertEqual([obj value], 1, @"disable restores the original behavior");
    XCTAssertEqual(DHTValueIMP(cls), original, @"disable puts the saved original IMP back");

    DHGroupSetEnabled(group, NO); // no-op
    XCTAssertFalse(DHGroupIsEnabled(group));
    XCTAssertEqual(DHTValueIMP(cls), original);
    XCTAssertEqual([obj value], 1);

    DHGroupSetEnabled(group, YES);
    XCTAssertTrue(DHGroupIsEnabled(group));
    XCTAssertTrue(DHHookIsActive(gBasicHook));
    XCTAssertEqual(DHTValueIMP(cls), (IMP)DHTBasic_value);
    XCTAssertEqual(DHOriginal(gBasicHook), original);
    XCTAssertEqual([obj value], 11);

    DHGroupSetEnabled(group, YES); // no-op: must not install on top of itself
    XCTAssertEqual(DHOriginal(gBasicHook), original);
    XCTAssertEqual([obj value], 11);

    // A second cycle behaves the same.
    DHGroupSetEnabled(group, NO);
    XCTAssertEqual([obj value], 1);
    DHGroupSetEnabled(group, YES);
    XCTAssertEqual([obj value], 11);
}

- (void)testDisableWithHookStackedOnTopKeepsBehaviorAndMarksInactive {
    Class cls = [DHTGroupStacked class];
    DHGroup *group = DHGroupCreate("dht.group.stacked");
    gStackedGroupHook = DHHookMessage(cls, @selector(value), (IMP)DHTStackedGroup_value, group);
    gStackedTopHook = DHHookMessage(cls, @selector(value), (IMP)DHTStackedTop_value, NULL);
    XCTAssertTrue(gStackedGroupHook != NULL && gStackedTopHook != NULL);
    DHTGroupStacked *obj = [DHTGroupStacked new];
    XCTAssertEqual([obj value], 111);

    DHGroupSetEnabled(group, NO);
    XCTAssertFalse(DHHookIsActive(gStackedGroupHook));
    XCTAssertTrue(DHHookIsActive(gStackedTopHook));
    XCTAssertEqual(DHTValueIMP(cls), (IMP)DHTStackedTop_value, @"the later hook must not be unlinked");
    XCTAssertEqual([obj value], 111, @"behavior flows through the stack unchanged");

    DHGroupSetEnabled(group, YES);
    XCTAssertTrue(DHHookIsActive(gStackedGroupHook));
    XCTAssertTrue(DHHookIsActive(gStackedTopHook));
    XCTAssertEqual(DHTValueIMP(cls), (IMP)DHTStackedTop_value);
    XCTAssertEqual([obj value], 111, @"re-enable does not install the group hook a second time");
}

- (void)testHookCreatedWhileGroupDisabledIsInstalledOnEnable {
    Class cls = [DHTGroupLate class];
    IMP original = DHTValueIMP(cls);
    DHGroup *group = DHGroupCreate("dht.group.late");
    DHGroupSetEnabled(group, NO);

    gLateHook = DHHookMessage(cls, @selector(value), (IMP)DHTLate_value, group);
    XCTAssertTrue(gLateHook != NULL, @"the hook is registered even though the group is disabled");
    XCTAssertFalse(DHHookIsActive(gLateHook));
    XCTAssertEqual(DHTValueIMP(cls), original, @"not installed while the group is disabled");
    XCTAssertEqual([[DHTGroupLate new] value], 1);

    DHGroupSetEnabled(group, YES);
    XCTAssertTrue(DHHookIsActive(gLateHook));
    XCTAssertEqual(DHTValueIMP(cls), (IMP)DHTLate_value);
    XCTAssertEqual(DHOriginal(gLateHook), original);
    XCTAssertEqual([[DHTGroupLate new] value], 11);
}

// Two hooks of one group on one method: disable unwinds in reverse install
// order (fully restoring the original); enable reinstalls both.
- (void)testTwoHooksInSameGroupOnSameMethod {
    Class cls = [DHTGroupSame class];
    IMP original = DHTValueIMP(cls);
    DHGroup *group = DHGroupCreate("dht.group.same");
    gSameHook1 = DHHookMessage(cls, @selector(value), (IMP)DHTSame1_value, group);
    gSameHook2 = DHHookMessage(cls, @selector(value), (IMP)DHTSame2_value, group);
    DHTGroupSame *obj = [DHTGroupSame new];
    XCTAssertEqual([obj value], 111);

    DHGroupSetEnabled(group, NO);
    XCTAssertEqual(DHTValueIMP(cls), original);
    XCTAssertEqual([obj value], 1);
    XCTAssertFalse(DHHookIsActive(gSameHook1));
    XCTAssertFalse(DHHookIsActive(gSameHook2));

    DHGroupSetEnabled(group, YES);
    XCTAssertTrue(DHHookIsActive(gSameHook1));
    XCTAssertTrue(DHHookIsActive(gSameHook2));
    XCTAssertEqual(DHTValueIMP(cls), (IMP)DHTSame2_value);
    XCTAssertEqual([obj value], 111);
}

- (void)testInheritedMethodHookDisableEnable {
    Class base = [DHTGroupInhBase class];
    Class child = [DHTGroupInhChild class];
    IMP baseOriginal = DHTValueIMP(base);
    DHGroup *group = DHGroupCreate("dht.group.inherited");
    gInhChildHook = DHHookMessage(child, @selector(value), (IMP)DHTGroupInhChild_value, group);
    XCTAssertTrue(gInhChildHook != NULL);
    XCTAssertEqual([[DHTGroupInhChild new] value], 11);
    XCTAssertEqual([[DHTGroupInhBase new] value], 1);

    DHGroupSetEnabled(group, NO);
    XCTAssertFalse(DHHookIsActive(gInhChildHook));
    XCTAssertEqual(DHTValueIMP(child), baseOriginal, @"added method now forwards to the superclass IMP");
    XCTAssertEqual([[DHTGroupInhChild new] value], 1);
    XCTAssertEqual([[DHTGroupInhBase new] value], 1);

    DHGroupSetEnabled(group, YES);
    XCTAssertTrue(DHHookIsActive(gInhChildHook));
    XCTAssertEqual(DHTValueIMP(child), (IMP)DHTGroupInhChild_value);
    XCTAssertEqual([[DHTGroupInhChild new] value], 11);

    // The original is still resolved dynamically after a disable/enable cycle.
    gInhBaseHook = DHHookMessage(base, @selector(value), (IMP)DHTGroupInhBase_value, NULL);
    XCTAssertEqual([[DHTGroupInhBase new] value], 101);
    XCTAssertEqual([[DHTGroupInhChild new] value], 111);
}

// A base-class hook and an inherited-method hook on its subclass in one group.
// The subclass hook is disabled first (reverse install order), while the base
// hook is still installed; DynjectHook.h promises that the override left behind
// on the subclass keeps following the superclass, so once the whole group is
// off no replacement of the group runs any more.
- (void)testDisabledInheritedHookFollowsSuperclass {
    Class base = [DHTGroupFamilyBase class];
    Class child = [DHTGroupFamilyChild class];
    IMP baseOriginal = DHTValueIMP(base);
    DHGroup *group = DHGroupCreate("dht.group.family");
    gFamilyBaseHook = DHHookMessage(base, @selector(value), (IMP)DHTGroupFamilyBase_value, group);
    gFamilyChildHook = DHHookMessage(child, @selector(value), (IMP)DHTGroupFamilyChild_value, group);
    XCTAssertTrue(gFamilyBaseHook != NULL && gFamilyChildHook != NULL);
    XCTAssertEqual([[DHTGroupFamilyBase new] value], 101);
    XCTAssertEqual([[DHTGroupFamilyChild new] value], 111);

    DHGroupSetEnabled(group, NO);
    XCTAssertFalse(DHHookIsActive(gFamilyBaseHook));
    XCTAssertFalse(DHHookIsActive(gFamilyChildHook));
    gFamilyBaseCalls = gFamilyChildCalls = 0;
    XCTAssertEqual([[DHTGroupFamilyBase new] value], 1);
    XCTAssertEqual([[DHTGroupFamilyChild new] value], 1);
    XCTAssertEqual(gFamilyBaseCalls, 0, @"no replacement of a fully disabled group runs");
    XCTAssertEqual(gFamilyChildCalls, 0);
    XCTAssertEqual(DHTValueIMP(base), baseOriginal);
    XCTAssertEqual(DHTValueIMP(child), baseOriginal);

    // A hook placed on the base while the group is off is seen through the subclass.
    gFamilyLateHook = DHHookMessage(base, @selector(value), (IMP)DHTGroupFamilyLate_value, NULL);
    XCTAssertTrue(gFamilyLateHook != NULL);
    XCTAssertEqual([[DHTGroupFamilyBase new] value], 1001);
    XCTAssertEqual([[DHTGroupFamilyChild new] value], 1001);

    // Re-enabling puts the subclass hook back. The base hook was installed before
    // the later hook, which is a hook of the same registry: it goes back into the
    // chain beneath it, as its original, and the later hook stays outermost.
    DHGroupSetEnabled(group, YES);
    XCTAssertTrue(DHHookIsActive(gFamilyBaseHook));
    XCTAssertTrue(DHHookIsActive(gFamilyChildHook));
    XCTAssertEqual(DHTValueIMP(child), (IMP)DHTGroupFamilyChild_value);
    XCTAssertEqual(DHTValueIMP(base), (IMP)DHTGroupFamilyLate_value);
    XCTAssertEqual(DHOriginal(gFamilyLateHook), (IMP)DHTGroupFamilyBase_value);
    XCTAssertEqual(DHOriginal(gFamilyBaseHook), baseOriginal);
    gFamilyBaseCalls = gFamilyChildCalls = 0;
    XCTAssertEqual([[DHTGroupFamilyBase new] value], 1101);
    XCTAssertEqual(gFamilyBaseCalls, 1);
    XCTAssertEqual([[DHTGroupFamilyChild new] value], 1111);
    XCTAssertEqual(gFamilyBaseCalls, 2);
    XCTAssertEqual(gFamilyChildCalls, 1);
}

// Two settings, each with its own group, hook the same method. Whatever order
// the groups are switched in, an enabled group's hook runs, and the hooks keep
// their install order (the later one outermost).
- (void)testTwoGroupsOnOneMethodFirstOffFirstOn {
    Class cls = [DHTGroupOrderA class];
    IMP original = DHTTraceIMP(cls);
    DHGroup *g1 = DHGroupCreate("dht.group.order.a1");
    DHGroup *g2 = DHGroupCreate("dht.group.order.a2");
    DHTOrderA_1Hook = DHHookMessage(cls, @selector(trace), (IMP)DHTOrderA_1, g1);
    DHTOrderA_2Hook = DHHookMessage(cls, @selector(trace), (IMP)DHTOrderA_2, g2);
    DHTGroupOrderA *obj = [DHTGroupOrderA new];
    XCTAssertEqualObjects([obj trace], @"orig>h1>h2");

    DHGroupSetEnabled(g2, NO);
    XCTAssertEqualObjects([obj trace], @"orig>h1");
    DHGroupSetEnabled(g1, NO);
    XCTAssertEqualObjects([obj trace], @"orig");
    XCTAssertEqual(DHTTraceIMP(cls), original);

    // The upper hook comes back alone: its original is now the real implementation.
    DHGroupSetEnabled(g2, YES);
    XCTAssertTrue(DHHookIsActive(DHTOrderA_2Hook));
    XCTAssertEqualObjects([obj trace], @"orig>h2", @"an enabled group's hook must run");
    XCTAssertEqual(DHOriginal(DHTOrderA_2Hook), original);
    XCTAssertFalse(DHHookIsActive(DHTOrderA_1Hook));

    // The lower hook comes back beneath it.
    DHGroupSetEnabled(g1, YES);
    XCTAssertTrue(DHHookIsActive(DHTOrderA_1Hook));
    XCTAssertEqualObjects([obj trace], @"orig>h1>h2");
    XCTAssertEqual(DHTTraceIMP(cls), (IMP)DHTOrderA_2);
    XCTAssertEqual(DHOriginal(DHTOrderA_2Hook), (IMP)DHTOrderA_1);
    XCTAssertEqual(DHOriginal(DHTOrderA_1Hook), original);

    // With the first setting off, the second can still be switched freely.
    DHGroupSetEnabled(g2, NO);
    DHGroupSetEnabled(g1, NO);
    for (int i = 0; i < 3; i++) {
        DHGroupSetEnabled(g2, YES);
        XCTAssertEqualObjects([obj trace], @"orig>h2");
        DHGroupSetEnabled(g2, NO);
        XCTAssertEqualObjects([obj trace], @"orig");
    }
    DHGroupSetEnabled(g1, YES);
    XCTAssertEqualObjects([obj trace], @"orig>h1");
    DHGroupSetEnabled(g2, YES);
    XCTAssertEqualObjects([obj trace], @"orig>h1>h2");
}

- (void)testTwoGroupsOnOneMethodLowerHookToggledBeneath {
    Class cls = [DHTGroupOrderB class];
    DHGroup *g1 = DHGroupCreate("dht.group.order.b1");
    DHGroup *g2 = DHGroupCreate("dht.group.order.b2");
    DHTOrderB_1Hook = DHHookMessage(cls, @selector(trace), (IMP)DHTOrderB_1, g1);
    DHTOrderB_2Hook = DHHookMessage(cls, @selector(trace), (IMP)DHTOrderB_2, g2);
    DHTGroupOrderB *obj = [DHTGroupOrderB new];

    // Both off, lower one first on.
    DHGroupSetEnabled(g2, NO);
    DHGroupSetEnabled(g1, NO);
    DHGroupSetEnabled(g1, YES);
    XCTAssertEqualObjects([obj trace], @"orig>h1");
    DHGroupSetEnabled(g2, YES);
    XCTAssertEqualObjects([obj trace], @"orig>h1>h2");

    // The lower hook cannot be unlinked beneath the upper one: it stays, inactive.
    DHGroupSetEnabled(g1, NO);
    XCTAssertFalse(DHHookIsActive(DHTOrderB_1Hook));
    XCTAssertEqualObjects([obj trace], @"orig>h1>h2");
    // ...and is uncovered, still installed, when the upper one goes.
    DHGroupSetEnabled(g2, NO);
    XCTAssertEqualObjects([obj trace], @"orig>h1");
    DHGroupSetEnabled(g2, YES);
    DHGroupSetEnabled(g1, YES);
    XCTAssertEqualObjects([obj trace], @"orig>h1>h2");
    XCTAssertTrue(DHHookIsActive(DHTOrderB_1Hook));
    XCTAssertTrue(DHHookIsActive(DHTOrderB_2Hook));
}

- (void)testThreeGroupsOnOneMethodKeepInstallOrder {
    Class cls = [DHTGroupOrderC class];
    DHGroup *g1 = DHGroupCreate("dht.group.order.c1");
    DHGroup *g2 = DHGroupCreate("dht.group.order.c2");
    DHGroup *g3 = DHGroupCreate("dht.group.order.c3");
    DHTOrderC_1Hook = DHHookMessage(cls, @selector(trace), (IMP)DHTOrderC_1, g1);
    DHTOrderC_2Hook = DHHookMessage(cls, @selector(trace), (IMP)DHTOrderC_2, g2);
    DHTOrderC_3Hook = DHHookMessage(cls, @selector(trace), (IMP)DHTOrderC_3, g3);
    DHTGroupOrderC *obj = [DHTGroupOrderC new];
    XCTAssertEqualObjects([obj trace], @"orig>h1>h2>h3");
    DHGroup *groups[] = { g1, g2, g3 };

    // All off (top first), then on again in every order.
    int orders[6][3] = { {0, 1, 2}, {0, 2, 1}, {1, 0, 2}, {1, 2, 0}, {2, 0, 1}, {2, 1, 0} };
    for (int o = 0; o < 6; o++) {
        DHGroupSetEnabled(g3, NO);
        DHGroupSetEnabled(g2, NO);
        DHGroupSetEnabled(g1, NO);
        XCTAssertEqualObjects([obj trace], @"orig");
        BOOL on[3] = { NO, NO, NO };
        for (int step = 0; step < 3; step++) {
            on[orders[o][step]] = YES;
            DHGroupSetEnabled(groups[orders[o][step]], YES);
            NSString *expected = [NSString stringWithFormat:@"orig%@%@%@", on[0] ? @">h1" : @"",
                                  on[1] ? @">h2" : @"", on[2] ? @">h3" : @""];
            XCTAssertEqualObjects([obj trace], expected, @"enable order %d, step %d", o, step);
        }
    }

    // The middle hook leaves and returns between its neighbours.
    DHGroupSetEnabled(g3, NO);
    DHGroupSetEnabled(g2, NO);
    DHGroupSetEnabled(g3, YES);
    XCTAssertEqualObjects([obj trace], @"orig>h1>h3");
    DHGroupSetEnabled(g2, YES);
    XCTAssertEqualObjects([obj trace], @"orig>h1>h2>h3");
}

// The same with an inherited method: both hooks sit on an override the first one added.
- (void)testTwoGroupsOnInheritedMethodFirstOffFirstOn {
    Class child = [DHTGroupOrderInhChild class];
    Class base = [DHTGroupOrderInhBase class];
    DHGroup *g1 = DHGroupCreate("dht.group.order.inh1");
    DHGroup *g2 = DHGroupCreate("dht.group.order.inh2");
    DHTOrderInh_1Hook = DHHookMessage(child, @selector(trace), (IMP)DHTOrderInh_1, g1);
    DHTOrderInh_2Hook = DHHookMessage(child, @selector(trace), (IMP)DHTOrderInh_2, g2);
    DHTGroupOrderInhChild *obj = [DHTGroupOrderInhChild new];
    XCTAssertEqualObjects([obj trace], @"base>h1>h2");

    DHGroupSetEnabled(g2, NO);
    DHGroupSetEnabled(g1, NO);
    XCTAssertEqualObjects([obj trace], @"base");
    XCTAssertEqual(DHTTraceIMP(child), DHTTraceIMP(base));
    DHGroupSetEnabled(g2, YES);
    XCTAssertEqualObjects([obj trace], @"base>h2");
    XCTAssertEqual(DHOriginal(DHTOrderInh_2Hook), DHTTraceIMP(base), @"its original is the superclass's now");
    DHGroupSetEnabled(g1, YES);
    XCTAssertEqualObjects([obj trace], @"base>h1>h2");
    XCTAssertEqualObjects([[DHTGroupOrderInhBase new] trace], @"base");
}

// A change made by code outside the registry is different: DynjectHook cannot
// know what that code keeps as its original, so the hook stays out (marked
// active, logged) until the method is back to what DynjectHook restored.
- (void)testReenableAfterForeignChangeStaysOut {
    Class cls = [DHTGroupForeign class];
    Method method = class_getInstanceMethod(cls, @selector(trace));
    IMP original = DHTTraceIMP(cls);
    DHGroup *group = DHGroupCreate("dht.group.foreign");
    DHTForeign_hookHook = DHHookMessage(cls, @selector(trace), (IMP)DHTForeign_hook, group);
    DHTGroupForeign *obj = [DHTGroupForeign new];
    XCTAssertEqualObjects([obj trace], @"orig>h");

    DHGroupSetEnabled(group, NO);
    gForeignOriginal = method_setImplementation(method, (IMP)DHTForeign_other);
    XCTAssertEqual(gForeignOriginal, original);
    XCTAssertEqualObjects([obj trace], @"orig>foreign");

    DHGroupSetEnabled(group, YES);
    XCTAssertTrue(DHHookIsActive(DHTForeign_hookHook));
    XCTAssertEqual(DHTTraceIMP(cls), (IMP)DHTForeign_other, @"the foreign hook is left alone");
    XCTAssertEqualObjects([obj trace], @"orig>foreign");

    // Once the foreign hook is gone, switching the group off and on installs the hook.
    method_setImplementation(method, gForeignOriginal);
    DHGroupSetEnabled(group, NO);
    DHGroupSetEnabled(group, YES);
    XCTAssertEqualObjects([obj trace], @"orig>h");
}

// A class that only inherits the method keeps doing so in DynjectHook's eyes
// while the override an earlier, now disabled hook added to it merely holds a
// copy of the superclass implementation. A second hook on that class must get
// the dynamic superclass lookup (not that copy) as its original, and the
// disabled hook must be able to come back.
- (void)testHookOnClassWhoseInheritedHookIsDisabled {
    Class base = [DHTGroupFrozenBase class];
    Class child = [DHTGroupFrozenChild class];
    DHGroup *groupA = DHGroupCreate("dht.group.frozen.a");
    DHTFrozen_aHook = DHHookMessage(child, @selector(trace), (IMP)DHTFrozen_a, groupA);
    DHTGroupFrozenChild *obj = [DHTGroupFrozenChild new];
    XCTAssertEqualObjects([obj trace], @"base>a");
    DHGroupSetEnabled(groupA, NO);
    XCTAssertEqualObjects([obj trace], @"base");

    DHTFrozen_bHook = DHHookMessage(child, @selector(trace), (IMP)DHTFrozen_b, NULL);
    XCTAssertTrue(DHTFrozen_bHook != NULL);
    XCTAssertEqualObjects([obj trace], @"base>b");

    // A hook installed on the superclass afterwards is honoured.
    DHTFrozen_baseHook = DHHookMessage(base, @selector(trace), (IMP)DHTFrozen_base, NULL);
    XCTAssertEqualObjects([[DHTGroupFrozenBase new] trace], @"base>baseHook");
    XCTAssertEqual(DHOriginal(DHTFrozen_bHook), (IMP)DHTFrozen_base, @"the original is looked up in the superclass");
    XCTAssertEqualObjects([obj trace], @"base>baseHook>b");

    // The first hook comes back, beneath the hook installed after it.
    DHGroupSetEnabled(groupA, YES);
    XCTAssertTrue(DHHookIsActive(DHTFrozen_aHook));
    XCTAssertEqualObjects([obj trace], @"base>baseHook>a>b");
    DHGroupSetEnabled(groupA, NO);
    XCTAssertEqualObjects([obj trace], @"base>baseHook>a>b", @"beneath another hook it stays installed, inactive");
    XCTAssertFalse(DHHookIsActive(DHTFrozen_aHook));
    DHGroupSetEnabled(groupA, YES);
}

// The same with the second hook in a group of its own that is switched off
// while the superclass changes.
- (void)testSecondGroupOnClassWhoseInheritedHookIsDisabled {
    Class base = [DHTGroupFrozenBase2 class];
    Class child = [DHTGroupFrozenChild2 class];
    DHGroup *groupA = DHGroupCreate("dht.group.frozen2.a");
    DHGroup *groupB = DHGroupCreate("dht.group.frozen2.b");
    DHTFrozen2_aHook = DHHookMessage(child, @selector(trace), (IMP)DHTFrozen2_a, groupA);
    DHGroupSetEnabled(groupA, NO);
    DHTFrozen2_bHook = DHHookMessage(child, @selector(trace), (IMP)DHTFrozen2_b, groupB);
    DHTGroupFrozenChild2 *obj = [DHTGroupFrozenChild2 new];
    XCTAssertEqualObjects([obj trace], @"base>b");

    DHGroupSetEnabled(groupB, NO);
    XCTAssertEqualObjects([obj trace], @"base");
    DHTFrozen2_baseHook = DHHookMessage(base, @selector(trace), (IMP)DHTFrozen2_base, NULL);
    XCTAssertEqualObjects([obj trace], @"base>baseHook", @"with both hooks off the class follows its superclass");

    DHGroupSetEnabled(groupB, YES);
    XCTAssertEqualObjects([obj trace], @"base>baseHook>b");
    DHGroupSetEnabled(groupA, YES);
    XCTAssertEqualObjects([obj trace], @"base>baseHook>a>b");
    XCTAssertTrue(DHHookIsActive(DHTFrozen2_aHook));
    XCTAssertTrue(DHHookIsActive(DHTFrozen2_bHook));
}

- (void)testNullGroupIsUngroupedAndAlwaysEnabled {
    gUngroupedHook = DHHookMessage([DHTGroupUngrouped class], @selector(value), (IMP)DHTUngrouped_value, NULL);
    XCTAssertTrue(gUngroupedHook != NULL);
    DHGroupSetEnabled(NULL, NO); // must not crash or affect ungrouped hooks
    XCTAssertTrue(DHHookIsActive(gUngroupedHook));
    XCTAssertEqual([[DHTGroupUngrouped new] value], 11);
    DHGroupSetEnabled(NULL, YES);
    XCTAssertEqual([[DHTGroupUngrouped new] value], 11);
}

@end
