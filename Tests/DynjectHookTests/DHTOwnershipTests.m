// ARC ownership when hooking methods that return a retained (+1) object: the
// copy family and the init family, in both hooking styles. The function types
// used here are the ones DynjectHook.h and docs/hooking.md prescribe:
//
// - hook-class method (DH_ORIG): the method is itself in the family, so FN_TYPE
//   carries ns_returns_retained (and ns_consumed on self for init);
// - C replacement (DH_CALL_ORIG): a plain function returns an unretained
//   object, so FN_TYPE is the plain type, without attributes.
//
// Every test counts live objects: a leak leaves the count above zero, an
// over-release crashes or frees an object that is still held.

#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import "DynjectHook.h"

static _Atomic long gOwnLive;
static _Atomic long gOwnHookCalls;

// Counts its instances from allocation to deallocation.
@interface DHTOwnCounted : NSObject
@property (nonatomic) NSInteger tag;
@end
@implementation DHTOwnCounted
+ (instancetype)allocWithZone:(NSZone *)zone {
    atomic_fetch_add(&gOwnLive, 1);
    return [super allocWithZone:zone];
}
- (void)dealloc { atomic_fetch_sub(&gOwnLive, 1); }
@end

#pragma mark - copy family

@interface DHTOwnCopyBase : DHTOwnCounted <NSCopying>
@end
@implementation DHTOwnCopyBase
- (id)copyWithZone:(NSZone *)zone {
    DHTOwnCopyBase *copy = [[[self class] allocWithZone:zone] init];
    copy.tag = self.tag + 1;
    return copy;
}
@end
@interface DHTOwnCopyViaClass : DHTOwnCopyBase
@end
@implementation DHTOwnCopyViaClass
- (id)copyWithZone:(NSZone *)zone { return [super copyWithZone:zone]; }
@end
@interface DHTOwnCopyViaFunction : DHTOwnCopyBase
@end
@implementation DHTOwnCopyViaFunction
- (id)copyWithZone:(NSZone *)zone { return [super copyWithZone:zone]; }
@end

// Hook class: copyWithZone: returns +1, and so does the original it calls.
typedef id (*DHTOwnRetainedCopyFn)(id, SEL, NSZone *) __attribute__((ns_returns_retained));
@interface DHTOwnCopySource : NSObject
@end
@implementation DHTOwnCopySource
- (id)copyWithZone:(NSZone *)zone {
    atomic_fetch_add(&gOwnHookCalls, 1);
    return DH_ORIG(DHTOwnRetainedCopyFn, zone);
}
@end

// C replacement: the plain type. ARC retains and autoreleases around the call,
// which hands the original's +1 through to the caller of -copy.
static DHHook *gOwnCopyHook;
static id DHTOwnCopy_function(id self, SEL _cmd, NSZone *zone) {
    atomic_fetch_add(&gOwnHookCalls, 1);
    return DH_CALL_ORIG(gOwnCopyHook, id (*)(id, SEL, NSZone *), self, _cmd, zone);
}

#pragma mark - init family

// mode 0: returns self; 1: returns nil; 2: returns another object instead of self.
@interface DHTOwnInitBase : DHTOwnCounted
- (instancetype)initWithMode:(int)mode;
@end
@implementation DHTOwnInitBase
- (instancetype)initWithMode:(int)mode {
    self = [super init];
    if (mode == 1) return nil;
    if (mode == 2) {
        DHTOwnInitBase *substitute = [[[self class] alloc] initWithMode:0];
        substitute.tag = 2;
        return substitute;
    }
    return self;
}
@end
@interface DHTOwnInitViaClass : DHTOwnInitBase
@end
@implementation DHTOwnInitViaClass
- (instancetype)initWithMode:(int)mode { return [super initWithMode:mode]; }
@end
@interface DHTOwnInitViaFunction : DHTOwnInitBase
@end
@implementation DHTOwnInitViaFunction
- (instancetype)initWithMode:(int)mode { return [super initWithMode:mode]; }
@end

// Hook class: an init method consumes self and returns +1, and so does the original.
typedef id (*DHTOwnInitFn)(id __attribute__((ns_consumed)), SEL, int) __attribute__((ns_returns_retained));
@interface DHTOwnInitSource : NSObject
@end
@implementation DHTOwnInitSource
- (instancetype)initWithMode:(int)mode {
    atomic_fetch_add(&gOwnHookCalls, 1);
    return DH_ORIG(DHTOwnInitFn, mode);
}
@end

// C replacement: the plain type again.
static DHHook *gOwnInitHook;
static id DHTOwnInit_function(id self, SEL _cmd, int mode) {
    atomic_fetch_add(&gOwnHookCalls, 1);
    return DH_CALL_ORIG(gOwnInitHook, id (*)(id, SEL, int), self, _cmd, mode);
}

@interface DynjectHookTestsOwnership : XCTestCase
@end

@implementation DynjectHookTestsOwnership

- (void)setUp {
    [super setUp];
    atomic_store(&gOwnLive, 0);
    atomic_store(&gOwnHookCalls, 0);
}

- (void)checkCopiesOfClass:(Class)cls {
    static const int kRounds = 50;
    @autoreleasepool {
        DHTOwnCopyBase *box = [[cls alloc] init];
        box.tag = 40;
        DHTOwnCopyBase *kept = nil;
        @autoreleasepool {
            for (int i = 0; i < kRounds; i++) {
                DHTOwnCopyBase *copy = [box copy];
                XCTAssertEqual(copy.tag, 41);
                if (i == 0) kept = copy;
            }
        }
        // An over-released copy would be gone (or freed twice) by now.
        XCTAssertEqual(atomic_load(&gOwnLive), 2, @"only the box and the kept copy are alive");
        XCTAssertEqual(kept.tag, 41);
        XCTAssertEqual(object_getClass(kept), cls);
    }
    XCTAssertEqual(atomic_load(&gOwnLive), 0, @"no copy leaked");
    XCTAssertEqual(atomic_load(&gOwnHookCalls), kRounds, @"the hook ran for every copy");
}

- (void)testCopyFamilyThroughHookClass {
    XCTAssertEqual(DHHookClass([DHTOwnCopySource class], [DHTOwnCopyViaClass class], NULL), (NSUInteger)1);
    [self checkCopiesOfClass:[DHTOwnCopyViaClass class]];
}

- (void)testCopyFamilyThroughFunctionReplacement {
    gOwnCopyHook = DHHookMessage([DHTOwnCopyViaFunction class], @selector(copyWithZone:),
                                 (IMP)DHTOwnCopy_function, NULL);
    XCTAssertTrue(gOwnCopyHook != NULL);
    [self checkCopiesOfClass:[DHTOwnCopyViaFunction class]];
}

- (void)checkInitOfClass:(Class)cls {
    static const int kRounds = 20;
    for (int mode = 0; mode <= 2; mode++) {
        atomic_store(&gOwnHookCalls, 0);
        @autoreleasepool {
            DHTOwnInitBase *kept = nil;
            @autoreleasepool {
                for (int i = 0; i < kRounds; i++) {
                    DHTOwnInitBase *object = [[cls alloc] initWithMode:mode];
                    if (mode == 1) {
                        XCTAssertNil(object);
                    } else {
                        XCTAssertEqual(object_getClass(object), cls);
                        XCTAssertEqual(object.tag, mode);
                    }
                    if (i == 0) kept = object;
                }
            }
            XCTAssertEqual(atomic_load(&gOwnLive), mode == 1 ? 0 : 1, @"mode %d: only the kept object is alive", mode);
            XCTAssertEqual(kept.tag, mode == 1 ? 0 : mode);
        }
        XCTAssertEqual(atomic_load(&gOwnLive), 0, @"mode %d: nothing leaked", mode);
        // In mode 2 the original creates its substitute through the hooked init as well.
        XCTAssertEqual(atomic_load(&gOwnHookCalls), mode == 2 ? 2 * kRounds : kRounds, @"mode %d", mode);
    }
}

- (void)testInitFamilyThroughHookClass {
    XCTAssertEqual(DHHookClass([DHTOwnInitSource class], [DHTOwnInitViaClass class], NULL), (NSUInteger)1);
    [self checkInitOfClass:[DHTOwnInitViaClass class]];
}

- (void)testInitFamilyThroughFunctionReplacement {
    gOwnInitHook = DHHookMessage([DHTOwnInitViaFunction class], @selector(initWithMode:),
                                 (IMP)DHTOwnInit_function, NULL);
    XCTAssertTrue(gOwnInitHook != NULL);
    [self checkInitOfClass:[DHTOwnInitViaFunction class]];
}

@end
