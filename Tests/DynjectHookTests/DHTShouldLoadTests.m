// Load policy: DHShouldLoad (bundle filter, Safe Mode preferences, Shift bypass)
// and the DH_CTOR entry point.
//
// Safe Mode tests write only to a unique, throwaway preferences domain selected
// with DHSetPreferencesDomainForTesting. The domain is an absolute path inside a
// fresh temporary directory (CFPreferences accepts path domains), so nothing is
// written to ~/Library/Preferences; -tearDown clears the key and deletes the directory.

#import <XCTest/XCTest.h>
#import <CoreGraphics/CoreGraphics.h>
#import "DynjectHook.h"

#pragma mark - DH_CTOR (the only one in this test bundle: "one DH_CTOR per tweak")

static int gDHTCtorBodyRuns;
static int gDHTCtorAfterThrow;

// DH_CTOR checks the Shift bypass while the test bundle loads, against the real
// keyboard, so a Shift key held at that moment would skip the body. Constructors
// of one translation unit run in priority order and then in definition order:
// this one switches the bypass off for the DH_CTOR below, and the constructor
// after it restores the environment.
static BOOL gDHTCtorSetShiftEnv;
__attribute__((constructor(101))) static void DHTCtorDisableShiftBypass(void) {
    if (getenv("DH_DISABLE_SHIFT_BYPASS")) return;
    setenv("DH_DISABLE_SHIFT_BYPASS", "1", 1);
    gDHTCtorSetShiftEnv = YES;
}

// No bundle IDs: loads into every app. The body throws; DH_CTOR must catch and
// log the exception instead of letting it escape the constructor (which would
// abort loading the test bundle).
DH_CTOR("dht.tests.ctor") {
    gDHTCtorBodyRuns++;
    if (gDHTCtorBodyRuns > 0) {
        @throw [NSException exceptionWithName:@"DHTCtorTestException" reason:@"thrown on purpose" userInfo:nil];
    }
    gDHTCtorAfterThrow++;
}

__attribute__((constructor)) static void DHTCtorRestoreShiftBypass(void) {
    if (gDHTCtorSetShiftEnv) unsetenv("DH_DISABLE_SHIFT_BYPASS");
}

#pragma mark - Tests

static NSString *const kDHTSafeModeKey = @"dynject.safemode";
static const char *const kDHTHostID = "com.dynject.tests.host";

@interface DynjectHookTestsShouldLoad : XCTestCase
@property (nonatomic, copy) NSString *domain;
@property (nonatomic, copy) NSString *domainDirectory;
@property (nonatomic, copy) NSString *savedShiftEnv;
@end

@implementation DynjectHookTestsShouldLoad

- (void)setUp {
    [super setUp];
    const char *env = getenv("DH_DISABLE_SHIFT_BYPASS");
    self.savedShiftEnv = env ? @(env) : nil;
    setenv("DH_DISABLE_SHIFT_BYPASS", "1", 1);
    self.domainDirectory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"dht-safemode-%@", [NSUUID UUID].UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.domainDirectory withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    self.domain = [self.domainDirectory stringByAppendingPathComponent:@"local.dynject.tests.safemode"];
    DHSetPreferencesDomainForTesting((__bridge CFStringRef)self.domain);
    DHSetBundleIdentifierForTesting(kDHTHostID);
}

- (void)tearDown {
    CFStringRef domain = (__bridge CFStringRef)self.domain;
    CFPreferencesSetValue((__bridge CFStringRef)kDHTSafeModeKey, NULL, domain, kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    [[NSFileManager defaultManager] removeItemAtPath:self.domainDirectory error:NULL];

    DHSetPreferencesDomainForTesting(NULL);
    DHSetBundleIdentifierForTesting(NULL);
    if (self.savedShiftEnv) {
        setenv("DH_DISABLE_SHIFT_BYPASS", self.savedShiftEnv.UTF8String, 1);
    } else {
        unsetenv("DH_DISABLE_SHIFT_BYPASS");
    }
    [super tearDown];
}

- (void)setSafeMode:(id)value {
    CFStringRef domain = (__bridge CFStringRef)self.domain;
    CFPreferencesSetValue((__bridge CFStringRef)kDHTSafeModeKey, (__bridge CFPropertyListRef)value, domain,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    XCTAssertTrue(CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
}

- (void)testCtorRanBodyAndCaughtException {
    XCTAssertEqual(gDHTCtorBodyRuns, 1, @"DH_CTOR with no bundle IDs runs its body once at load");
    XCTAssertEqual(gDHTCtorAfterThrow, 0, @"the body stopped at the exception");
}

- (void)testBundleFilter {
    XCTAssertTrue(DHShouldLoad("dht.tweak", NULL), @"NULL list: all apps");
    const char *empty[] = {NULL};
    XCTAssertTrue(DHShouldLoad("dht.tweak", empty), @"empty list: all apps");
    const char *match[] = {kDHTHostID, NULL};
    XCTAssertTrue(DHShouldLoad("dht.tweak", match));
    const char *several[] = {"com.example.other", kDHTHostID, "com.example.third", NULL};
    XCTAssertTrue(DHShouldLoad("dht.tweak", several));
    const char *noMatch[] = {"com.example.other", "com.example.third", NULL};
    XCTAssertFalse(DHShouldLoad("dht.tweak", noMatch));
    const char *prefix[] = {"com.dynject.tests", NULL};
    XCTAssertFalse(DHShouldLoad("dht.tweak", prefix), @"bundle IDs match exactly, not by prefix");
}

- (void)testBundleIdentifierOverrideCanBeReset {
    DHSetBundleIdentifierForTesting("com.example.overridden");
    const char *overridden[] = {"com.example.overridden", NULL};
    XCTAssertTrue(DHShouldLoad("dht.tweak", overridden));

    DHSetBundleIdentifierForTesting(NULL);
    const char *testHost[] = {kDHTHostID, NULL};
    XCTAssertFalse(DHShouldLoad("dht.tweak", testHost), @"NULL restores the real main bundle identifier");
    NSString *mainID = [NSBundle mainBundle].bundleIdentifier;
    if (mainID.length > 0) {
        const char *real[] = {mainID.UTF8String, NULL};
        XCTAssertTrue(DHShouldLoad("dht.tweak", real));
    }
}

- (void)testSafeModeMatchingBundleSkips {
    [self setSafeMode:@{@"dht.tweak" : @[ @"com.example.other", @(kDHTHostID) ]}];
    XCTAssertFalse(DHShouldLoad("dht.tweak", NULL));
    const char *match[] = {kDHTHostID, NULL};
    XCTAssertFalse(DHShouldLoad("dht.tweak", match), @"Safe Mode wins over a matching bundle filter");
    XCTAssertTrue(DHShouldLoad("dht.other.tweak", NULL), @"other tweak IDs are unaffected");
}

- (void)testSafeModeWildcardSkipsEveryApp {
    [self setSafeMode:@{@"dht.tweak" : @[ @"*" ]}];
    XCTAssertFalse(DHShouldLoad("dht.tweak", NULL));
    DHSetBundleIdentifierForTesting("com.example.anything");
    XCTAssertFalse(DHShouldLoad("dht.tweak", NULL));
    XCTAssertTrue(DHShouldLoad("dht.other.tweak", NULL));
}

- (void)testSafeModeOtherBundlesAndOtherTweaksLoad {
    [self setSafeMode:@{
        @"dht.tweak" : @[ @"com.example.other" ],
        @"dht.other.tweak" : @[ @"*" ],
    }];
    XCTAssertTrue(DHShouldLoad("dht.tweak", NULL));
    XCTAssertFalse(DHShouldLoad("dht.other.tweak", NULL));
}

- (void)testSafeModeIsReadFreshEachTime {
    XCTAssertTrue(DHShouldLoad("dht.tweak", NULL));
    [self setSafeMode:@{@"dht.tweak" : @[ @(kDHTHostID) ]}];
    XCTAssertFalse(DHShouldLoad("dht.tweak", NULL));
    [self setSafeMode:@{}];
    XCTAssertTrue(DHShouldLoad("dht.tweak", NULL));
}

- (void)testSafeModeWrongTypesAreIgnored {
    NSArray *wrongValues = @[
        @"*",                                     // top level: string, not a dictionary
        @[ @"dht.tweak" ],                        // top level: array
        @42,                                      // top level: number
        @{@"dht.tweak" : @"*"},                   // per-tweak value: string, not an array
        @{@"dht.tweak" : @(kDHTHostID)},          // per-tweak value: string
        @{@"dht.tweak" : @{@"*" : @YES}},         // per-tweak value: dictionary
        @{@"dht.tweak" : @[ @1, @2 ]},            // array elements: numbers
        @{@"dht.tweak" : @[ @[ @"*" ], @{@"*" : @"*"} ]}, // array elements: containers
        @{@"dht.tweak" : @[]},                    // empty array
    ];
    for (id value in wrongValues) {
        [self setSafeMode:value];
        XCTAssertTrue(DHShouldLoad("dht.tweak", NULL), @"wrong-typed Safe Mode value %@ must be ignored", value);
    }
}

- (void)testPanicSwitchSkipsEveryTweakEverywhere {
    [self setSafeMode:@{@"*" : @[ @"*" ]}];
    XCTAssertFalse(DHShouldLoad("dht.tweak", NULL));
    XCTAssertFalse(DHShouldLoad("dht.other.tweak", NULL));
    const char *match[] = {kDHTHostID, NULL};
    XCTAssertFalse(DHShouldLoad("dht.tweak", match), @"the panic switch wins over a matching bundle filter");
    DHSetBundleIdentifierForTesting("com.example.anything");
    XCTAssertFalse(DHShouldLoad("dht.tweak", NULL));
    DHSetBundleIdentifierForTesting(NULL);
    XCTAssertFalse(DHShouldLoad("dht.tweak", NULL), @"also applies to the real main bundle identifier");
}

- (void)testPanicSwitchForListedAppsOnly {
    [self setSafeMode:@{@"*" : @[ @"com.example.other", @(kDHTHostID) ]}];
    XCTAssertFalse(DHShouldLoad("dht.tweak", NULL));
    XCTAssertFalse(DHShouldLoad("dht.other.tweak", NULL));
    DHSetBundleIdentifierForTesting("com.example.third");
    XCTAssertTrue(DHShouldLoad("dht.tweak", NULL), @"apps not listed under \"*\" still load every tweak");
    DHSetBundleIdentifierForTesting("com.example.other");
    XCTAssertFalse(DHShouldLoad("dht.other.tweak", NULL));
}

- (void)testPanicSwitchCombinesWithPerTweakEntries {
    [self setSafeMode:@{
        @"*" : @[ @"com.example.other" ],
        @"dht.tweak" : @[ @(kDHTHostID) ],
    }];
    XCTAssertFalse(DHShouldLoad("dht.tweak", NULL), @"the per-tweak entry still applies");
    XCTAssertTrue(DHShouldLoad("dht.other.tweak", NULL), @"\"*\" lists another app only");
    DHSetBundleIdentifierForTesting("com.example.other");
    XCTAssertFalse(DHShouldLoad("dht.tweak", NULL));
    XCTAssertFalse(DHShouldLoad("dht.other.tweak", NULL));
}

- (void)testPanicSwitchWithMalformedPerTweakEntry {
    // A malformed entry for the tweak must not hide a valid "*" entry, and vice versa.
    [self setSafeMode:@{@"*" : @[ @"*" ], @"dht.tweak" : @"not an array"}];
    XCTAssertFalse(DHShouldLoad("dht.tweak", NULL));
    [self setSafeMode:@{@"*" : @"*", @"dht.tweak" : @[ @(kDHTHostID) ]}];
    XCTAssertFalse(DHShouldLoad("dht.tweak", NULL));
    XCTAssertTrue(DHShouldLoad("dht.other.tweak", NULL), @"a malformed \"*\" entry is ignored");
}

- (void)testPanicSwitchWrongTypesAreIgnored {
    NSArray *wrongValues = @[
        @{@"*" : @"*"},
        @{@"*" : @(kDHTHostID)},
        @{@"*" : @{@"*" : @YES}},
        @{@"*" : @[ @1, @[ @"*" ] ]},
        @{@"*" : @[]},
        @{@"*" : @[ @"com.example.other" ]},
        @{@"**" : @[ @"*" ], @" *" : @[ @"*" ]},    // only the exact key "*" is the panic switch
    ];
    for (id value in wrongValues) {
        [self setSafeMode:value];
        XCTAssertTrue(DHShouldLoad("dht.tweak", NULL), @"Safe Mode value %@ must not stop the tweak", value);
    }
}

- (void)testPanicSwitchCanBeTurnedOff {
    [self setSafeMode:@{@"*" : @[ @"*" ], @"dht.other.tweak" : @[ @"*" ]}];
    XCTAssertFalse(DHShouldLoad("dht.tweak", NULL));
    [self setSafeMode:@{@"dht.other.tweak" : @[ @"*" ]}];
    XCTAssertTrue(DHShouldLoad("dht.tweak", NULL), @"read fresh: removing \"*\" re-enables at once");
    XCTAssertFalse(DHShouldLoad("dht.other.tweak", NULL), @"entries other than \"*\" are kept");
}

- (void)testShiftBypassFollowsKeyboardWhenNotDisabled {
    unsetenv("DH_DISABLE_SHIFT_BYPASS");
    // The real keyboard decides here. Sample it on both sides of the call and
    // compare only if it did not change in between.
    BOOL heldBefore = (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & kCGEventFlagMaskShift) != 0;
    BOOL loaded = DHShouldLoad("dht.tweak", NULL);
    BOOL heldAfter = (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & kCGEventFlagMaskShift) != 0;
    if (heldBefore == heldAfter) XCTAssertEqual(loaded, (BOOL)!heldBefore);

    setenv("DH_DISABLE_SHIFT_BYPASS", "", 1); // any value, even empty, disables the bypass
    XCTAssertTrue(DHShouldLoad("dht.tweak", NULL));
}

@end
