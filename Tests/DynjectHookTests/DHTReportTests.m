// Hook reports (`dw hooks`): the lines a copy writes for a request, captured through DHSetReportSinkForTesting.
// The registry is shared with the other tests, so the checks look for this file's own classes and symbol.

#import <XCTest/XCTest.h>
#import "DynjectHook.h"

static NSMutableArray<NSString *> *sLines;
static void DHTReportSink(const char *line) { [sLines addObject:@(line)]; }

@interface DHTReportTarget : NSObject
- (int)value;
- (int)other;
+ (int)classValue;
@end
@implementation DHTReportTarget
- (int)value { return 1; }
- (int)other { return 2; }
+ (int)classValue { return 3; }
@end

static DHHook *sValue, *sValueTop, *sOther, *sClassValue;
static int DHTValue(id self, SEL _cmd) { return ((int (*)(id, SEL))DHOriginal(sValue))(self, _cmd) + 10; }
static int DHTValueTop(id self, SEL _cmd) { return ((int (*)(id, SEL))DHOriginal(sValueTop))(self, _cmd) + 100; }
static int DHTOther(id self, SEL _cmd) { return ((int (*)(id, SEL))DHOriginal(sOther))(self, _cmd) + 10; }
static int DHTClassValue(id self, SEL _cmd) { return ((int (*)(id, SEL))DHOriginal(sClassValue))(self, _cmd) + 10; }
static DHImportHook *sImport;
static int DHTImportReplacement(void) { return 0; }

@interface DynjectHookTestsReport : XCTestCase
@end

@implementation DynjectHookTestsReport

- (NSArray<NSString *> *)report:(uint64_t)request {
    sLines = [NSMutableArray array];
    DHSetReportSinkForTesting(DHTReportSink);
    DHReportForTesting(request);
    DHSetReportSinkForTesting(NULL);
    return sLines;
}

static NSString *DHTLine(NSArray<NSString *> *lines, NSString *needle) {
    for (NSString *l in lines) if ([l containsString:needle]) return l;
    return nil;
}

- (void)testReportLines {
    DHGroup *group = DHGroupCreate("report-group");
    Class cls = [DHTReportTarget class];
    sValue = DHHookMessage(cls, @selector(value), (IMP)DHTValue, group);
    sValueTop = DHHookMessage(cls, @selector(value), (IMP)DHTValueTop, NULL);
    DHGroup *off = DHGroupCreate("report-off");
    sOther = DHHookMessage(cls, @selector(other), (IMP)DHTOther, off);
    sClassValue = DHHookMessage(object_getClass(cls), @selector(classValue), (IMP)DHTClassValue, NULL);
    sImport = DHHookImport("dhti_report_symbol_nobody_imports", "libNope.dylib", (void *)DHTImportReplacement, NULL);
    DHGroupSetEnabled(off, NO);
    DHGroupSetEnabled(group, NO);   // the inner hook stays beneath sValueTop: buried

    NSArray<NSString *> *lines = [self report:4242];
    XCTAssertTrue([lines.firstObject hasPrefix:@"R 4242 begin "], @"%@", lines.firstObject);
    XCTAssertTrue([lines.firstObject containsString:@" sdk=" DH_SDK_VERSION " image="], @"%@", lines.firstObject);
    XCTAssertTrue([DHTLine(lines, @"- DHTReportTarget value buried beneath group=report-group") length] > 0, @"%@", lines);
    XCTAssertTrue([DHTLine(lines, @"- DHTReportTarget value installed top group=-") length] > 0, @"%@", lines);
    XCTAssertTrue([DHTLine(lines, @"- DHTReportTarget other restored beneath group=report-off") length] > 0, @"%@", lines);
    XCTAssertTrue([DHTLine(lines, @"+ DHTReportTarget classValue installed top group=-") length] > 0, @"%@", lines);
    XCTAssertTrue([DHTLine(lines, @"dhti_report_symbol_nobody_imports lib=libNope.dylib sites=0 active") length] > 0, @"%@", lines);
    NSString *end = lines.lastObject;
    XCTAssertTrue([end hasPrefix:@"R 4242 end "] && [end containsString:@" hooks="] && [end containsString:@" imports="], @"%@", end);
    for (NSString *l in lines) XCTAssertTrue([l hasPrefix:@"R 4242 "], @"%@", l);
    XCTAssertEqual([DHTReportTarget new].value, 111, @"buried: still called (it doesn't check DHHookIsActive), beneath the top one");

    lines = [self report:0];
    XCTAssertEqual(lines.count, 0u, @"request 0 is no request");
}

- (void)testScanIsRunOncePerRequest {
    NSArray<NSString *> *lines = [self report:(1ull << 32) | 777];
    XCTAssertTrue([DHTLine(lines, @"R 777 scan-begin tweak-images=0") length] > 0, @"no image here is in a lib/tweaks folder: %@", lines);
    XCTAssertTrue([lines.lastObject hasPrefix:@"R 777 scan-end found=0 "], @"%@", lines.lastObject);
    lines = [self report:(1ull << 32) | 777];
    XCTAssertNil(DHTLine(lines, @"scan-begin"), @"the same request again: another copy already scanned");
    XCTAssertTrue([lines.lastObject hasPrefix:@"R 777 end "], @"%@", lines.lastObject);
}

@end
