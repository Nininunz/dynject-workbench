// Test host for Title Badge, run WITHOUT Dynject:
//   DYLD_INSERT_LIBRARIES=build/libTitleBadge.dylib TitleBadgeTestHost.app/Contents/MacOS/TitleBadgeTestHost
// It writes the tweak's settings payload (the same contract Workbench uses), opens a window, and checks
// the badge the injected tweak draws: initial values, a live change with a per-app override, and
// switching it off. It saves and restores any existing payload for the tweak.
#import <AppKit/AppKit.h>
#import <notify.h>

static NSString *const kKey = @"dynject.tweak.local.dynject.titlebadge";
static const char *kNotify = "dynject.tweak.local.dynject.titlebadge.changed";
static int failures = 0;

static void check(BOOL ok, NSString *what) {
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what.UTF8String);
    if (!ok) failures++;
}

static void writePayload(NSDictionary *values, NSDictionary *perApp) {
    NSDictionary *payload = @{@"formatVersion": @1, @"values": values, @"perApp": perApp ?: @{},
                              @"defaults": @{@"enabled": @YES, @"text": @"Dynject", @"style": @"pill",
                                             @"color": @"#FF6A00", @"fontSize": @11}};
    CFPreferencesSetValue((__bridge CFStringRef)kKey, (__bridge CFPropertyListRef)payload, kCFPreferencesAnyApplication,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

static NSView *badgeIn(NSWindow *w) {
    for (NSTitlebarAccessoryViewController *vc in w.titlebarAccessoryViewControllers)
        if ([vc.view.identifier isEqualToString:@"local.dynject.titlebadge.badge"]) return vc.view.subviews.firstObject;
    return nil;
}

static NSString *badgeText(NSWindow *w) {
    for (NSView *v in badgeIn(w).subviews) if ([v isKindOfClass:[NSTextField class]]) return ((NSTextField *)v).stringValue;
    return nil;
}

@interface Host : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property id saved;
@end

@implementation Host
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 420, 200)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Title Badge test host";
    [self.window makeKeyAndOrderFront:nil];
    // Watchdog: never hang; restore settings and fail after 15 s.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        check(NO, @"finished within 15 s");
        [self finish];
    });
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        printf("Phase 1: settings present at launch\n");
        check(badgeIn(self.window) != nil, @"badge added to the titlebar");
        check([badgeText(self.window) isEqualToString:@"Phase One"], [NSString stringWithFormat:@"text is \"Phase One\" (got \"%@\")", badgeText(self.window)]);
        check(badgeIn(self.window).layer.backgroundColor != NULL, @"pill style has a fill");

        printf("Phase 2: live change with a per-app override\n");
        writePayload(@{@"text": @"Phase Two", @"style": @"outline", @"color": @"#0066FF"},
                     @{bid: @{@"text": @"Per App"}});
        notify_post(kNotify);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            check([badgeText(self.window) isEqualToString:@"Per App"], [NSString stringWithFormat:@"per-app override wins (got \"%@\")", badgeText(self.window)]);
            check(badgeIn(self.window).layer.borderWidth > 0, @"outline style applied live");

            printf("Phase 3: switched off\n");
            writePayload(@{@"enabled": @NO}, nil);
            notify_post(kNotify);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                check(badgeIn(self.window) == nil, @"badge removed live");
                [self finish];
            });
        });
    });
}

- (void)finish {
    CFPreferencesSetValue((__bridge CFStringRef)kKey, (__bridge CFPropertyListRef)self.saved, kCFPreferencesAnyApplication,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    printf("%s\n", failures == 0 ? "ALL PASSED" : "FAILED");
    exit(failures == 0 ? 0 : 1);
}
@end

int main(void) {
    @autoreleasepool {
        if (!getenv("DYLD_INSERT_LIBRARIES")) { fprintf(stderr, "run with DYLD_INSERT_LIBRARIES=libTitleBadge.dylib\n"); return 2; }
        Host *host = [Host new];
        host.saved = CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)kKey, kCFPreferencesAnyApplication,
                                                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
        // Settings exist before the tweak's first read, as they would after using Workbench.
        writePayload(@{@"text": @"Phase One", @"color": @"#00AA00"}, nil);
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;   // no Dock icon, no focus steal
        app.delegate = host;
        [app run];
    }
    return 0;
}
