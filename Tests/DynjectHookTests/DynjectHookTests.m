// Core DynjectHook tests: DHHookMessage on own, inherited and class methods,
// DHOriginal, chaining, failure inputs, logging and symbol visibility.
//
// Hooks are process-global and never freed, so every test hooks its own
// uniquely named DHT... fixture class.
//
// Naming: SwiftPM lists Objective-C tests as "Class/method", without the target
// name, so every XCTestCase class of this target is called DynjectHookTests...
// That makes `swift test --filter DynjectHookTests` run all of them.

#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "DynjectHook.h"

#pragma mark - Fixtures

@interface DHTOwn : NSObject
- (NSInteger)addOne:(NSInteger)x;
@end
@implementation DHTOwn
- (NSInteger)addOne:(NSInteger)x { return x + 1; }
@end

@interface DHTInhBase : NSObject
- (NSString *)name;
@end
@implementation DHTInhBase
- (NSString *)name { return @"base"; }
@end

@interface DHTInhChild : DHTInhBase
@end
@implementation DHTInhChild
@end

@interface DHTClassSide : NSObject
+ (NSInteger)classValue;
@end
@implementation DHTClassSide
+ (NSInteger)classValue { return 7; }
@end

@interface DHTClassSideChild : DHTClassSide
@end
@implementation DHTClassSideChild
@end

@interface DHTChain : NSObject
- (NSString *)trace;
@end
@implementation DHTChain
- (NSString *)trace { return @"orig"; }
@end

@interface DHTFail : NSObject
- (NSInteger)present;
+ (NSInteger)classOnly;
@end
@implementation DHTFail
- (NSInteger)present { return 1; }
+ (NSInteger)classOnly { return 2; }
@end

@interface DHTTwice : NSObject
- (NSInteger)twice;
@end
@implementation DHTTwice
- (NSInteger)twice { return 1; }
@end

@interface DHTDupBase : NSObject
- (NSInteger)value;
@end
@implementation DHTDupBase
- (NSInteger)value { return 1; }
@end
@interface DHTDupChild : DHTDupBase
@end
@implementation DHTDupChild
@end
@interface DHTDupLateChild : DHTDupBase
@end
@implementation DHTDupLateChild
@end

@interface DHTEx : NSObject
- (NSInteger)value;
- (NSInteger)pending;
- (NSInteger)twice;
@end
@implementation DHTEx
- (NSInteger)value { return 1; }
- (NSInteger)pending { return 1; }
- (NSInteger)twice { return 1; }
@end

#pragma mark - Replacements

static DHHook *gDupBaseHook;
static NSInteger DHTDup_value(id self, SEL _cmd) {
    return DH_CALL_ORIG(gDupBaseHook, NSInteger (*)(id, SEL), self, _cmd) + 10;
}

static DHHook *gExHook;
static NSInteger DHTEx_value(id self, SEL _cmd) {
    return DH_CALL_ORIG(gExHook, NSInteger (*)(id, SEL), self, _cmd) + 10;
}
static DHHook *gExPendingHook;
static NSInteger DHTEx_pending(id self, SEL _cmd) {
    return DH_CALL_ORIG(gExPendingHook, NSInteger (*)(id, SEL), self, _cmd) + 10;
}
static DHHook *gExTwiceHook;
static NSInteger DHTEx_twice(id self, SEL _cmd) {
    return DH_CALL_ORIG(gExTwiceHook, NSInteger (*)(id, SEL), self, _cmd) + 10;
}

static DHHook *gTwiceHook;
static NSInteger DHTTwice_twice(id self, SEL _cmd) {
    return DH_CALL_ORIG(gTwiceHook, NSInteger (*)(id, SEL), self, _cmd) + 2;
}

static DHHook *gOwnHook;
static NSInteger DHTOwn_addOne(id self, SEL _cmd, NSInteger x) {
    return DH_CALL_ORIG(gOwnHook, NSInteger (*)(id, SEL, NSInteger), self, _cmd, x) * 100;
}

static DHHook *gInhChildHook;
static NSString *DHTInhChild_name(id self, SEL _cmd) {
    NSString *orig = DH_CALL_ORIG(gInhChildHook, NSString *(*)(id, SEL), self, _cmd);
    return [orig stringByAppendingString:@"+child"];
}

static DHHook *gInhBaseHook;
static NSString *DHTInhBase_name(id self, SEL _cmd) {
    NSString *orig = DH_CALL_ORIG(gInhBaseHook, NSString *(*)(id, SEL), self, _cmd);
    return [orig stringByAppendingString:@"+base"];
}

static DHHook *gClassSideHook;
static NSInteger DHTClassSide_classValue(id self, SEL _cmd) {
    return DH_CALL_ORIG(gClassSideHook, NSInteger (*)(id, SEL), self, _cmd) * 10;
}

static DHHook *gClassSideChildHook;
static NSInteger DHTClassSideChild_classValue(id self, SEL _cmd) {
    return DH_CALL_ORIG(gClassSideChildHook, NSInteger (*)(id, SEL), self, _cmd) + 1000;
}

static NSMutableArray<NSString *> *gChainLog;
static DHHook *gChainHook1;
static DHHook *gChainHook2;
static NSString *DHTChain_trace1(id self, SEL _cmd) {
    [gChainLog addObject:@"h1"];
    NSString *orig = DH_CALL_ORIG(gChainHook1, NSString *(*)(id, SEL), self, _cmd);
    return [orig stringByAppendingString:@">h1"];
}
static NSString *DHTChain_trace2(id self, SEL _cmd) {
    [gChainLog addObject:@"h2"];
    NSString *orig = DH_CALL_ORIG(gChainHook2, NSString *(*)(id, SEL), self, _cmd);
    return [orig stringByAppendingString:@">h2"];
}

static NSInteger DHTFail_replacement(__unused id self, __unused SEL _cmd) { return -1; }

static BOOL DHTClassHasOwnMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { found = YES; break; }
    }
    free(methods);
    return found;
}

#pragma mark - Tests

@interface DynjectHookTests : XCTestCase
@end

@implementation DynjectHookTests

- (void)testOwnMethodHookChangesBehaviorAndCallsOriginal {
    SEL sel = @selector(addOne:);
    IMP before = method_getImplementation(class_getInstanceMethod([DHTOwn class], sel));
    DHTOwn *obj = [DHTOwn new];
    XCTAssertEqual([obj addOne:4], 5);

    gOwnHook = DHHookMessage([DHTOwn class], sel, (IMP)DHTOwn_addOne, NULL);
    XCTAssertTrue(gOwnHook != NULL);
    XCTAssertTrue(DHHookIsActive(gOwnHook));
    XCTAssertEqual(DHOriginal(gOwnHook), before, @"DHOriginal must be the pre-hook IMP");
    XCTAssertEqual(method_getImplementation(class_getInstanceMethod([DHTOwn class], sel)),
                   (IMP)DHTOwn_addOne, @"own method's IMP is replaced in place");
    XCTAssertFalse(DHTClassHasOwnMethod([NSObject class], sel));

    XCTAssertEqual([obj addOne:4], 500, @"replacement runs and calls the original");
    XCTAssertEqual([[DHTOwn new] addOne:0], 100);
    // Calling the original directly through the handle bypasses the hook.
    XCTAssertEqual(DH_CALL_ORIG(gOwnHook, NSInteger (*)(id, SEL, NSInteger), obj, sel, 9), 10);
}

- (void)testInheritedMethodHookIsDynamicSuper {
    SEL sel = @selector(name);
    Method baseMethod = class_getInstanceMethod([DHTInhBase class], sel);
    IMP baseIMP = method_getImplementation(baseMethod);
    XCTAssertFalse(DHTClassHasOwnMethod([DHTInhChild class], sel));

    gInhChildHook = DHHookMessage([DHTInhChild class], sel, (IMP)DHTInhChild_name, NULL);
    XCTAssertTrue(gInhChildHook != NULL);
    XCTAssertTrue(DHHookIsActive(gInhChildHook));

    // The subclass gained its own method with the inherited method's type encoding.
    XCTAssertTrue(DHTClassHasOwnMethod([DHTInhChild class], sel));
    Method childMethod = class_getInstanceMethod([DHTInhChild class], sel);
    XCTAssertEqual(strcmp(method_getTypeEncoding(childMethod), method_getTypeEncoding(baseMethod)), 0);
    XCTAssertEqual(method_getImplementation(childMethod), (IMP)DHTInhChild_name);

    // The base class is untouched.
    XCTAssertEqual(method_getImplementation(class_getInstanceMethod([DHTInhBase class], sel)), baseIMP);
    XCTAssertEqualObjects([[DHTInhBase new] name], @"base");
    XCTAssertEqualObjects([[DHTInhChild new] name], @"base+child");
    XCTAssertEqual(DHOriginal(gInhChildHook), baseIMP);

    // Hooking the base afterwards is seen through the subclass hook's original.
    gInhBaseHook = DHHookMessage([DHTInhBase class], sel, (IMP)DHTInhBase_name, NULL);
    XCTAssertTrue(gInhBaseHook != NULL);
    XCTAssertEqual(DHOriginal(gInhBaseHook), baseIMP);
    XCTAssertEqual(DHOriginal(gInhChildHook), (IMP)DHTInhBase_name,
                   @"inherited original is resolved dynamically on each call");
    XCTAssertEqualObjects([[DHTInhBase new] name], @"base+base");
    XCTAssertEqualObjects([[DHTInhChild new] name], @"base+base+child");
}

- (void)testClassMethodHookViaMetaclass {
    SEL sel = @selector(classValue);
    Class meta = object_getClass([DHTClassSide class]);
    IMP before = method_getImplementation(class_getClassMethod([DHTClassSide class], sel));
    XCTAssertEqual([DHTClassSide classValue], 7);

    gClassSideHook = DHHookMessage(meta, sel, (IMP)DHTClassSide_classValue, NULL);
    XCTAssertTrue(gClassSideHook != NULL);
    XCTAssertEqual(DHOriginal(gClassSideHook), before);
    XCTAssertEqual([DHTClassSide classValue], 70);
    XCTAssertEqual([DHTClassSideChild classValue], 70, @"subclass inherits the hooked class method");

    // Inherited class method hooked on the subclass's metaclass only.
    gClassSideChildHook = DHHookMessage(object_getClass([DHTClassSideChild class]), sel,
                                        (IMP)DHTClassSideChild_classValue, NULL);
    XCTAssertTrue(gClassSideChildHook != NULL);
    XCTAssertEqual(DHOriginal(gClassSideChildHook), (IMP)DHTClassSide_classValue);
    XCTAssertEqual([DHTClassSideChild classValue], 1070);
    XCTAssertEqual([DHTClassSide classValue], 70);
}

- (void)testChainingLaterHookIsOutermost {
    SEL sel = @selector(trace);
    IMP base = method_getImplementation(class_getInstanceMethod([DHTChain class], sel));
    gChainLog = [NSMutableArray array];

    gChainHook1 = DHHookMessage([DHTChain class], sel, (IMP)DHTChain_trace1, NULL);
    gChainHook2 = DHHookMessage([DHTChain class], sel, (IMP)DHTChain_trace2, NULL);
    XCTAssertTrue(gChainHook1 != NULL);
    XCTAssertTrue(gChainHook2 != NULL);
    XCTAssertTrue(gChainHook1 != gChainHook2);
    XCTAssertEqual(DHOriginal(gChainHook1), base);
    XCTAssertEqual(DHOriginal(gChainHook2), (IMP)DHTChain_trace1,
                   @"the second hook's original is the first hook's replacement");

    XCTAssertEqualObjects([[DHTChain new] trace], @"orig>h1>h2");
    NSArray *expectedOrder = @[ @"h2", @"h1" ];
    XCTAssertEqualObjects(gChainLog, expectedOrder, @"later hook runs first (outermost)");
    XCTAssertTrue(DHHookIsActive(gChainHook1));
    XCTAssertTrue(DHHookIsActive(gChainHook2));
}

- (void)testFailureInputsReturnNULL {
    SEL present = @selector(present);
    IMP before = method_getImplementation(class_getInstanceMethod([DHTFail class], present));

    XCTAssertTrue(DHHookMessage(Nil, present, (IMP)DHTFail_replacement, NULL) == NULL);
    XCTAssertTrue(DHHookMessage([DHTFail class], NULL, (IMP)DHTFail_replacement, NULL) == NULL);
    XCTAssertTrue(DHHookMessage([DHTFail class], present, NULL, NULL) == NULL);
    XCTAssertTrue(DHHookMessage([DHTFail class], sel_registerName("dhtNoSuchMethod:"),
                                (IMP)DHTFail_replacement, NULL) == NULL);
    // A class method selector on the class (not the metaclass) is not an instance method.
    XCTAssertTrue(DHHookMessage([DHTFail class], @selector(classOnly),
                                (IMP)DHTFail_replacement, NULL) == NULL);
    // An instance method selector on the metaclass is not a class method.
    XCTAssertTrue(DHHookMessage(object_getClass([DHTFail class]), sel_registerName("dhtNoSuchClassMethod"),
                                (IMP)DHTFail_replacement, NULL) == NULL);
    DHGroup *group = DHGroupCreate("dht.fail.group");
    XCTAssertTrue(DHHookMessage([DHTFail class], sel_registerName("dhtNoSuchMethod2"),
                                (IMP)DHTFail_replacement, group) == NULL);

    // Nothing was installed or added.
    XCTAssertEqual(method_getImplementation(class_getInstanceMethod([DHTFail class], present)), before);
    XCTAssertFalse(class_respondsToSelector([DHTFail class], sel_registerName("dhtNoSuchMethod:")));
    XCTAssertFalse(class_respondsToSelector([DHTFail class], @selector(classOnly)));
    XCTAssertEqual([[DHTFail new] present], 1);
    XCTAssertEqual([DHTFail classOnly], 2);

    // NULL handles.
    XCTAssertTrue(DHOriginal(NULL) == NULL);
    XCTAssertFalse(DHHookIsActive(NULL));
}

// Installing a replacement that already is the method's implementation would
// make it its own original (endless recursion): it is refused instead.
- (void)testSameReplacementTwiceIsRefused {
    SEL sel = @selector(twice);
    IMP before = method_getImplementation(class_getInstanceMethod([DHTTwice class], sel));
    gTwiceHook = DHHookMessage([DHTTwice class], sel, (IMP)DHTTwice_twice, NULL);
    XCTAssertTrue(gTwiceHook != NULL);
    XCTAssertTrue(DHHookMessage([DHTTwice class], sel, (IMP)DHTTwice_twice, NULL) == NULL);
    XCTAssertEqual(DHOriginal(gTwiceHook), before);
    XCTAssertEqual([[DHTTwice new] twice], 3);
}

// The same holds when the class only inherits the method and the replacement
// already is what it inherits (one replacement applied to a class and then to a
// subclass, e.g. in a loop over a class list): as an override the hook would
// look its original up in the superclass and find itself.
- (void)testSameReplacementOnSubclassThatInheritsItIsRefused {
    SEL sel = @selector(value);
    gDupBaseHook = DHHookMessage([DHTDupBase class], sel, (IMP)DHTDup_value, NULL);
    XCTAssertTrue(gDupBaseHook != NULL);
    XCTAssertEqual(class_getMethodImplementation([DHTDupChild class], sel), (IMP)DHTDup_value, @"fixture precondition");

    DHHook *childHook = DHHookMessage([DHTDupChild class], sel, (IMP)DHTDup_value, NULL);
    XCTAssertTrue(childHook == NULL, @"the replacement already is the class's implementation");
    XCTAssertFalse(DHTClassHasOwnMethod([DHTDupChild class], sel), @"no override was added");
    XCTAssertEqual([[DHTDupChild new] value], 11);
    XCTAssertEqual([[DHTDupBase new] value], 11);

    // A hook that waits for its group is checked when the group is enabled.
    DHGroup *group = DHGroupCreate("dht.dup.group");
    DHGroupSetEnabled(group, NO);
    DHHook *lateHook = DHHookMessage([DHTDupLateChild class], sel, (IMP)DHTDup_value, group);
    XCTAssertTrue(lateHook != NULL, @"registered; nothing is installed yet");
    DHGroupSetEnabled(group, YES);
    XCTAssertFalse(DHTClassHasOwnMethod([DHTDupLateChild class], sel), @"no override was added");
    XCTAssertEqual([[DHTDupLateChild new] value], 11);
}

// DHHookMessageEx also writes the handle to *outHook (before the replacement is
// reachable: see the concurrency tests), and leaves it alone when it fails.
- (void)testHookMessageExStoresHandle {
    DHHook *returned = DHHookMessageEx([DHTEx class], @selector(value), (IMP)DHTEx_value, NULL, &gExHook);
    XCTAssertTrue(returned != NULL);
    XCTAssertEqual(gExHook, returned);
    XCTAssertTrue(DHHookIsActive(returned));
    XCTAssertEqual([[DHTEx new] value], 11);

    // Failures: the variable keeps its value.
    XCTAssertTrue(DHHookMessageEx([DHTEx class], @selector(value), (IMP)DHTEx_value, NULL, &gExHook) == NULL,
                  @"same replacement again");
    XCTAssertEqual(gExHook, returned);
    XCTAssertTrue(DHHookMessageEx([DHTEx class], sel_registerName("dhtNoSuchMethod:"), (IMP)DHTEx_value, NULL,
                                  &gExHook) == NULL);
    XCTAssertEqual(gExHook, returned);
    XCTAssertTrue(DHHookMessageEx(Nil, @selector(value), (IMP)DHTEx_value, NULL, &gExHook) == NULL);
    XCTAssertEqual(gExHook, returned);
    XCTAssertEqual([[DHTEx new] value], 11);

    // A NULL outHook is DHHookMessage.
    gExTwiceHook = DHHookMessageEx([DHTEx class], @selector(twice), (IMP)DHTEx_twice, NULL, NULL);
    XCTAssertTrue(gExTwiceHook != NULL);
    XCTAssertEqual([[DHTEx new] twice], 11);

    // In a disabled group the handle is stored at once and the hook installed on enable.
    DHGroup *group = DHGroupCreate("dht.ex.group");
    DHGroupSetEnabled(group, NO);
    DHHook *pending = DHHookMessageEx([DHTEx class], @selector(pending), (IMP)DHTEx_pending, group, &gExPendingHook);
    XCTAssertTrue(pending != NULL);
    XCTAssertEqual(gExPendingHook, pending);
    XCTAssertEqual([[DHTEx new] pending], 1);
    DHGroupSetEnabled(group, YES);
    XCTAssertEqual([[DHTEx new] pending], 11);
}

- (void)testLoggingDoesNotCrash {
    DHLog(@"DynjectHookTests: plain message");
    DHLog(@"DynjectHookTests: %@ %d %s %.2f", @"object", 42, "cstring", 1.5);
    DHSetLogSubsystem("dht.tests.logging");
    DHLog(@"DynjectHookTests: after subsystem change %@", [NSNull null]);
    DHSetLogSubsystem("dynject.hook");
    DHLog(@"DynjectHookTests: subsystem restored");
}

// Hard constraint 2: every non-static symbol has hidden visibility, so it is
// not exported from the image that compiled DynjectHook.m.
- (void)testPublicFunctionsAreNotExported {
    const char *names[] = {
        "DHSetLogSubsystem", "DHGroupCreate", "DHGroupSetEnabled", "DHGroupIsEnabled",
        "DHHookMessage", "DHHookMessageEx", "DHOriginal", "DHHookIsActive", "DHHookClass", "DHOriginalForSource",
        "DHClass", "DHSwiftClass", "DHFindClassWithSuffix", "DHWhenClassLoads",
        "DHCheckPendingClasses", "DHShouldLoad", "DHSetPreferencesDomainForTesting",
        "DHSetBundleIdentifierForTesting", "DHLogFormat",
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        XCTAssertTrue(dlsym(RTLD_DEFAULT, names[i]) == NULL, @"%s must have hidden visibility", names[i]);
    }
    // Sanity: the functions are still callable from inside the image.
    XCTAssertTrue((void *)DHHookMessage != NULL);
}

@end
