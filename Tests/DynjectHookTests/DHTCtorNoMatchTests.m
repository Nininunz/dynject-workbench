// DH_CTOR with a bundle-ID list that does not contain this app: the body must
// not run. If the macro ever stopped forwarding its list to DHShouldLoad, every
// tweak would load into every app it is injected into; this pins the filter.
// See DHTCtorMatchTests.m for how the constructors here are ordered.

#import <XCTest/XCTest.h>
#import "DynjectHook.h"

static int gDHTCtorNoMatchRuns;
static BOOL gDHTCtorNoMatchSetShiftEnv;

__attribute__((constructor(101))) static void DHTCtorNoMatchPrepare(void) {
    DHSetBundleIdentifierForTesting("com.dynject.tests.ctor-host");
    if (getenv("DH_DISABLE_SHIFT_BYPASS")) return;
    setenv("DH_DISABLE_SHIFT_BYPASS", "1", 1);
    gDHTCtorNoMatchSetShiftEnv = YES;
}

DH_CTOR("dht.tests.ctor.nomatch", "com.example.dht.never", "com.example.dht.never2") {
    gDHTCtorNoMatchRuns++;
}

__attribute__((constructor)) static void DHTCtorNoMatchRestore(void) {
    DHSetBundleIdentifierForTesting(NULL);
    if (gDHTCtorNoMatchSetShiftEnv) unsetenv("DH_DISABLE_SHIFT_BYPASS");
}

@interface DynjectHookTestsCtorNoMatch : XCTestCase
@end

@implementation DynjectHookTestsCtorNoMatch

- (void)testCtorWithoutMatchingBundleIDSkipsBody {
    XCTAssertEqual(gDHTCtorNoMatchRuns, 0, @"DH_CTOR must not run its body in an app outside its bundle-ID list");
}

@end
