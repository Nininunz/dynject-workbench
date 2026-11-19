// ABI coverage: originals reached through DH_CALL_ORIG (DHHookMessage, own and
// inherited methods) and DH_ORIG (DHHookClass) with float/double arguments,
// NSRect argument and return, a five-double struct returned by value (indirect
// return on arm64, stret on x86_64), BOOL and char returns, and a method with
// more than 8 arguments mixing integers and floating point (spills to the stack
// in both register files on arm64).

#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "DynjectHook.h"

typedef struct { double a, b, c, d, e; } DHTFive;

@protocol DHTABIMethods <NSObject>
- (float)dhtScaleFloat:(float)f by:(double)d;
- (double)dhtMixDouble:(double)d float:(float)f int:(int)i;
- (NSRect)dhtOffsetRect:(NSRect)r by:(CGFloat)delta;
- (DHTFive)dhtFiveFrom:(double)base step:(double)step;
- (BOOL)dhtIsPositive:(NSInteger)x;
- (char)dhtCharAt:(NSUInteger)i of:(const char *)s;
- (double)dhtManyI1:(long)i1 d1:(double)d1 i2:(int)i2 d2:(double)d2 i3:(long)i3 d3:(double)d3
                 i4:(short)i4 d4:(float)d4 i5:(long)i5 d5:(double)d5 i6:(char)i6 d6:(double)d6
                 i7:(long)i7 d7:(double)d7 i8:(long)i8 d8:(double)d8 i9:(int)i9 d9:(double)d9
                i10:(long)i10 d10:(double)d10;
@end

static double DHTManyExpected(long i1, double d1, int i2, double d2, long i3, double d3, short i4, float d4,
                              long i5, double d5, char i6, double d6, long i7, double d7, long i8, double d8,
                              int i9, double d9, long i10, double d10) {
    // Distinct weights so any dropped, swapped or misaligned argument changes the result.
    return i1 * 1.0 + i2 * 2.0 + i3 * 3.0 + i4 * 4.0 + i5 * 5.0 + i6 * 6.0 + i7 * 7.0 + i8 * 8.0 + i9 * 9.0 +
           i10 * 10.0 + d1 * 100.0 + d2 * 200.0 + d3 * 300.0 + d4 * 400.0 + d5 * 500.0 + d6 * 600.0 +
           d7 * 700.0 + d8 * 800.0 + d9 * 900.0 + d10 * 1000.0;
}

// Original implementations, shared by every fixture class that defines them.
#define DHT_ABI_ORIGINALS                                                                                 \
    -(float)dhtScaleFloat : (float)f by : (double)d { return (float)(f * d); }                            \
    -(double)dhtMixDouble : (double)d float : (float)f int : (int)i { return d + f * 2.0 + i * 4.0; }      \
    -(NSRect)dhtOffsetRect : (NSRect)r by : (CGFloat)delta {                                              \
        return NSMakeRect(r.origin.x + delta, r.origin.y + delta * 2, r.size.width * 2,                   \
                          r.size.height + delta);                                                         \
    }                                                                                                     \
    -(DHTFive)dhtFiveFrom : (double)base step : (double)step {                                            \
        DHTFive v = {base, base + step, base + 2 * step, base + 3 * step, base + 4 * step};               \
        return v;                                                                                         \
    }                                                                                                     \
    -(BOOL)dhtIsPositive : (NSInteger)x { return x > 0; }                                                 \
    -(char)dhtCharAt : (NSUInteger)i of : (const char *)s { return s[i]; }                                \
    -(double)dhtManyI1 : (long)i1 d1 : (double)d1 i2 : (int)i2 d2 : (double)d2 i3 : (long)i3 d3           \
        : (double)d3 i4 : (short)i4 d4 : (float)d4 i5 : (long)i5 d5 : (double)d5 i6 : (char)i6 d6         \
        : (double)d6 i7 : (long)i7 d7 : (double)d7 i8 : (long)i8 d8 : (double)d8 i9 : (int)i9 d9          \
        : (double)d9 i10 : (long)i10 d10 : (double)d10 {                                                  \
        return DHTManyExpected(i1, d1, i2, d2, i3, d3, i4, d4, i5, d5, i6, d6, i7, d7, i8, d8, i9, d9,    \
                               i10, d10);                                                                 \
    }

// Own methods, hooked with DHHookMessage.
@interface DHTABIMsgTarget : NSObject <DHTABIMethods>
@end
@implementation DHTABIMsgTarget
DHT_ABI_ORIGINALS
@end

// Inherited methods: the child is hooked with DHHookMessage (class_addMethod path).
@interface DHTABIInhBase : NSObject <DHTABIMethods>
@end
@implementation DHTABIInhBase
DHT_ABI_ORIGINALS
@end
@interface DHTABIInhChild : DHTABIInhBase
@end
@implementation DHTABIInhChild
@end

// Own methods, hooked with DHHookClass from DHTABISource.
@interface DHTABIClsTarget : NSObject <DHTABIMethods>
@end
@implementation DHTABIClsTarget
DHT_ABI_ORIGINALS
@end

#pragma mark - Hook transforms (identical for every hooking style)

static float DHTXScale(float o) { return o + 0.5f; }
static double DHTXMix(double o) { return o * 10.0; }
static NSRect DHTXRect(NSRect o) { o.origin.x += 1000; return o; }
static DHTFive DHTXFive(DHTFive o) { o.a = -o.a; o.e += 1000; return o; }
static BOOL DHTXBool(BOOL o) { return !o; }
static char DHTXChar(char o) { return (char)(o + 1); }
static double DHTXMany(double o) { return o + 0.125; }

#pragma mark - DH_CALL_ORIG replacements (one set per handle table)

typedef struct {
    DHHook *scale, *mix, *rect, *five, *boolean, *chr, *many;
} DHTABIHooks;

static DHTABIHooks gMsgHooks;
static DHTABIHooks gInhHooks;

#define DHT_DEFINE_ABI_REPLACEMENTS(PREFIX, H)                                                             \
    static float PREFIX##_scale(id self, SEL _cmd, float f, double d) {                                    \
        return DHTXScale(DH_CALL_ORIG(H.scale, float (*)(id, SEL, float, double), self, _cmd, f, d));       \
    }                                                                                                      \
    static double PREFIX##_mix(id self, SEL _cmd, double d, float f, int i) {                              \
        return DHTXMix(DH_CALL_ORIG(H.mix, double (*)(id, SEL, double, float, int), self, _cmd, d, f, i));  \
    }                                                                                                      \
    static NSRect PREFIX##_rect(id self, SEL _cmd, NSRect r, CGFloat delta) {                              \
        return DHTXRect(DH_CALL_ORIG(H.rect, NSRect (*)(id, SEL, NSRect, CGFloat), self, _cmd, r, delta)); \
    }                                                                                                      \
    static DHTFive PREFIX##_five(id self, SEL _cmd, double base, double step) {                            \
        return DHTXFive(                                                                                   \
            DH_CALL_ORIG(H.five, DHTFive (*)(id, SEL, double, double), self, _cmd, base, step));           \
    }                                                                                                      \
    static BOOL PREFIX##_bool(id self, SEL _cmd, NSInteger x) {                                            \
        return DHTXBool(DH_CALL_ORIG(H.boolean, BOOL (*)(id, SEL, NSInteger), self, _cmd, x));             \
    }                                                                                                      \
    static char PREFIX##_char(id self, SEL _cmd, NSUInteger i, const char *s) {                            \
        return DHTXChar(DH_CALL_ORIG(H.chr, char (*)(id, SEL, NSUInteger, const char *), self, _cmd, i, s)); \
    }                                                                                                      \
    static double PREFIX##_many(id self, SEL _cmd, long i1, double d1, int i2, double d2, long i3,         \
                                double d3, short i4, float d4, long i5, double d5, char i6, double d6,     \
                                long i7, double d7, long i8, double d8, int i9, double d9, long i10,       \
                                double d10) {                                                              \
        return DHTXMany(DH_CALL_ORIG(H.many,                                                               \
                                     double (*)(id, SEL, long, double, int, double, long, double, short,   \
                                                float, long, double, char, double, long, double, long,     \
                                                double, int, double, long, double),                        \
                                     self, _cmd, i1, d1, i2, d2, i3, d3, i4, d4, i5, d5, i6, d6, i7, d7,   \
                                     i8, d8, i9, d9, i10, d10));                                           \
    }

DHT_DEFINE_ABI_REPLACEMENTS(DHTMsg, gMsgHooks)
DHT_DEFINE_ABI_REPLACEMENTS(DHTInh, gInhHooks)

#define DHT_INSTALL_ABI_HOOKS(CLS, PREFIX, H)                                                              \
    do {                                                                                                   \
        H.scale = DHHookMessage(CLS, @selector(dhtScaleFloat:by:), (IMP)PREFIX##_scale, NULL);             \
        H.mix = DHHookMessage(CLS, @selector(dhtMixDouble:float:int:), (IMP)PREFIX##_mix, NULL);           \
        H.rect = DHHookMessage(CLS, @selector(dhtOffsetRect:by:), (IMP)PREFIX##_rect, NULL);               \
        H.five = DHHookMessage(CLS, @selector(dhtFiveFrom:step:), (IMP)PREFIX##_five, NULL);               \
        H.boolean = DHHookMessage(CLS, @selector(dhtIsPositive:), (IMP)PREFIX##_bool, NULL);               \
        H.chr = DHHookMessage(CLS, @selector(dhtCharAt:of:), (IMP)PREFIX##_char, NULL);                    \
        H.many = DHHookMessage(CLS,                                                                        \
                               @selector(dhtManyI1:d1:i2:d2:i3:d3:i4:d4:i5:d5:i6:d6:i7:d7:i8:d8:i9:d9:i10:d10:), \
                               (IMP)PREFIX##_many, NULL);                                                  \
    } while (0)

#pragma mark - DH_ORIG source class

@interface DHTABISource : NSObject
@end
@implementation DHTABISource
- (float)dhtScaleFloat:(float)f by:(double)d {
    return DHTXScale(DH_ORIG(float (*)(id, SEL, float, double), f, d));
}
- (double)dhtMixDouble:(double)d float:(float)f int:(int)i {
    return DHTXMix(DH_ORIG(double (*)(id, SEL, double, float, int), d, f, i));
}
- (NSRect)dhtOffsetRect:(NSRect)r by:(CGFloat)delta {
    return DHTXRect(DH_ORIG(NSRect (*)(id, SEL, NSRect, CGFloat), r, delta));
}
- (DHTFive)dhtFiveFrom:(double)base step:(double)step {
    return DHTXFive(DH_ORIG(DHTFive (*)(id, SEL, double, double), base, step));
}
- (BOOL)dhtIsPositive:(NSInteger)x {
    return DHTXBool(DH_ORIG(BOOL (*)(id, SEL, NSInteger), x));
}
- (char)dhtCharAt:(NSUInteger)i of:(const char *)s {
    return DHTXChar(DH_ORIG(char (*)(id, SEL, NSUInteger, const char *), i, s));
}
- (double)dhtManyI1:(long)i1 d1:(double)d1 i2:(int)i2 d2:(double)d2 i3:(long)i3 d3:(double)d3
                 i4:(short)i4 d4:(float)d4 i5:(long)i5 d5:(double)d5 i6:(char)i6 d6:(double)d6
                 i7:(long)i7 d7:(double)d7 i8:(long)i8 d8:(double)d8 i9:(int)i9 d9:(double)d9
                i10:(long)i10 d10:(double)d10 {
    return DHTXMany(DH_ORIG(double (*)(id, SEL, long, double, int, double, long, double, short, float, long,
                                       double, char, double, long, double, long, double, int, double, long,
                                       double),
                            i1, d1, i2, d2, i3, d3, i4, d4, i5, d5, i6, d6, i7, d7, i8, d8, i9, d9, i10, d10));
}
@end

#pragma mark - Tests

@interface DynjectHookTestsABI : XCTestCase
@end

@implementation DynjectHookTestsABI

// Checks all seven methods on obj; hooked == YES expects the hook transforms on top.
- (void)verifyABIOn:(id<DHTABIMethods>)obj hooked:(BOOL)hooked label:(NSString *)label {
    // float and double arguments, float return.
    XCTAssertEqual([obj dhtScaleFloat:1.5f by:3.0], hooked ? 5.0f : 4.5f, @"%@ float", label);
    // double, float and int arguments, double return.
    XCTAssertEqual([obj dhtMixDouble:0.25 float:1.5f int:3], hooked ? 152.5 : 15.25, @"%@ double", label);

    // NSRect argument and return.
    NSRect r = [obj dhtOffsetRect:NSMakeRect(1, 2, 3, 4) by:0.5];
    NSRect expected = NSMakeRect(1.5 + (hooked ? 1000 : 0), 3, 6, 4.5);
    XCTAssertTrue(NSEqualRects(r, expected), @"%@ rect: got %@, expected %@", label, NSStringFromRect(r),
                  NSStringFromRect(expected));

    // Five doubles returned by value.
    DHTFive five = [obj dhtFiveFrom:2.0 step:0.5];
    XCTAssertEqual(five.a, hooked ? -2.0 : 2.0, @"%@ five.a", label);
    XCTAssertEqual(five.b, 2.5, @"%@ five.b", label);
    XCTAssertEqual(five.c, 3.0, @"%@ five.c", label);
    XCTAssertEqual(five.d, 3.5, @"%@ five.d", label);
    XCTAssertEqual(five.e, hooked ? 1004.0 : 4.0, @"%@ five.e", label);

    // BOOL return.
    XCTAssertEqual([obj dhtIsPositive:5], hooked ? NO : YES, @"%@ BOOL+", label);
    XCTAssertEqual([obj dhtIsPositive:-5], hooked ? YES : NO, @"%@ BOOL-", label);

    // char return.
    XCTAssertEqual([obj dhtCharAt:2 of:"abcdef"], hooked ? 'd' : 'c', @"%@ char", label);

    // More than 8 arguments, integers and floating point mixed.
    double many = [obj dhtManyI1:1 d1:0.5 i2:-2 d2:1.25 i3:3 d3:2.5 i4:-4 d4:0.75f i5:5 d5:3.5
                              i6:6 d6:4.25 i7:-7 d7:5.5 i8:8 d8:6.75 i9:9 d9:-7.5 i10:10 d10:8.25];
    double expectedMany = DHTManyExpected(1, 0.5, -2, 1.25, 3, 2.5, -4, 0.75f, 5, 3.5, 6, 4.25, -7, 5.5, 8, 6.75,
                                          9, -7.5, 10, 8.25) +
                          (hooked ? 0.125 : 0.0);
    XCTAssertEqual(many, expectedMany, @"%@ many", label);
}

- (void)testABIThroughDHCallOrigOnOwnMethods {
    [self verifyABIOn:[DHTABIMsgTarget new] hooked:NO label:@"msg/before"];
    DHT_INSTALL_ABI_HOOKS([DHTABIMsgTarget class], DHTMsg, gMsgHooks);
    DHHook *all[] = {gMsgHooks.scale, gMsgHooks.mix, gMsgHooks.rect, gMsgHooks.five,
                     gMsgHooks.boolean, gMsgHooks.chr, gMsgHooks.many};
    for (size_t i = 0; i < 7; i++) XCTAssertTrue(all[i] != NULL, @"hook %zu", i);
    [self verifyABIOn:[DHTABIMsgTarget new] hooked:YES label:@"msg"];
}

- (void)testABIThroughDHCallOrigOnInheritedMethods {
    DHT_INSTALL_ABI_HOOKS([DHTABIInhChild class], DHTInh, gInhHooks);
    DHHook *all[] = {gInhHooks.scale, gInhHooks.mix, gInhHooks.rect, gInhHooks.five,
                     gInhHooks.boolean, gInhHooks.chr, gInhHooks.many};
    for (size_t i = 0; i < 7; i++) XCTAssertTrue(all[i] != NULL, @"hook %zu", i);
    [self verifyABIOn:[DHTABIInhChild new] hooked:YES label:@"inherited"];
    [self verifyABIOn:[DHTABIInhBase new] hooked:NO label:@"inherited/base"];
}

- (void)testABIThroughDHOrigInHookClass {
    [self verifyABIOn:[DHTABIClsTarget new] hooked:NO label:@"cls/before"];
    XCTAssertEqual(DHHookClass([DHTABISource class], [DHTABIClsTarget class], NULL), (NSUInteger)7);
    [self verifyABIOn:[DHTABIClsTarget new] hooked:YES label:@"cls"];
}

@end
