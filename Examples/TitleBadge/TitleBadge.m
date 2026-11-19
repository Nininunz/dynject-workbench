// Title Badge — proof-of-concept Dynject tweak for the Workbench tweak format.
//
// Adds a small badge to the trailing side of every titled window, using only public AppKit API
// (NSTitlebarAccessoryViewController): no swizzling, nothing the host app depends on.
// Settings come from Dynject Workbench through DynjectTweak.h and update live.
#import <AppKit/AppKit.h>
#import <os/log.h>
#import "DynjectTweak.h"

#define TB_ID @"local.dynject.titlebadge"
static NSString *const kTBViewID = @"local.dynject.titlebadge.badge";
/// Result of the last settings read. Window events only trigger a re-apply while the badge is on,
/// so a disabled tweak costs nothing per window update.
static BOOL gTBEnabled = YES;

static os_log_t TBLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("local.dynject.titlebadge", "tweak"); });
    return log;
}

static NSColor *TBColor(NSString *hex) {
    if (![hex hasPrefix:@"#"] || (hex.length != 7 && hex.length != 9)) return [NSColor controlAccentColor];
    unsigned long long v = 0;
    [[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexLongLong:&v];
    BOOL alpha = hex.length == 9;
    CGFloat r = ((v >> (alpha ? 24 : 16)) & 0xFF) / 255.0;
    CGFloat g = ((v >> (alpha ? 16 : 8)) & 0xFF) / 255.0;
    CGFloat b = ((v >> (alpha ? 8 : 0)) & 0xFF) / 255.0;
    CGFloat a = alpha ? (v & 0xFF) / 255.0 : 1.0;
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a];
}

static void TBApplyToWindow(NSWindow *window, BOOL enabled, NSString *text, NSColor *color, NSString *style, double fontSize) {
    if (!(window.styleMask & NSWindowStyleMaskTitled) || [window isKindOfClass:[NSPanel class]]) return;

    NSTitlebarAccessoryViewController *existing = nil;
    for (NSTitlebarAccessoryViewController *vc in window.titlebarAccessoryViewControllers) {
        if ([vc.view.identifier isEqualToString:kTBViewID]) { existing = vc; break; }
    }
    if (!enabled) {
        if (existing) {
            NSUInteger i = [window.titlebarAccessoryViewControllers indexOfObject:existing];
            if (i != NSNotFound) [window removeTitlebarAccessoryViewControllerAtIndex:(NSInteger)i];
        }
        return;
    }

    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:fontSize weight:NSFontWeightSemibold];
    [label sizeToFit];
    CGFloat padX = [style isEqualToString:@"plain"] ? 2 : 7, h = ceil(label.frame.size.height) + 4;
    NSView *badge = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, ceil(label.frame.size.width) + padX * 2, h)];
    badge.wantsLayer = YES;
    badge.layer.cornerRadius = h / 2;
    if ([style isEqualToString:@"pill"]) {
        badge.layer.backgroundColor = color.CGColor;
        CGFloat lum = 0;
        NSColor *rgb = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        if (rgb) lum = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent;
        label.textColor = lum > 0.6 ? [NSColor blackColor] : [NSColor whiteColor];
    } else if ([style isEqualToString:@"outline"]) {
        badge.layer.borderColor = color.CGColor;
        badge.layer.borderWidth = 1.5;
        label.textColor = color;
    } else {
        label.textColor = color;
    }
    label.frame = NSMakeRect(padX, 2, label.frame.size.width, label.frame.size.height);
    [badge addSubview:label];

    // Container sized to the titlebar; the badge is centred vertically, with a little trailing margin.
    CGFloat barHeight = 28;
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, badge.frame.size.width + 10, barHeight)];
    container.identifier = kTBViewID;
    badge.frame = NSMakeRect(2, floor((barHeight - h) / 2), badge.frame.size.width, h);
    badge.autoresizingMask = NSViewMinYMargin | NSViewMaxYMargin;
    [container addSubview:badge];

    if (existing) {
        existing.view = container;
    } else {
        NSTitlebarAccessoryViewController *vc = [[NSTitlebarAccessoryViewController alloc] init];
        vc.layoutAttribute = NSLayoutAttributeTrailing;
        vc.view = container;
        [window addTitlebarAccessoryViewController:vc];
    }
}

static void TBApplyAll(NSString *reason) {
    if (!NSApp) return;
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    BOOL enabled = DTPrefBool(TB_ID, @"enabled", YES) && ![DTPrefList(TB_ID, @"exclude") containsObject:bundleID];
    NSString *text = DTPrefBool(TB_ID, @"showBundleID", NO) ? bundleID : DTPrefString(TB_ID, @"text", @"Dynject");
    if (text.length == 0) text = @"Dynject";
    NSString *colorHex = DTPrefString(TB_ID, @"color", @"#FF6A00");
    NSString *style = DTPrefString(TB_ID, @"style", @"pill");
    double fontSize = MIN(MAX(DTPrefDouble(TB_ID, @"fontSize", 11), 8), 20);
    NSColor *color = [colorHex isEqualToString:@"auto"] ? [NSColor controlAccentColor] : TBColor(colorHex);
    gTBEnabled = enabled;

    NSUInteger n = 0;
    for (NSWindow *w in NSApp.windows) {
        TBApplyToWindow(w, enabled, text, color, style, fontSize);
        if (w.styleMask & NSWindowStyleMaskTitled) n++;
    }
    os_log(TBLog(), "%{public}@ in %{public}@: enabled=%d text=\"%{public}@\" color=%{public}@ style=%{public}@ size=%.0f windows=%lu",
           reason, bundleID, enabled, text, colorHex, style, fontSize, (unsigned long)n);
}

__attribute__((constructor)) static void TBInit(void) {
    // Runs before main(); NSApp doesn't exist yet, so wait for launch and window events.
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    NSOperationQueue *main = [NSOperationQueue mainQueue];
    // Apps often create windows after this notification (their own launch handler runs later, or
    // windows are restored asynchronously), so apply again shortly afterwards too.
    [nc addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:main
                usingBlock:^(NSNotification *n) {
        (void)n;
        TBApplyAll(@"launch");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TBApplyAll(@"launch+0.5s"); });
    }];
    // Catch windows created later, including in apps that stay in the background (no key/main events).
    for (NSNotificationName name in @[NSWindowDidBecomeKeyNotification, NSWindowDidBecomeMainNotification,
                                      NSWindowDidUpdateNotification]) {
        [nc addObserverForName:name object:nil queue:main usingBlock:^(NSNotification *n) {
            NSWindow *w = n.object;
            if (!gTBEnabled || ![w isKindOfClass:[NSWindow class]] || [w isKindOfClass:[NSPanel class]] ||
                !(w.styleMask & NSWindowStyleMaskTitled)) return;
            BOOL has = NO;
            for (NSTitlebarAccessoryViewController *vc in w.titlebarAccessoryViewControllers)
                if ([vc.view.identifier isEqualToString:kTBViewID]) has = YES;
            if (!has) TBApplyAll(@"window");
        }];
    }
    DTPrefObserve(TB_ID, dispatch_get_main_queue(), ^{ TBApplyAll(@"settings-changed"); });
    os_log(TBLog(), "loaded into %{public}@", [[NSBundle mainBundle] bundleIdentifier] ?: @"(no bundle)");
}
