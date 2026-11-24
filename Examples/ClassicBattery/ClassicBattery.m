// ClassicBattery: the menu bar battery as in older macOS: the percentage beside the battery, not inside it.
//
// Two styles (setting `style`): "classic" draws the older battery itself (a thin outline whose fill shows the level,
// a bolt while charging, a plug when held at a limit, yellow in Low Power Mode, red at 10% or less) after the number;
// "apple" keeps macOS's battery and puts the number before it. `showPercent` and `textSize` apply to both, `enabled`
// off gives the battery back to macOS. All of them apply live.
//
// Runs in ControlCenter, which draws the battery item. Each ControlCenter item is an NSHostedViewScene (one per
// display): AppKit shows its `view`, a SwiftUI NSHostingView, in MenuBarAgent's menu bar, and reports that view's size
// so MenuBarAgent can lay the menu bar out.
//
//   1. Which scenes are the battery: ControlCenter makes an MBControlCenterItemAssertionXPC per item; the battery's
//      has systemIdentifier "battery", and its assertionID is the controlCenterItemIDRawValue in the settings of every
//      battery scene. It's made before the scenes.
//   2. The battery scenes' view is replaced by a DYClassicBatteryView, with the SwiftUI view inside it, still getting
//      every click, so the menu and the highlight are macOS's own: invisible in the classic style, at the right end
//      in Apple's. -[NSHostedViewScene setView:] is hooked so a view ControlCenter puts there later is wrapped too.
//   3. The wrapper draws the item and is exactly as wide as it, so MenuBarAgent lays it out like any item; when the
//      width changes (9% → 10%, 99% → 100%, a setting) the scene publishes the new size and MenuBarAgent follows.
//      State comes from IOKit power sources and Low Power Mode, redrawn when they change.
//
//
// The lock screen's battery is drawn by loginwindow (LoginUIKit), not ControlCenter: it asks BatteryUIKit for the
// picture with +[BUIImage batteryImagesForParameters:], whose "Modern Style" parameter picks today's filled pill.
// BatteryUIKit still has the older one (a thin outline with the level fill inside it), so in loginwindow, with the
// classic style, the tweak turns "Modern Style" off and the lock screen gets Apple's own classic battery.
//
//   ./build.sh && dw tweak install . --for com.apple.controlcenter --also com.apple.controlcenter.PreloginSystemBannerRenderer
//   dw respring --only com.apple.controlcenter
//   log stream --predicate 'subsystem == "local.dynject.classicbattery"'
#import <AppKit/AppKit.h>
#import <IOKit/ps/IOPSKeys.h>
#import <IOKit/ps/IOPowerSources.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import "DynjectHook.h"
#import "DynjectTweak.h"

// `./build.sh test` compiles a test copy (-DTWEAK_TEST) for testhost/: it also loads into the test host, and exports
// CBTestSetState and CBTestSetSettings so the host can draw the item in any state, with any settings.
#ifdef TWEAK_TEST
#define TWEAK_ID_C "local.dynject.classicbattery.test"
#define TWEAK_APPS "com.apple.controlcenter", "com.apple.loginwindow", "local.dynject.classicbattery.testhost"
#else
#define TWEAK_ID_C "local.dynject.classicbattery"
#define TWEAK_APPS "com.apple.controlcenter", "com.apple.loginwindow"
#endif
#define TWEAK_ID @TWEAK_ID_C

// The classic item, in points (older macOS's battery is about 2.2 times as wide as it is tall).
static const CGFloat kBodyWidth = 25, kBodyHeight = 11.5, kBodyRadius = 3, kNubWidth = 1.5, kNubHeight = 4;
static const CGFloat kInset = 1.5;   // between the outline and the fill
static const CGFloat kGap = 4;       // between the number and the battery
static const CGFloat kMargin = 1;    // at either end of the item
static const CGFloat kNativeWidth = 26;   // macOS's battery without its percentage, if its view can't say

static DHHook *sAssertionInit, *sSetView, *sBatteryImages, *sBatteryImageSize;
static BOOL gMenuBar;   // this process draws the menu bar's battery (ControlCenter, or the test host)
static NSString *gBatteryItemID;   // main thread

typedef struct {
    BOOL present;        // there is an internal battery
    double fraction;     // 0…1
    BOOL charging;       // the battery is charging
    BOOL external;       // on AC power (charging or not)
    BOOL lowPower;       // Low Power Mode
} BatteryState;
static BatteryState gState;

typedef struct {
    BOOL on;
    BOOL classic;        // style: draw the older battery (else keep macOS's)
    BOOL showPercent;
    CGFloat textSize;    // default 12: smaller than the menu bar's 13, as in older macOS (capitals ≈ 3/4 the battery)
} Settings;
static Settings gSettings;   // main thread

static Settings ReadSettings(void) {
    Settings s;
    s.on = DTPrefBool(TWEAK_ID, @"enabled", YES);
    s.classic = ![DTPrefString(TWEAK_ID, @"style", @"classic") isEqualToString:@"apple"];
    s.showPercent = DTPrefBool(TWEAK_ID, @"showPercent", YES);
    s.textSize = MIN(MAX(DTPrefDouble(TWEAK_ID, @"textSize", 12), 9), 15);
    return s;
}

static os_log_t Log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create(TWEAK_ID_C, "tweak"); });
    return log;
}

static NSFont *TextFont(void) { return [NSFont menuBarFontOfSize:gSettings.textSize]; }

#pragma mark - Battery state

static BatteryState ReadState(void) {
    BatteryState state = {0};
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    CFArrayRef list = info ? IOPSCopyPowerSourcesList(info) : NULL;
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
        NSDictionary *d = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
        NSNumber *current = d[@kIOPSCurrentCapacityKey], *max = d[@kIOPSMaxCapacityKey];
        if (![d[@kIOPSTypeKey] isEqual:@kIOPSInternalBatteryType] || max.doubleValue <= 0) continue;
        state.present = YES;
        state.fraction = MIN(MAX(current.doubleValue / max.doubleValue, 0), 1);
        state.charging = [d[@kIOPSIsChargingKey] boolValue];
        state.external = [d[@kIOPSPowerSourceStateKey] isEqual:@kIOPSACPowerValue];
        break;
    }
    if (list) CFRelease(list);
    if (info) CFRelease(info);
    state.lowPower = NSProcessInfo.processInfo.isLowPowerModeEnabled;
    return state;
}

static NSString *PercentText(BatteryState state) {
    return [NSString stringWithFormat:@"%.0f%%", round(state.fraction * 100)];
}

#ifdef TWEAK_TEST
/// Test copy only: the state the item draws.
__attribute__((visibility("default"))) void CBTestSetState(double fraction, int charging, int external, int lowPower) {
    gState = (BatteryState){.present = YES, .fraction = fraction, .charging = charging, .external = external,
                            .lowPower = lowPower};
}
/// Test copy only: the settings the item draws with.
__attribute__((visibility("default"))) void CBTestSetSettings(int classic, int showPercent, double textSize) {
    gSettings = (Settings){.on = YES, .classic = classic, .showPercent = showPercent, .textSize = textSize};
}
#endif

#pragma mark - The classic item

/// An SF Symbol drawn in one colour, `height` points tall.
static NSImage *Symbol(NSString *name, CGFloat height, NSColor *color) {
    NSImage *symbol = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!symbol) return nil;
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:height
                                                                                         weight:NSFontWeightBold];
    symbol = [symbol imageWithSymbolConfiguration:config] ?: symbol;
    NSSize size = symbol.size;
    CGFloat scale = height / MAX(size.height, 1);
    size = NSMakeSize(size.width * scale, height);
    return [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [symbol drawInRect:rect];
        [color set];
        NSRectFillUsingOperation(rect, NSCompositingOperationSourceIn);
        return YES;
    }];
}

/// The menu bar's own text and icon colour, measured on macOS 27.2: 92% white on a dark menu bar (pure white looks
/// harsher than the clock and the icons beside it), 85% black on a light one.
static NSColor *MenuBarInk(NSAppearance *appearance) {
    BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
                 isEqualToString:NSAppearanceNameDarkAqua];
    return dark ? [NSColor colorWithWhite:0.92 alpha:1] : [NSColor colorWithWhite:0 alpha:0.85];
}

@interface DYClassicBatteryView : NSView
/// ControlCenter's own view for the battery (SwiftUI), inside this one: invisible, gets the clicks. nil in tests.
@property (strong) NSView *hosted;
@end

/// The width of the number as it is now, and the gap after it; 0 without the percentage.
static CGFloat TextWidth(BatteryState state) {
    if (!gSettings.showPercent) return 0;
    return [PercentText(state) sizeWithAttributes:@{NSFontAttributeName: TextFont()}].width + kGap;
}

@implementation DYClassicBatteryView

/// macOS's battery: as wide as ControlCenter's view wants to be (wider with Control Center's Show Percentage on).
- (CGFloat)nativeWidth {
    CGFloat width = self.hosted ? ceil(self.hosted.fittingSize.width) : 0;
    return width > 0 ? width : kNativeWidth;
}

/// The item's width. Classic: the number, the battery, a point at either end. Apple's: a point, the number, then
/// macOS's battery (whose glyph starts a point in).
- (CGFloat)itemWidth {
    CGFloat text = TextWidth(gState);
    CGFloat width = gSettings.classic ? kMargin + text + kBodyWidth + kNubWidth + kMargin
                                      : (text > 0 ? kMargin + text - 1 : 0) + self.nativeWidth;
    return ceil(width * 2) / 2;
}

// Sized by its content: AppKit reports this to MenuBarAgent, which lays the menu bar out with it.
- (NSSize)intrinsicContentSize { return NSMakeSize(self.itemWidth, NSHeight(self.hosted.frame) ?: 39); }
- (NSSize)fittingSize { return self.intrinsicContentSize; }
- (BOOL)isFlipped { return NO; }

- (NSView *)hitTest:(NSPoint)point {   // every click in the item goes to ControlCenter's own view
    NSPoint p = [self convertPoint:point fromView:self.superview];
    if (!self.hosted || !NSPointInRect(p, self.bounds)) return nil;
    return [self.hosted hitTest:[self.hosted convertPoint:p fromView:self]] ?: self.hosted;
}

- (void)layout {
    [super layout];
    // Classic: ControlCenter's view covers the item, invisible. Apple's: shown at the right end.
    NSRect bounds = self.bounds;
    CGFloat native = MIN(self.nativeWidth, NSWidth(bounds));
    self.hosted.frame = gSettings.classic ? bounds : NSMakeRect(NSMaxX(bounds) - native, 0, native, NSHeight(bounds));
    float opacity = gSettings.classic ? 0 : 1;
    if (self.hosted.layer.opacity != opacity) self.hosted.layer.opacity = opacity;
}
- (BOOL)isOpaque { return NO; }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; self.needsDisplay = YES; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; self.needsDisplay = YES; }

- (NSRect)aligned:(NSRect)rect {
    return [self backingAlignedRect:rect options:NSAlignAllEdgesNearest];
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    BatteryState state = gState;
    if (!state.present) return;
    NSColor *ink = MenuBarInk(self.effectiveAppearance);
    NSRect bounds = self.bounds;
    // Measured (macOS 27.2): the icons beside it (search, Control Center) are centred on the slot's middle; centre the
    // battery there, and the number on the battery.
    CGFloat midY = round(NSMidY(bounds) * 2) / 2;

    if (!gSettings.classic) {   // macOS's battery is at the right end (its glyph starts a point in)
        [self drawPercent:state ink:ink midY:midY before:NSMaxX(bounds) - MIN(self.nativeWidth, NSWidth(bounds)) + 1];
        return;
    }

    // The number and the battery, centred together.
    CGFloat textWidth = TextWidth(state);
    CGFloat contentWidth = textWidth + kBodyWidth + kNubWidth;
    CGFloat bodyX = round((NSMidX(bounds) - contentWidth / 2 + textWidth) * 2) / 2;
    NSRect body = [self aligned:NSMakeRect(bodyX, midY - kBodyHeight / 2, kBodyWidth, kBodyHeight)];
    NSRect nub = [self aligned:NSMakeRect(NSMaxX(body), midY - kNubHeight / 2, kNubWidth, kNubHeight)];

    [NSGraphicsContext saveGraphicsState];
    CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
    CGContextBeginTransparencyLayer(cg, NULL);

    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(body, 0.5, 0.5)
                                                            xRadius:kBodyRadius - 0.5 yRadius:kBodyRadius - 0.5];
    outline.lineWidth = 1;
    [[ink colorWithAlphaComponent:0.4] set];
    [outline stroke];
    NSBezierPath *nubPath = [NSBezierPath bezierPath];
    [nubPath appendBezierPathWithRoundedRect:nub xRadius:kNubWidth / 1.5 yRadius:kNubWidth / 1.5];
    [nubPath fill];

    NSRect inner = NSInsetRect(body, kInset, kInset);
    CGFloat fillWidth = round(NSWidth(inner) * state.fraction * 2) / 2;
    if (state.fraction > 0 && fillWidth < 1.5) fillWidth = 1.5;
    NSColor *fillColor = ink;
    if (state.lowPower) fillColor = NSColor.systemYellowColor;
    else if (!state.external && state.fraction <= 0.10) fillColor = NSColor.systemRedColor;
    [fillColor set];
    CGFloat innerRadius = kBodyRadius - kInset;
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(inner), NSMinY(inner), fillWidth, NSHeight(inner))
                                     xRadius:innerRadius yRadius:innerRadius] fill];

    // Charging: a bolt; on power but not charging (held at a limit): a plug. Each with a cut-out edge so it reads
    // over the fill.
    NSString *badge = state.charging ? @"bolt.fill" : state.external ? @"powerplug.portrait.fill" : nil;
    if (badge) {
        CGFloat height = state.charging ? kBodyHeight + 1.5 : kBodyHeight - 2.5;
        NSImage *image = Symbol(badge, height, ink);
        NSImage *cut = Symbol(badge, height, NSColor.blackColor);
        if (image && cut) {
            NSRect r = NSMakeRect(NSMidX(body) - image.size.width / 2, midY - height / 2, image.size.width, height);
            for (int dx = -1; dx <= 1; dx++)
                for (int dy = -1; dy <= 1; dy++)
                    [cut drawInRect:NSOffsetRect(r, dx * 1.25, dy * 1.25) fromRect:NSZeroRect
                          operation:NSCompositingOperationDestinationOut fraction:1];
            [image drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        }
    }
    CGContextEndTransparencyLayer(cg);
    [NSGraphicsContext restoreGraphicsState];

    [self drawPercent:state ink:ink midY:midY before:NSMinX(body)];
}

/// The number, right-aligned `kGap` before `x`, its cap height centred on the battery.
- (void)drawPercent:(BatteryState)state ink:(NSColor *)ink midY:(CGFloat)midY before:(CGFloat)x {
    if (!gSettings.showPercent) return;
    NSFont *font = TextFont();
    NSDictionary *attributes = @{NSFontAttributeName: font, NSForegroundColorAttributeName: ink};
    NSString *text = PercentText(state);
    NSSize size = [text sizeWithAttributes:attributes];
    CGFloat baseline = round((midY - font.capHeight / 2) * 2) / 2;
    [text drawAtPoint:NSMakePoint(x - kGap - size.width, baseline + font.descender) withAttributes:attributes];
}

@end

#pragma mark - Which scenes are the battery

static id Call(id object, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    return [object respondsToSelector:sel] ? ((id (*)(id, SEL))objc_msgSend)(object, sel) : nil;
}

static id CBAssertionInit(id self, SEL _cmd, id ident, NSInteger behavior, BOOL primary, BOOL springLoaded,
                          BOOL canDrop, id highlight, NSInteger sortOrder, id persistence, id displayable, id system,
                          id token) {
    self = DH_CALL_ORIG(sAssertionInit,
                        id (*)(id, SEL, id, NSInteger, BOOL, BOOL, BOOL, id, NSInteger, id, id, id, id), self, _cmd,
                        ident, behavior, primary, springLoaded, canDrop, highlight, sortOrder, persistence, displayable,
                        system, token);
    if ([system isEqual:@"battery"]) {
        NSString *itemID = [Call(self, @"assertionID") copy];
        void (^set)(void) = ^{
            if (![gBatteryItemID isEqual:itemID]) os_log(Log(), "battery item %{public}@", itemID);
            gBatteryItemID = itemID;
        };
        if ([NSThread isMainThread]) set(); else dispatch_async(dispatch_get_main_queue(), set);
    }
    return self;
}

static BOOL IsBatteryScene(id scene) {
    if (!gBatteryItemID) return NO;
    id uuid = Call(Call(Call(scene, @"_FBSScene"), @"settings"), @"controlCenterItemIDRawValue");
    return [uuid isKindOfClass:[NSUUID class]] && [[uuid UUIDString] isEqualToString:gBatteryItemID];
}

#pragma mark - The wrapper

static DYClassicBatteryView *Wrapper(NSView *hosted) {
    DYClassicBatteryView *wrapper = [[DYClassicBatteryView alloc] initWithFrame:hosted.frame];
    wrapper.wantsLayer = YES;
    wrapper.hosted = hosted;
    return wrapper;
}

/// After the wrapper became the scene's view: the SwiftUI view goes inside it (laid out by the wrapper), and the scene
/// publishes the wrapper's size.
static void Adopt(id scene, DYClassicBatteryView *wrapper) {
    NSView *hosted = wrapper.hosted;
    [wrapper addSubview:hosted];
    hosted.wantsLayer = YES;
    hosted.layer.opacity = gSettings.classic ? 0 : 1;
    [wrapper setFrameSize:wrapper.intrinsicContentSize];
    ((void (*)(id, SEL))objc_msgSend)(scene, NSSelectorFromString(@"viewHierarchyDidChange"));
}

static void CBSetView(id self, SEL _cmd, NSView *view) {
    if (!view || !gSettings.on || [view isKindOfClass:[DYClassicBatteryView class]] || !IsBatteryScene(self)) {
        DH_CALL_ORIG(sSetView, void (*)(id, SEL, NSView *), self, _cmd, view);
        return;
    }
    DYClassicBatteryView *wrapper = Wrapper(view);
    DH_CALL_ORIG(sSetView, void (*)(id, SEL, NSView *), self, _cmd, wrapper);
    Adopt(self, wrapper);
    os_log(Log(), "wrapped a new battery view");
}

static NSArray *BatteryScenes(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (id scene in (NSSet *)Call(NSApp, @"connectedScenes"))
        if (IsBatteryScene(scene)) [out addObject:scene];
    return out;
}

/// Gives a battery scene ControlCenter's own view back (the tweak turned off).
static void Unwrap(id scene, DYClassicBatteryView *wrapper) {
    NSView *hosted = wrapper.hosted;
    [hosted removeFromSuperview];
    hosted.layer.opacity = 1;
    hosted.frame = (NSRect){NSZeroPoint, hosted.fittingSize};
    ((void (*)(id, SEL, id))objc_msgSend)(scene, NSSelectorFromString(@"setView:"), hosted);   // passes through: off
    ((void (*)(id, SEL))objc_msgSend)(scene, NSSelectorFromString(@"viewHierarchyDidChange"));
}

/// Wraps the battery scenes that aren't yet (they were set up before the hook, or before the battery's ID was known),
/// or unwraps them when the tweak is off, and brings every wrapper up to date with the state and the settings:
/// laid out, redrawn, and resized when its width changed.
static void Refresh(NSString *why) {
    gState = ReadState();
    NSArray *scenes = BatteryScenes();
    for (id scene in scenes) {
        NSView *view = Call(scene, @"view");
        if (!view) continue;
        if (!gSettings.on) {
            if ([view isKindOfClass:[DYClassicBatteryView class]]) Unwrap(scene, (DYClassicBatteryView *)view);
            continue;
        }
        if (![view isKindOfClass:[DYClassicBatteryView class]]) {
            DYClassicBatteryView *wrapper = Wrapper(view);
            ((void (*)(id, SEL, id))objc_msgSend)(scene, NSSelectorFromString(@"setView:"), wrapper);   // passes through
            Adopt(scene, wrapper);
            continue;
        }
        DYClassicBatteryView *wrapper = (DYClassicBatteryView *)view;
        NSSize size = wrapper.intrinsicContentSize;
        if (!NSEqualSizes(wrapper.frame.size, size)) {
            [wrapper invalidateIntrinsicContentSize];
            [wrapper setFrameSize:size];
            ((void (*)(id, SEL))objc_msgSend)(scene, NSSelectorFromString(@"viewHierarchyDidChange"));
        }
        wrapper.needsLayout = YES;
        wrapper.needsDisplay = YES;
    }
    os_log(Log(), "%{public}@: %lu battery scenes, %{public}@ charging=%d external=%d lowPower=%d; on=%d classic=%d "
           "percent=%d text %g", why, (unsigned long)scenes.count, PercentText(gState), gState.charging, gState.external,
           gState.lowPower, gSettings.on, gSettings.classic, gSettings.showPercent, gSettings.textSize);
}

#pragma mark - The lock screen (loginwindow)

/// BatteryUIKit's parameters with "Modern Style" off while the tweak draws the classic battery; as they are otherwise.
static id LockScreenParameters(id params) {
    Settings settings = gSettings;
    if (!settings.on || !settings.classic || ![params isKindOfClass:[NSDictionary class]]) return params;
    id modern = ((NSDictionary *)params)[@"Modern Style"];
    if (![modern respondsToSelector:@selector(boolValue)] || ![modern boolValue]) return params;
    NSMutableDictionary *legacy = [params mutableCopy];
    legacy[@"Modern Style"] = @NO;
    return legacy;
}

static id CBBatteryImages(id self, SEL _cmd, id params) {
    return DH_CALL_ORIG(sBatteryImages, id (*)(id, SEL, id), self, _cmd, LockScreenParameters(params));
}

static CGSize CBBatteryImageSize(id self, SEL _cmd, id params) {
    return DH_CALL_ORIG(sBatteryImageSize, CGSize (*)(id, SEL, id), self, _cmd, LockScreenParameters(params));
}

/// loginwindow loads BatteryUIKit only when it first draws the battery: load it now so BUIImage can be hooked.
static void HookLockScreen(void) {
    dlopen("/System/Library/PrivateFrameworks/BatteryUIKit.framework/Versions/A/BatteryUIKit", RTLD_NOW);
    Class images = NSClassFromString(@"BUIImage");
    if (!images) { os_log(Log(), "lock screen: no BUIImage"); return; }
    sBatteryImages = DHHookMessage(object_getClass(images), NSSelectorFromString(@"batteryImagesForParameters:"),
                                   (IMP)CBBatteryImages, NULL);
    sBatteryImageSize = DHHookMessage(object_getClass(images), NSSelectorFromString(@"imageSizeForParameters:"),
                                      (IMP)CBBatteryImageSize, NULL);
    os_log(Log(), "lock screen: hooks images %d size %d", sBatteryImages != NULL, sBatteryImageSize != NULL);
}

static void PowerChanged(void *context) {
    (void)context;
    Refresh(@"power changed");
}

DH_CTOR(TWEAK_ID_C, TWEAK_APPS) {
    DH_REQUIRE_SYSTEM("27.0");
    gSettings = ReadSettings();
    DTPrefObserve(TWEAK_ID, dispatch_get_main_queue(), ^{
        gSettings = ReadSettings();
        if (gMenuBar) Refresh(@"settings");
    });
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    BOOL test = [bundleID hasSuffix:@".testhost"];
    if (test || [bundleID isEqualToString:@"com.apple.loginwindow"]) HookLockScreen();
    if (!test && ![bundleID isEqualToString:@"com.apple.controlcenter"]) return;   // the rest is the menu bar's

    gMenuBar = YES;
    gState = ReadState();
    DHGroup *group = DHGroupCreate("main");
    SEL init = NSSelectorFromString(@"initWithID:behavior:isPrimary:isSpringLoaded:canDropOnBentoBox:encodedHighlight:"
                                    @"sortOrder:persistenceID:displayableID:systemIdentifier:accessibilityToken:");
    sAssertionInit = DHHookMessage(NSClassFromString(@"MBControlCenterItemAssertionXPC"), init, (IMP)CBAssertionInit, group);
    sSetView = DHHookMessage(NSClassFromString(@"NSHostedViewScene"), NSSelectorFromString(@"setView:"), (IMP)CBSetView,
                             group);
    os_log(Log(), "loaded: %{public}@, hooks assertion %d setView %d", PercentText(gState), sAssertionInit != NULL,
           sSetView != NULL);
    CFRunLoopSourceRef source = IOPSNotificationCreateRunLoopSource(PowerChanged, NULL);
    if (source) { CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes); CFRelease(source); }
    [[NSNotificationCenter defaultCenter] addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *note) { (void)note; Refresh(@"low power"); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Refresh(@"at 2 s"); });
}
