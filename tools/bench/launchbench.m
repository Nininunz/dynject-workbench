// launchbench: a minimal AppKit app that times its own launch, for tools/bench/launch.
//
// Prints one line and exits:  <ms to main()> <ms to first window drawn> <tweak dylibs loaded, comma-separated, or ->
// Both times are from process start (proc_pidinfo). "To main" is dyld plus every initializer, the tweaks' DH_CTOR
// bodies included; "to first window" adds NSApplication setup, launch notifications and drawing one window, where
// tweak hooks on AppKit would show. Accessory app (no Dock icon, never takes focus), window off-screen.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <libproc.h>
#import <mach-o/dyld.h>
#import <sys/time.h>

static double Now(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec + tv.tv_usec / 1e6; }

static double ProcessStart(void) {
    struct proc_bsdinfo bi;
    if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &bi, sizeof bi) != (int)sizeof bi) return 0;
    return bi.pbi_start_tvsec + bi.pbi_start_tvusec / 1e6;
}

static double gMain;

@interface LBDelegate : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@end

@implementation LBDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-20000, -20000, 480, 320)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"launchbench";
    [self.window orderFrontRegardless];
    [self.window display];
    [CATransaction flush];
    dispatch_async(dispatch_get_main_queue(), ^{
        double t = Now(), start = ProcessStart();
        NSMutableArray *tweaks = [NSMutableArray array];
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *p = _dyld_get_image_name(i);
            if (p && strstr(p, "/lib/tweaks/")) [tweaks addObject:@(p).lastPathComponent];
        }
        printf("%.2f %.2f %s\n", (gMain - start) * 1000, (t - start) * 1000,
               tweaks.count ? [tweaks componentsJoinedByString:@","].UTF8String : "-");
        fflush(stdout);
        exit(0);
    });
}
@end

int main(void) {
    gMain = Now();
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        LBDelegate *d = [LBDelegate new];
        app.delegate = d;
        [app run];
    }
    return 0;
}
