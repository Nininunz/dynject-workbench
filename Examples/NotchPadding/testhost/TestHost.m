// Test host for NotchPadding, run by `./build.sh test` (no Dynject involved):
//   DYLD_INSERT_LIBRARIES=build/test/libNotchPadding.dylib build/test/NotchPaddingTestHost.app/Contents/MacOS/NotchPaddingTestHost
//
// It talks to the test copy of the tweak (tweak ID local.dynject.notchpadding.test), so the settings it writes never
// touch your real ones; it removes them at the end. It reads NSScreen's notch frame and the top strips beside it
// (which AppKit derives from the notch frame) with the tweak off,
// then on with a padding, and checks the difference. On a Mac without a notch both are empty and must stay so; the
// hooks are checked by where the methods' implementations now live.
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kTweakID = @"local.dynject.notchpadding.test";
static int sChecks, sFailures;

static void Check(BOOL ok, NSString *what) {
    sChecks++;
    if (!ok) sFailures++;
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what.UTF8String);
}

static void SetSettings(NSDictionary *values) {
    NSString *key = [@"dynject.tweak." stringByAppendingString:kTweakID];
    NSDictionary *payload = values ? @{@"formatVersion": @1, @"values": values, @"perApp": @{},
                                       @"defaults": @{@"enabled": @YES, @"padding": @40}} : nil;
    CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)payload, kCFPreferencesAnyApplication,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    notify_post([NSString stringWithFormat:@"dynject.tweak.%@.changed", kTweakID].UTF8String);
}

static NSRect Notch(NSScreen *s) { return ((NSRect (*)(id, SEL))objc_msgSend)(s, NSSelectorFromString(@"_notchFrame")); }

static NSString *ImageOf(SEL sel) {
    Method m = class_getInstanceMethod([NSScreen class], sel);
    Dl_info info;
    if (!m || !dladdr((const void *)method_getImplementation(m), &info) || !info.dli_fname) return @"?";
    return @(info.dli_fname).lastPathComponent;
}

@interface Host : NSObject <NSApplicationDelegate>
@property NSArray<void (^)(void)> *steps;
@end

@implementation Host {
    NSRect _notch, _left, _right;   // with the tweak off
}

- (NSArray<void (^)(void)> *)makeSteps {
    NSScreen *screen = NSScreen.screens.firstObject;
    return @[
        ^{
            for (NSString *sel in @[@"_notchFrame", @"_notchFrameForSpace:"]) {
                NSString *image = ImageOf(NSSelectorFromString(sel));
                Check([image isEqualToString:@"libNotchPadding.dylib"], [NSString stringWithFormat:@"-[NSScreen %@] is hooked (%@)", sel, image]);
            }
            SetSettings(@{@"enabled": @NO});
        },
        ^{
            self->_notch = Notch(screen);
            self->_left = screen.auxiliaryTopLeftArea;
            self->_right = screen.auxiliaryTopRightArea;
            printf("  this Mac's notch: %s\n", NSIsEmptyRect(self->_notch) ? "none" : NSStringFromRect(self->_notch).UTF8String);
            SetSettings(@{@"enabled": @YES, @"padding": @30});
        },
        ^{
            NSRect n = Notch(screen), l = screen.auxiliaryTopLeftArea, r = screen.auxiliaryTopRightArea;
            if (NSIsEmptyRect(self->_notch)) {
                Check(NSIsEmptyRect(n) && NSIsEmptyRect(l) && NSIsEmptyRect(r), @"no notch: nothing changes");
            } else {
                Check(NSEqualRects(n, NSInsetRect(self->_notch, -30, 0)), [NSString stringWithFormat:@"the notch is 30 wider each side: %@", NSStringFromRect(n)]);
                // AppKit derives the strips beside the notch from _notchFrame: they follow by themselves.
                Check(NSMaxX(l) == NSMaxX(self->_left) - 30 && NSMinX(l) == NSMinX(self->_left), @"the left strip ends 30 sooner");
                Check(NSMinX(r) == NSMinX(self->_right) + 30 && NSMaxX(r) == NSMaxX(self->_right), @"the right strip starts 30 later");
            }
            SetSettings(@{@"enabled": @YES, @"padding": @0});
        },
        ^{
            Check(NSEqualRects(Notch(screen), self->_notch), @"padding 0: the real notch");
            SetSettings(@{@"enabled": @NO, @"padding": @30});
        },
        ^{
            Check(NSEqualRects(Notch(screen), self->_notch) && NSEqualRects(screen.auxiliaryTopRightArea, self->_right), @"switched off: the real notch and strips");
        },
    ];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    self.steps = [self makeSteps];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        Check(NO, @"finished within 20 s");
        [self finish];
    });
    [self runStep:0];
}

- (void)runStep:(NSUInteger)index {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (index == self.steps.count) { [self finish]; return; }
        self.steps[index]();
        [self runStep:index + 1];
    });
}

- (void)finish {
    SetSettings(nil);
    printf("%d checks, %s\n", sChecks, sFailures ? "FAILED" : "all passed");
    exit(sFailures ? 1 : 0);
}

@end

int main(void) {
    @autoreleasepool {
        if (!getenv("DYLD_INSERT_LIBRARIES")) {
            fprintf(stderr, "run it with ./build.sh test (it needs the test copy injected)\n");
            return 2;
        }
        SetSettings(nil);
        Host *host = [Host new];
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        app.delegate = host;
        [app run];
    }
    return 0;
}
