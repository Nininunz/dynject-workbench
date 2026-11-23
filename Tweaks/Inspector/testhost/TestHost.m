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

// Tracer fixtures: plain values, a class method, a nested call, a struct, an exception, recursion, and an override
// that calls super.
@interface ITTraceBase : NSObject
- (NSInteger)value:(NSInteger)x;
+ (NSString *)classValue;
- (NSInteger)outer;
- (NSInteger)inner;
- (CGRect)rectFor:(CGFloat)w;
- (void)boom;
- (NSInteger)fib:(NSInteger)n;
@end
@implementation ITTraceBase
- (NSInteger)value:(NSInteger)x { return x * 2; }
+ (NSString *)classValue { return @"cv"; }
- (NSInteger)outer { return [self inner] + 1; }
- (NSInteger)inner { return 3; }
- (CGRect)rectFor:(CGFloat)w { return CGRectMake(0, 0, w, w); }
- (void)boom { [NSException raise:NSInvalidArgumentException format:@"boom on purpose"]; }
- (NSInteger)fib:(NSInteger)n { return n < 2 ? n : [self fib:n - 1] + [self fib:n - 2]; }
@end
@interface ITTraceChild : ITTraceBase
@end
@implementation ITTraceChild
- (NSInteger)value:(NSInteger)x { return [super value:x] + 1; }
@end

static int gITMenuRuns, gITTargetedRuns;

static NSDictionary *DYI(NSString *cmd, NSDictionary *args);
static NSArray<NSString *> *ITTraceLines(void) { return DYI(@"traceLines", @{@"clear": @YES})[@"lines"]; }

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
- (void)itTestAction:(id)sender { (void)sender; gITMenuRuns++; }
- (void)itTargeted:(id)sender { (void)sender; gITTargetedRuns++; }

/// The menu bar the menu checks use: Host ▸ Test Action (⇧⌘T, first responder), Targeted (⌥↩, this object), —,
/// No Responder (an action nobody implements).
- (NSMenu *)buildMenus {
    NSMenu *bar = [[NSMenu alloc] initWithTitle:@"Main"];
    NSMenuItem *top = [bar addItemWithTitle:@"Host" action:nil keyEquivalent:@""];
    NSMenu *sub = [[NSMenu alloc] initWithTitle:@"Host"];
    NSMenuItem *test = [sub addItemWithTitle:@"Test Action" action:@selector(itTestAction:) keyEquivalent:@"t"];
    test.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    NSMenuItem *targeted = [sub addItemWithTitle:@"Targeted" action:@selector(itTargeted:) keyEquivalent:@"\r"];
    targeted.keyEquivalentModifierMask = NSEventModifierFlagOption;
    targeted.target = self;
    [sub addItem:[NSMenuItem separatorItem]];
    [sub addItemWithTitle:@"No Responder" action:NSSelectorFromString(@"itNobodyImplementsThis:") keyEquivalent:@""];
    top.submenu = sub;
    NSApp.mainMenu = bar;
    return sub;
}

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

    }];
    __block ITTraceBase *base = nil;
    [self step:0.1 do:^{
        printf("== trace ==\n");
        base = [ITTraceBase new];
        ITTraceChild *child = [ITTraceChild new];
        DYI(@"openClass", @{@"name": @"ITTraceBase"});
        NSDictionary *s = DYI(@"trace", @{@"sel": @"value:"});
        check([s[@"traced"] boolValue] && [s[@"traceButton"] isEqualToString:@"Stop Trace"],
              [NSString stringWithFormat:@"traced from the panel (button \"%@\"; %@)", s[@"traceButton"], s[@"status"]]);
        check(ITRowsContain(s, @"value:", @"traced"), @"its method row says traced");
        ITTraceLines();
        check([base value:5] == 10, @"a traced method still returns its value");
        NSArray *lines = ITTraceLines();
        check(lines.count == 1 && [lines.firstObject containsString:@"-[ITTraceBase 0x"] && [lines.firstObject containsString:@"value:5] → 10  ("] &&
              [lines.firstObject containsString:@"ms, main)"], [NSString stringWithFormat:@"one line: %@", lines.firstObject]);
        check([child value:5] == 11, @"an untraced override calling super into it");
        lines = ITTraceLines();
        check(lines.count == 1 && [lines.firstObject containsString:@"value:5] → 10"], [NSString stringWithFormat:@"the super call is logged once: %@", lines]);
        s = DYI(@"traceDirect", @{@"class": @"ITTraceChild", @"sel": @"value:"});
        check([s[@"error"] containsString:@"traced already"], [NSString stringWithFormat:@"its subclass can't be traced as well: %@", s[@"error"]]);
        s = DYI(@"trace", @{@"sel": @"value:", @"on": @NO});
        check(![s[@"traced"] boolValue] && [s[@"traceButton"] isEqualToString:@"Trace"], @"stopped from the panel");
        s = DYI(@"traceDirect", @{@"class": @"ITTraceChild", @"sel": @"value:"});
        check([s[@"error"] isEqualToString:@""], @"then the subclass can be");
        check([child value:5] == 11 && [base value:5] == 10, @"values unchanged");
        lines = ITTraceLines();
        check(lines.count == 1 && [lines.firstObject containsString:@"-[ITTraceChild 0x"] && [lines.firstObject containsString:@"value:5] → 11"],
              [NSString stringWithFormat:@"only the subclass is logged: %@", lines]);

        for (NSString *sel in @[@"outer", @"inner", @"rectFor:", @"boom", @"fib:"]) DYI(@"trace", @{@"sel": sel});
        s = DYI(@"trace", @{@"sel": @"classValue", @"classMethod": @YES});
        check([s[@"traced"] boolValue], [NSString stringWithFormat:@"a class method (%@)", s[@"status"]]);
        check([[ITTraceBase classValue] isEqualToString:@"cv"] && [base outer] == 4 && CGRectEqualToRect([base rectFor:2], CGRectMake(0, 0, 2, 2)),
              @"traced methods return their values");
        BOOL raised = NO;
        @try { [base boom]; } @catch (NSException *e) { raised = [e.name isEqualToString:NSInvalidArgumentException]; }
        check(raised, @"an exception passes through a traced method");
        NSString *all = [ITTraceLines() componentsJoinedByString:@"\n"];
        check([all containsString:@"+[ITTraceBase classValue] → \"cv\""], @"class method line");
        check([all containsString:@"→ -[ITTraceBase 0x"] && [all containsString:@"\n  -[ITTraceBase 0x"] && [all containsString:@"inner] → 3"] &&
              [all containsString:@"← -[ITTraceBase outer] → 4"], @"nested: outer opens, inner indented, outer closes with its value");
        check([all containsString:@"rectFor:2] → {{0, 0}, {2, 2}}"], @"a CGFloat argument and a CGRect result");
        check([all containsString:@"boom] raised NSInvalidArgumentException"], @"the exception is logged");
        check([base fib:12] == 144, @"a recursive traced method");
        lines = ITTraceLines();
        check(lines.count >= 40 && lines.count <= 80, [NSString stringWithFormat:@"rate limited: %lu lines for 465 calls", (unsigned long)lines.count]);
        if (!raised || ![all containsString:@"← -[ITTraceBase outer] → 4"]) printf("%s\n", all.UTF8String);
    }];
    [self step:1.1 do:^{
        check([base fib:1] == 1, @"recursion again after a second");
        NSArray *lines = ITTraceLines();
        check(lines.count == 1 && [lines.firstObject containsString:@"calls not shown"], [NSString stringWithFormat:@"says what wasn't shown: %@", lines.firstObject]);

        DYI(@"openClass", @{@"name": @"ITLeafView"});
        DYI(@"trace", @{@"sel": @"setPair:flag:"});
        DYI(@"trace", @{@"sel": @"pair"});
        ITLeafView *leaf = self.leaf;
        [leaf setPair:(ITPair){1.5, 2} flag:YES];
        ITPair p = [leaf pair];
        NSString *all = [ITTraceLines() componentsJoinedByString:@"\n"];
        check(p.weight == 1.5 && p.count == 2, @"a struct result comes back intact");
        check([all containsString:@"setPair:{1.5, 2} flag:YES] → void"] && [all containsString:@"pair] → {1.5, 2}"],
              [NSString stringWithFormat:@"struct arguments and results, field by field: %@", all]);
        NSDictionary *s = DYI(@"traceDirect", @{@"class": @"NSObject", @"sel": @"retain"});
        check([s[@"error"] containsString:@"runtime itself"], [NSString stringWithFormat:@"refused: -retain (%@)", s[@"error"]]);
        s = DYI(@"traceDirect", @{@"class": @"ITLeafView", @"sel": @"takeUnion:"});
        check([s[@"error"] containsString:@"union"], [NSString stringWithFormat:@"refused: a union argument (%@)", s[@"error"]]);
        DYI(@"traceBacktraces", @{@"on": @YES});
        [base inner];
        all = [ITTraceLines() componentsJoinedByString:@"\n"];
        DYI(@"traceBacktraces", @{@"on": @NO});
        check([all containsString:@"\n    at "], @"backtraces when asked for");

        DYI(@"openClass", @{@"name": @"ITTraceBase"});
        s = DYI(@"traceClass", nil);
        check([s[@"status"] hasPrefix:@"tracing "] && [s[@"tracedCount"] integerValue] >= 7,
              [NSString stringWithFormat:@"trace all methods of a class: %@", s[@"status"]]);
        s = DYI(@"untraceAll", nil);
        check([s[@"tracedCount"] integerValue] == 0, @"stop all");
        ITTraceLines();
        BOOL raised = NO;
        @try { [base boom]; } @catch (__unused NSException *e) { raised = YES; }
        check([base outer] == 4 && [base fib:10] == 55 && raised && ITTraceLines().count == 0, @"untraced: same behaviour, nothing logged");
    }];
    __block NSMenu *hostMenu = nil;
    [self step:0.1 do:^{
        printf("== menus ==\n");
        hostMenu = [self buildMenus];
        NSDictionary *s = DYI(@"menuBar", nil);
        check([s[@"targetClass"] isEqualToString:@"NSMenu"] && ITRowsContain(s, @"\"Host\"", @"submenu (4 items)"),
              [NSString stringWithFormat:@"the menu bar: %@ with its items", s[@"targetClass"]]);
        s = DYI(@"navigate", @{@"contains": @"\"Host\""});
        check([s[@"targetClass"] isEqualToString:@"NSMenuItem"] && ITRowsContain(s, @"\"Test Action\"", @"⇧⌘T · itTestAction:") &&
              ITRowsContain(s, @"—", @"separator"), @"a menu bar item: its submenu's items, shortcut and action");
        s = DYI(@"navigate", @{@"contains": @"\"Test Action\""});
        check(ITRowsContain(s, @"NSMenu", @"main menu · 1 items") && ITRowsContain(s, @"NSMenu", @"\"Host\" · 4 items") &&
              ITRowsContain(s, @"▶ \"Test Action\"", nil), @"an item's hierarchy: the menus above it");
        s = DYI(@"tab", @{@"name": @"Properties"});
        check([ITRow(s, @"keyEquivalent")[@"right"] isEqualToString:@"⇧⌘T"], [NSString stringWithFormat:@"keyEquivalent %@", ITRow(s, @"keyEquivalent")[@"right"]]);
        check([ITRow(s, @"action")[@"right"] isEqualToString:@"itTestAction:"] && [ITRow(s, @"target")[@"right"] isEqualToString:@"nil"], @"action, no target");
        NSString *sent = ITRow(s, @"sent to")[@"right"];
        check([sent hasPrefix:@"<ITHost 0x"] && [sent containsString:@"responder chain"], [NSString stringWithFormat:@"sent to: %@", sent]);
        NSString *runs = ITRow(s, @"runs")[@"right"];
        check([runs hasPrefix:@"-[ITHost itTestAction:] in InspectorTestHost"], [NSString stringWithFormat:@"runs: %@", runs]);
        s = DYI(@"traceRuns", nil);
        check([s[@"status"] hasPrefix:@"tracing -[ITHost itTestAction:]"], [NSString stringWithFormat:@"trace it from its row: %@", s[@"status"]]);
        ITTraceLines();
        [hostMenu performActionForItemAtIndex:0];
        NSString *lines = [ITTraceLines() componentsJoinedByString:@"\n"];
        check(gITMenuRuns == 1 && [lines containsString:@"itTestAction:<NSMenuItem 0x"], [NSString stringWithFormat:@"choosing it is traced: %@", lines]);
        s = DYI(@"traceRuns", nil);
        check([s[@"status"] hasPrefix:@"stopped tracing"], @"and stopped again");
        s = DYI(@"openRuns", nil);
        check([s[@"context"] isEqualToString:@"ITHost"] && [s[@"tab"] isEqualToString:@"Methods"] && [s[@"search"] isEqualToString:@"itTestAction:"] &&
              ITRowsContain(s, @"itTestAction:", nil), @"its runs row opens the method");

        s = DYI(@"menuPick", @{@"on": @YES});
        check([s[@"menuPickArmed"] boolValue] && [s[@"status"] hasPrefix:@"choose a menu item"], @"pick mode on");
        [hostMenu performActionForItemAtIndex:0];
    }];
    [self step:0.3 do:^{
        NSDictionary *s = DYI(@"tab", @{@"name": @"Properties"});
        check(gITMenuRuns == 1, @"picking an item doesn't run its action");
        check(![s[@"menuPickArmed"] boolValue] && [s[@"targetClass"] isEqualToString:@"NSMenuItem"] &&
              [ITRow(s, @"title")[@"right"] isEqualToString:@"\"Test Action\""] && [s[@"status"] hasPrefix:@"picked"],
              [NSString stringWithFormat:@"the picked item opens: %@", s[@"status"]]);
        DYI(@"menuPick", @{@"on": @YES});
        NSEvent *key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
                                   modifierFlags:NSEventModifierFlagCommand | NSEventModifierFlagShift timestamp:0
                                    windowNumber:self.window.windowNumber context:nil characters:@"T" charactersIgnoringModifiers:@"t"
                                       isARepeat:NO keyCode:17];
        BOOL handled = [NSApp.mainMenu performKeyEquivalent:key];
        check(handled && gITMenuRuns == 1, @"its shortcut picks it too, without running it");
    }];
    [self step:0.3 do:^{
        NSDictionary *s = DYI(@"tab", @{@"name": @"Properties"});
        check(![s[@"menuPickArmed"] boolValue] && [ITRow(s, @"title")[@"right"] isEqualToString:@"\"Test Action\""], @"... and opens it");
        DYI(@"menuPick", @{@"on": @YES});
        ITPostKey(self.window, @"\x1b", 53);
    }];
    [self step:0.3 do:^{
        NSDictionary *s = DYI(@"state", nil);
        s = DYI(@"tab", @{@"name": @"Properties"});
        check(![s[@"menuPickArmed"] boolValue] && [s[@"status"] isEqualToString:@"menu pick cancelled"], @"esc cancels");
        [hostMenu performActionForItemAtIndex:0];
        [hostMenu performActionForItemAtIndex:1];
        check(gITMenuRuns == 2 && gITTargetedRuns == 1, @"after picking, menu items work again");
        DYI(@"menuBar", nil);
        DYI(@"navigate", @{@"contains": @"\"Host\""});
        DYI(@"navigate", @{@"contains": @"\"Targeted\""});
        s = DYI(@"tab", @{@"name": @"Properties"});
        check([ITRow(s, @"keyEquivalent")[@"right"] isEqualToString:@"⌥↩"] && [ITRow(s, @"target")[@"right"] hasPrefix:@"<ITHost 0x"] &&
              ![ITRow(s, @"sent to")[@"right"] containsString:@"responder chain"], @"an item with a target: ⌥↩, sent to its target");
        DYI(@"menuBar", nil);
        DYI(@"navigate", @{@"contains": @"\"Host\""});
        DYI(@"navigate", @{@"contains": @"\"No Responder\""});
        s = DYI(@"tab", @{@"name": @"Properties"});
        check([ITRow(s, @"sent to")[@"right"] hasPrefix:@"nobody responds"] && !ITRow(s, @"runs"), @"an action nobody implements");
    }];
    [self step:0.1 do:^{
        printf("== dw inspect ==\n");
        NSDictionary *s = DYI(@"command", @{@"code": @1, @"request": @7});
        NSArray *answers = s[@"answers"];
        check([answers.firstObject hasPrefix:@"A 7 opened "], [NSString stringWithFormat:@"open: %@", answers.firstObject]);
        s = DYI(@"state", nil);
        check([s[@"panelVisible"] boolValue], @"the panel is open");
        s = DYI(@"tab", @{@"name": @"Hierarchy"});
        check([s[@"targetClass"] hasSuffix:@"NSApplication"] && ITRowsContain(s, @"NSWindow", @"\"Inspector Test\" · level 0") &&
              !ITRowsContain(s, @"DYIOverlayPanel", nil) && !ITRowsContain(s, @"NSKVONotifying_", nil) && ITRowsContain(s, @"NSMenu", @"main menu"),
              @"on the app: its windows (not Inspector's own, KVO classes unwrapped) and its menu bar");
        s = DYI(@"tab", @{@"name": @"Properties"});
        check([ITRow(s, @"activationPolicy")[@"right"] hasPrefix:@"accessory"], [NSString stringWithFormat:@"activationPolicy: %@", ITRow(s, @"activationPolicy")[@"right"]]);
        NSStatusItem *item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        item.autosaveName = @"local.dynject.inspector.testitem";
        item.button.title = @"IT";
        s = DYI(@"command", @{@"code": @4, @"request": @8});
        answers = s[@"answers"];
        NSString *all = [answers componentsJoinedByString:@"\n"];
        check([all containsString:@"A 8 S local.dynject.inspector.testitem visible=YES"] && [all containsString:@"statusitem=local.dynject.inspector.testitem"],
              @"tree: the status item by its autosave name, and its window marked with it");
        [NSStatusBar.systemStatusBar removeStatusItem:item];
        check([all containsString:@"A 8 W "] && [all containsString:@" NSWindow level=0 frame="] && ![all containsString:@"NSKVONotifying_"] &&
              ![all containsString:@"DYIOverlayPanel"] && [all containsString:@"A 8 V 1 "] &&
              [all containsString:@"ITLeafView frame="] && [answers.lastObject hasPrefix:@"A 8 end windows="],
              [NSString stringWithFormat:@"tree: %lu lines, windows and views, then end", (unsigned long)answers.count]);
        s = DYI(@"command", @{@"code": @5, @"request": @14});
        all = [s[@"answers"] componentsJoinedByString:@"\n"];
        check([all containsString:@"A 14 W "] && [all containsString:@"A 14 end windows="], @"tree with properties: windows, views, end");
        s = DYI(@"command", @{@"code": @2, @"request": @9});
        check([[s[@"answers"] firstObject] isEqualToString:@"A 9 picking"] && [DYI(@"state", nil)[@"pickActive"] boolValue], @"pick: pick mode on");
        s = DYI(@"command", @{@"code": @3, @"request": @10});
        s = DYI(@"state", nil);
        check(![s[@"pickActive"] boolValue] && ![s[@"panelVisible"] boolValue], @"stop: pick mode off, panel closed");
        DYI(@"setEnabled", @{@"value": @NO});
        s = DYI(@"command", @{@"code": @1, @"request": @11});
        check([[s[@"answers"] firstObject] hasPrefix:@"A 11 refused"], @"switched off: refused");
        DYI(@"setEnabled", @{@"value": @YES});
        // The real channel: the notification for this pid, with the request in its state.
        NSString *name = [NSString stringWithFormat:@"local.dynject.inspector.command.%d", getpid()];
        int token = 0;
        notify_register_check(name.UTF8String, &token);
        notify_set_state(token, 4 | (12ull << 8));
        notify_post(name.UTF8String);
        notify_cancel(token);
    }];
    [self step:0.5 do:^{
        NSArray *answers = DYI(@"command", @{@"code": @0, @"request": @13})[@"answers"];
        BOOL viaNotification = NO;
        for (NSString *a in answers) if ([a hasPrefix:@"A 12 end windows="]) viaNotification = YES;
        check(viaNotification, @"the same through the darwin notification for this pid");
        check([answers.lastObject hasPrefix:@"A 13 refused: unknown command 0"], @"an unknown command is refused");
    }];
    [self step:0.1 do:^{
        printf("== settings and cleanup ==\n");
        DYI(@"setEnabled", @{@"value": @NO});
        NSDictionary *s = DYI(@"pick", nil);
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
