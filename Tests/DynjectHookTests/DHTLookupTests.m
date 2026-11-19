// Class lookup: DHClass, DHSwiftClass, DHFindClassWithSuffix (on the Swift
// fixtures image), and DHWhenClassLoads / DHCheckPendingClasses.

#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import "DynjectHook.h"

// Methods of DHTSwiftPublic (Tests/DynjectHookSwiftFixtures/Fixtures.swift), reached
// through the runtime only.
@protocol DHTSwiftPublicMethods <NSObject>
- (NSInteger)swiftValue;
- (NSString *)swiftGreeting:(NSString *)name;
- (NSInteger)swiftValueCalledFromSwift;
@end
@protocol DHTSwiftPublicClassMethods <NSObject>
- (Class)privateCellClass; // sent to the class object
@end

static const char *const kDHTSwiftModule = "DynjectHookSwiftFixtures";
static const char *const kDHTSwiftPublicName = "DHTSwiftPublic";

static DHHook *gSwiftValueHook;
static NSInteger DHTSwift_swiftValue(id self, SEL _cmd) {
    return DH_CALL_ORIG(gSwiftValueHook, NSInteger (*)(id, SEL), self, _cmd) + 1000;
}

static Class DHTRegisterClassNamed(const char *name) {
    Class cls = objc_allocateClassPair([NSObject class], name, 0);
    if (cls) objc_registerClassPair(cls);
    return cls ?: objc_getClass(name);
}

@interface DynjectHookTestsLookup : XCTestCase
@end

@implementation DynjectHookTestsLookup

- (void)testDHClass {
    XCTAssertEqual(DHClass("NSObject"), [NSObject class]);
    XCTAssertEqual(DHClass("DynjectHookTestsLookup"), [DynjectHookTestsLookup class]);
    XCTAssertTrue(DHClass("DHTNoSuchClass_8D1F") == Nil);
    XCTAssertTrue(DHClass("") == Nil);
    XCTAssertTrue(DHClass(NULL) == Nil);
}

- (void)testDHSwiftClassBothLookupForms {
    Class byDottedName = objc_getClass("DynjectHookSwiftFixtures.DHTSwiftPublic");
    Class byMangledName = objc_getClass("_TtC24DynjectHookSwiftFixtures14DHTSwiftPublic");
    XCTAssertTrue(byDottedName != Nil, @"fixture precondition: Swift fixtures are linked");
    XCTAssertEqual(byDottedName, byMangledName);

    Class cls = DHSwiftClass(kDHTSwiftModule, kDHTSwiftPublicName);
    XCTAssertEqual(cls, byDottedName);
    XCTAssertEqual(cls, NSClassFromString(@"DynjectHookSwiftFixtures.DHTSwiftPublic"));

    // Mangled-name fallback: a class registered under the "_TtC<len><module><len><name>"
    // spelling only (module and name lengths of more than one digit).
    Class mangledOnly = DHTRegisterClassNamed("_TtC12DHTMangledMd17DHTMangledOnlyCls");
    XCTAssertTrue(mangledOnly != Nil);
    XCTAssertEqual(DHSwiftClass("DHTMangledMd", "DHTMangledOnlyCls"), mangledOnly);

    // Dotted-name form: a class registered literally as "Module.Name".
    Class dottedOnly = DHTRegisterClassNamed("DHTDottedMd.DHTDottedOnlyCls");
    XCTAssertTrue(dottedOnly != Nil);
    XCTAssertEqual(DHSwiftClass("DHTDottedMd", "DHTDottedOnlyCls"), dottedOnly);

    // Absent and bad inputs.
    XCTAssertTrue(DHSwiftClass(kDHTSwiftModule, "DHTSwiftNoSuchClass") == Nil);
    XCTAssertTrue(DHSwiftClass("DHTNoSuchModule", kDHTSwiftPublicName) == Nil);
    XCTAssertTrue(DHSwiftClass(NULL, kDHTSwiftPublicName) == Nil);
    XCTAssertTrue(DHSwiftClass(kDHTSwiftModule, NULL) == Nil);
}

- (void)testHookSwiftDynamicMethod {
    Class cls = DHSwiftClass(kDHTSwiftModule, kDHTSwiftPublicName);
    XCTAssertTrue(cls != Nil);
    id<DHTSwiftPublicMethods> obj = [[cls alloc] init];
    XCTAssertEqual([obj swiftValue], 42);
    XCTAssertEqualObjects([obj swiftGreeting:@"swift"], @"hello swift");

    gSwiftValueHook = DHHookMessage(cls, @selector(swiftValue), (IMP)DHTSwift_swiftValue, NULL);
    XCTAssertTrue(gSwiftValueHook != NULL);
    XCTAssertEqual([obj swiftValue], 1042);
    XCTAssertEqual([obj swiftValueCalledFromSwift], 1042, @"Swift callers of a dynamic method see the hook");
}

- (void)testFindClassWithSuffixOnSwiftFixturesImage {
    Class publicCls = DHSwiftClass(kDHTSwiftModule, kDHTSwiftPublicName);
    XCTAssertTrue(publicCls != Nil);
    Class privateCls = [(id<DHTSwiftPublicClassMethods>)publicCls privateCellClass];
    XCTAssertTrue(privateCls != Nil);
    // Private Swift classes carry a discriminator: "_TtC24DynjectHookSwiftFixturesP33_<hash>19DHTSwiftPrivateCell".
    const char *privateName = class_getName(privateCls);
    XCTAssertTrue(strstr(privateName, "P33_") != NULL, @"unexpected private class name %s", privateName);

    // The image that holds the fixtures (the .xctest bundle under `swift test`).
    Dl_info info = {0};
    XCTAssertNotEqual(dladdr((__bridge const void *)publicCls, &info), 0);
    const char *imagePath = info.dli_fname;
    XCTAssertTrue(imagePath != NULL);

    XCTAssertEqual(DHFindClassWithSuffix(imagePath, "19DHTSwiftPrivateCell"), privateCls);
    XCTAssertEqual(DHFindClassWithSuffix(imagePath, "DHTSwiftPrivateCell"), privateCls);
    XCTAssertEqual(DHFindClassWithSuffix(imagePath, ".DHTSwiftPublic"), publicCls);
    XCTAssertEqual(DHFindClassWithSuffix(imagePath, "DynjectHookTestsLookup"), [DynjectHookTestsLookup class]);

    XCTAssertTrue(DHFindClassWithSuffix(imagePath, "DHTNoClassEndsWithThis_5C2A") == Nil);
    XCTAssertTrue(DHFindClassWithSuffix("/nonexistent/dht/image.dylib", "DHTSwiftPrivateCell") == Nil);
    XCTAssertTrue(DHFindClassWithSuffix(imagePath, NULL) == Nil);
    // NULL image means the main executable; it must not crash, and nothing there ends with this.
    XCTAssertTrue(DHFindClassWithSuffix(NULL, "DHTNoClassEndsWithThis_5C2A") == Nil);
}

- (void)testWhenClassLoadsRunsImmediatelyForExistingClass {
    __block int runs = 0;
    __block Class seen = Nil;
    DHWhenClassLoads("NSObject", ^(Class cls) {
        runs++;
        seen = cls;
    });
    XCTAssertEqual(runs, 1, @"runs synchronously for an existing class");
    XCTAssertEqual(seen, [NSObject class]);
    DHCheckPendingClasses();
    DHCheckPendingClasses();
    XCTAssertEqual(runs, 1, @"runs exactly once");
}

- (void)testWhenClassLoadsDeferredUntilClassIsRegistered {
    const char *name = "DHTLateClass_A7C1";
    XCTAssertTrue(objc_getClass(name) == Nil, @"fixture precondition");
    __block int runs = 0;
    __block int secondRuns = 0;
    __block Class seen = Nil;
    __block int nestedRuns = 0;
    DHWhenClassLoads(name, ^(Class cls) {
        runs++;
        seen = cls;
        // Blocks run outside the lock: re-entering the API must not deadlock,
        // and the pending entry is already gone, so this does not re-run us.
        DHCheckPendingClasses();
        DHWhenClassLoads("NSObject", ^(__unused Class inner) { nestedRuns++; });
    });
    // A second registration for the same name gets its own single run.
    DHWhenClassLoads(name, ^(__unused Class cls) { secondRuns++; });
    XCTAssertEqual(runs, 0);
    DHCheckPendingClasses();
    XCTAssertEqual(runs, 0, @"class does not exist yet");

    Class created = DHTRegisterClassNamed(name);
    XCTAssertTrue(created != Nil);
    DHCheckPendingClasses();
    XCTAssertEqual(runs, 1);
    XCTAssertEqual(secondRuns, 1);
    XCTAssertEqual(nestedRuns, 1);
    XCTAssertEqual(seen, created);

    DHCheckPendingClasses();
    DHCheckPendingClasses();
    XCTAssertEqual(runs, 1, @"block runs exactly once even if checked repeatedly");
    XCTAssertEqual(secondRuns, 1);

    // Any main-queue re-check scheduled by the image callback must not re-run it either.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    XCTAssertEqual(runs, 1);
}

// The path a tweak relies on for classes in bundles and plug-ins the app loads
// later: nobody calls DHCheckPendingClasses(); the dyld add-image callback has
// to notice the class, directly or through its follow-up check on the main
// queue. The image is a small dylib compiled here, so that its class certainly
// is not loaded yet.
- (void)testWhenClassLoadsFiresWhenAnImageBringsTheClass {
    const char *name = "DHTLateImageClass_C41D";
    XCTAssertTrue(objc_getClass(name) == Nil, @"fixture precondition");
    NSString *library = [self buildLibraryDefiningClassNamed:@(name)];
    if (!library) {
        XCTSkip(@"could not compile the fixture dylib (no usable clang); see the test log");
    }

    __block int runs = 0;
    __block Class seen = Nil;
    XCTestExpectation *ran = [self expectationWithDescription:@"the block ran after dlopen"];
    DHWhenClassLoads(name, ^(Class cls) {
        runs++;
        seen = cls;
        [ran fulfill];
    });
    // Let any check scheduled while registering (dyld replays the loaded images
    // to a new callback) run now: nothing may be left to deliver the block
    // later except the callback for the image loaded below.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    XCTAssertEqual(runs, 0, @"the class does not exist yet");

    void *handle = dlopen(library.fileSystemRepresentation, RTLD_NOW);
    XCTAssertTrue(handle != NULL, @"dlopen: %s", dlerror());
    [self waitForExpectations:@[ ran ] timeout:10];
    XCTAssertEqual(runs, 1);
    Class loaded = objc_getClass(name);
    XCTAssertTrue(loaded != Nil);
    XCTAssertEqual(seen, loaded);

    // Exactly once: neither an explicit check nor a late main-queue check runs it again.
    DHCheckPendingClasses();
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    XCTAssertEqual(runs, 1);
    [[NSFileManager defaultManager] removeItemAtPath:library.stringByDeletingLastPathComponent error:NULL];
}

// Compiles a dylib that defines one NSObject subclass; nil if that fails.
- (NSString *)buildLibraryDefiningClassNamed:(NSString *)className {
    NSString *directory = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"dht-late-image-%@", [NSUUID UUID].UUIDString]];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                    attributes:nil error:NULL]) return nil;
    NSString *source = [directory stringByAppendingPathComponent:@"late.m"];
    NSString *library = [directory stringByAppendingPathComponent:@"libdhtlate.dylib"];
    NSString *code = [NSString stringWithFormat:
        @"#import <Foundation/Foundation.h>\n@interface %@ : NSObject\n@end\n@implementation %@\n@end\n",
        className, className];
    if (![code writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:NULL]) return nil;
#if defined(__arm64__)
    NSString *architecture = @"arm64";
#else
    NSString *architecture = @"x86_64";
#endif
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[ @"clang", @"-arch", architecture, @"-dynamiclib", @"-fobjc-arc", source,
                        @"-framework", @"Foundation", @"-o", library ];
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = output;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"DHTLookupTests: could not run xcrun clang: %@", error);
        return nil;
    }
    NSData *log = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0 || ![[NSFileManager defaultManager] fileExistsAtPath:library]) {
        NSLog(@"DHTLookupTests: xcrun clang failed (%d): %@", task.terminationStatus,
              [[NSString alloc] initWithData:log encoding:NSUTF8StringEncoding]);
        return nil;
    }
    return library;
}

- (void)testWhenClassLoadsConcurrentChecksRunOnce {
    const char *name = "DHTLateClass_B93E";
    static _Atomic int runs;
    atomic_store(&runs, 0);
    DHWhenClassLoads(name, ^(__unused Class cls) { atomic_fetch_add(&runs, 1); });
    XCTAssertEqual(atomic_load(&runs), 0);
    XCTAssertTrue(DHTRegisterClassNamed(name) != Nil);
    dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(__unused size_t i) {
        DHCheckPendingClasses();
    });
    DHCheckPendingClasses();
    XCTAssertEqual(atomic_load(&runs), 1);
}

- (void)testWhenClassLoadsBadInputs {
    __block int runs = 0;
    DHWhenClassLoads(NULL, ^(__unused Class cls) { runs++; });
    DHWhenClassLoads("NSObject", nil);
    DHWhenClassLoads("DHTLateClass_NeverCreated", nil);
    DHCheckPendingClasses();
    XCTAssertEqual(runs, 0);
}

@end
