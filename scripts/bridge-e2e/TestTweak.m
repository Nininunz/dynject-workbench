// The bridge end-to-end test's tweak (scripts/bridge-e2e.sh). Injected with DYLD_INSERT_LIBRARIES into the sandboxed
// test host, it talks to the broker through DynjectBridge.h exactly as a real tweak would and prints one line per
// check: "CHECK PASS|FAIL <name> — <evidence>". BRIDGE_E2E_MODE=probe only pings and prints "PROBE <reason>" (the
// stranger app and the unsandboxed probe tool). Built with the test names (-DDB_SERVICE_NAME etc.).
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <notify.h>
#import "DynjectBridge.h"

#define TWEAK "local.bridge-e2e.tweak"
#define SETTINGS_CHANGED "dynject.tweak.local.bridge-e2e.tweak.changed"
#define HELLO "local.bridge-e2e.tweak.hello"

static int sFailures;

static void Check(BOOL ok, NSString *name, NSString *evidence) {
    printf("CHECK %s %s — %s\n", ok ? "PASS" : "FAIL", name.UTF8String, evidence.UTF8String);
    fflush(stdout);
    if (!ok) sFailures++;
}

static NSDictionary *Call(const char *tweak, const char *action, NSDictionary *args, NSError **error) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *result = nil;
    __block NSError *err = nil;
    DBRequest(tweak, action, args, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(NSDictionary *r, NSError *e) {
        result = r;
        err = e;
        dispatch_semaphore_signal(sem);
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC)) != 0) {
        *error = [NSError errorWithDomain:@"e2e" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"the reply block never ran"}];
        return nil;
    }
    *error = err;
    return result;
}

static NSString *Reason(NSError *e) {
    if (!e) return @"ok";
    return e.userInfo[DBErrorReasonKey] ?: [NSString stringWithFormat:@"%@#%ld", e.domain, (long)e.code];
}

static void Expect(NSString *name, const char *tweak, const char *action, NSDictionary *args, NSString *expected) {
    NSError *e = nil;
    Call(tweak, action, args, &e);
    NSString *got = Reason(e);
    Check([got isEqualToString:expected], name,
          [NSString stringWithFormat:@"expected %@, got %@%@", expected, got, e ? [@": " stringByAppendingString:e.localizedDescription] : @""]);
}

/// Waits up to 2 s for the Darwin notification `name` after `body` runs.
static BOOL Observe(const char *name, void (^body)(void)) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    int token = 0;
    notify_register_dispatch(name, &token, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(int t) {
        (void)t;
        dispatch_semaphore_signal(sem);
    });
    body();
    BOOL seen = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
    notify_cancel(token);
    return seen;
}

static int SandboxCheck(const char *operation, const char *name) {
    typedef int (*CheckFn)(pid_t, const char *, int, ...);
    CheckFn check = (CheckFn)dlsym(RTLD_DEFAULT, "sandbox_check");
    if (!check) return -1;
    return operation ? check(getpid(), operation, 2 /* SANDBOX_FILTER_GLOBAL_NAME */, name) : check(getpid(), NULL, 0);
}

static void Scenario(void) {
    printf("scenario in %s (pid %d)\n", NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "?", getpid());
    Check(SandboxCheck(NULL, NULL) == 1, @"host is sandboxed", [NSString stringWithFormat:@"sandbox_check(self) = %d", SandboxCheck(NULL, NULL)]);
    int before = SandboxCheck("mach-lookup", DB_SERVICE_NAME);
    Check(before == 1, @"lookup denied before the token", [NSString stringWithFormat:@"sandbox_check(mach-lookup %s) = %d", DB_SERVICE_NAME, before]);
    Check(DBIsAvailable(), @"DBIsAvailable", @"token key present");

    // The main thread is never blocked: the call returns before any reply.
    __block double callMs = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        DBRequest(TWEAK, "ping", nil, NULL, ^(NSDictionary *r, NSError *e) { (void)r; (void)e; });
        callMs = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
    });
    Check(callMs < 50, @"DBRequest returns at once on the main thread", [NSString stringWithFormat:@"%.2f ms", callMs]);

    NSError *e = nil;
    NSDictionary *r = Call(TWEAK, "ping", nil, &e);
    long brokerPID = [r[@"brokerPID"] longValue];
    Check(r && !e && [r[@"app"] isEqual:NSBundle.mainBundle.bundleIdentifier], @"ping ok",
          [NSString stringWithFormat:@"%@: app %@, broker pid %ld, capabilities %@", Reason(e), r[@"app"], brokerPID,
           [r[@"capabilities"] componentsJoinedByString:@" "]]);
    int after = SandboxCheck("mach-lookup", DB_SERVICE_NAME);
    Check(after == 0, @"lookup allowed after the token", [NSString stringWithFormat:@"sandbox_check(mach-lookup) = %d", after]);

    __block NSError *setError = nil;
    BOOL changed = Observe(SETTINGS_CHANGED, ^{
        NSError *x = nil;
        Call(TWEAK, "settings.set", @{@"key": @"enabled", @"value": @NO}, &x);
        setError = x;
    });
    Check(!setError, @"settings.set declared key", Reason(setError));
    Check(changed, @"settings.set posts .changed", @SETTINGS_CHANGED);
    Expect(@"settings.set per-app override for itself", TWEAK, "settings.set",
           @{@"key": @"enabled", @"value": @YES, @"app": NSBundle.mainBundle.bundleIdentifier}, @"ok");
    Expect(@"settings.set undeclared key", TWEAK, "settings.set", @{@"key": @"bogus", @"value": @YES}, @"bad-arguments");
    Expect(@"settings.set out of range", TWEAK, "settings.set", @{@"key": @"size", @"value": @99}, @"bad-arguments");
    Expect(@"settings.set another app's override", TWEAK, "settings.set",
           @{@"key": @"enabled", @"value": @YES, @"app": @"com.apple.Notes"}, @"bad-arguments");

    __block NSError *notifyError = nil;
    BOOL hello = Observe(HELLO, ^{
        NSError *x = nil;
        Call(TWEAK, "notify", @{@"name": @HELLO}, &x);
        notifyError = x;
    });
    Check(!notifyError && hello, @"notify own prefix delivered", [NSString stringWithFormat:@"%@, delivered %d", Reason(notifyError), hello]);
    Expect(@"notify other prefix", TWEAK, "notify", @{@"name": @"local.bridge-e2e.elsewhere.hello"}, @"bad-arguments");
    Expect(@"notify look-alike prefix", TWEAK, "notify", @{@"name": @"local.bridge-e2e.tweaky"}, @"bad-arguments");

    Expect(@"open file:", TWEAK, "open", @{@"url": @"file:///etc/passwd"}, @"bad-arguments");
    Expect(@"open javascript:", TWEAK, "open", @{@"url": @"javascript:alert(1)"}, @"bad-arguments");
    Expect(@"open undeclared scheme", TWEAK, "open", @{@"url": @"mailto:someone@example.com"}, @"capability-missing");
    Expect(@"pasteboard.write undeclared", TWEAK, "pasteboard.write", @{@"string": @"x"}, @"capability-missing");
    // The reply doesn't tell an unknown tweak from one that isn't injected here (the log does).
    Expect(@"tweak without a manifest", "local.bridge-e2e.undeclared", "ping", nil, @"not-injected");
    Expect(@"tweak not injected here", "local.bridge-e2e.elsewhere", "notify", @{@"name": @"local.bridge-e2e.elsewhere.x"}, @"not-injected");
    Expect(@"unknown action", TWEAK, "run", @{@"command": @"/bin/sh"}, @"unknown-action");

    NSError *bad = nil;
    Call(TWEAK, "ping", (NSDictionary *)@[@1], &bad);
    Check(bad.code == DBErrorInvalidArgument, @"SDK refuses non-dictionary args", Reason(bad));
    NSMutableData *huge = [NSMutableData dataWithLength:(1 << 20) + 1];
    bad = nil;
    Call(TWEAK, "ping", @{@"blob": huge}, &bad);
    Check(bad.code == DBErrorInvalidArgument, @"SDK refuses > 1 MB", Reason(bad));

    // A forged dynject.bridge.changed (anyone can post it) while requests are in flight fails none of them.
    [NSThread sleepForTimeInterval:4.5];
    dispatch_group_t forged = dispatch_group_create();
    __block int forgedOK = 0, forgedFailed = 0;
    NSObject *forgedLock = [NSObject new];
    for (int i = 0; i < 10; i++) {
        dispatch_group_enter(forged);
        DBRequest(TWEAK, "ping", nil, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(NSDictionary *rr, NSError *ee) {
            (void)rr;
            @synchronized(forgedLock) { if (ee) forgedFailed++; else forgedOK++; }
            dispatch_group_leave(forged);
        });
        if (i == 4) notify_post(DB_CHANGED_NOTIFICATION);
    }
    dispatch_group_wait(forged, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    Check(forgedOK == 10 && forgedFailed == 0, @"forged change notification fails nothing in flight",
          [NSString stringWithFormat:@"%d ok, %d failed", forgedOK, forgedFailed]);

    // Rate limit: let the bucket refill, then 30 at once (burst 20, 5/s).
    [NSThread sleepForTimeInterval:4.5];
    dispatch_group_t group = dispatch_group_create();
    __block int ok = 0, limited = 0, other = 0;
    NSObject *lock = [NSObject new];
    for (int i = 0; i < 30; i++) {
        dispatch_group_enter(group);
        DBRequest(TWEAK, "ping", nil, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(NSDictionary *rr, NSError *ee) {
            (void)rr;
            @synchronized(lock) {
                if (!ee) ok++; else if ([Reason(ee) isEqual:@"rate-limited"]) limited++; else other++;
            }
            dispatch_group_leave(group);
        });
    }
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    Check(ok >= 20 && ok <= 22 && limited >= 8 && other == 0, @"rate limit hit",
          [NSString stringWithFormat:@"%d ok, %d rate-limited, %d other", ok, limited, other]);

    // Broker restart: the script kickstarts the job when it sees this line.
    [NSThread sleepForTimeInterval:1.5];
    printf("READY_FOR_RESTART %ld\n", brokerPID);
    fflush(stdout);
    NSMutableSet *seen = [NSMutableSet set];
    long now = brokerPID;
    int attempts = 0;
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:25];
    while ([end timeIntervalSinceNow] > 0) {
        [NSThread sleepForTimeInterval:0.5];
        attempts++;
        e = nil;
        r = Call(TWEAK, "ping", nil, &e);
        if (e) [seen addObject:Reason(e)];
        if (r && [r[@"brokerPID"] longValue] != brokerPID) { now = [r[@"brokerPID"] longValue]; break; }
    }
    Check(now != brokerPID, @"reconnects after broker restart",
          [NSString stringWithFormat:@"broker pid %ld -> %ld after %d pings; errors meanwhile: %@", brokerPID, now, attempts,
           seen.count ? [seen.allObjects componentsJoinedByString:@", "] : @"none"]);
    Expect(@"settings.set after restart", TWEAK, "settings.set", @{@"key": @"size", @"value": @7}, @"ok");
}

__attribute__((constructor)) static void BridgeE2EInit(void) {
    const char *mode = getenv("BRIDGE_E2E_MODE");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (mode && strcmp(mode, "badtoken") == 0) {
            // The token key holds a token for another service: the SDK must not consume it or try.
            NSError *e = nil;
            Call(TWEAK, "ping", nil, &e);
            printf("BADTOKEN available=%d error=%ld\n", DBIsAvailable(), (long)e.code);
            fflush(stdout);
            exit(0);
        }
        if (mode && strcmp(mode, "probe") == 0) {
            NSError *e = nil;
            Call(TWEAK, "ping", nil, &e);
            printf("PROBE %s %s\n", Reason(e).UTF8String, e.localizedDescription.UTF8String ?: "");
            fflush(stdout);
            exit(0);
        }
        Scenario();
        printf("DONE %d failure(s)\n", sFailures);
        fflush(stdout);
        exit(sFailures ? 1 : 0);
    });
}
