// Hook classes meeting other swizzling code and unusual function names:
// - DH_ORIG after somebody exchanges the hooked method's implementation with an
//   alias selector (method_exchangeImplementations and friends), so that the
//   hook-class method is entered with a foreign _cmd;
// - DH_ORIG from a C++ lambda (the function name clang gives it);
// - a hook class declared with objc_runtime_name (documented as unsupported);
// - -dealloc in a hook class (never installed) and the supported way to hook it.

#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "DynjectHook.h"

#pragma mark - Exchange fixtures

@interface DHTExTarget : NSObject
- (NSString *)title;
- (NSString *)viaBlock;
+ (NSString *)classTitle;
@end
@implementation DHTExTarget
- (NSString *)title { return @"orig"; }
- (NSString *)viaBlock { return @"orig"; }
+ (NSString *)classTitle { return @"orig"; }
@end

// What an SDK or another tweak does: add an alias, exchange, and call the alias
// to reach "the original" (by then the hook-class method installed earlier).
@interface DHTExTarget (ThirdParty)
- (NSString *)tp_title;
- (NSString *)tp_viaBlock;
+ (NSString *)tp_classTitle;
@end
@implementation DHTExTarget (ThirdParty)
- (NSString *)tp_title { return [[self tp_title] stringByAppendingString:@">tp"]; }
- (NSString *)tp_viaBlock { return [[self tp_viaBlock] stringByAppendingString:@">tp"]; }
+ (NSString *)tp_classTitle { return [[self tp_classTitle] stringByAppendingString:@">tp"]; }
@end

@interface DHTExSource : NSObject
@end
@implementation DHTExSource
- (NSString *)title { return [DH_ORIG(NSString * (*)(id, SEL)) stringByAppendingString:@">dh"]; }
- (NSString *)viaBlock {
    NSString * (^callOriginal)(void) = ^{
        return DH_ORIG(NSString * (*)(id, SEL));
    };
    return [callOriginal() stringByAppendingString:@">dh"];
}
+ (NSString *)classTitle { return [DH_ORIG(NSString * (*)(id, SEL)) stringByAppendingString:@">dh"]; }
@end

// A hook class that hooks both selectors of a pair somebody exchanges later.
@interface DHTExPairTarget : NSObject
- (NSString *)first;
- (NSString *)second;
@end
@implementation DHTExPairTarget
- (NSString *)first { return @"first"; }
- (NSString *)second { return @"second"; }
@end
@interface DHTExPairSource : NSObject
@end
@implementation DHTExPairSource
- (NSString *)first { return [DH_ORIG(NSString * (*)(id, SEL)) stringByAppendingString:@">hookFirst"]; }
- (NSString *)second { return [DH_ORIG(NSString * (*)(id, SEL)) stringByAppendingString:@">hookSecond"]; }
@end

// An inherited method: the hook is an override added to the subclass, and the
// swizzler then exchanges that override.
@interface DHTExInhBase : NSObject
- (NSString *)title;
@end
@implementation DHTExInhBase
- (NSString *)title { return @"base"; }
@end
@interface DHTExInhChild : DHTExInhBase
- (NSString *)tp_title;
@end
@implementation DHTExInhChild
- (NSString *)tp_title { return [[self tp_title] stringByAppendingString:@">tp"]; }
@end
@interface DHTExInhSource : NSObject
@end
@implementation DHTExInhSource
- (NSString *)title { return [DH_ORIG(NSString * (*)(id, SEL)) stringByAppendingString:@">dh"]; }
@end

#pragma mark - Lambda-name fixtures

@interface DHTLambdaTarget : NSObject
- (NSInteger)value;
- (NSInteger)add:(NSInteger)a to:(NSInteger)b;
+ (NSInteger)classValue;
- (NSInteger)both;
+ (NSInteger)both;
@end
@implementation DHTLambdaTarget
- (NSInteger)value { return 1; }
- (NSInteger)add:(NSInteger)a to:(NSInteger)b { return a + b; }
+ (NSInteger)classValue { return 2; }
- (NSInteger)both { return 3; }
+ (NSInteger)both { return 4; }
@end
@interface DHTLambdaSource : NSObject
@end
@implementation DHTLambdaSource
- (NSInteger)value { return DH_ORIG(NSInteger (*)(id, SEL)) + 10; }
- (NSInteger)add:(NSInteger)a to:(NSInteger)b { return DH_ORIG(NSInteger (*)(id, SEL, NSInteger, NSInteger), a, b) + 10; }
+ (NSInteger)classValue { return DH_ORIG(NSInteger (*)(id, SEL)) + 10; }
- (NSInteger)both { return DH_ORIG(NSInteger (*)(id, SEL)) + 10; }
+ (NSInteger)both { return DH_ORIG(NSInteger (*)(id, SEL)) + 10; }
@end

#pragma mark - objc_runtime_name fixtures

@interface DHTRuntimeNameTarget : NSObject
- (NSInteger)value;
@end
@implementation DHTRuntimeNameTarget
- (NSInteger)value { return 1; }
@end

// __PRETTY_FUNCTION__ says "-[DHTRuntimeNameSource value]", the runtime knows
// the class only as "DHT_rt9f3a_Source".
__attribute__((objc_runtime_name("DHT_rt9f3a_Source")))
@interface DHTRuntimeNameSource : NSObject
@end
@implementation DHTRuntimeNameSource
- (NSInteger)value {
    IMP original = DHOriginalForSource(__PRETTY_FUNCTION__, _cmd, self);
    if (!original) return -1;   // what DH_ORIG would have called
    return ((NSInteger (*)(id, SEL))original)(self, _cmd) + 10;
}
@end

#pragma mark - dealloc fixtures

static int gDeallocMidRuns;
static int gDeallocTargetRuns;
static int gDeallocSourceRuns;
static int gDeallocFunctionRuns;

@interface DHTDeallocMid : NSObject
@end
@implementation DHTDeallocMid
- (void)dealloc { gDeallocMidRuns++; }
@end
@interface DHTDeallocTarget : DHTDeallocMid
- (NSInteger)value;
@end
@implementation DHTDeallocTarget
- (NSInteger)value { return 1; }
- (void)dealloc { gDeallocTargetRuns++; }
@end

// Under ARC this -dealloc ends in [super dealloc] bound to NSObject: installed
// on the target it would skip -[DHTDeallocTarget dealloc] and -[DHTDeallocMid dealloc].
@interface DHTDeallocSource : NSObject
@end
@implementation DHTDeallocSource
- (NSInteger)value { return DH_ORIG(NSInteger (*)(id, SEL)) + 10; }
- (void)dealloc { gDeallocSourceRuns++; }
@end

// The supported way: DHHookMessage with a C function. `self` must not be
// retained or released while the object is being deallocated.
static DHHook *gDeallocHook;
static void DHTDealloc_function(__unsafe_unretained id self, SEL _cmd) {
    gDeallocFunctionRuns++;
    DH_CALL_ORIG(gDeallocHook, void (*)(__unsafe_unretained id, SEL), self, _cmd);
}

#pragma mark - Helpers

static IMP DHTSwizzleOwnIMP(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    IMP imp = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { imp = method_getImplementation(methods[i]); break; }
    }
    free(methods);
    return imp;
}

static void DHTExchange(Class cls, SEL a, SEL b) {
    method_exchangeImplementations(class_getInstanceMethod(cls, a), class_getInstanceMethod(cls, b));
}

@interface DynjectHookTestsSwizzle : XCTestCase
@end

@implementation DynjectHookTestsSwizzle

// DH_CTOR runs before the app's own +load and startup code, so a swizzle by the
// app, an SDK or another tweak normally lands on top of a hook class's method
// and enters it under the swizzler's alias selector. DH_ORIG must still find
// the method's own hook (and pass the live _cmd on to the original).
- (void)testOrigAfterExchangeWithAliasSelector {
    Class target = [DHTExTarget class];
    Class meta = object_getClass(target);
    IMP titleOriginal = DHTSwizzleOwnIMP(target, @selector(title));
    XCTAssertEqual(DHHookClass([DHTExSource class], target, NULL), (NSUInteger)3);
    DHTExTarget *obj = [DHTExTarget new];
    XCTAssertEqualObjects([obj title], @"orig>dh");

    DHTExchange(target, @selector(title), @selector(tp_title));
    DHTExchange(target, @selector(viaBlock), @selector(tp_viaBlock));
    DHTExchange(meta, @selector(classTitle), @selector(tp_classTitle));

    // What DH_ORIG evaluates inside -[DHTExSource title] now: _cmd is the alias.
    IMP resolved = DHOriginalForSource("-[DHTExSource title]", @selector(tp_title), obj);
    XCTAssertEqual(resolved, titleOriginal, @"the hook is found from the function's name, not from _cmd");
    XCTAssertTrue(DHOriginalForSource("__33-[DHTExSource viaBlock]_block_invoke", @selector(tp_viaBlock), obj) != NULL);
    XCTAssertTrue(DHOriginalForSource("+[DHTExSource classTitle]", @selector(tp_classTitle), (id)target) != NULL);
    if (!resolved) return;   // the calls below would jump to NULL

    XCTAssertEqualObjects([obj title], @"orig>dh>tp");
    XCTAssertEqualObjects([obj viaBlock], @"orig>dh>tp");
    XCTAssertEqualObjects([DHTExTarget classTitle], @"orig>dh>tp");
    // Calling the alias directly reaches the hook-class method without the swizzler.
    XCTAssertEqualObjects([obj tp_title], @"orig>dh");
}

// When the hook class hooks both selectors of the exchanged pair, _cmd names
// the *other* hook-class method: each method must still get its own original.
- (void)testOrigAfterExchangeBetweenTwoHookedSelectors {
    Class target = [DHTExPairTarget class];
    IMP firstOriginal = DHTSwizzleOwnIMP(target, @selector(first));
    IMP secondOriginal = DHTSwizzleOwnIMP(target, @selector(second));
    XCTAssertEqual(DHHookClass([DHTExPairSource class], target, NULL), (NSUInteger)2);
    DHTExPairTarget *obj = [DHTExPairTarget new];
    XCTAssertEqualObjects([obj first], @"first>hookFirst");
    XCTAssertEqualObjects([obj second], @"second>hookSecond");

    DHTExchange(target, @selector(first), @selector(second));
    XCTAssertEqual(DHOriginalForSource("-[DHTExPairSource first]", @selector(second), obj), firstOriginal);
    XCTAssertEqual(DHOriginalForSource("-[DHTExPairSource second]", @selector(first), obj), secondOriginal);
    XCTAssertEqualObjects([obj first], @"second>hookSecond", @"each hook-class method keeps its own original");
    XCTAssertEqualObjects([obj second], @"first>hookFirst");
}

- (void)testOrigAfterExchangeOfInheritedMethodHook {
    Class child = [DHTExInhChild class];
    XCTAssertEqual(DHHookClass([DHTExInhSource class], child, NULL), (NSUInteger)1);
    DHTExInhChild *obj = [DHTExInhChild new];
    XCTAssertEqualObjects([obj title], @"base>dh");

    DHTExchange(child, @selector(title), @selector(tp_title));
    IMP resolved = DHOriginalForSource("-[DHTExInhSource title]", @selector(tp_title), obj);
    XCTAssertEqual(resolved, class_getMethodImplementation([DHTExInhBase class], @selector(title)));
    if (!resolved) return;
    XCTAssertEqualObjects([obj title], @"base>dh>tp");
    XCTAssertEqualObjects([[DHTExInhBase new] title], @"base");
}

// Objective-C++: inside a C++ lambda written in a hook-class method clang's
// __PRETTY_FUNCTION__ is "auto Class::selector::(anonymous class)::operator()() const".
// The test bundle is Objective-C, so the names are passed as the strings clang
// produces (checked against Apple clang 21).
- (void)testOrigFromLambdaFunctionNames {
    Class target = [DHTLambdaTarget class];
    Class meta = object_getClass(target);
    IMP value = DHTSwizzleOwnIMP(target, @selector(value));
    IMP addTo = DHTSwizzleOwnIMP(target, @selector(add:to:));
    IMP classValue = DHTSwizzleOwnIMP(meta, @selector(classValue));
    IMP instanceBoth = DHTSwizzleOwnIMP(target, @selector(both));
    IMP classBoth = DHTSwizzleOwnIMP(meta, @selector(both));
    XCTAssertEqual(DHHookClass([DHTLambdaSource class], target, NULL), (NSUInteger)5);
    DHTLambdaTarget *obj = [DHTLambdaTarget new];
    XCTAssertEqual([obj value], 11);

    XCTAssertEqual(DHOriginalForSource("auto DHTLambdaSource::value::(anonymous class)::operator()() const",
                                       @selector(value), obj), value);
    XCTAssertEqual(DHOriginalForSource("auto DHTLambdaSource::add:to:::(anonymous class)::operator()() const",
                                       @selector(add:to:), obj), addTo, @"multi-part selector");
    XCTAssertEqual(DHOriginalForSource("auto DHTLambdaSource::classValue::(anonymous class)::operator()() const",
                                       @selector(classValue), (id)target), classValue, @"class method");
    // Generic lambda, nested lambda, and a block inside a lambda.
    XCTAssertEqual(DHOriginalForSource("auto DHTLambdaSource::value::(anonymous class)::operator()(auto) const [x:auto = int]",
                                       @selector(value), obj), value);
    XCTAssertEqual(DHOriginalForSource("auto DHTLambdaSource::value::(anonymous class)::operator()()::(anonymous class)::operator()() const",
                                       @selector(value), obj), value);
    XCTAssertEqual(DHOriginalForSource("auto DHTLambdaSource::value::(anonymous class)::operator()() const_block_invoke",
                                       @selector(value), obj), value);
    // The name does not tell -both from +both; the receiver does.
    const char *both = "auto DHTLambdaSource::both::(anonymous class)::operator()() const";
    XCTAssertEqual(DHOriginalForSource(both, @selector(both), obj), instanceBoth);
    XCTAssertEqual(DHOriginalForSource(both, @selector(both), (id)target), classBoth);
    // Like the bracket form, the name wins over a foreign _cmd.
    XCTAssertEqual(DHOriginalForSource("auto DHTLambdaSource::value::(anonymous class)::operator()() const",
                                       @selector(add:to:), obj), value);

    // Not a registered hook class, not a hooked selector, not a lambda inside a method.
    XCTAssertTrue(DHOriginalForSource("auto DHTNoSuchSource::value::(anonymous class)::operator()() const",
                                      @selector(value), obj) == NULL);
    XCTAssertTrue(DHOriginalForSource("auto DHTLambdaSource::dhtNotHooked::(anonymous class)::operator()() const",
                                      sel_registerName("dhtNotHooked"), obj) == NULL);
    XCTAssertTrue(DHOriginalForSource("auto helper()::(anonymous class)::operator()() const", @selector(value), obj) == NULL);
    XCTAssertTrue(DHOriginalForSource("DHTLambdaSource::value", @selector(value), obj) == NULL);
    XCTAssertTrue(DHOriginalForSource("::", @selector(value), obj) == NULL);
    XCTAssertTrue(DHOriginalForSource("DHTLambdaSource::::(", @selector(value), obj) == NULL);
}

// Documented limit: DH_ORIG finds the hook class by the name in __PRETTY_FUNCTION__,
// which is the source-level name. A hook class renamed with objc_runtime_name
// is installed but not found (logged, NULL), and never resolved to another class.
- (void)testHookClassWithRuntimeNameIsNotFoundByOrig {
    Class source = [DHTRuntimeNameSource class];
    XCTAssertEqual(strcmp(class_getName(source), "DHT_rt9f3a_Source"), 0, @"fixture precondition");
    XCTAssertEqual(DHHookClass(source, [DHTRuntimeNameTarget class], NULL), (NSUInteger)1);
    DHTRuntimeNameTarget *obj = [DHTRuntimeNameTarget new];
    XCTAssertEqual([obj value], -1, @"the method's own __PRETTY_FUNCTION__ does not name the registered class");
    // Under its runtime name the hook is there.
    XCTAssertTrue(DHOriginalForSource("-[DHT_rt9f3a_Source value]", @selector(value), obj) != NULL);
}

- (void)testHookClassDeallocIsNotInstalled {
    Class target = [DHTDeallocTarget class];
    SEL deallocSel = sel_registerName("dealloc");
    IMP deallocBefore = DHTSwizzleOwnIMP(target, deallocSel);
    XCTAssertTrue(deallocBefore != NULL, @"fixture precondition");
    XCTAssertTrue(DHTSwizzleOwnIMP([DHTDeallocSource class], deallocSel) != NULL, @"fixture precondition");

    XCTAssertEqual(DHHookClass([DHTDeallocSource class], target, NULL), (NSUInteger)1, @"-value only, not -dealloc");
    XCTAssertEqual(DHTSwizzleOwnIMP(target, deallocSel), deallocBefore, @"-dealloc must not be replaced");
    XCTAssertTrue(DHOriginalForSource("-[DHTDeallocSource dealloc]", deallocSel, nil) == NULL);

    gDeallocMidRuns = gDeallocTargetRuns = gDeallocSourceRuns = 0;
    for (int i = 0; i < 10; i++) {
        @autoreleasepool {
            XCTAssertEqual([[DHTDeallocTarget new] value], 11);
        }
    }
    XCTAssertEqual(gDeallocTargetRuns, 10, @"the target's own dealloc chain still runs");
    XCTAssertEqual(gDeallocMidRuns, 10);
    XCTAssertEqual(gDeallocSourceRuns, 0);

    // The supported way to hook dealloc.
    gDeallocHook = DHHookMessage(target, deallocSel, (IMP)DHTDealloc_function, NULL);
    XCTAssertTrue(gDeallocHook != NULL);
    gDeallocMidRuns = gDeallocTargetRuns = gDeallocFunctionRuns = 0;
    for (int i = 0; i < 10; i++) {
        @autoreleasepool {
            XCTAssertEqual([[DHTDeallocTarget new] value], 11);
        }
    }
    XCTAssertEqual(gDeallocFunctionRuns, 10);
    XCTAssertEqual(gDeallocTargetRuns, 10);
    XCTAssertEqual(gDeallocMidRuns, 10);
}

@end
