// Inspector test host (built and run by ../build.sh test). An AppKit window with nested views, a button, a table
// and a SwiftUI view with Liquid Glass in an NSHostingView. Run with the test build of libInspector.dylib in
// DYLD_INSERT_LIBRARIES and DYI_TEST=1: it drives the inspector through its test channel (an in-process
// notification) and through real posted events (⌃⌥⌘, L, Esc, a click), checks what was picked and what the panel
// shows, writes the hook skeletons it copied to $DYI_TEST_OUT/hooks/ (build.sh compiles them) and captures the
// overlay and the panel with screencapture -l. Exits 0 when every check passed.
//
// No real app is touched, the clipboard isn't used (the test build copies to a private pasteboard) and no
// preferences are written.
#import "TestHost.h"
#import <notify.h>
#import <objc/runtime.h>

NSView *ITMakeSwiftUIView(void);   // TestHostUI.swift

int gITRiskyCalls;
static BOOL gITButtonPressed;
static int failures;

static void check(BOOL ok, NSString *what) {
    printf("  %s  %s\n", ok ? "ok  " : "FAIL", what.UTF8String);
    if (!ok) failures++;
}

@interface ITContainerView : NSView
@end
@implementation ITContainerView
@end
@interface ITInnerView : NSView
@end
@implementation ITInnerView
@end
@interface ITBadgeLayer : CALayer
@end
@implementation ITBadgeLayer
@end

@implementation ITLeafView
- (NSInteger)riskyValue { gITRiskyCalls++; return 42; }
- (NSString *)throwingValue { [NSException raise:NSInvalidArgumentException format:@"getter raised on purpose"]; return nil; }
- (ITPair)pair { return (ITPair){1.5, 2}; }
- (void)setPair:(ITPair)pair flag:(BOOL)flag { (void)pair; (void)flag; }
- (void)takeUnion:(ITUnion)u { (void)u; }
@end

@interface ITHost : NSObject <NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) ITLeafView *leaf;
@property (nonatomic, strong) ITBadgeLayer *badge;
@property (nonatomic, strong) NSButton *button;
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSView *hosting;
@property (nonatomic, copy) NSString *outDir;
@property (nonatomic, strong) NSMutableArray *steps;
@end

#pragma mark - Talking to the inspector

static NSDictionary *DYI(NSString *cmd, NSDictionary *args) {
    NSMutableDictionary *reply = [NSMutableDictionary dictionary];
    NSMutableDictionary *info = args ? [args mutableCopy] : [NSMutableDictionary dictionary];
    info[@"cmd"] = cmd;
    info[@"reply"] = reply;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"local.dynject.inspector.test.command" object:nil userInfo:info];
    return reply;
}

static NSPoint ITScreenPoint(NSView *v, NSPoint local) {
    return [v.window convertPointToScreen:[v convertPoint:local toView:nil]];
}

static NSPoint ITCenter(NSView *v) { return ITScreenPoint(v, NSMakePoint(NSMidX(v.bounds), NSMidY(v.bounds))); }

static NSDictionary *ITHover(NSPoint screen) { return DYI(@"hover", @{@"x": @(screen.x), @"y": @(screen.y)}); }

static void ITPostFlags(NSWindow *w, NSEventModifierFlags flags) {
    NSEvent *e = [NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint modifierFlags:flags timestamp:0
                              windowNumber:w.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@""
                                 isARepeat:NO keyCode:flags ? 55 : 0];
    [NSApp postEvent:e atStart:NO];
}

static void ITPostKey(NSWindow *w, NSString *chars, unsigned short keyCode) {
    for (NSNumber *t in @[@(NSEventTypeKeyDown), @(NSEventTypeKeyUp)]) {
        NSEvent *e = [NSEvent keyEventWithType:(NSEventType)t.integerValue location:NSZeroPoint modifierFlags:0 timestamp:0
                                  windowNumber:w.windowNumber context:nil characters:chars charactersIgnoringModifiers:chars
                                     isARepeat:NO keyCode:keyCode];
        [NSApp postEvent:e atStart:NO];
    }
}

static void ITPostClick(NSWindow *w, NSPoint screen) {
    NSPoint p = [w convertPointFromScreen:screen];
    for (NSNumber *t in @[@(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp)]) {
        NSEvent *e = [NSEvent mouseEventWithType:(NSEventType)t.integerValue location:p modifierFlags:0 timestamp:0
                                    windowNumber:w.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        [NSApp postEvent:e atStart:NO];
    }
}

static BOOL ITRowsContain(NSDictionary *reply, NSString *left, NSString *right) {
    for (NSDictionary *r in reply[@"rows"]) {
        BOOL l = !left || [r[@"left"] containsString:left];
        BOOL rt = !right || [r[@"right"] containsString:right];
        if (l && rt) return YES;
    }
    return NO;
}

static NSDictionary *ITRow(NSDictionary *reply, NSString *left) {
    for (NSDictionary *r in reply[@"rows"]) if (![r[@"group"] boolValue] && [r[@"left"] isEqualToString:left]) return r;
    return nil;
}

/// Whether the view with this pointer is `root` or one of its descendants.
static BOOL ITViewIsIn(NSView *root, NSString *pointer) {
    if ([[NSString stringWithFormat:@"%p", (__bridge void *)root] isEqualToString:pointer]) return YES;
    for (NSView *s in root.subviews) if (ITViewIsIn(s, pointer)) return YES;
    return NO;
}

static void ITCollectLayers(CALayer *l, NSMutableSet *out) {
    [out addObject:[NSString stringWithFormat:@"%p", (__bridge void *)l]];
    for (CALayer *s in l.sublayers) ITCollectLayers(s, out);
}

static CALayer *ITFindLayer(CALayer *l, BOOL (^match)(CALayer *)) {
    if (match(l)) return l;
    for (CALayer *s in l.sublayers) { CALayer *hit = ITFindLayer(s, match); if (hit) return hit; }
    return nil;
}

@implementation ITHost

#pragma mark Window

- (void)buildWindow {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 860, 560)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered defer:NO];
    w.title = @"Inspector Test";
    w.releasedWhenClosed = NO;
    NSView *content = w.contentView;

    ITContainerView *container = [[ITContainerView alloc] initWithFrame:NSMakeRect(20, 300, 360, 230)];
    container.wantsLayer = YES;
    container.layer.backgroundColor = [NSColor colorWithSRGBRed:0.85 green:0.88 blue:0.95 alpha:1].CGColor;
    container.layer.cornerRadius = 12;
    ITInnerView *inner = [[ITInnerView alloc] initWithFrame:NSMakeRect(20, 20, 320, 190)];
    inner.wantsLayer = YES;
    inner.layer.backgroundColor = [NSColor colorWithSRGBRed:0.7 green:0.78 blue:0.92 alpha:1].CGColor;
    inner.layer.cornerRadius = 8;
    ITLeafView *leaf = [[ITLeafView alloc] initWithFrame:NSMakeRect(20, 20, 170, 110)];
    leaf.wantsLayer = YES;
    leaf.layer.backgroundColor = [NSColor colorWithSRGBRed:0.35 green:0.5 blue:0.85 alpha:1].CGColor;
    leaf.accessibilityIdentifier = @"leaf-view";
    ITBadgeLayer *badge = [ITBadgeLayer layer];
    badge.frame = CGRectMake(110, 70, 44, 26);
    badge.cornerRadius = 6;
    badge.backgroundColor = [NSColor systemRedColor].CGColor;
    [leaf.layer addSublayer:badge];
    [inner addSubview:leaf];
    [container addSubview:inner];
    [content addSubview:container];

    NSButton *button = [NSButton buttonWithTitle:@"Push Me" target:self action:@selector(pushed:)];
    button.frame = NSMakeRect(20, 250, 140, 32);
    [content addSubview:button];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(400, 300, 440, 230)];
    scroll.hasVerticalScroller = YES;
    NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    for (NSString *ident in @[@"name", @"value"]) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
        col.title = ident;
        col.width = 200;
        [table addTableColumn:col];
    }
    table.dataSource = self;
    table.delegate = self;
    scroll.documentView = table;
    [content addSubview:scroll];

    NSView *hosting = ITMakeSwiftUIView();
    hosting.frame = NSMakeRect(400, 20, 440, 260);
    [content addSubview:hosting];

    NSRect vis = NSScreen.mainScreen.visibleFrame;
    [w setFrameTopLeftPoint:NSMakePoint(NSMinX(vis) + 40, NSMaxY(vis) - 40)];
    self.window = w;
    self.leaf = leaf;
    self.badge = badge;
    self.button = button;
    self.table = table;
    self.hosting = hosting;
}

- (void)pushed:(id)sender { (void)sender; gITButtonPressed = YES; }

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { (void)tv; return 6; }

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSTableCellView *cell = [tv makeViewWithIdentifier:col.identifier owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, col.width, 20)];
        cell.identifier = col.identifier;
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.frame = NSMakeRect(2, 2, col.width - 4, 17);
        tf.autoresizingMask = NSViewWidthSizable;
        [cell addSubview:tf];
        cell.textField = tf;
    }
    cell.textField.stringValue = [NSString stringWithFormat:@"%@ %ld", col.identifier, (long)row];
    return cell;
}

#pragma mark Capture

- (CGWindowID)windowIDFor:(NSWindow *)w {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    CGWindowID found = 0;
    for (NSDictionary *info in (__bridge NSArray *)list) {
        if ([info[(id)kCGWindowOwnerPID] intValue] != getpid()) continue;
        if ([info[(id)kCGWindowNumber] unsignedIntValue] == (CGWindowID)w.windowNumber) found = (CGWindowID)w.windowNumber;
    }
    if (list) CFRelease(list);
    return found;
}

- (NSString *)capture:(NSWindow *)w name:(NSString *)name {
    CGWindowID wid = w ? [self windowIDFor:w] : 0;
    if (!wid) { check(NO, [NSString stringWithFormat:@"%@: window id in CGWindowListCopyWindowInfo", name]); return nil; }
    NSString *path = [self.outDir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
    t.arguments = @[@"-x", @"-o", [NSString stringWithFormat:@"-l%u", wid], path];
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];   // the tweak is for this process only
    [env removeObjectForKey:@"DYI_TEST"];
    t.environment = env;
    if ([t launchAndReturnError:nil]) [t waitUntilExit];
    BOOL ok = t.terminationStatus == 0 && [[NSFileManager defaultManager] fileExistsAtPath:path];
    check(ok, [NSString stringWithFormat:@"screenshot %@", path]);
    return ok ? path : nil;
}

/// The window with the overlay drawn on top (both captured separately: same frame, same size).
- (void)captureOverlay:(NSString *)name {
    NSDictionary *s = DYI(@"state", nil);
    NSWindow *overlay = [NSApp windowWithWindowNumber:[s[@"overlayWindowNumber"] integerValue]];
    NSString *base = [self capture:self.window name:[name stringByAppendingString:@"-window"]];
    NSString *top = [self capture:overlay name:[name stringByAppendingString:@"-overlay"]];
    if (!base || !top) return;
    NSBitmapImageRep *a = [[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfFile:base]];
    NSBitmapImageRep *b = [[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfFile:top]];
    NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:a.pixelsWide pixelsHigh:a.pixelsHigh
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:out];
    NSRect r = NSMakeRect(0, 0, a.pixelsWide, a.pixelsHigh);
    [a drawInRect:r];
    [b drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:NO hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    NSString *path = [self.outDir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
    BOOL ok = [[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    check(ok && a.pixelsWide == b.pixelsWide && a.pixelsHigh == b.pixelsHigh,
          [NSString stringWithFormat:@"overlay composited over the window (same size) -> %@", path]);
}

- (void)saveHook:(NSString *)text name:(NSString *)name {
    NSString *dir = [self.outDir stringByAppendingPathComponent:@"hooks"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [text writeToFile:[dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"txt"]]
           atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark Steps

/// Each step runs from the main event loop (so posted events get dispatched in between), `delay` after the last.
- (void)step:(double)delay do:(void (^)(void))block {
    [self.steps addObject:@[@(delay), [block copy]]];
}

/// Waits (polling every 0.1 s) until `condition` holds or `timeout` seconds pass, then runs the next step, which
/// checks the outcome. For background work whose duration depends on the machine (slow CI runners).
- (void)waitUpTo:(double)timeout until:(BOOL (^)(void))condition {
    [self.steps addObject:@[@"wait", @(timeout), [condition copy]]];
}

- (void)poll:(BOOL (^)(void))condition deadline:(CFAbsoluteTime)deadline {
    if (condition() || CFAbsoluteTimeGetCurrent() > deadline) { [self runSteps]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self poll:condition deadline:deadline];
    });
}

- (void)runSteps {
    if (self.steps.count == 0) { [self finish]; return; }
    NSArray *s = self.steps.firstObject;
    [self.steps removeObjectAtIndex:0];
    if ([s[0] isEqual:@"wait"]) {
        [self poll:s[2] deadline:CFAbsoluteTimeGetCurrent() + [s[1] doubleValue]];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([s[0] doubleValue] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ((void (^)(void))s[1])();
        [self runSteps];
    });
}

- (void)finish {
    DYI(@"close", nil);
    DYI(@"cancel", nil);
    printf("%s\n", failures == 0 ? "host: all checks passed" : "host: FAILED");
    exit(failures == 0 ? 0 : 1);
}

- (void)planTests {
    NSWindow *w = self.window;
    const NSEventModifierFlags hot = NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;
    __block NSWindow *keyBefore = nil;

    [self step:1.5 do:^{   // let the window, the table and SwiftUI lay out first
        printf("== loaded ==\n");
        NSDictionary *s = DYI(@"state", nil);
        check(s[@"pickActive"] != nil, @"tweak loaded, test channel answers");
        check([s[@"enabled"] boolValue], @"enabled by default (no settings written)");
        ITHover(ITCenter(self.leaf));   // the test cursor; the real mouse is ignored from here on
        keyBefore = NSApp.keyWindow;
        printf("== hold ⌃⌥⌘ (posted flagsChanged events) ==\n");
        ITPostFlags(w, hot);
    }];
    [self step:0.3 do:^{
        NSDictionary *s = DYI(@"state", nil);
        check([s[@"pickActive"] boolValue] && [s[@"holdMode"] boolValue], @"⌃⌥⌘ starts pick mode (hold)");
        check([s[@"overlayVisible"] boolValue], @"overlay is shown");
        check([s[@"overlayIgnoresMouse"] boolValue] && ![s[@"overlayCanBecomeKey"] boolValue] && ![s[@"overlayIsKey"] boolValue],
              @"overlay ignores the mouse and can't become key");
        check(NSApp.keyWindow == keyBefore, @"key window unchanged");
        check([s[@"viewClass"] isEqualToString:@"ITLeafView"], [NSString stringWithFormat:@"hovered view under the cursor: %@", s[@"viewClass"]]);
        ITPostFlags(w, NSEventModifierFlagControl | NSEventModifierFlagCommand);   // option released
    }];
    [self step:0.3 do:^{
        NSDictionary *s = DYI(@"state", nil);
        check(![s[@"pickActive"] boolValue] && ![s[@"overlayVisible"] boolValue], @"releasing without a click cancels, overlay gone");
        ITPostFlags(w, hot);
    }];
    [self step:0.3 do:^{
        check([DYI(@"state", nil)[@"pickActive"] boolValue], @"⌃⌥⌘ again");
        ITPostKey(w, @"t", 17);
    }];
    [self step:0.3 do:^{
        check(![DYI(@"state", nil)[@"pickActive"] boolValue], @"⌃⌥⌘T (an app shortcut) cancels the pick");
        ITPostFlags(w, 0);
        printf("== darwin toggle ==\n");
        notify_post("local.dynject.inspector.test.toggle");
    }];
    [self step:0.3 do:^{
        NSDictionary *s = DYI(@"state", nil);
        if (!NSApp.isActive) check(![s[@"pickActive"] boolValue], @"toggle ignored while the app isn't frontmost");
        DYI(@"assumeActive", @{@"value": @YES});
        notify_post("local.dynject.inspector.test.toggle");
    }];
    [self step:0.3 do:^{
        check([DYI(@"state", nil)[@"pickActive"] boolValue], @"toggle starts pick mode in the frontmost app");
        notify_post("local.dynject.inspector.test.toggle");
    }];
    [self step:0.3 do:^{
        check(![DYI(@"state", nil)[@"pickActive"] boolValue], @"toggle again ends it");
        DYI(@"assumeActive", @{@"value": @NO});

        printf("== view picking ==\n");
        DYI(@"pick", nil);
        NSDictionary *s = ITHover(ITCenter(self.leaf));
        NSString *frame = NSStringFromRect([self.leaf convertRect:self.leaf.bounds toView:nil]);
        check([s[@"viewClass"] isEqualToString:@"ITLeafView"], [NSString stringWithFormat:@"leaf: %@", s[@"viewClass"]]);
        check([s[@"label"] containsString:@"ITLeafView"] && [s[@"label"] containsString:frame] &&
              [s[@"label"] containsString:@"id leaf-view"] && [s[@"label"] containsString:@"layer "],
              [NSString stringWithFormat:@"label: %@", [s[@"label"] stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]]);
        s = ITHover(ITScreenPoint(self.leaf.superview, NSMakePoint(250, 160)));
        check([s[@"viewClass"] isEqualToString:@"ITInnerView"], [NSString stringWithFormat:@"inner view: %@", s[@"viewClass"]]);
        s = ITHover(ITScreenPoint(self.leaf.superview.superview, NSMakePoint(8, 8)));
        check([s[@"viewClass"] isEqualToString:@"ITContainerView"], [NSString stringWithFormat:@"container: %@", s[@"viewClass"]]);
        // AppKit draws some controls with private subviews (macOS 27: a hosting view inside NSButton, a label class
        // for text fields): the deepest view is then one of those, inside the control.
        s = ITHover(ITCenter(self.button));
        check(ITViewIsIn(self.button, s[@"viewPointer"]), [NSString stringWithFormat:@"button (or its content): %@", s[@"viewClass"]]);
        NSTableCellView *cell = [self.table viewAtColumn:0 row:1 makeIfNecessary:NO];
        s = ITHover(ITCenter(cell.textField ?: cell));
        check(cell && ITViewIsIn(cell, s[@"viewPointer"]) && [s[@"label"] containsString:s[@"viewClass"]],
              [NSString stringWithFormat:@"table cell (row 1): %@", s[@"viewClass"]]);
        s = ITHover(ITScreenPoint(self.hosting, NSMakePoint(30, 30)));
        check([s[@"viewClass"] containsString:@"NSHostingView"], [NSString stringWithFormat:@"swiftui: %@", s[@"viewClass"]]);
        ITHover(ITCenter(self.leaf));
    }];
    [self step:0.4 do:^{ [self captureOverlay:@"overlay-view"]; }];
    [self step:0 do:^{
        printf("== layer picking (L) ==\n");
        ITPostKey(w, @"l", 37);
    }];
    [self step:0.3 do:^{
        NSDictionary *s = DYI(@"state", nil);
        check([s[@"layerMode"] boolValue] && [s[@"pickActive"] boolValue], @"L switches to layer mode, key swallowed");
        s = ITHover(ITScreenPoint(self.leaf, NSMakePoint(132, 83)));
        check([s[@"layerClass"] isEqualToString:@"ITBadgeLayer"], [NSString stringWithFormat:@"badge sublayer: %@", s[@"layerClass"]]);
        check([s[@"label"] containsString:@"cornerRadius 6"] && [s[@"label"] containsString:@"bounds {{0, 0}, {44, 26}}"],
              [NSString stringWithFormat:@"layer label: %@", [s[@"label"] stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]]);
        s = ITHover(ITScreenPoint(self.leaf, NSMakePoint(20, 20)));
        check([s[@"layerPointer"] isEqualToString:[NSString stringWithFormat:@"%p", (__bridge void *)self.leaf.layer]],
              [NSString stringWithFormat:@"leaf's own layer outside the badge: %@", s[@"layerClass"]]);

        NSMutableSet *swiftUILayers = [NSMutableSet set];
        ITCollectLayers(self.hosting.layer, swiftUILayers);
        NSString *hostingLayer = [NSString stringWithFormat:@"%p", (__bridge void *)self.hosting.layer];
        CALayer *circle = ITFindLayer(self.hosting.layer, ^BOOL(CALayer *l) { return CGSizeEqualToSize(l.bounds.size, CGSizeMake(36, 36)); });
        check(circle != nil, @"swiftui circle layer found by the test");
        if (circle) {
            CGRect r = [circle convertRect:circle.bounds toLayer:self.hosting.layer];
            s = ITHover(ITScreenPoint(self.hosting, NSMakePoint(CGRectGetMidX(r), CGRectGetMidY(r))));
            check([s[@"layerPointer"] isEqualToString:[NSString stringWithFormat:@"%p", (__bridge void *)circle]],
                  [NSString stringWithFormat:@"swiftui circle: %@ (%@)", s[@"layerClass"], [s[@"label"] stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]]);
        }
        CALayer *glass = ITFindLayer(self.hosting.layer, ^BOOL(CALayer *l) { return [NSStringFromClass(object_getClass(l)) containsString:@"SDFLayer"]; });
        check(glass != nil, @"swiftui glass layer found by the test");
        if (glass) {
            CGRect r = [glass convertRect:glass.bounds toLayer:self.hosting.layer];
            s = ITHover(ITScreenPoint(self.hosting, NSMakePoint(CGRectGetMidX(r), CGRectGetMidY(r))));
            check(s[@"layerPointer"] && [swiftUILayers containsObject:s[@"layerPointer"]] && ![s[@"layerPointer"] isEqualToString:hostingLayer],
                  [NSString stringWithFormat:@"layer inside the swiftui glass: %@", s[@"layerClass"]]);
        }
    }];
    [self step:0.4 do:^{ [self captureOverlay:@"overlay-layer"]; }];
    [self step:0 do:^{ ITPostKey(w, @"\x1b", 53); }];
    [self step:0.3 do:^{
        NSDictionary *s = DYI(@"state", nil);
        check(![s[@"pickActive"] boolValue] && ![s[@"overlayVisible"] boolValue], @"esc cancels, overlay ordered out");

        printf("== click selects (posted mouse down/up) ==\n");
        DYI(@"pick", nil);
        ITHover(ITCenter(self.button));
        ITPostClick(w, ITCenter(self.button));
    }];
    [self step:0.5 do:^{
        NSDictionary *s = DYI(@"state", nil);
        check(![s[@"pickActive"] boolValue] && [s[@"panelVisible"] boolValue], @"click leaves pick mode and opens the panel");
        check(!gITButtonPressed, @"the click didn't reach the button");
        s = DYI(@"tab", @{@"name": @"Hierarchy"});
        if (![s[@"targetClass"] isEqualToString:@"NSButton"]) {   // picked the button's content view: go up to the button
            check([s[@"header"] length] > 0 && ITRowsContain(s, @"NSButton", nil), [NSString stringWithFormat:@"picked %@ inside the button", s[@"targetClass"]]);
            s = DYI(@"navigate", @{@"contains": @"NSButton"});
        }
        check([s[@"targetClass"] isEqualToString:@"NSButton"], [NSString stringWithFormat:@"panel inspects %@", s[@"targetClass"]]);
        check([s[@"header"] containsString:@"NSButton"] && [s[@"header"] containsString:@"0x"] && [s[@"header"] containsString:@"AppKit"],
              @"header: class, pointer, image");
        check([s[@"chain"] isEqual:@[@"NSButton", @"NSControl", @"NSView", @"NSResponder", @"NSObject"]],
              [NSString stringWithFormat:@"superclass chain %@", [s[@"chain"] componentsJoinedByString:@" > "]]);
        check(ITRowsContain(s, @"▶ NSButton", nil) && ITRowsContain(s, @"NSWindow", @"Inspector Test") && ITRowsContain(s, @"NSView", nil),
              @"hierarchy: window, ancestors, self");
        s = DYI(@"tab", @{@"name": @"Properties"});
        check([ITRow(s, @"frame")[@"right"] isEqualToString:NSStringFromRect(self.button.frame)], @"curated frame");
        check([ITRow(s, @"isHidden")[@"right"] isEqualToString:@"NO"] && [ITRow(s, @"accessibilityRole")[@"right"] hasPrefix:@"AX"],
              [NSString stringWithFormat:@"curated isHidden %@, accessibilityRole %@", ITRow(s, @"isHidden")[@"right"], ITRow(s, @"accessibilityRole")[@"right"]]);
        NSDictionary *title = ITRow(s, @"title");
        check(title && ![title[@"evaluated"] boolValue] && [title[@"right"] hasPrefix:@"▸ evaluate"], @"title listed, not evaluated");
        s = DYI(@"evaluate", @{@"name": @"title"});
        check([s[@"value"] isEqualToString:@"\"Push Me\""], [NSString stringWithFormat:@"evaluate title -> %@", s[@"value"]]);
        s = DYI(@"copyName", nil);
        check([s[@"text"] isEqualToString:@"NSButton"], @"Copy Class Name");
        s = DYI(@"copyDescription", nil);
        check([s[@"text"] containsString:@"NSButton"], @"Copy Description");
        [self capture:[NSApp windowWithWindowNumber:[DYI(@"state", nil)[@"panelWindowNumber"] integerValue]] name:@"panel-button-properties"];

        printf("== leaf view: risky and throwing getters ==\n");
        DYI(@"pick", nil);
        ITHover(ITCenter(self.leaf));
        DYI(@"select", nil);
        s = DYI(@"tab", @{@"name": @"Properties"});
        check([s[@"targetClass"] isEqualToString:@"ITLeafView"], @"leaf selected");
        check(ITRow(s, @"riskyValue") && ![ITRow(s, @"riskyValue")[@"evaluated"] boolValue] && gITRiskyCalls == 0,
              @"riskyValue listed and not read automatically");
        check([ITRow(s, @"accessibilityIdentifier")[@"right"] isEqualToString:@"leaf-view"], @"curated accessibilityIdentifier");
        s = DYI(@"evaluate", @{@"name": @"riskyValue"});
        check([s[@"value"] isEqualToString:@"42"] && gITRiskyCalls == 1, [NSString stringWithFormat:@"evaluate riskyValue -> %@ (%d call)", s[@"value"], gITRiskyCalls]);
        s = DYI(@"evaluate", @{@"name": @"throwingValue"});
        check([s[@"value"] hasPrefix:@"exception: NSInvalidArgumentException"], [NSString stringWithFormat:@"NSException caught: %@", s[@"value"]]);
        s = DYI(@"evaluate", @{@"name": @"cxxThrowingValue"});
        check([s[@"value"] hasPrefix:@"exception: C++"], [NSString stringWithFormat:@"C++ exception caught: %@", s[@"value"]]);
        s = DYI(@"evaluate", @{@"name": @"superview"});
        check([s[@"value"] containsString:@"ITInnerView"], [NSString stringWithFormat:@"object value: %@", s[@"value"]]);
        [self capture:[NSApp windowWithWindowNumber:[DYI(@"state", nil)[@"panelWindowNumber"] integerValue]] name:@"panel-leaf-properties"];

        printf("== navigation ==\n");
        s = DYI(@"tab", @{@"name": @"Hierarchy"});
        s = DYI(@"navigate", @{@"contains": @"NSViewBackingLayer"});
        check([s[@"targetClass"] isEqualToString:@"NSViewBackingLayer"], [NSString stringWithFormat:@"hierarchy -> layer: %@", s[@"targetClass"]]);
        check(ITRowsContain(s, @"ITBadgeLayer", nil), @"layer hierarchy lists the badge sublayer");
        s = DYI(@"navigate", @{@"contains": @"ITBadgeLayer"});
        check([s[@"targetClass"] isEqualToString:@"ITBadgeLayer"], @"-> badge layer");
        s = DYI(@"tab", @{@"name": @"Properties"});
        check([ITRow(s, @"cornerRadius")[@"right"] isEqualToString:@"6"] && [ITRow(s, @"bounds")[@"right"] isEqualToString:@"{{0, 0}, {44, 26}}"],
              @"curated layer properties");
        check([ITRow(s, @"backgroundColor")[@"right"] hasPrefix:@"#"], [NSString stringWithFormat:@"backgroundColor %@", ITRow(s, @"backgroundColor")[@"right"]]);
        s = DYI(@"back", nil);
        check([s[@"targetClass"] isEqualToString:@"NSViewBackingLayer"], @"back");
        s = DYI(@"back", nil);
        check([s[@"targetClass"] isEqualToString:@"ITLeafView"], @"back again");
        s = DYI(@"forward", nil);
        check([s[@"targetClass"] isEqualToString:@"NSViewBackingLayer"], @"forward");
        DYI(@"forward", nil);

        printf("== hooks ==\n");
        struct { NSString *cls, *context, *sel; BOOL classMethod; NSString *expect; } cases[] = {
            {@"ITBadgeLayer", @"CALayer", @"setCornerRadius:", NO, @"DH_ORIG(void (*)(id, SEL, double), arg1);"},
            {@"ITBadgeLayer", @"CALayer", @"cornerRadius", NO, @"double r = DH_ORIG(double (*)(id, SEL));"},
            {@"ITBadgeLayer", @"CALayer", @"setBackgroundColor:", NO, @"CGColorRef"},
            {@"ITBadgeLayer", @"CALayer", @"defaultValueForKey:", YES, @"+ (id)defaultValueForKey:(id)arg1"},
        };
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
            DYI(@"context", @{@"class": cases[i].context});
            s = DYI(@"copyHook", @{@"sel": cases[i].sel, @"classMethod": @(cases[i].classMethod)});
            NSString *text = s[@"text"];
            check([text containsString:cases[i].expect] && [text containsString:@"DHClass(\"CALayer\")"],
                  [NSString stringWithFormat:@"hook %@[%@ %@]", cases[i].classMethod ? @"+" : @"-", cases[i].context, cases[i].sel]);
            [self saveHook:text name:[NSString stringWithFormat:@"CALayer-%@", [cases[i].sel stringByReplacingOccurrencesOfString:@":" withString:@"_"]]];
        }
        s = DYI(@"tab", @{@"name": @"Methods"});
        [self capture:[NSApp windowWithWindowNumber:[DYI(@"state", nil)[@"panelWindowNumber"] integerValue]] name:@"panel-layer-methods"];
        s = DYI(@"back", nil);
        s = DYI(@"back", nil);
        check([s[@"targetClass"] isEqualToString:@"ITLeafView"], @"back to the leaf");
        struct { NSString *context, *sel; BOOL classMethod; NSString *expect; } leafCases[] = {
            {@"NSView", @"setFrame:", NO, @"- (void)setFrame:(CGRect)arg1"},
            {@"NSView", @"isHidden", NO, @"BOOL r = DH_ORIG(BOOL (*)(id, SEL));"},
            {@"NSView", @"convertRect:toView:", NO, @"CGRect r = DH_ORIG(CGRect (*)(id, SEL, CGRect, id), arg1, arg2);"},
            {@"NSView", @"initWithFrame:", NO, @"ns_consumed"},
            {@"NSView", @"defaultMenu", YES, @"+ (id)defaultMenu"},
            {@"NSObject", @"validateValue:forKey:error:", NO, @"id __autoreleasing *"},
            {@"NSObject", @"copy", NO, @"ns_returns_retained"},
            {@"ITLeafView", @"pair", NO, @"typedef struct { double f0; int f1; } MYITLeafViewHook_ITPair;"},
            {@"ITLeafView", @"setPair:flag:", NO, @"- (void)setPair:(MYITLeafViewHook_ITPair)arg1 flag:(BOOL)arg2"},
            {@"ITLeafView", @"takeUnion:", NO, @"no hook class for this method: its types can't be written exactly in C (union)"},
            {@"ITLeafView", @"riskyValue", NO, @"NSInteger r = DH_ORIG(NSInteger (*)(id, SEL));"},
        };
        for (size_t i = 0; i < sizeof leafCases / sizeof leafCases[0]; i++) {
            DYI(@"context", @{@"class": leafCases[i].context});
            s = DYI(@"copyHook", @{@"sel": leafCases[i].sel, @"classMethod": @(leafCases[i].classMethod)});
            NSString *text = s[@"text"];
            BOOL refused = [leafCases[i].expect hasPrefix:@"no hook class"];
            BOOL ok = [text containsString:leafCases[i].expect] &&
                      (refused || [text containsString:[NSString stringWithFormat:@"DHClass(\"%@\")", leafCases[i].context]]);
            check(ok, [NSString stringWithFormat:@"hook %@[%@ %@]", leafCases[i].classMethod ? @"+" : @"-", leafCases[i].context, leafCases[i].sel]);
            if (!ok) printf("%s\n", text.UTF8String);
            [self saveHook:text name:[NSString stringWithFormat:@"ITLeafView-%@-%@", leafCases[i].context,
                                      [leafCases[i].sel stringByReplacingOccurrencesOfString:@":" withString:@"_"]]];
        }
        DYI(@"openClass", @{@"name": @"NSString"});
        s = DYI(@"copyHook", @{@"sel": @"stringWithFormat:", @"classMethod": @YES});
        check([s[@"text"] containsString:@"looks variadic"], @"hook +[NSString stringWithFormat:] refused as variadic");
        [self saveHook:s[@"text"] name:@"NSString-stringWithFormat_"];

        printf("== runtime browser ==\n");
        DYI(@"runtime", @{@"query": @"ITLeaf"});
    }];
    // The class list loads in the background: ~1 s here, much longer on a CI runner.
    [self waitUpTo:30 until:^BOOL { return ![DYI(@"runtime", @{@"query": @"ITLeaf"})[@"loading"] boolValue]; }];
    [self step:0.2 do:^{
        NSDictionary *s = DYI(@"runtime", @{@"query": @"ITLeaf"});
        check(![s[@"loading"] boolValue], @"class list loaded in the background");
        check(ITRowsContain(s, @"ITLeafView", nil), @"runtime search finds ITLeafView");
        s = DYI(@"runtime", @{@"query": @"CASDF"});
        NSUInteger n = 0;
        for (NSDictionary *r in s[@"rows"]) if ([r[@"link"] boolValue]) n++;
        check(n >= 3, [NSString stringWithFormat:@"runtime search CASDF: %lu classes", (unsigned long)n]);
        [self capture:[NSApp windowWithWindowNumber:[DYI(@"state", nil)[@"panelWindowNumber"] integerValue]] name:@"panel-runtime"];
        s = DYI(@"navigate", @{@"contains": @"CASDFLayer"});
        check([s[@"targetClass"] isEqualToString:@"CASDFLayer"] && ![s[@"hasInstance"] boolValue] &&
              [s[@"header"] containsString:@"class (no instance)"] && [s[@"tab"] isEqualToString:@"Methods"],
              [NSString stringWithFormat:@"class view: %@ on %@", s[@"targetClass"], s[@"tab"]]);
        check(ITRowsContain(s, @"effect", nil), @"class view lists methods");
        s = DYI(@"tab", @{@"name": @"Properties"});
        check(ITRowsContain(s, @"smoothness", @"double") && !ITRowsContain(s, nil, @"evaluate"), @"class view: properties with types, nothing to evaluate");

        printf("== settings and cleanup ==\n");
        DYI(@"setEnabled", @{@"value": @NO});
        s = DYI(@"pick", nil);
        check(![s[@"pickActive"] boolValue] && ![s[@"panelVisible"] boolValue], @"enabled off: panel closed, no pick mode");
        ITPostFlags(w, hot);
    }];
    [self step:0.3 do:^{
        check(![DYI(@"state", nil)[@"pickActive"] boolValue], @"enabled off: ⌃⌥⌘ ignored");
        ITPostFlags(w, 0);
        DYI(@"setEnabled", @{@"value": @YES});
        DYI(@"pick", nil);
        ITHover(ITCenter(self.leaf));
        DYI(@"select", nil);
        NSDictionary *s = DYI(@"close", nil);
        s = DYI(@"state", nil);
        check(![s[@"panelVisible"] boolValue] && ![s[@"overlayVisible"] boolValue] && ![s[@"pickActive"] boolValue],
              @"panel closed, overlay hidden, pick mode off");
        BOOL others = NO;
        for (NSWindow *win in NSApp.windows) if (win != self.window && win.isVisible) others = YES;
        check(!others, @"no inspector window left on screen");
    }];
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    (void)n;
    [self buildWindow];
    [self.window orderFrontRegardless];
    self.steps = [NSMutableArray array];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        check(NO, @"finished within 60 s");
        [self finish];
    });
    [self planTests];
    [self runSteps];
}

@end

int main(void) {
    @autoreleasepool {
        if (!getenv("DYLD_INSERT_LIBRARIES") || !getenv("DYI_TEST")) {
            fprintf(stderr, "run with DYI_TEST=1 DYLD_INSERT_LIBRARIES=<test build of libInspector.dylib> (see ../build.sh test)\n");
            return 2;
        }
        ITHost *host = [ITHost new];
        host.outDir = getenv("DYI_TEST_OUT") ? @(getenv("DYI_TEST_OUT")) : NSTemporaryDirectory();
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;   // no Dock icon, doesn't take focus
        app.delegate = host;
        [app run];
    }
    return 0;
}
