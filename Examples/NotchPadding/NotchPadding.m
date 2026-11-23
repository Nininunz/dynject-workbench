// NotchPadding: keeps the menu bar's items a set distance from the notch.
//
// It loads into MenuBarAgent, the process that draws and lays out the whole menu bar: the app's menus, every app's
// status items, and the « that collects the ones that don't fit. MenuBarAgent places them around the notch it gets from
// -[NSScreen _notchFrame]; the tweak makes that notch wider by `padding` points on each side. (ControlCenter only draws
// some of the items, inside scenes MenuBarAgent hosts: widening the notch there changes nothing.) AppKit works out the
// screen's two top strips beside the notch (auxiliaryTopLeftArea and auxiliaryTopRightArea) from the same method, so
// they shrink to match by themselves.
//
//   ./build.sh                                           build/libNotchPadding.dylib
//   ./build.sh test                                      also runs testhost/
//   dw tweak install . --for com.apple.MenuBarAgent      install, enable for MenuBarAgent, restart dynjectd
//   killall MenuBarAgent                                 launchd starts it again, with the tweak
#import <AppKit/AppKit.h>
#import <os/log.h>
#import <stdatomic.h>
#import "DynjectHook.h"
#import "DynjectTweak.h"

// `./build.sh test` compiles a test copy (-DTWEAK_TEST) for testhost/: a tweak ID of its own, so the test never
// touches your real settings, and it also loads into the test host.
#ifdef TWEAK_TEST
#define TWEAK_ID_C "local.dynject.notchpadding.test"
#define TWEAK_APPS "com.apple.MenuBarAgent", "local.dynject.notchpadding.testhost"
#else
#define TWEAK_ID_C "local.dynject.notchpadding"
#define TWEAK_APPS "com.apple.MenuBarAgent"
#endif
#define TWEAK_ID @TWEAK_ID_C

static DHGroup *gMain;
static _Atomic(double) gPadding = 40;
static DHHook *sNotch, *sNotchForSpace;

static os_log_t TweakLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create(TWEAK_ID_C, "tweak"); });
    return log;
}

/// Whether to pad: on, and the hook is ours to apply (a disabled group's hook can stay installed beneath another).
static BOOL NPActive(void) { return DHGroupIsEnabled(gMain); }

static NSRect NPWiden(NSRect notch) {
    if (NSIsEmptyRect(notch) || !NPActive()) return notch;
    double p = atomic_load(&gPadding);
    return NSMakeRect(notch.origin.x - p, notch.origin.y, notch.size.width + 2 * p, notch.size.height);
}

static NSRect NPNotchFrame(NSScreen *self, SEL _cmd) {
    return NPWiden(DH_CALL_ORIG(sNotch, NSRect (*)(id, SEL), self, _cmd));
}

static NSRect NPNotchFrameForSpace(NSScreen *self, SEL _cmd, unsigned long long space) {
    return NPWiden(DH_CALL_ORIG(sNotchForSpace, NSRect (*)(id, SEL, unsigned long long), self, _cmd, space));
}

/// Reads the settings Workbench publishes (DynjectTweak.h) and applies them.
static void ApplySettings(NSString *reason) {
    BOOL enabled = DTPrefBool(TWEAK_ID, @"enabled", YES);
    double padding = MIN(MAX(DTPrefDouble(TWEAK_ID, @"padding", 40), 0), 200);
    atomic_store(&gPadding, padding);
    DHGroupSetEnabled(gMain, enabled);
    os_log(TweakLog(), "%{public}@: enabled=%d padding=%g", reason, enabled, padding);
}

// Runs when the dylib loads, before main(), unless Safe Mode or Shift-at-launch says to skip this tweak.
DH_CTOR(TWEAK_ID_C, TWEAK_APPS) {   // MenuBarAgent only (and the test host), even if the config injects it elsewhere
    DH_REQUIRE_SYSTEM("27.0");   // = minimumSystemVersion in NotchPadding.workbench.plist
    gMain = DHGroupCreate("main");
    ApplySettings(@"loaded");
    Class screen = [NSScreen class];
    sNotch = DHHookMessage(screen, NSSelectorFromString(@"_notchFrame"), (IMP)NPNotchFrame, gMain);
    sNotchForSpace = DHHookMessage(screen, NSSelectorFromString(@"_notchFrameForSpace:"), (IMP)NPNotchFrameForSpace, gMain);
    os_log(TweakLog(), "loaded into %{public}@: hooked _notchFrame %d, _notchFrameForSpace: %d",
           NSBundle.mainBundle.bundleIdentifier ?: @"(no bundle ID)", sNotch != NULL, sNotchForSpace != NULL);
    // Workbench posts this after every change to the tweak's settings. A screen-parameters change makes MenuBarAgent
    // lay the menu bar out again, with the new padding (seen live: no relaunch needed).
    DTPrefObserve(TWEAK_ID, nil, ^{
        ApplySettings(@"settings changed");
        [[NSNotificationCenter defaultCenter] postNotificationName:NSApplicationDidChangeScreenParametersNotification object:NSApp];
    });
}
