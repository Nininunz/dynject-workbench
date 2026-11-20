// DHSystemVersionAtLeast, DH_REQUIRE_SYSTEM and the SDK version marker.
//
// The running version is replaced with DHSetSystemVersionForTesting; -tearDown restores it.

#import <XCTest/XCTest.h>
#import <dlfcn.h>
#import "DynjectHook.h"

// A DH_CTOR body stand-in: DH_REQUIRE_SYSTEM returns from the function it is used in.
static void DHTGuardedBody(const char *version, int *ran) {
    DH_REQUIRE_SYSTEM(version);
    (*ran)++;
}

@interface DynjectHookTestsSystemVersion : XCTestCase
@end

@implementation DynjectHookTestsSystemVersion

- (void)tearDown {
    DHSetSystemVersionForTesting(NULL);
    [super tearDown];
}

- (void)testAtLeastComparesComponentsWithMissingOnesAsZero {
    DHSetSystemVersionForTesting("27.2.1");
    XCTAssertTrue(DHSystemVersionAtLeast("27"));
    XCTAssertTrue(DHSystemVersionAtLeast("27.0"));
    XCTAssertTrue(DHSystemVersionAtLeast("27.2"));
    XCTAssertTrue(DHSystemVersionAtLeast("27.2.1"));
    XCTAssertFalse(DHSystemVersionAtLeast("27.2.2"));
    XCTAssertFalse(DHSystemVersionAtLeast("27.10"));
    XCTAssertFalse(DHSystemVersionAtLeast("28"));
    XCTAssertTrue(DHSystemVersionAtLeast("26.9.9"));
}

- (void)testMalformedVersionsAreRefused {
    DHSetSystemVersionForTesting("27.2");
    XCTAssertFalse(DHSystemVersionAtLeast(NULL));
    XCTAssertFalse(DHSystemVersionAtLeast(""));
    XCTAssertFalse(DHSystemVersionAtLeast("27."));
    XCTAssertFalse(DHSystemVersionAtLeast(".27"));
    XCTAssertFalse(DHSystemVersionAtLeast("27.0.0.1"));
    XCTAssertFalse(DHSystemVersionAtLeast("v27"));
    XCTAssertFalse(DHSystemVersionAtLeast("27 "));
}

- (void)testCompatibilityVersionCountsAsUnknown {
    DHSetSystemVersionForTesting("10.16");
    XCTAssertTrue(DHSystemVersionAtLeast("27.0"), @"10.16 is what old-SDK apps are told; it says nothing");
}

- (void)testRunningSystemIsAtLeastItself {
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *s = [NSString stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
    XCTAssertTrue(DHSystemVersionAtLeast(s.UTF8String));
    XCTAssertFalse(DHSystemVersionAtLeast([NSString stringWithFormat:@"%ld", (long)v.majorVersion + 1].UTF8String));
}

- (void)testRequireSystemReturnsEarlyOnOlderSystems {
    int ran = 0;
    DHSetSystemVersionForTesting("26.4");
    DHTGuardedBody("27.0", &ran);
    XCTAssertEqual(ran, 0);
    DHSetSystemVersionForTesting("27.0");
    DHTGuardedBody("27.0", &ran);
    XCTAssertEqual(ran, 1);
    DHSetSystemVersionForTesting(NULL);
    DHTGuardedBody("14.0", &ran);
    XCTAssertEqual(ran, 2);
}

/// The marker survives compiling and linking (it is only referenced by the `used` attribute).
- (void)testSDKVersionMarkerIsInTheImage {
    Dl_info info;
    XCTAssertNotEqual(dladdr((const void *)&DHSystemVersionAtLeast, &info), 0);
    NSData *image = [NSData dataWithContentsOfFile:@(info.dli_fname) options:NSDataReadingMappedIfSafe error:NULL];
    XCTAssertNotNil(image);
    const char marker[] = "\0dynject.sdk:" DH_SDK_VERSION;
    NSData *needle = [NSData dataWithBytes:marker length:sizeof(marker)];   // with the terminating NUL
    XCTAssertNotEqual([image rangeOfData:needle options:0 range:NSMakeRange(0, image.length)].location, (NSUInteger)NSNotFound);
}

@end
