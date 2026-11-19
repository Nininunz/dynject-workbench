// DHHookClass (ZKSwizzle-style source classes), DH_ORIG and DHOriginalForSource parsing.

#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "DynjectHook.h"

static int gDHTSourceLoadRan;

#pragma mark - Basic DHHookClass fixtures

@interface DHTHCTarget : NSObject {
    id _targetKeep; // object ivar under ARC: target has its own .cxx_destruct
}
- (NSInteger)number;
- (NSString *)greet:(NSString *)name;
- (double)scale:(double)x;
+ (NSInteger)classNumber;
+ (NSString *)classTag;
@end
@implementation DHTHCTarget
- (NSInteger)number { return 10; }
- (NSString *)greet:(NSString *)name { return [@"hello " stringByAppendingString:name]; }
- (double)scale:(double)x { return x * 2; }
+ (NSInteger)classNumber { return 100; }
+ (NSString *)classTag { return @"target"; }
@end

@interface DHTHCSource : NSObject {
    id _sourceKeep; // object ivar under ARC: source has .cxx_destruct, which must not be installed
}
@end
@implementation DHTHCSource
+ (void)load { gDHTSourceLoadRan++; }
+ (void)initialize { }
- (NSInteger)number { return DH_ORIG(NSInteger (*)(id, SEL)) + 5; }
- (NSString *)greet:(NSString *)name {
    return [DH_ORIG(NSString * (*)(id, SEL, NSString *), name) stringByAppendingString:@"!"];
}
- (double)scale:(double)x { return DH_ORIG(double (*)(id, SEL, double), x) + 1; }
- (void)dhtSourceOnlyInstanceMethod { }
+ (NSInteger)classNumber { return DH_ORIG(NSInteger (*)(id, SEL)) + 1; }
+ (NSString *)classTag { return [DH_ORIG(NSString * (*)(id, SEL)) stringByAppendingString:@"+src"]; }
+ (void)dhtSourceOnlyClassMethod { }
@end

// A second target, used to prove a source class can only be applied once.
@interface DHTHCTarget2 : NSObject
- (NSInteger)number;
@end
@implementation DHTHCTarget2
- (NSInteger)number { return 20; }
@end

// Source used only with bad inputs.
@interface DHTHCBadSource : NSObject
@end
@implementation DHTHCBadSource
- (NSInteger)number { return -1; }
@end

#pragma mark - Inherited target fixtures

@interface DHTHCInhBase : NSObject
- (NSString *)describe;
@end
@implementation DHTHCInhBase
- (NSString *)describe { return @"base"; }
@end
@interface DHTHCInhChild : DHTHCInhBase
@end
@implementation DHTHCInhChild
@end
@interface DHTHCInhSource : NSObject
@end
@implementation DHTHCInhSource
- (NSString *)describe { return [DH_ORIG(NSString * (*)(id, SEL)) stringByAppendingString:@"+src"]; }
@end

#pragma mark - Parsing fixtures

@interface DHTParseTarget : NSObject
- (NSString *)plain;
- (NSString *)multi:(NSString *)a colon:(NSString *)b args:(NSString *)c;
- (NSString *)catMethod:(NSString *)a with:(NSString *)b;
+ (NSString *)classSide;
@end
@implementation DHTParseTarget
- (NSString *)plain { return @"plain"; }
- (NSString *)multi:(NSString *)a colon:(NSString *)b args:(NSString *)c {
    return [NSString stringWithFormat:@"%@%@%@", a, b, c];
}
- (NSString *)catMethod:(NSString *)a with:(NSString *)b { return [a stringByAppendingString:b]; }
+ (NSString *)classSide { return @"classSide"; }
@end

@interface DHTParseSrc : NSObject
@end
@implementation DHTParseSrc
- (NSString *)plain { return [DH_ORIG(NSString * (*)(id, SEL)) stringByAppendingString:@"*"]; }
- (NSString *)multi:(NSString *)a colon:(NSString *)b args:(NSString *)c {
    return [DH_ORIG(NSString * (*)(id, SEL, NSString *, NSString *, NSString *), a, b, c)
        stringByAppendingString:@"*"];
}
+ (NSString *)classSide { return [DH_ORIG(NSString * (*)(id, SEL)) stringByAppendingString:@"*"]; }
@end

// Category on the source class: __PRETTY_FUNCTION__ is "-[DHTParseSrc(Extra) catMethod:with:]".
@interface DHTParseSrc (Extra)
@end
@implementation DHTParseSrc (Extra)
- (NSString *)catMethod:(NSString *)a with:(NSString *)b {
    return [DH_ORIG(NSString * (*)(id, SEL, NSString *, NSString *), a, b) stringByAppendingString:@"*"];
}
@end

#pragma mark - Block fixtures

@interface DHTBlockTarget : NSObject
- (NSString *)viaBlock:(NSString *)suffix;
@end
@implementation DHTBlockTarget
- (NSString *)viaBlock:(NSString *)suffix { return [@"orig" stringByAppendingString:suffix]; }
@end
@interface DHTBlockSrc : NSObject
@end
@implementation DHTBlockSrc
// Inside the block __PRETTY_FUNCTION__ is "__31-[DHTBlockSrc viaBlock:]_block_invoke".
- (NSString *)viaBlock:(NSString *)suffix {
    NSString * (^callOriginal)(void) = ^{
        return DH_ORIG(NSString * (*)(id, SEL, NSString *), suffix);
    };
    return [callOriginal() stringByAppendingString:@"*"];
}
@end

#pragma mark - Group fixtures

@interface DHTHCGroupTarget : NSObject
- (NSInteger)value;
+ (NSInteger)classValue;
@end
@implementation DHTHCGroupTarget
- (NSInteger)value { return 1; }
+ (NSInteger)classValue { return 2; }
@end
@interface DHTHCGroupSource : NSObject
@end
@implementation DHTHCGroupSource
- (NSInteger)value { return DH_ORIG(NSInteger (*)(id, SEL)) + 10; }
+ (NSInteger)classValue { return DH_ORIG(NSInteger (*)(id, SEL)) + 20; }
@end

#pragma mark - Helpers

static BOOL DHTOwnsMethod(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { found = YES; break; }
    }
    free(methods);
    return found;
}

static IMP DHTOwnIMP(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    IMP imp = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { imp = method_getImplementation(methods[i]); break; }
    }
    free(methods);
    return imp;
}

@interface DynjectHookTestsHookClass : XCTestCase
@end

@implementation DynjectHookTestsHookClass

- (void)testHookClassInstallsInstanceAndClassMethods {
    Class target = [DHTHCTarget class];
    Class targetMeta = object_getClass(target);
    SEL cxxDestruct = sel_registerName(".cxx_destruct");
    XCTAssertTrue(DHTOwnsMethod([DHTHCSource class], cxxDestruct), @"fixture precondition");
    XCTAssertTrue(DHTOwnsMethod(target, cxxDestruct), @"fixture precondition");
    XCTAssertTrue(DHTOwnsMethod(object_getClass([DHTHCSource class]), @selector(load)), @"fixture precondition");
    XCTAssertTrue(DHTOwnsMethod(object_getClass([DHTHCSource class]), @selector(initialize)),
                  @"fixture precondition");
    XCTAssertEqual(gDHTSourceLoadRan, 1);

    IMP targetCxxDestruct = DHTOwnIMP(target, cxxDestruct);
    IMP numberBefore = DHTOwnIMP(target, @selector(number));

    // number, greet:, scale:, +classNumber, +classTag. Not .cxx_destruct, +load,
    // +initialize, nor the two source-only methods the target does not respond to.
    XCTAssertEqual(DHHookClass([DHTHCSource class], target, NULL), (NSUInteger)5);

    DHTHCTarget *obj = [DHTHCTarget new];
    XCTAssertEqual([obj number], 15);
    XCTAssertEqualObjects([obj greet:@"world"], @"hello world!");
    XCTAssertEqual([obj scale:2.25], 5.5);
    XCTAssertEqual([DHTHCTarget classNumber], 101);
    XCTAssertEqualObjects([DHTHCTarget classTag], @"target+src");

    // Excluded methods were not installed.
    XCTAssertEqual(DHTOwnIMP(target, cxxDestruct), targetCxxDestruct, @".cxx_destruct must not be replaced");
    XCTAssertFalse(DHTOwnsMethod(targetMeta, @selector(load)), @"+load must not be installed");
    XCTAssertFalse(DHTOwnsMethod(targetMeta, @selector(initialize)), @"+initialize must not be installed");
    XCTAssertEqual(gDHTSourceLoadRan, 1);

    // Methods the target does not respond to were skipped, not added.
    XCTAssertFalse(class_respondsToSelector(target, @selector(dhtSourceOnlyInstanceMethod)));
    XCTAssertFalse(class_respondsToSelector(targetMeta, @selector(dhtSourceOnlyClassMethod)));

    // DH_ORIG resolves through the registry to the pre-hook IMP.
    XCTAssertEqual(DHOriginalForSource("-[DHTHCSource number]", @selector(number), obj), numberBefore);

    // One target per source: applying the same source again (to any target) returns 0.
    XCTAssertEqual(DHHookClass([DHTHCSource class], [DHTHCTarget2 class], NULL), (NSUInteger)0);
    XCTAssertEqual([[DHTHCTarget2 new] number], 20, @"second target is untouched");
    XCTAssertEqual(DHHookClass([DHTHCSource class], target, NULL), (NSUInteger)0);
    XCTAssertEqual([obj number], 15, @"applying a source twice must not stack");

    // Objects of the target still deallocate correctly (its own .cxx_destruct runs).
    @autoreleasepool {
        __weak id weakRef = nil;
        @autoreleasepool {
            DHTHCTarget *temp = [DHTHCTarget new];
            weakRef = temp;
            XCTAssertEqual([temp number], 15);
        }
        XCTAssertNil(weakRef);
    }
}

- (void)testHookClassBadInputsReturnZero {
    XCTAssertEqual(DHHookClass(Nil, [DHTHCTarget2 class], NULL), (NSUInteger)0);
    XCTAssertEqual(DHHookClass([DHTHCBadSource class], Nil, NULL), (NSUInteger)0);
    XCTAssertEqual([[DHTHCTarget2 new] number], 20);
}

- (void)testHookClassOnInheritedMethod {
    XCTAssertEqual(DHHookClass([DHTHCInhSource class], [DHTHCInhChild class], NULL), (NSUInteger)1);
    XCTAssertEqualObjects([[DHTHCInhChild new] describe], @"base+src");
    XCTAssertEqualObjects([[DHTHCInhBase new] describe], @"base");
}

- (void)testOriginalForSourceParsing {
    Class target = [DHTParseTarget class];
    Class meta = object_getClass(target);
    IMP plain = DHTOwnIMP(target, @selector(plain));
    IMP multi = DHTOwnIMP(target, @selector(multi:colon:args:));
    IMP cat = DHTOwnIMP(target, @selector(catMethod:with:));
    IMP classSide = DHTOwnIMP(meta, @selector(classSide));
    XCTAssertTrue(plain && multi && cat && classSide);

    XCTAssertEqual(DHHookClass([DHTParseSrc class], target, NULL), (NSUInteger)4);

    DHTParseTarget *obj = [DHTParseTarget new];
    XCTAssertEqual(DHOriginalForSource("-[DHTParseSrc plain]", @selector(plain), obj), plain);
    XCTAssertEqual(DHOriginalForSource("-[DHTParseSrc multi:colon:args:]", @selector(multi:colon:args:), obj),
                   multi);
    XCTAssertEqual(DHOriginalForSource("+[DHTParseSrc classSide]", @selector(classSide), (id)target), classSide);
    XCTAssertEqual(DHOriginalForSource("-[DHTParseSrc(Extra) catMethod:with:]", @selector(catMethod:with:), obj),
                   cat);
    // Repeated lookups with the same pointer (cached parse) are stable.
    const char *pf = "-[DHTParseSrc(Extra) catMethod:with:]";
    for (int i = 0; i < 3; i++) {
        XCTAssertEqual(DHOriginalForSource(pf, @selector(catMethod:with:), obj), cat);
    }

    // The real DH_ORIG paths, including the category method.
    XCTAssertEqualObjects([obj plain], @"plain*");
    XCTAssertEqualObjects([obj multi:@"a" colon:@"b" args:@"c"], @"abc*");
    XCTAssertEqualObjects([obj catMethod:@"x" with:@"y"], @"xy*");
    XCTAssertEqualObjects([DHTParseTarget classSide], @"classSide*");

    // Unknown source, unknown selector, wrong instance/class kind, malformed input.
    XCTAssertTrue(DHOriginalForSource("-[DHTNoSuchSourceClass plain]", @selector(plain), obj) == NULL);
    XCTAssertTrue(DHOriginalForSource("-[DHTParseSrc dhtNotHooked]", sel_registerName("dhtNotHooked"), obj) == NULL);
    XCTAssertTrue(DHOriginalForSource("+[DHTParseSrc plain]", @selector(plain), obj) == NULL);
    XCTAssertTrue(DHOriginalForSource("-[DHTParseSrc classSide]", @selector(classSide), obj) == NULL);
    XCTAssertTrue(DHOriginalForSource("garbage", @selector(plain), obj) == NULL);
    XCTAssertTrue(DHOriginalForSource("", @selector(plain), obj) == NULL);
    XCTAssertTrue(DHOriginalForSource("-[", @selector(plain), obj) == NULL);
    XCTAssertTrue(DHOriginalForSource("-[DHTParseSrc", @selector(plain), obj) == NULL);
    XCTAssertTrue(DHOriginalForSource("main", @selector(plain), nil) == NULL);
    XCTAssertTrue(DHOriginalForSource(NULL, @selector(plain), obj) == NULL);
    XCTAssertTrue(DHOriginalForSource("-[DHTParseSrc plain]", NULL, obj) == NULL);
}

// DH_ORIG also works from a block nested in a hook-class method, where
// __PRETTY_FUNCTION__ wraps the method's name ("__NN-[Class sel]_block_invoke").
- (void)testOrigFromBlockInsideHookClassMethod {
    IMP original = DHTOwnIMP([DHTBlockTarget class], @selector(viaBlock:));
    XCTAssertEqual(DHHookClass([DHTBlockSrc class], [DHTBlockTarget class], NULL), (NSUInteger)1);
    DHTBlockTarget *obj = [DHTBlockTarget new];
    XCTAssertEqualObjects([obj viaBlock:@"!"], @"orig!*");
    XCTAssertEqual(DHOriginalForSource("__31-[DHTBlockSrc viaBlock:]_block_invoke", @selector(viaBlock:), obj),
                   original);
    XCTAssertEqual(DHOriginalForSource("__31-[DHTBlockSrc viaBlock:]_block_invoke_2", @selector(viaBlock:), obj),
                   original);
}

- (void)testHookClassWithGroup {
    DHGroup *group = DHGroupCreate("dht.hookclass.group");
    XCTAssertEqual(DHHookClass([DHTHCGroupSource class], [DHTHCGroupTarget class], group), (NSUInteger)2);
    XCTAssertEqual([[DHTHCGroupTarget new] value], 11);
    XCTAssertEqual([DHTHCGroupTarget classValue], 22);

    DHGroupSetEnabled(group, NO);
    XCTAssertEqual([[DHTHCGroupTarget new] value], 1);
    XCTAssertEqual([DHTHCGroupTarget classValue], 2);

    DHGroupSetEnabled(group, YES);
    XCTAssertEqual([[DHTHCGroupTarget new] value], 11);
    XCTAssertEqual([DHTHCGroupTarget classValue], 22);
}

@end
