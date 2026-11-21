// Import hooks (DHHookImport). The hooks live in this test bundle, which DHHookImport skips (a tweak's own calls
// are not redirected), so the calls under test are made by dylibs compiled into a temporary folder at the start:
// a provider exporting dhti_valueN() (returns N) and callers whose dhti_callN() calls it through their imports.
// libDHTImpLate is loaded only after its hook exists; libDHTImpUnload is unloaded again.

#import <XCTest/XCTest.h>
#import <dlfcn.h>
#import "DynjectHook.h"

// The second copy's functions (see DHTSecondCopy.m).
DH_HIDDEN DHImportHook *DHT2_DHHookImport(const char *symbol, const char *library, void *replacement, DHGroup *group);
DH_HIDDEN void *DHT2_DHImportOriginal(DHImportHook *hook);
DH_HIDDEN NSUInteger DHT2_DHImportHookSiteCount(DHImportHook *hook);

typedef int (*DHTIntFn)(void);

static NSString *sDir;
static NSString *sFailure;
static void *sCaller;

static NSString *DHTRun(NSArray<NSString *> *args) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = args;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return error.localizedDescription;
    NSData *output = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    return task.terminationStatus == 0 ? nil : [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
}

static NSString *DHTPath(NSString *name) { return [sDir stringByAppendingPathComponent:name]; }

// Builds lib<name>.dylib from `source`, linked against the provider unless it is the provider.
static NSString *DHTBuild(NSString *name, NSString *source) {
    NSString *c = DHTPath([name stringByAppendingString:@".c"]);
    NSString *out = DHTPath([NSString stringWithFormat:@"lib%@.dylib", name]);
    if (![source writeToFile:c atomically:YES encoding:NSUTF8StringEncoding error:NULL]) return @"can't write the source";
#if defined(__arm64__)
    NSString *arch = @"arm64";
#else
    NSString *arch = @"x86_64";
#endif
    NSMutableArray *args = [@[@"clang", @"-arch", arch, @"-O0", @"-dynamiclib", @"-install_name", out, @"-o", out, c] mutableCopy];
    if (![name isEqualToString:@"DHTImpProvider"]) [args addObjectsFromArray:@[DHTPath(@"libDHTImpProvider.dylib")]];
    return DHTRun(args);
}

static int DHTCall(void *image, const char *name) {
    DHTIntFn f = (DHTIntFn)dlsym(image, name);
    return f ? f() : -1;
}

static void *DHTOpen(NSString *name) {
    return dlopen(DHTPath([NSString stringWithFormat:@"lib%@.dylib", name]).fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
}

// Replacements: each adds its own amount to what the original returns.
#define DHT_ADDER(NAME, HOOK, ORIGINAL, AMOUNT)                                                 \
    static DHImportHook *HOOK;                                                                  \
    static int NAME(void) { return ((DHTIntFn)ORIGINAL(HOOK))() + (AMOUNT); }

DHT_ADDER(DHTPlus100One, sHookOne, DHImportOriginal, 100)
DHT_ADDER(DHTPlus100Two, sHookTwo, DHImportOriginal, 100)
DHT_ADDER(DHTPlus100Three, sHookThree, DHImportOriginal, 100)
DHT_ADDER(DHTPlus100Eight, sHookEight, DHImportOriginal, 100)
DHT_ADDER(DHTPlus100Four, sHookFour, DHImportOriginal, 100)
DHT_ADDER(DHTPlus100Five, sHookFive, DHImportOriginal, 100)
DHT_ADDER(DHTPlus1000Six, sHookSixOuter, DHImportOriginal, 1000)
DHT_ADDER(DHTPlus100Seven, sHookSeven, DHImportOriginal, 100)
DHT_ADDER(DHTPlus100NineSecond, sHookNineSecond, DHT2_DHImportOriginal, 100)
DHT_ADDER(DHTPlus1000Nine, sHookNine, DHImportOriginal, 1000)

// Passes straight through while its group is disabled (it may stay installed beneath another hook).
static DHImportHook *sHookSixInner;
static int DHTPlus100SixInner(void) {
    int value = ((DHTIntFn)DHImportOriginal(sHookSixInner))();
    return DHImportHookIsActive(sHookSixInner) ? value + 100 : value;
}

@interface DynjectHookTestsImports : XCTestCase
@end

@implementation DynjectHookTestsImports

+ (void)setUp {
    sDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"dht-imports-%d", getpid()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:sDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSMutableString *provider = [NSMutableString string];
    NSMutableString *caller = [NSMutableString string];
    for (int n = 1; n <= 9; n++) {
        [provider appendFormat:@"int dhti_value%d(void) { return %d; }\n", n, n];
        [caller appendFormat:@"int dhti_value%d(void);\nint dhti_call%d(void) { return dhti_value%d(); }\n", n, n, n];
    }
    sFailure = DHTBuild(@"DHTImpProvider", provider)
        ?: DHTBuild(@"DHTImpCaller", caller)
        ?: DHTBuild(@"DHTImpLate", @"int dhti_value4(void);\nint dhti_late4(void) { return dhti_value4(); }\n")
        ?: DHTBuild(@"DHTImpUnload", @"int dhti_value7(void);\nint dhti_unload7(void) { return dhti_value7(); }\n");
    if (!sFailure) {
        sCaller = DHTOpen(@"DHTImpCaller");
        if (!sCaller) sFailure = @(dlerror() ?: "dlopen failed");
    }
}

+ (void)tearDown {
    [[NSFileManager defaultManager] removeItemAtPath:sDir error:NULL];
}

- (void)setUp {
    if (sFailure) XCTFail(@"couldn't build the fixture dylibs: %@", sFailure);
}

- (void)testRedirectsAnotherImagesImport {
    XCTAssertEqual(DHTCall(sCaller, "dhti_call1"), 1);
    sHookOne = DHHookImport("dhti_value1", NULL, (void *)DHTPlus100One, NULL);
    XCTAssertNotEqual(sHookOne, NULL);
    XCTAssertEqual(DHImportHookSiteCount(sHookOne), 1u, @"the caller's import; this bundle (the hook's own image) is skipped");
    XCTAssertEqual(DHTCall(sCaller, "dhti_call1"), 101);
    XCTAssertEqual(DH_CALL_IMPORT_ORIG(sHookOne, int (*)(void)), 1);
    XCTAssertTrue(DHImportHookIsActive(sHookOne));
    void *provider = DHTOpen(@"DHTImpProvider");
    XCTAssertEqual(DHTCall(provider, "dhti_value1"), 1, @"a pointer from dlsym is not redirected");
}

- (void)testLibraryFilter {
    sHookTwo = DHHookImport("dhti_value2", "libDHTImpProvider.dylib", (void *)DHTPlus100Two, NULL);
    XCTAssertEqual(DHImportHookSiteCount(sHookTwo), 1u, @"by file name");
    XCTAssertEqual(DHTCall(sCaller, "dhti_call2"), 102);

    sHookThree = DHHookImport("dhti_value3", DHTPath(@"libDHTImpProvider.dylib").fileSystemRepresentation,
                              (void *)DHTPlus100Three, NULL);
    XCTAssertEqual(DHImportHookSiteCount(sHookThree), 1u, @"by full path");
    XCTAssertEqual(DHTCall(sCaller, "dhti_call3"), 103);

    sHookEight = DHHookImport("dhti_value8", "libNope.dylib", (void *)DHTPlus100Eight, NULL);
    XCTAssertNotEqual(sHookEight, NULL, @"a hook is returned even when nothing matches");
    XCTAssertEqual(DHImportHookSiteCount(sHookEight), 0u);
    XCTAssertEqual(DHTCall(sCaller, "dhti_call8"), 8);
    XCTAssertEqual(DH_CALL_IMPORT_ORIG(sHookEight, int (*)(void)), 8, @"nothing patched: dlsym's answer");
}

- (void)testImageLoadedLater {
    sHookFour = DHHookImport("dhti_value4", NULL, (void *)DHTPlus100Four, NULL);
    NSUInteger before = DHImportHookSiteCount(sHookFour);
    void *late = DHTOpen(@"DHTImpLate");
    XCTAssertNotEqual(late, NULL);
    XCTAssertEqual(DHImportHookSiteCount(sHookFour), before + 1, @"patched as it loads");
    XCTAssertEqual(DHTCall(late, "dhti_late4"), 104);
    XCTAssertEqual(DHTCall(sCaller, "dhti_call4"), 104);
}

- (void)testGroupDisableAndEnable {
    DHGroup *group = DHGroupCreate("imports");
    sHookFive = DHHookImport("dhti_value5", NULL, (void *)DHTPlus100Five, group);
    XCTAssertEqual(DHTCall(sCaller, "dhti_call5"), 105);
    DHGroupSetEnabled(group, NO);
    XCTAssertEqual(DHTCall(sCaller, "dhti_call5"), 5, @"the import is put back");
    XCTAssertFalse(DHImportHookIsActive(sHookFive));
    XCTAssertEqual(DHImportHookSiteCount(sHookFive), 0u);
    DHGroupSetEnabled(group, YES);
    XCTAssertEqual(DHTCall(sCaller, "dhti_call5"), 105);
    XCTAssertTrue(DHImportHookIsActive(sHookFive));
    XCTAssertEqual(DHImportHookSiteCount(sHookFive), 1u);
}

- (void)testDisabledHookBeneathAnotherStaysAndPassesThrough {
    DHGroup *group = DHGroupCreate("inner");
    sHookSixInner = DHHookImport("dhti_value6", NULL, (void *)DHTPlus100SixInner, group);
    sHookSixOuter = DHHookImport("dhti_value6", NULL, (void *)DHTPlus1000Six, NULL);
    XCTAssertEqual(DHTCall(sCaller, "dhti_call6"), 1106, @"the latest hook outermost");
    DHGroupSetEnabled(group, NO);
    XCTAssertEqual(DHTCall(sCaller, "dhti_call6"), 1006, @"the inner hook stays beneath the outer one, inactive");
    XCTAssertEqual(DHImportHookSiteCount(sHookSixInner), 1u);
    DHGroupSetEnabled(group, YES);
    XCTAssertEqual(DHTCall(sCaller, "dhti_call6"), 1106);
}

- (void)testTwoCopiesChain {
    sHookNineSecond = DHT2_DHHookImport("dhti_value9", NULL, (void *)DHTPlus100NineSecond, NULL);
    sHookNine = DHHookImport("dhti_value9", NULL, (void *)DHTPlus1000Nine, NULL);
    XCTAssertEqual(DHT2_DHImportHookSiteCount(sHookNineSecond), 1u);
    XCTAssertEqual(DHTCall(sCaller, "dhti_call9"), 1109);
}

- (void)testUnloadedImageIsForgotten {
    void *image = DHTOpen(@"DHTImpUnload");
    XCTAssertNotEqual(image, NULL);
    DHGroup *group = DHGroupCreate("unload");
    sHookSeven = DHHookImport("dhti_value7", NULL, (void *)DHTPlus100Seven, group);
    NSUInteger loaded = DHImportHookSiteCount(sHookSeven);
    XCTAssertEqual(DHTCall(image, "dhti_unload7"), 107);
    dlclose(image);
    void *still = dlopen(DHTPath(@"libDHTImpUnload.dylib").fileSystemRepresentation, RTLD_NOLOAD);
    if (still) {   // dyld kept it loaded; nothing to forget
        dlclose(still);
        return;
    }
    XCTAssertEqual(DHImportHookSiteCount(sHookSeven), loaded - 1);
    DHGroupSetEnabled(group, NO);   // must not touch the unmapped image
    DHGroupSetEnabled(group, YES);
    XCTAssertEqual(DHTCall(sCaller, "dhti_call7"), 107);
}

- (void)testBadInputAndEx {
    XCTAssertEqual(DHHookImport(NULL, NULL, (void *)DHTPlus100One, NULL), NULL);
    XCTAssertEqual(DHHookImport("", NULL, (void *)DHTPlus100One, NULL), NULL);
    XCTAssertEqual(DHHookImport("dhti_value1", NULL, NULL, NULL), NULL);
    DHImportHook *kept = (DHImportHook *)0x1;
    XCTAssertEqual(DHHookImportEx(NULL, NULL, (void *)DHTPlus100One, NULL, &kept), NULL);
    XCTAssertEqual(kept, (DHImportHook *)0x1, @"untouched on failure");
    DHImportHook *written = NULL;
    DHImportHook *h = DHHookImportEx("dhti_no_such_function", NULL, (void *)DHTPlus100One, NULL, &written);
    XCTAssertEqual(h, written);
    XCTAssertEqual(DHImportOriginal(h), NULL, @"nothing imports it and dlsym finds nothing");
    XCTAssertEqual(DHImportOriginal(NULL), NULL);
    XCTAssertFalse(DHImportHookIsActive(NULL));
    XCTAssertEqual(DHImportHookSiteCount(NULL), 0u);
}

@end
