// DH_CTOR with a bundle-ID list that contains this app: the body runs.
//
// DH_CTOR may be used once per translation unit, so each form has its own file
// (DHTShouldLoadTests.m: no bundle IDs; DHTCtorNoMatchTests.m: a list without
// this app). The constructors below run in this order when the test bundle
// loads: the one with a priority first, then the others as written. The first
// gives the process a known bundle identifier (and switches the Shift bypass
// off, see DHTShouldLoadTests.m); the last undoes both.

#import <XCTest/XCTest.h>
#import "DynjectHook.h"

static int gDHTCtorMatchRuns;
static BOOL gDHTCtorMatchSetShiftEnv;

__attribute__((constructor(101))) static void DHTCtorMatchPrepare(void) {
    DHSetBundleIdentifierForTesting("com.dynject.tests.ctor-host");
    if (getenv("DH_DISABLE_SHIFT_BYPASS")) return;
    setenv("DH_DISABLE_SHIFT_BYPASS", "1", 1);
    gDHTCtorMatchSetShiftEnv = YES;
}

DH_CTOR("dht.tests.ctor.match", "com.example.dht.first", "com.dynject.tests.ctor-host", "com.example.dht.last") {
    gDHTCtorMatchRuns++;
}

__attribute__((constructor)) static void DHTCtorMatchRestore(void) {
    DHSetBundleIdentifierForTesting(NULL);
    if (gDHTCtorMatchSetShiftEnv) unsetenv("DH_DISABLE_SHIFT_BYPASS");
}

@interface DynjectHookTestsCtorMatch : XCTestCase
@end

@implementation DynjectHookTestsCtorMatch

- (void)testCtorWithMatchingBundleIDRunsBody {
    XCTAssertEqual(gDHTCtorMatchRuns, 1, @"DH_CTOR runs its body once when the app is in its bundle-ID list");
}

@end
