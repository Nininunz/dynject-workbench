// Inspector: a FLEX-style in-app inspector for macOS apps. Hold ⌃⌥⌘ in an app it's injected into and point at
// something: the deepest view (or, after pressing L, the deepest Core Animation layer) under the cursor is outlined
// and labelled. Click to open the inspector panel on it: class, image, superclass chain, view/layer hierarchy, a safe
// set of properties, every other property on request, methods with readable signatures (and a DynjectHook skeleton
// to copy), ivars, and a browser for every class in the process. Read-only: it never sets anything and only calls
// getters it knows are safe, or the one you click.
//
// Files: Inspector.m (entry point, settings, activation), DYIPicker.m (pick mode and the overlay), DYIPanel.m (the
// panel), DYIRuntime.m (introspection, type encodings, hook skeletons). No hooks: nothing in the app is swizzled.
//
//   ./build.sh
//   dw tweak install . --for <bundleID>
//   dw respring
#import "DYIInternal.h"
#import "DynjectHook.h"
#import "DynjectTweak.h"
#import <notify.h>
#import <os/log.h>

static BOOL gEnabled = YES, gHotkeyEnabled = YES;
#ifdef DYI_TEST
static BOOL gTestMode, gTestAssumeActive;
static NSPasteboard *gTestPasteboard;
#endif

static os_log_t DYIOSLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create(DYI_ID_C, "tweak"); });
    return log;
}

void DYILog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log(DYIOSLog(), "%{public}@", msg);
}

NSString *DYITry(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
    } @catch (...) {
        return @"C++ or other non-Objective-C exception";
    }
}

BOOL DYIEnabled(void) { return gEnabled; }

NSPasteboard *DYIPasteboard(void) {
#ifdef DYI_TEST
    if (gTestMode) {
        if (!gTestPasteboard) gTestPasteboard = [NSPasteboard pasteboardWithUniqueName];
        return gTestPasteboard;
    }
#endif
    return [NSPasteboard generalPasteboard];
}

BOOL DYIHotkeyEnabled(void) { return gEnabled && gHotkeyEnabled; }

static void DYIReadSettings(void) {
    gEnabled = DTPrefBool(DYI_ID, @"enabled", YES);
    gHotkeyEnabled = DTPrefBool(DYI_ID, @"hotkeyEnabled", YES);
    if (!gEnabled) {
        [[DYIPicker shared] cancel];
        [[DYIPanelController shared] close];
    }
}

/// The Apple-menu item (and anything else) posts the toggle; only the frontmost app acts on it.
static void DYIToggleFromNotification(void) {
    BOOL active = NSApp.isActive;
#ifdef DYI_TEST
    active = active || gTestAssumeActive;
#endif
    if (!gEnabled || !active) return;
    DYIPicker *picker = [DYIPicker shared];
    if (picker.active) [picker cancel];
    else [picker beginWithHold:NO];
}

#ifdef DYI_TEST
#pragma mark - Test channel (test build only)

/// The test host posts "local.dynject.inspector.test.command" (an in-process NSNotification) with a command
/// dictionary and a mutable "reply" dictionary; this fills the reply synchronously. Compiled into the test build only
/// and active only with DYI_TEST=1 in the environment.
static NSDictionary *DYIPickerState(void) {
    DYIPicker *p = [DYIPicker shared];
    NSWindow *o = p.overlayWindow;
    NSMutableDictionary *d = [@{
        @"pickActive": @(p.active), @"layerMode": @(p.layerMode), @"holdMode": @(p.holdMode),
        @"label": p.labelText ?: @"", @"enabled": @(gEnabled),
        @"overlayVisible": @(o.isVisible), @"overlayWindowNumber": @(o.isVisible ? o.windowNumber : 0),
        @"overlayIgnoresMouse": @(o ? o.ignoresMouseEvents : YES), @"overlayCanBecomeKey": @(o.canBecomeKeyWindow),
        @"overlayIsKey": @(o.isKeyWindow), @"overlayLevel": @(o.level),
        @"panelVisible": @([DYIPanelController shared].panel.isVisible),
        @"panelWindowNumber": @([DYIPanelController shared].panel.isVisible ? [DYIPanelController shared].panel.windowNumber : 0),
    } mutableCopy];
    if (p.hoveredView) {
        d[@"viewClass"] = NSStringFromClass(object_getClass(p.hoveredView));
        d[@"viewPointer"] = [NSString stringWithFormat:@"%p", (__bridge void *)p.hoveredView];
    }
    if (p.hoveredLayer) {
        d[@"layerClass"] = NSStringFromClass(object_getClass(p.hoveredLayer));
        d[@"layerPointer"] = [NSString stringWithFormat:@"%p", (__bridge void *)p.hoveredLayer];
    }
    return d;
}

static void DYIHandleTestCommand(NSNotification *note) {
    NSDictionary *cmd = note.userInfo;
    NSMutableDictionary *reply = cmd[@"reply"];
    NSString *name = cmd[@"cmd"];
    DYIPicker *picker = [DYIPicker shared];
    if ([name isEqualToString:@"state"]) {
    } else if ([name isEqualToString:@"pick"]) {
        [picker beginWithHold:NO];
    } else if ([name isEqualToString:@"hover"]) {
        NSPoint pt = NSMakePoint([cmd[@"x"] doubleValue], [cmd[@"y"] doubleValue]);
        picker.testCursor = pt;
        [picker updateForScreenPoint:pt];
    } else if ([name isEqualToString:@"layerMode"]) {
        [picker toggleLayerMode];
    } else if ([name isEqualToString:@"select"]) {
        [picker selectCurrent];
    } else if ([name isEqualToString:@"cancel"]) {
        [picker cancel];
    } else if ([name isEqualToString:@"assumeActive"]) {
        gTestAssumeActive = [cmd[@"value"] boolValue];
    } else if ([name isEqualToString:@"setEnabled"]) {
        gEnabled = [cmd[@"value"] boolValue];
        if (!gEnabled) { [picker cancel]; [[DYIPanelController shared] close]; }
    } else {
        [reply addEntriesFromDictionary:[[DYIPanelController shared] testCommand:cmd]];
    }
    [reply addEntriesFromDictionary:DYIPickerState()];
}
#endif

DH_CTOR(DYI_ID_C) {
    DH_REQUIRE_SYSTEM("27.0");   // = minimumSystemVersion in Inspector.workbench.plist
    // Nothing at load time: settings, the event monitor and the notification are set up once AppKit is running.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!NSApp || NSApp.activationPolicy == NSApplicationActivationPolicyProhibited) return;   // not an app with windows
        DYIReadSettings();
        DTPrefObserve(DYI_ID, nil, ^{ DYIReadSettings(); });
        [[DYIPicker shared] installMonitor];
        static int token;
        notify_register_dispatch(DYI_TOGGLE_NOTIFICATION, &token, dispatch_get_main_queue(), ^(int t) {
            (void)t;
            DYIToggleFromNotification();
        });
#ifdef DYI_TEST
        if (getenv("DYI_TEST")) {
            gTestMode = YES;
            [[NSNotificationCenter defaultCenter] addObserverForName:@DYI_ID_C ".test.command" object:nil queue:nil
                                                          usingBlock:^(NSNotification *note) { DYIHandleTestCommand(note); }];
            DYILog(@"test channel on");
        }
#endif
        DYILog(@"ready in %@ (enabled %d, hotkey %d)", NSBundle.mainBundle.bundleIdentifier, gEnabled, gHotkeyEnabled);
    });
}
