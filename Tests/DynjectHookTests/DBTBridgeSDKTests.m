// DynjectBridge SDK (TweakSDK/DynjectBridge.m): requests that are refused before the SDK reads the token or connects,
// so these tests never touch the global preferences or XPC. The real round trip is scripts/bridge-e2e.sh.

#import <XCTest/XCTest.h>
#import "DynjectBridge.h"

@interface DBTBridgeSDKTests : XCTestCase
@end

@implementation DBTBridgeSDKTests

- (NSError *)errorFor:(const char *)tweak action:(const char *)action args:(id)args {
    XCTestExpectation *done = [self expectationWithDescription:@"reply"];
    __block NSError *error = nil;
    __block BOOL onQueue = NO;
    dispatch_queue_t q = dispatch_queue_create("dbt.reply", DISPATCH_QUEUE_SERIAL);
    static char key;
    dispatch_queue_set_specific(q, &key, &key, NULL);
    DBRequest(tweak, action, args, q, ^(NSDictionary *result, NSError *e) {
        XCTAssertNil(result);
        error = e;
        onQueue = dispatch_get_specific(&key) == &key;
        [done fulfill];
    });
    [self waitForExpectations:@[done] timeout:2];
    XCTAssertTrue(onQueue, @"the reply runs on the queue given");
    return error;
}

- (void)testInvalidArgumentsAreRefusedAtOnce {
    XCTAssertEqual([self errorFor:NULL action:"ping" args:nil].code, DBErrorInvalidArgument);
    XCTAssertEqual([self errorFor:"" action:"ping" args:nil].code, DBErrorInvalidArgument);
    XCTAssertEqual([self errorFor:"a.b" action:NULL args:nil].code, DBErrorInvalidArgument);
    XCTAssertEqual([self errorFor:"a.b" action:"ping" args:@[@1]].code, DBErrorInvalidArgument, @"not a dictionary");
    XCTAssertEqual([self errorFor:"a.b" action:"ping" args:@{@"x": [NSObject new]}].code, DBErrorInvalidArgument, @"not a plist");
    NSError *big = [self errorFor:"a.b" action:"ping" args:@{@"x": [NSMutableData dataWithLength:(1 << 20) + 1]}];
    XCTAssertEqual(big.code, DBErrorInvalidArgument, @"over 1 MB");
    XCTAssertEqualObjects(big.domain, DBErrorDomain);
}

- (void)testNilReplyBlockIsFine {
    DBRequest(NULL, "ping", nil, NULL, nil);
    DBRequest("a.b", "ping", @{@"x": [NSObject new]}, NULL, nil);
}

- (void)testSetSettingNeedsKeyAndValue {
    XCTestExpectation *done = [self expectationWithDescription:@"done"];
    DBSetSetting("a.b", nil, @YES, nil, ^(NSError *error) {
        XCTAssertEqual(error.code, DBErrorInvalidArgument);
        XCTAssertTrue(NSThread.isMainThread);
        [done fulfill];
    });
    [self waitForExpectations:@[done] timeout:2];
}

@end
