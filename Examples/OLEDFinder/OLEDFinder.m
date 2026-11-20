// OLEDFinder: pure black Finder browser windows, for OLED screens. No settings; the colours are the constants below.
//
// Only windows of Finder's browser window class (TBrowserWindow) are changed, and never one below the normal window
// level or of the desktop's class (TDesktopWindow): the desktop, Get Info, Quick Look, panels, sheets, menus and
// popovers keep their normal look. In a browser window it:
//   - gives the window the dark appearance (DarkAqua) and a black background, so text and icons stay light;
//   - puts an opaque black view at the bottom of every translucent background, so it no longer draws grey:
//     NSVisualEffectViews with a background material (window, content, sidebar, titlebar, header), Liquid Glass
//     backgrounds (NSGlassEffectView, e.g. the sidebar) and the scroll edge effect under the titlebar and the list
//     header (NSScrollPocket). Selection, menu and popover materials and the toolbar's glass buttons are left alone;
//   - makes scroll, clip, table, outline, collection and column (NSBrowser) views draw black, turns off alternating
//     row stripes and draws grid lines and split view dividers in the separator colour.
// Views are handled once, when they enter a browser window (-[NSView viewDidMoveToWindow]), and again only when the
// app later sets one of the properties above (a setter hook substitutes the black value). Nothing runs per frame.
//
//   ./build.sh
//   dw tweak install . --for com.apple.finder
//   dw respring --include com.apple.finder
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/log.h>
#import "DynjectHook.h"

#define OLF_ID_C "local.dynject.oledfinder"

// The look. 0xRRGGBB, sRGB.
static const uint32_t kOLEDBackground = 0x000000;   // every background: pure black, pixels off
static const uint32_t kOLEDSeparator  = 0x1C1C1E;   // grid lines and split view dividers: just visible on black
static const BOOL     kOLEDGlassTitlebar = YES;     // YES: the titlebar band keeps the stock glass and scroll edge
                                                    // effect over the black content; NO: black there too

// Finder's window classes. Only the first is changed; the second is excluded even if it ever became a subclass.
static const char *const kOLFBrowserWindowClass = "TBrowserWindow";
static const char *const kOLFDesktopWindowClass = "TDesktopWindow";

#ifdef OLF_TEST_BUNDLE   // test build (./build.sh test): also loads in the test host, never shipped
#define OLF_BUNDLES "com.apple.finder", OLF_TEST_BUNDLE
#else
#define OLF_BUNDLES "com.apple.finder"
#endif

static Class gOLFBrowserWindow, gOLFDesktopWindow, gOLFGlassView, gOLFScrollPocket;
static NSColor *gOLFBlack, *gOLFSeparator;
static char kOLFWindowDoneKey;

static os_log_t OLFLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create(OLF_ID_C, "tweak"); });
    return log;
}

static NSColor *OLFColor(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0 alpha:1];
}

/// A Finder browser window: of class TBrowserWindow, not the desktop's class, at normal level or above.
static BOOL OLFIsBrowserWindow(NSWindow *w) {
    if (!w || !gOLFBrowserWindow || ![w isKindOfClass:gOLFBrowserWindow]) return NO;
    if (gOLFDesktopWindow && [w isKindOfClass:gOLFDesktopWindow]) return NO;
    return w.level >= NSNormalWindowLevel;
}

#pragma mark - Black backdrop

/// An opaque black layer-backed view put at the bottom of a translucent view's subviews: it covers the material,
/// and the view's own content still draws on top. It takes no events and is skipped by accessibility.
@interface OLFBackdropView : NSView
@end
@implementation OLFBackdropView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
    return self;
}
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer { self.layer.backgroundColor = gOLFBlack.CGColor; }
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
- (BOOL)isAccessibilityElement { return NO; }
- (BOOL)accessibilityIsIgnored { return YES; }
@end

static OLFBackdropView *OLFAddBackdrop(NSView *v, CGFloat cornerRadius) {
    NSView *first = v.subviews.firstObject;
    if ([first isKindOfClass:[OLFBackdropView class]]) return (OLFBackdropView *)first;
    OLFBackdropView *b = [[OLFBackdropView alloc] initWithFrame:v.bounds];
    if (cornerRadius > 0) {
        b.layer.cornerRadius = cornerRadius;
        b.layer.cornerCurve = kCACornerCurveContinuous;
    }
    [v addSubview:b positioned:NSWindowBelow relativeTo:first];
    return b;
}

static void OLFRemoveBackdrop(NSView *v) {
    NSView *first = v.subviews.firstObject;
    if ([first isKindOfClass:[OLFBackdropView class]]) [first removeFromSuperview];
}

/// Liquid Glass used as a background. The backdrop goes into the view that holds the glass's content view, below
/// it: put into the glass view itself, the glass still draws over it. Glass in the titlebar (the toolbar's button
/// platters) is a control and is left alone.
static void OLFApplyToGlass(NSView *glass) {
    if (@available(macOS 26.0, *)) {
        NSView *content = ((NSGlassEffectView *)glass).contentView;
        NSView *holder = content.superview;
        if (!content || !holder || ![holder isDescendantOf:glass]) return;
        for (NSView *a = glass.superview; a; a = a.superview)
            if ([NSStringFromClass([a class]) hasPrefix:@"NSTitlebar"]) return;
        if (holder.subviews.firstObject == content || [holder.subviews.firstObject isKindOfClass:[OLFBackdropView class]])
            OLFAddBackdrop(holder, ((NSGlassEffectView *)glass).cornerRadius);
    }
}

/// Background materials. Selection, menu, popover, sheet, HUD, tooltip and full-screen UI materials are not.
static BOOL OLFIsBackgroundMaterial(NSVisualEffectMaterial m) {
    switch (m) {
        case NSVisualEffectMaterialTitlebar: case NSVisualEffectMaterialSidebar: case NSVisualEffectMaterialHeaderView:
        case NSVisualEffectMaterialWindowBackground: case NSVisualEffectMaterialContentBackground:
        case NSVisualEffectMaterialUnderWindowBackground: case NSVisualEffectMaterialUnderPageBackground:
            return YES;
        default:
            return NO;
    }
}

#pragma mark - Applying

/// Inside the titlebar container (the titlebar's own materials).
static BOOL OLFInTitlebar(NSView *v) {
    for (NSView *a = v.superview; a; a = a.superview)
        if ([NSStringFromClass([a class]) hasPrefix:@"NSTitlebar"]) return YES;
    return NO;
}

/// A scroll edge effect under the titlebar: it lives in the scroll view (which extends under the titlebar), so tell
/// it from a list header's by reaching above the window's content layout rect.
static BOOL OLFInTitlebarBand(NSView *v) {
    if (OLFInTitlebar(v)) return YES;
    NSWindow *w = v.window;
    if (!w) return NO;
    NSRect inWindow = [v convertRect:v.bounds toView:nil];
    return NSMaxY(inWindow) > NSMaxY(w.contentLayoutRect) + 0.5;
}

static void OLFApplyToView(NSView *v) {
    if ([v isKindOfClass:[OLFBackdropView class]]) return;
    if ([v isKindOfClass:[NSVisualEffectView class]]) {
        if (OLFIsBackgroundMaterial(((NSVisualEffectView *)v).material) && !(kOLEDGlassTitlebar && OLFInTitlebar(v)))
            OLFAddBackdrop(v, 0);
    } else if (gOLFGlassView && [v isKindOfClass:gOLFGlassView]) {
        OLFApplyToGlass(v);
    } else if (gOLFScrollPocket && [v isKindOfClass:gOLFScrollPocket]) {
        // The scroll edge effect: a tinted blur over content under the titlebar and the list header. Black there
        // still hides the rows scrolled under them, as the effect is meant to. With kOLEDGlassTitlebar the one under
        // the titlebar keeps the stock effect.
        if (!(kOLEDGlassTitlebar && OLFInTitlebarBand(v))) OLFAddBackdrop(v, 0);
    } else if ([v isKindOfClass:[NSScrollView class]]) {
        NSScrollView *s = (NSScrollView *)v;
        s.backgroundColor = gOLFBlack;
        s.drawsBackground = YES;
    } else if ([v isKindOfClass:[NSClipView class]]) {
        // Only a scroll view's own clip view: a text field's editing clip view is left alone.
        if ([v.superview isKindOfClass:[NSScrollView class]]) {
            ((NSClipView *)v).backgroundColor = gOLFBlack;
            ((NSClipView *)v).drawsBackground = YES;
        }
    } else if ([v isKindOfClass:[NSTableView class]]) {
        NSTableView *t = (NSTableView *)v;
        t.backgroundColor = gOLFBlack;
        t.usesAlternatingRowBackgroundColors = NO;
        t.gridColor = gOLFSeparator;
    } else if ([v isKindOfClass:[NSCollectionView class]]) {
        ((NSCollectionView *)v).backgroundColors = @[gOLFBlack];
    } else if ([v isKindOfClass:[NSBrowser class]]) {
        ((NSBrowser *)v).backgroundColor = gOLFBlack;
    }
}

static void OLFApplyToTree(NSView *v) {
    OLFApplyToView(v);
    for (NSView *sub in [v.subviews copy]) OLFApplyToTree(sub);
}

/// The window-wide part, once per window; afterwards views are handled as they arrive.
static void OLFApplyToWindow(NSWindow *w) {
    if (objc_getAssociatedObject(w, &kOLFWindowDoneKey)) return;
    objc_setAssociatedObject(w, &kOLFWindowDoneKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    w.backgroundColor = gOLFBlack;
    NSView *root = w.contentView.superview ?: w.contentView;   // the frame view: titlebar and toolbar included
    if (root) OLFApplyToTree(root);
    os_log(OLFLog(), "applied to %{public}@ \"%{public}@\"", NSStringFromClass([w class]), w.title);
}

#pragma mark - Hooks

// -viewDidMoveToWindow reaches every view of a subtree that moves into a window, so one cheap class check per view
// is all it costs outside browser windows.
@interface OLF_NSViewHook : NSObject @end
@implementation OLF_NSViewHook
- (void)viewDidMoveToWindow {
    DH_ORIG(void (*)(id, SEL));
    NSWindow *w = [(NSView *)self window];
    if (!OLFIsBrowserWindow(w)) return;
    if (!objc_getAssociatedObject(w, &kOLFWindowDoneKey)) OLFApplyToWindow(w);
    else OLFApplyToView((NSView *)self);
}
@end

// The app setting a property later gets the black value instead, in browser windows only.
@interface OLF_NSWindowHook : NSObject @end
@implementation OLF_NSWindowHook
- (void)setBackgroundColor:(NSColor *)c {
    if (OLFIsBrowserWindow((NSWindow *)self) && objc_getAssociatedObject(self, &kOLFWindowDoneKey)) c = gOLFBlack;
    DH_ORIG(void (*)(id, SEL, NSColor *), c);
}
- (void)setAppearance:(NSAppearance *)a {
    if (OLFIsBrowserWindow((NSWindow *)self) && objc_getAssociatedObject(self, &kOLFWindowDoneKey))
        a = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    DH_ORIG(void (*)(id, SEL, NSAppearance *), a);
}
@end

#define OLF_IN_BROWSER(view) OLFIsBrowserWindow([(NSView *)(view) window])

@interface OLF_NSScrollViewHook : NSObject @end
@implementation OLF_NSScrollViewHook
- (void)setBackgroundColor:(NSColor *)c { DH_ORIG(void (*)(id, SEL, NSColor *), OLF_IN_BROWSER(self) ? gOLFBlack : c); }
- (void)setDrawsBackground:(BOOL)d { DH_ORIG(void (*)(id, SEL, BOOL), OLF_IN_BROWSER(self) ? YES : d); }
@end

@interface OLF_NSClipViewHook : NSObject @end
@implementation OLF_NSClipViewHook
- (void)setBackgroundColor:(NSColor *)c {
    BOOL ours = OLF_IN_BROWSER(self) && [[(NSView *)self superview] isKindOfClass:[NSScrollView class]];
    DH_ORIG(void (*)(id, SEL, NSColor *), ours ? gOLFBlack : c);
}
@end

@interface OLF_NSTableViewHook : NSObject @end
@implementation OLF_NSTableViewHook
- (void)setBackgroundColor:(NSColor *)c { DH_ORIG(void (*)(id, SEL, NSColor *), OLF_IN_BROWSER(self) ? gOLFBlack : c); }
- (void)setUsesAlternatingRowBackgroundColors:(BOOL)u { DH_ORIG(void (*)(id, SEL, BOOL), OLF_IN_BROWSER(self) ? NO : u); }
- (void)setGridColor:(NSColor *)c { DH_ORIG(void (*)(id, SEL, NSColor *), OLF_IN_BROWSER(self) ? gOLFSeparator : c); }
@end

@interface OLF_NSCollectionViewHook : NSObject @end
@implementation OLF_NSCollectionViewHook
- (void)setBackgroundColors:(NSArray<NSColor *> *)c {
    DH_ORIG(void (*)(id, SEL, NSArray *), OLF_IN_BROWSER(self) ? @[gOLFBlack] : c);
}
@end

@interface OLF_NSBrowserHook : NSObject @end
@implementation OLF_NSBrowserHook
- (void)setBackgroundColor:(NSColor *)c { DH_ORIG(void (*)(id, SEL, NSColor *), OLF_IN_BROWSER(self) ? gOLFBlack : c); }
@end

@interface OLF_NSVisualEffectViewHook : NSObject @end
@implementation OLF_NSVisualEffectViewHook
- (void)setMaterial:(NSVisualEffectMaterial)m {
    DH_ORIG(void (*)(id, SEL, NSVisualEffectMaterial), m);
    if (!OLF_IN_BROWSER(self)) return;
    if (OLFIsBackgroundMaterial(m)) OLFAddBackdrop((NSView *)self, 0);
    else OLFRemoveBackdrop((NSView *)self);
}
@end

// A content view set after the glass entered the window.
@interface OLF_NSGlassEffectViewHook : NSObject @end
@implementation OLF_NSGlassEffectViewHook
- (void)setContentView:(NSView *)v {
    DH_ORIG(void (*)(id, SEL, NSView *), v);
    if (OLF_IN_BROWSER(self)) OLFApplyToGlass((NSView *)self);
}
@end

@interface OLF_NSSplitViewHook : NSObject @end
@implementation OLF_NSSplitViewHook
- (NSColor *)dividerColor {
    return OLF_IN_BROWSER(self) ? gOLFSeparator : DH_ORIG(NSColor *(*)(id, SEL));
}
@end

DH_CTOR(OLF_ID_C, OLF_BUNDLES) {
    gOLFBrowserWindow = DHClass(kOLFBrowserWindowClass);
    gOLFDesktopWindow = DHClass(kOLFDesktopWindowClass);
    gOLFGlassView = DHClass("NSGlassEffectView");   // macOS 26 and later, like the next one
    gOLFScrollPocket = DHClass("NSScrollPocket");
    if (!gOLFBrowserWindow) {
        // Finder renamed its window class: change nothing rather than guess which windows are browsers.
        os_log(OLFLog(), "no %{public}s class in this Finder; doing nothing", kOLFBrowserWindowClass);
        return;
    }
    gOLFBlack = OLFColor(kOLEDBackground);
    gOLFSeparator = OLFColor(kOLEDSeparator);

    NSUInteger n = 0;
    n += DHHookClass([OLF_NSViewHook class], [NSView class], NULL);
    n += DHHookClass([OLF_NSWindowHook class], [NSWindow class], NULL);
    n += DHHookClass([OLF_NSScrollViewHook class], [NSScrollView class], NULL);
    n += DHHookClass([OLF_NSClipViewHook class], [NSClipView class], NULL);
    n += DHHookClass([OLF_NSTableViewHook class], [NSTableView class], NULL);
    n += DHHookClass([OLF_NSCollectionViewHook class], [NSCollectionView class], NULL);
    n += DHHookClass([OLF_NSBrowserHook class], [NSBrowser class], NULL);
    n += DHHookClass([OLF_NSVisualEffectViewHook class], [NSVisualEffectView class], NULL);
    n += DHHookClass([OLF_NSSplitViewHook class], [NSSplitView class], NULL);
    if (gOLFGlassView) n += DHHookClass([OLF_NSGlassEffectViewHook class], gOLFGlassView, NULL);
    os_log(OLFLog(), "loaded into %{public}@ (%lu methods hooked)",
           [[NSBundle mainBundle] bundleIdentifier] ?: @"(no bundle ID)", (unsigned long)n);
}
