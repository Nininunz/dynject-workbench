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

#pragma mark - dw inspect

// `dw inspect <app>` sends commands to this process: it sets the state of the Darwin notification
// "local.dynject.inspector.command.<pid>" and posts it. Low 8 bits: the command; the next 32 bits: a request ID that
// the answer's log lines carry (subsystem "dynject.inspect", "A <request> ..."). It reaches background apps
// (ControlCenter, the Dock), which the hotkey and the Apple-menu item can't, since they're never frontmost.
// dw reads the marker below to tell builds that understand it. Keep both as they are.
__attribute__((used)) static const char *const DYIInspectCapability = "dynject.inspect:v1";
enum { DYICommandOpen = 1, DYICommandPick = 2, DYICommandStop = 3, DYICommandTree = 4 };

#ifdef DYI_TEST
static NSMutableArray<NSString *> *gTestAnswers;
#endif

static void DYIAnswer(uint32_t request, NSString *text) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("dynject.inspect", "answer"); });
    NSString *line = [NSString stringWithFormat:@"A %u %@", request, text];
    os_log(log, "%{public}@", line);
#ifdef DYI_TEST
    if (gTestMode) { if (!gTestAnswers) gTestAnswers = [NSMutableArray array]; [gTestAnswers addObject:line]; }
#endif
}

static NSString *DYIRectText(NSRect r) {
    return [NSString stringWithFormat:@"%g,%g %gx%g", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

// One line per window, then its views from the frame view down: "W ..." / "V <depth> ...".
static void DYIAnswerTree(uint32_t request) {
    __block NSUInteger windows = 0, views = 0;
    __block BOOL cut = NO;
    void (^__block walk)(NSView *, NSInteger);
    void (^walkRef)(NSView *, NSInteger) = ^(NSView *v, NSInteger depth) {
        if (views >= 4000 || depth > 40) { cut = YES; return; }
        views++;
        NSMutableString *line = [NSMutableString stringWithFormat:@"V %ld %@ frame=%@", (long)depth, DYIDisplayClassName(v), DYIRectText(v.frame)];
        if (v.isHidden) [line appendString:@" hidden"];
        if (v.identifier.length) [line appendFormat:@" id=%@", v.identifier];
        if (v.accessibilityIdentifier.length) [line appendFormat:@" ax=%@", v.accessibilityIdentifier];
        if (v.layer) [line appendFormat:@" layer=%@", DYIDisplayClassName(v.layer)];
        DYIAnswer(request, line);
        for (NSView *s in v.subviews) walk(s, depth + 1);
    };
    walk = walkRef;
    NSString *err = DYITry(^{
        for (NSWindow *w in NSApp.windows) {
            if ([[DYIPicker shared] isOwnWindow:w]) continue;
            windows++;
            NSString *title = w.title.length ? [NSString stringWithFormat:@" title=\"%@\"", w.title] : @"";
            DYIAnswer(request, [NSString stringWithFormat:@"W %ld %@ level=%ld frame=%@ %@%@", (long)w.windowNumber, DYIDisplayClassName(w),
                                (long)w.level, DYIRectText(w.frame), w.isVisible ? @"visible" : @"hidden", title]);
            NSView *top = w.contentView.superview ?: w.contentView;
            if (top) walk(top, 1);
        }
    });
    walk = nil;
    if (err) DYIAnswer(request, [@"error " stringByAppendingString:err]);
    DYIAnswer(request, [NSString stringWithFormat:@"end windows=%lu views=%lu%@", (unsigned long)windows, (unsigned long)views, cut ? @" cut" : @""]);
}

static void DYIHandleCommand(uint64_t state) {
    uint8_t command = (uint8_t)(state & 0xff);
    uint32_t request = (uint32_t)(state >> 8);
    if (!gEnabled) { DYIAnswer(request, @"refused: Inspector is switched off in this app"); return; }
    switch (command) {
        case DYICommandOpen: {
            DYIPanelController *panel = [DYIPanelController shared];
            [panel inspectObject:NSApp];
            [panel showPanel];
            [NSApp activate];
            NSUInteger n = 0;
            for (NSWindow *w in NSApp.windows) n += [[DYIPicker shared] isOwnWindow:w] ? 0 : 1;
            DYIAnswer(request, [NSString stringWithFormat:@"opened %lu windows", (unsigned long)n]);
            break;
        }
        case DYICommandPick:
            [[DYIPicker shared] beginWithHold:NO];
            DYIAnswer(request, @"picking");
            break;
        case DYICommandStop:
            [[DYIPicker shared] cancel];
            [[DYIPanelController shared] close];
            DYIAnswer(request, @"stopped");
            break;
        case DYICommandTree:
            DYIAnswerTree(request);
            break;
        default:
            DYIAnswer(request, [NSString stringWithFormat:@"refused: unknown command %u", command]);
    }
}

static void DYIListenForCommands(void) {
    static int token;
    NSString *name = [NSString stringWithFormat:@"%s.command.%d", DYI_ID_C, getpid()];
    notify_register_dispatch(name.UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0;
        notify_get_state(t, &state);
        DYIHandleCommand(state);
    });
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
    } else if ([name isEqualToString:@"command"]) {   // as dw inspect would send it, without the notification
        DYIHandleCommand((uint64_t)[cmd[@"code"] unsignedIntValue] | ((uint64_t)[cmd[@"request"] unsignedIntValue] << 8));
        reply[@"answers"] = [gTestAnswers copy] ?: @[];
        [gTestAnswers removeAllObjects];
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
        DYIListenForCommands();
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
