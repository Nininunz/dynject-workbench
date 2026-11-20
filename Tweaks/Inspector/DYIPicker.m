// Inspector: pick mode. A local event monitor (only events this app receives; never a global monitor or an event tap)
// starts it while ⌃⌥⌘ are held, swallows the click that selects and the L / Esc keys while it runs. The outline is
// drawn in a borderless, transparent panel laid over the hovered window: it ignores the mouse, can't become key or
// main, and is ordered out when pick mode ends, so the app's windows keep focus and get every other event.
#import "DYIInternal.h"

#pragma mark - Hit testing

static NSView *DYIDeepestIn(NSView *v, NSPoint windowPoint, int depth) {
    if (!v || depth > 200 || v.isHidden || v.alphaValue < 0.01) return nil;
    NSPoint p = [v convertPoint:windowPoint fromView:nil];
    BOOL inside = [v mouse:p inRect:v.bounds];
    if (!inside && v.clipsToBounds) return nil;
    for (NSView *sub in v.subviews.reverseObjectEnumerator) {
        NSView *hit = DYIDeepestIn(sub, windowPoint, depth + 1);
        if (hit) return hit;
    }
    return inside ? v : nil;
}

NSView *DYIDeepestView(NSWindow *window, NSPoint windowPoint) {
    NSView *root = window.contentView.superview ?: window.contentView;   // the frame view: titlebar views too
    __block NSView *hit = nil;
    DYITry(^{ hit = DYIDeepestIn(root, windowPoint, 0); });
    return hit;
}

static CALayer *DYIDeepestLayerIn(CALayer *layer, CGPoint p, int depth, int *budget) {
    if (!layer || depth > 64 || --*budget < 0 || layer.hidden || layer.opacity < 0.01f) return nil;
    BOOL inside = CGRectContainsPoint(layer.bounds, p);
    if (!inside && layer.masksToBounds) return nil;
    // Front to back: higher zPosition first, then later siblings.
    NSArray<CALayer *> *subs = [layer.sublayers sortedArrayWithOptions:NSSortStable
                                                       usingComparator:^NSComparisonResult(CALayer *a, CALayer *b) {
        return a.zPosition < b.zPosition ? NSOrderedAscending : a.zPosition > b.zPosition ? NSOrderedDescending : NSOrderedSame;
    }];
    for (CALayer *sub in subs.reverseObjectEnumerator) {
        CALayer *hit = DYIDeepestLayerIn(sub, [layer convertPoint:p toLayer:sub], depth + 1, budget);
        if (hit) return hit;
    }
    return inside ? layer : nil;
}

CALayer *DYIDeepestLayer(NSView *view, NSPoint windowPoint, NSView **outHost) {
    NSView *host = view;
    while (host && !host.layer) host = host.superview;
    if (outHost) *outHost = host;
    if (!host) return nil;
    // A layer-backed view's layer uses the view's own coordinates (flipped views included).
    NSPoint p = [host convertPoint:windowPoint fromView:nil];
    __block CALayer *hit = nil;
    DYITry(^{
        int budget = 20000;
        hit = DYIDeepestLayerIn(host.layer, p, 0, &budget);
    });
    return hit ?: host.layer;
}

NSRect DYILayerRectInWindow(CALayer *layer, NSView *host) {
    if (!layer || !host.layer) return NSZeroRect;
    __block NSRect r = NSZeroRect;
    DYITry(^{
        CGRect inRoot = [layer convertRect:layer.bounds toLayer:host.layer];
        r = [host convertRect:inRoot toView:nil];
    });
    return r;
}

#pragma mark - Overlay

@interface DYIOverlayPanel : NSPanel
@end
@implementation DYIOverlayPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface DYIOverlayView : NSView
@property (nonatomic) NSRect highlight;   // window (= overlay) coordinates; NSZeroRect: nothing
@property (nonatomic, copy) NSString *label;
@property (nonatomic) BOOL layerMode;
@end

@implementation DYIOverlayView

- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSColor *tint = self.layerMode ? [NSColor systemOrangeColor] : [NSColor systemBlueColor];
    // Hint along the top edge.
    NSString *hint = self.layerMode ? @"layers · L views · esc cancel · click inspect"
                                    : @"views · L layers · esc cancel · click inspect";
    [self drawText:hint at:NSMakePoint(NSMaxX(self.bounds), 8) below:NO tint:tint small:YES];   // bottom right
    if (NSEqualRects(self.highlight, NSZeroRect)) return;
    NSRect r = NSInsetRect(NSIntegralRectWithOptions(self.highlight, NSAlignAllEdgesNearest), 0.5, 0.5);
    if (r.size.width < 1) r.size.width = 1;
    if (r.size.height < 1) r.size.height = 1;
    [[tint colorWithAlphaComponent:0.16] setFill];
    NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
    NSBezierPath *path = [NSBezierPath bezierPathWithRect:r];
    path.lineWidth = 1.5;
    [tint setStroke];
    [path stroke];
    if (self.label.length) {
        // Below the outline if there's room, else above, else inside the top.
        BOOL below = NSMinY(r) > 70;
        NSPoint at = below ? NSMakePoint(NSMinX(r), NSMinY(r) - 4) : NSMakePoint(NSMinX(r), NSMaxY(r) + 4);
        if (!below && NSMaxY(r) + 70 > NSMaxY(self.bounds)) { at = NSMakePoint(NSMinX(r) + 4, NSMaxY(r) - 4); below = YES; }
        [self drawText:self.label at:at below:below tint:tint small:NO];
    }
}

/// Draws a label box whose top-left (below = YES) or bottom-left corner is at `at`, kept inside the view.
- (void)drawText:(NSString *)text at:(NSPoint)at below:(BOOL)below tint:(NSColor *)tint small:(BOOL)small {
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:small ? 10 : 11 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName: [NSColor whiteColor]};
    NSSize size = [text boundingRectWithSize:NSMakeSize(MAX(NSWidth(self.bounds) - 24, 100), 400)
                                     options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs].size;
    NSRect box = NSMakeRect(at.x, below ? at.y - size.height - 8 : at.y, ceil(size.width) + 12, ceil(size.height) + 8);
    box.origin.x = MIN(MAX(box.origin.x, 4), NSMaxX(self.bounds) - NSWidth(box) - 4);
    box.origin.y = MIN(MAX(box.origin.y, 4), NSMaxY(self.bounds) - NSHeight(box) - 4);
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:box xRadius:5 yRadius:5];
    [[NSColor colorWithWhite:0.08 alpha:small ? 0.6 : 0.85] setFill];
    [bg fill];
    [[tint colorWithAlphaComponent:0.9] setStroke];
    bg.lineWidth = 1;
    [bg stroke];
    [text drawWithRect:NSMakeRect(NSMinX(box) + 6, NSMinY(box) + 4, size.width + 1, size.height)
               options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs];
}

@end

#pragma mark - Picker

@interface DYIPicker ()
@property (nonatomic, readwrite, getter=isActive) BOOL active;
@property (nonatomic, readwrite) BOOL layerMode;
@property (nonatomic, readwrite) BOOL holdMode;
@property (nonatomic, readwrite, strong, nullable) NSView *hoveredView;
@property (nonatomic, readwrite, strong, nullable) CALayer *hoveredLayer;
@property (nonatomic, readwrite, copy) NSString *labelText;
@property (nonatomic, strong, nullable) DYIOverlayPanel *overlay;
@property (nonatomic, strong, nullable) DYIOverlayView *overlayView;
@property (nonatomic, weak, nullable) NSWindow *hoveredWindow;
@property (nonatomic, strong, nullable) NSTimer *timer;
@property (nonatomic, strong, nullable) id monitor;
@property (nonatomic) BOOL swallowMouseUp;
@property (nonatomic) NSPoint lastPoint;
@end

@implementation DYIPicker

+ (instancetype)shared {
    static DYIPicker *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [DYIPicker new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _labelText = @"";
#ifdef DYI_TEST
        _testCursor = NSMakePoint(NAN, NAN);
#endif
        _lastPoint = NSMakePoint(NAN, NAN);
    }
    return self;
}

- (NSWindow *)overlayWindow { return self.overlay; }

- (void)installMonitor {
    if (self.monitor) return;
    NSEventMask mask = NSEventMaskFlagsChanged | NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged |
                       NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskRightMouseDown |
                       NSEventMaskRightMouseUp | NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp |
                       NSEventMaskKeyDown | NSEventMaskKeyUp;
    __weak DYIPicker *weakSelf = self;
    self.monitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *event) {
        DYIPicker *me = weakSelf;
        if (!me) return event;
        __block NSEvent *result = event;
        NSString *err = DYITry(^{ result = [me handleEvent:event]; });
        if (err) DYILog(@"event handling failed: %@", err);
        return result;
    }];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appResigned:)
                                                 name:NSApplicationDidResignActiveNotification object:nil];
}

- (void)appResigned:(NSNotification *)note {
    (void)note;
    if (self.active) [self cancel];
}

static NSPoint DYIScreenPointOfEvent(NSEvent *event) {
    if (event.window) return [event.window convertPointToScreen:event.locationInWindow];
    return event.locationInWindow;   // no window: already screen coordinates
}

- (BOOL)isOwnWindow:(NSWindow *)w {
    return w && (w == self.overlay || w == [DYIPanelController shared].panel);
}

- (nullable NSEvent *)handleEvent:(NSEvent *)event {
    NSEventType type = event.type;
    if (type == NSEventTypeLeftMouseUp && self.swallowMouseUp) {   // the release of the click that selected
        self.swallowMouseUp = NO;
        return nil;
    }
    if (type == NSEventTypeFlagsChanged) {
        NSEventModifierFlags want = NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;
        BOOL held = (event.modifierFlags & want) == want;
        if (held && !self.active && DYIHotkeyEnabled()) [self beginWithHold:YES];
        else if (!held && self.active && self.holdMode) [self cancel];   // released without clicking
        return event;
    }
    if (!self.active) return event;
    switch (type) {
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
            [self updateForScreenPoint:DYIScreenPointOfEvent(event)];
            return event;
        case NSEventTypeLeftMouseDown:
            if ([event.window isEqual:[DYIPanelController shared].panel]) {   // clicking the inspector ends picking
                [self cancel];
                return event;
            }
            [self updateForScreenPoint:DYIScreenPointOfEvent(event)];
            self.swallowMouseUp = YES;
            [self selectCurrent];
            return nil;
        case NSEventTypeRightMouseDown: case NSEventTypeRightMouseUp:
        case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseUp:
            return nil;   // no context menus or other clicks reach the app while picking
        case NSEventTypeKeyDown:
            if (event.keyCode == 53) { [self cancel]; return nil; }   // esc
            if ([event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"l"]) {
                if (!event.isARepeat) [self toggleLayerMode];
                return nil;
            }
            if (self.holdMode) [self cancel];   // ⌃⌥⌘ plus another key: a shortcut, not a pick
            return event;
        case NSEventTypeKeyUp:
            if (event.keyCode == 53 || [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"l"]) return nil;
            return event;
        default:
            return event;
    }
}

- (void)beginWithHold:(BOOL)hold {
    if (!DYIEnabled()) return;
    if (self.active) { self.holdMode = self.holdMode && hold; return; }
    self.active = YES;
    self.holdMode = hold;
    self.layerMode = NO;
    self.lastPoint = NSMakePoint(NAN, NAN);
    if (!self.overlay) [self makeOverlay];
    self.timer = [NSTimer timerWithTimeInterval:1.0 / 30 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self tick:nil];
    DYILog(@"pick mode on (%@)", hold ? @"hold" : @"toggle");
}

- (void)cancel {
    if (!self.active && !self.overlay.isVisible) return;
    self.active = NO;
    self.holdMode = NO;
    self.layerMode = NO;
    [self.timer invalidate];
    self.timer = nil;
    [self.overlay orderOut:nil];
    self.hoveredView = nil;
    self.hoveredLayer = nil;
    self.hoveredWindow = nil;
    self.labelText = @"";
    self.overlayView.highlight = NSZeroRect;
    self.overlayView.label = @"";
}

- (void)toggleLayerMode {
    if (!self.active) return;
    self.layerMode = !self.layerMode;
    self.lastPoint = NSMakePoint(NAN, NAN);
    [self tick:nil];
}

- (void)selectCurrent {
    if (!self.active) return;
    id target = self.layerMode ? (id)self.hoveredLayer : (id)self.hoveredView;
    [self cancel];
    if (target) [[DYIPanelController shared] inspectObject:target];
}

- (void)makeOverlay {
    DYIOverlayPanel *o = [[DYIOverlayPanel alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100)
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:YES];
    o.opaque = NO;
    o.backgroundColor = [NSColor clearColor];
    o.hasShadow = NO;
    o.ignoresMouseEvents = YES;
    o.releasedWhenClosed = NO;
    o.hidesOnDeactivate = NO;
    o.floatingPanel = YES;
    o.becomesKeyOnlyIfNeeded = YES;
    o.level = NSPopUpMenuWindowLevel;
    o.animationBehavior = NSWindowAnimationBehaviorNone;
    o.collectionBehavior = NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle |
                           NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorMoveToActiveSpace;
    o.excludedFromWindowsMenu = YES;
    o.title = @"Inspector Overlay";
    DYIOverlayView *v = [[DYIOverlayView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    o.contentView = v;
    self.overlay = o;
    self.overlayView = v;
}

- (void)tick:(NSTimer *)timer {
    (void)timer;
    if (!self.active) return;
    NSPoint pt = [NSEvent mouseLocation];
#ifdef DYI_TEST
    if (!isnan(self.testCursor.x)) pt = self.testCursor;
#endif
    if (NSEqualPoints(pt, self.lastPoint) && self.hoveredWindow) return;
    [self updateForScreenPoint:pt];
}

/// The topmost window of this app at a screen point, skipping the overlay and the inspector panel. nil when another
/// app's window (or nothing) is on top there.
- (nullable NSWindow *)windowAtScreenPoint:(NSPoint)pt {
    NSInteger below = 0;
    for (int i = 0; i < 8; i++) {
        NSInteger num = [NSWindow windowNumberAtPoint:pt belowWindowWithWindowNumber:below];
        if (num <= 0) return nil;
        NSWindow *w = [NSApp windowWithWindowNumber:num];
        if (!w) return nil;
        if (![self isOwnWindow:w]) return w;
        below = num;
    }
    return nil;
}

- (void)updateForScreenPoint:(NSPoint)pt {
    if (!self.active) return;
    self.lastPoint = pt;
    NSWindow *w = [self windowAtScreenPoint:pt];
    if (!w || !w.isVisible) {
        self.hoveredWindow = nil;
        self.hoveredView = nil;
        self.hoveredLayer = nil;
        self.labelText = @"";
        [self.overlay orderOut:nil];
        return;
    }
    NSPoint wp = [w convertPointFromScreen:pt];
    NSView *view = DYIDeepestView(w, wp);
    NSRect rect = NSZeroRect;
    NSString *label = @"";
    CALayer *layer = nil;
    if (view && self.layerMode) {
        NSView *host = nil;
        layer = DYIDeepestLayer(view, wp, &host);
        if (layer) {
            rect = DYILayerRectInWindow(layer, host);
            label = [self labelForLayer:layer];
        }
    } else if (view) {
        rect = [view convertRect:view.bounds toView:nil];
        label = [self labelForView:view frame:rect];
    }
    self.hoveredWindow = w;
    self.hoveredView = view;
    self.hoveredLayer = layer;
    self.labelText = label;
    // Lay the overlay over the window (same frame, so window and overlay coordinates match).
    if (!NSEqualRects(self.overlay.frame, w.frame)) [self.overlay setFrame:w.frame display:NO];
    self.overlayView.highlight = rect;
    self.overlayView.label = label;
    self.overlayView.layerMode = self.layerMode;
    self.overlayView.needsDisplay = YES;
    if (!self.overlay.isVisible) [self.overlay orderFrontRegardless];
}

- (NSString *)labelForView:(NSView *)view frame:(NSRect)rect {
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@  %@", NSStringFromClass(object_getClass(view)), NSStringFromRect(rect)];
    __block NSString *axID = nil, *role = nil;
    DYITry(^{ axID = view.accessibilityIdentifier; role = view.accessibilityRole; });
    NSMutableArray *extra = [NSMutableArray array];
    if (axID.length) [extra addObject:[@"id " stringByAppendingString:axID]];
    if (role.length) [extra addObject:[@"role " stringByAppendingString:role]];
    if (view.layer) [extra addObject:[@"layer " stringByAppendingString:NSStringFromClass(object_getClass(view.layer))]];
    if (extra.count) [s appendFormat:@"\n%@", [extra componentsJoinedByString:@" · "]];
    return s;
}

- (NSString *)labelForLayer:(CALayer *)layer {
    __block NSString *s = NSStringFromClass(object_getClass(layer));
    DYITry(^{
        s = [NSString stringWithFormat:@"%@\nbounds %@ · cornerRadius %g", s, NSStringFromRect(layer.bounds), layer.cornerRadius];
    });
    return s;
}

@end
