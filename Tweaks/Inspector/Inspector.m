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
#import <objc/message.h>
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
// `dw eval` (command 6) is newer: dw looks for this before asking.
__attribute__((used)) static const char *const DYIEvalCapability = "dynject.eval:v1";
enum { DYICommandOpen = 1, DYICommandPick = 2, DYICommandStop = 3, DYICommandTree = 4, DYICommandTreeWithProperties = 5,
       DYICommandEval = 6 };

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

/// For `dw eval`: values from the app's memory go out at debug level, which only a live `log stream --level debug`
/// sees; they're never kept in the log store.
static void DYIAnswerTransient(uint32_t request, NSString *text) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("dynject.inspect", "eval"); });
    NSString *line = [NSString stringWithFormat:@"A %u %@", request, text];
    os_log_debug(log, "%{public}@", line);
#ifdef DYI_TEST
    if (gTestMode) { if (!gTestAnswers) gTestAnswers = [NSMutableArray array]; [gTestAnswers addObject:line]; }
#endif
}

/// `dw eval`: the path is in the global preference "dynject.inspector.eval.<pid>" ({request, path, time}), which a
/// sandboxed app can read but not write, so only unsandboxed code running as the user can ask. A request whose
/// number doesn't match the notification's, or older than 10 s, is refused.
static void DYIAnswerEval(uint32_t request) {
    CFStringRef key = (__bridge CFStringRef)[NSString stringWithFormat:@"dynject.inspector.eval.%d", getpid()];
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    NSDictionary *ask = CFBridgingRelease(CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                                                 kCFPreferencesAnyHost));
    if (![ask isKindOfClass:NSDictionary.class] || ![ask[@"request"] isKindOfClass:NSNumber.class] ||
        [ask[@"request"] unsignedIntValue] != request || ![ask[@"path"] isKindOfClass:NSString.class] ||
        ![ask[@"time"] isKindOfClass:NSDate.class] || fabs([ask[@"time"] timeIntervalSinceNow]) > 10) {
        DYIAnswerTransient(request, @"refused: no current request for this app");
        return;
    }
    NSString *error = nil;
    NSArray<NSString *> *lines = DYIEvaluate(ask[@"path"], &error);
    if (!lines) { DYIAnswerTransient(request, [@"error " stringByAppendingString:error ?: @"?"]); return; }
    for (NSString *l in lines) DYIAnswerTransient(request, [@"V " stringByAppendingString:l]);
    DYIAnswerTransient(request, [NSString stringWithFormat:@"end %lu", (unsigned long)lines.count]);
}

static NSString *DYIRectText(NSRect r) {
    return [NSString stringWithFormat:@"%g,%g %gx%g", r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static NSString *DYIQuoted(NSString *s, NSUInteger max) {
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (s.length > max) s = [[s substringToIndex:max] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@"\"%@\"", s];
}

// Accessibility labels: where SwiftUI names what it draws ("Battery", "Wi-Fi").
static NSString *DYIAccessibilityText(NSView *v) {
    NSMutableString *s = [NSMutableString string];
    if (v.accessibilityLabel.length) [s appendFormat:@" axlabel=%@", DYIQuoted(v.accessibilityLabel, 80)];
    if (strstr(object_getClassName(v), "NSHostingView")) {
        NSMutableArray *labels = [NSMutableArray array];
        for (id child in v.accessibilityChildren ?: @[]) {
            NSString *l = [child respondsToSelector:@selector(accessibilityLabel)] ? [child accessibilityLabel] : nil;
            NSString *r = [child respondsToSelector:@selector(accessibilityRole)] ? [child accessibilityRole] : nil;
            if (l.length || r.length) [labels addObject:[NSString stringWithFormat:@"%@%@", r ?: @"", l.length ? [@" " stringByAppendingString:DYIQuoted(l, 60)] : @""]];
            if (labels.count == 4) break;
        }
        if (labels.count) [s appendFormat:@" axchildren=[%@]", [labels componentsJoinedByString:@", "]];
    }
    return s;
}

// The properties a window's own classes declare (below NSWindow), read with their getters: --tree --props.
static void DYIAnswerWindowProperties(uint32_t request, NSWindow *w) {
    for (Class c = object_getClass(w); c && c != [NSWindow class]; c = class_getSuperclass(c)) {
        if (strstr(class_getName(c), "NSKVONotifying_")) continue;
        for (DYIPropertyInfo *p in DYIPropertiesOfClass(c)) {
            NSString *text = DYIEvaluateProperty(w, p, NULL);
            if (text.length > 160) text = [[text substringToIndex:160] stringByAppendingString:@"…"];
            DYIAnswer(request, [NSString stringWithFormat:@"P %@.%@ = %@", DYIDisplayClassName(w) , p.name, text]);
        }
    }
}

// One line per window, then its views from the frame view down: "W ..." / "V <depth> ...", and with `properties`
// "P ..." lines for the window's own classes.
static void DYIAnswerTree(uint32_t request, BOOL properties) {
    // The app's status items (menu bar items), by autosave name, and the window each lives in.
    NSMutableDictionary<NSNumber *, NSString *> *itemOfWindow = [NSMutableDictionary dictionary];
    DYITry(^{
        NSStatusBar *bar = NSStatusBar.systemStatusBar;
        SEL itemsSel = NSSelectorFromString(@"_statusItems"), windowSel = NSSelectorFromString(@"_window");
        if (![bar respondsToSelector:itemsSel]) return;
        id items = ((id (*)(id, SEL))objc_msgSend)(bar, itemsSel);
        if ([items respondsToSelector:@selector(allObjects)]) items = [items allObjects];   // NSHashTable, NSPointerArray, NSSet
        if (![items isKindOfClass:[NSArray class]]) {
            if (items) DYIAnswer(request, [NSString stringWithFormat:@"S? _statusItems is a %s", object_getClassName(items)]);
            return;
        }
        for (NSStatusItem *it in items) {
            if (![it isKindOfClass:[NSStatusItem class]]) continue;
            NSWindow *w = [it respondsToSelector:windowSel] ? ((id (*)(id, SEL))objc_msgSend)(it, windowSel) : nil;
            NSString *name = it.autosaveName.length ? it.autosaveName : @"(no autosave name)";
            if (w) itemOfWindow[@(w.windowNumber)] = name;
            DYIAnswer(request, [NSString stringWithFormat:@"S %@ visible=%@ length=%g%@", name, it.isVisible ? @"YES" : @"NO", it.length,
                                w ? [NSString stringWithFormat:@" window=%ld frame=%@", (long)w.windowNumber, DYIRectText(w.frame)] : @""]);
        }
    });
    // FrontBoard scenes (menu bar items of ControlCenter and other scene-based UI): NSApp._workspace.scenes, by
    // identifier; with properties, a short description of each scene's settings (its frame among them).
    DYITry(^{
        SEL workspaceSel = NSSelectorFromString(@"_workspace"), scenesSel = NSSelectorFromString(@"scenes");
        if (![NSApp respondsToSelector:workspaceSel]) return;
        id workspace = ((id (*)(id, SEL))objc_msgSend)(NSApp, workspaceSel);
        if (![workspace respondsToSelector:scenesSel]) return;
        id scenes = ((id (*)(id, SEL))objc_msgSend)(workspace, scenesSel);
        if ([scenes respondsToSelector:@selector(allObjects)]) scenes = [scenes allObjects];
        if (![scenes isKindOfClass:[NSArray class]]) return;
        for (id scene in scenes) {
            NSString *identifier = [scene respondsToSelector:@selector(identifier)] ? [scene identifier] : nil;
            DYIAnswer(request, [NSString stringWithFormat:@"C %@ %s", identifier ?: @"(no identifier)", object_getClassName(scene)]);
            if (properties && [scene respondsToSelector:NSSelectorFromString(@"settings")]) {
                // The whole description, a line per log message (a log message holds about 1 KB).
                id settings = ((id (*)(id, SEL))objc_msgSend)(scene, NSSelectorFromString(@"settings"));
                NSUInteger n = 0;
                NSString *text = [DYIDescriptionOf(settings, 40000) stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
                for (NSString *l in [text componentsSeparatedByString:@"\n"]) {
                    NSString *t = [l stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                    if (!t.length) continue;
                    DYIAnswer(request, [NSString stringWithFormat:@"D %@", t.length > 700 ? [[t substringToIndex:700] stringByAppendingString:@"…"] : t]);
                    if (++n == 300) break;
                }
            }
        }
    });
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
        [line appendString:DYIAccessibilityText(v)];
        DYIAnswer(request, line);
        for (NSView *s in v.subviews) walk(s, depth + 1);
    };
    walk = walkRef;
    NSString *err = DYITry(^{
        for (NSWindow *w in NSApp.windows) {
            if ([[DYIPicker shared] isOwnWindow:w]) continue;
            windows++;
            NSMutableString *extra = [NSMutableString string];
            if (w.title.length) [extra appendFormat:@" title=%@", DYIQuoted(w.title, 80)];
            if (w.identifier.length) [extra appendFormat:@" id=%@", w.identifier];
            if (w.accessibilityLabel.length) [extra appendFormat:@" axlabel=%@", DYIQuoted(w.accessibilityLabel, 80)];
            if (itemOfWindow[@(w.windowNumber)]) [extra appendFormat:@" statusitem=%@", itemOfWindow[@(w.windowNumber)]];
            DYIAnswer(request, [NSString stringWithFormat:@"W %ld %@ level=%ld frame=%@ %@%@", (long)w.windowNumber, DYIDisplayClassName(w),
                                (long)w.level, DYIRectText(w.frame), w.isVisible ? @"visible" : @"hidden", extra]);
            if (properties) DYIAnswerWindowProperties(request, w);
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
        case DYICommandTreeWithProperties:
            DYIAnswerTree(request, command == DYICommandTreeWithProperties);
            break;
        case DYICommandEval:
            DYIAnswerEval(request);
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
