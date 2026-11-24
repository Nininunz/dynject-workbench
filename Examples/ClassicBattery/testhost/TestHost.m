// Test host for ClassicBattery, run by `./build.sh test` (no Dynject involved):
//   DYLD_INSERT_LIBRARIES=build/test/libClassicBattery.dylib build/test/ClassicBatteryTestHost.app/Contents/MacOS/… <dir>
//
// The test copy of the tweak loads here too and exports CBTestSetState. The host draws the tweak's item
// (DYClassicBatteryView) off screen in each battery state, in dark and light appearance, checks the pixels (fill
// width against the level, red, yellow, the cut-out bolt and plug, ink colour, the gap and the vertical centring) and
// saves every drawing as a PNG in <dir>. It also checks that the classes and methods the tweak hooks in MenuBarAgent
// still exist on this macOS (all but MenuBarCore's container view, which lives in MenuBarAgent itself).
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static int sChecks, sFailures;

static void Check(BOOL ok, NSString *what) {
    sChecks++;
    if (!ok) sFailures++;
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what.UTF8String);
}

typedef void (*SetStateFn)(double, int, int, int);
static SetStateFn sSetState;
typedef void (*SetSettingsFn)(int, int, double);
static SetSettingsFn sSetSettings;

/// One drawing: its pixels and how many there are per point.
@interface Drawing : NSObject
@property NSBitmapImageRep *rep;
@property CGFloat scale;
@end
@implementation Drawing
@end

static Drawing *Draw(NSString *name, NSString *dir, double fraction, int charging, int external, int lowPower, BOOL dark) {
    sSetState(fraction, charging, external, lowPower);
    NSView *view = [[NSClassFromString(@"DYClassicBatteryView") alloc] initWithFrame:NSMakeRect(0, 0, 64, 39)];
    view.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:128 pixelsHigh:78 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = view.bounds.size;   // 2 pixels per point, like a Retina menu bar
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    // Save it over the menu bar's colour so it can be looked at.
    NSImage *shown = [NSImage imageWithSize:view.bounds.size flipped:NO drawingHandler:^BOOL(NSRect r) {
        [(dark ? [NSColor colorWithWhite:0.06 alpha:1] : [NSColor colorWithWhite:0.93 alpha:1]) set];
        NSRectFill(r);
        [rep drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:NO
                  hints:nil];   // plain -drawInRect: copies, wiping the background
        return YES;
    }];
    NSBitmapImageRep *out = [[NSBitmapImageRep alloc] initWithData:shown.TIFFRepresentation];
    [[out representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[dir stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
    Drawing *d = [Drawing new];
    d.rep = rep;
    d.scale = 2;
    return d;
}

// The classic battery alone: a point at either end, the body, the nub.
static const double kBatteryOnly = 1 + 25 + 1.5 + 1;

static NSColor *Px(Drawing *d, NSInteger x, NSInteger y) { return [[d.rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace]; }
static BOOL Ink(NSColor *c) { return c.alphaComponent > 0.6; }

/// Columns with anything drawn, as runs [start, end] split at gaps of 4 pixels or more.
static NSArray<NSValue *> *Runs(Drawing *d) {
    NSInteger w = d.rep.pixelsWide, h = d.rep.pixelsHigh;
    NSMutableArray *runs = [NSMutableArray array];
    NSInteger start = -1, last = -10;
    for (NSInteger x = 0; x < w; x++) {
        BOOL any = NO;
        for (NSInteger y = 0; y < h && !any; y++) any = Px(d, x, y).alphaComponent > 0.25;
        if (!any) continue;
        if (x - last > 4) {
            if (start >= 0) [runs addObject:[NSValue valueWithRange:NSMakeRange(start, last - start + 1)]];
            start = x;
        }
        last = x;
    }
    if (start >= 0) [runs addObject:[NSValue valueWithRange:NSMakeRange(start, last - start + 1)]];
    return runs;
}

/// Rows with anything drawn between columns [x0, x1]: (top, bottom), top-down.
static NSRange Rows(Drawing *d, NSInteger x0, NSInteger x1) {
    NSInteger top = -1, bottom = -1;
    for (NSInteger y = 0; y < d.rep.pixelsHigh; y++) {
        for (NSInteger x = x0; x <= x1; x++) {
            if (Px(d, x, y).alphaComponent > 0.25) { if (top < 0) top = y; bottom = y; break; }
        }
    }
    return NSMakeRange(top, bottom - top + 1);
}

typedef struct { NSInteger fill; double r, g, b; NSInteger holes; } FillInfo;

/// Along the battery's middle row, inside the outline: how many solid pixels (the fill), their mean colour, and how
/// many clear pixels sit between solid ones (a cut-out badge).
static FillInfo Fill(Drawing *d, NSRange battery, NSRange rows) {
    battery = [Runs(d).lastObject rangeValue];   // the content is centred, so the battery moves with the number's width
    FillInfo f = {0};
    NSInteger y = rows.location + rows.length / 2;
    NSInteger from = battery.location + 3, to = NSMaxRange(battery) - 8;   // past the outline, before the nub
    NSInteger firstSolid = -1, lastSolid = -1;
    for (NSInteger x = from; x <= to; x++) {
        NSColor *c = Px(d, x, y);
        if (Ink(c)) {
            f.fill++; f.r += c.redComponent; f.g += c.greenComponent; f.b += c.blueComponent;
            if (firstSolid < 0) firstSolid = x;
            lastSolid = x;
        }
    }
    for (NSInteger x = firstSolid; firstSolid >= 0 && x <= lastSolid; x++) if (Px(d, x, y).alphaComponent < 0.2) f.holes++;
    if (f.fill) { f.r /= f.fill; f.g /= f.fill; f.b /= f.fill; }
    return f;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString *dir = argc > 1 ? @(argv[1]) : NSTemporaryDirectory();
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];

        printf("tweak\n");
        sSetState = (SetStateFn)dlsym(RTLD_DEFAULT, "CBTestSetState");
        Check(sSetState != NULL, @"the test copy is loaded (CBTestSetState)");
        Check(NSClassFromString(@"DYClassicBatteryView") != nil, @"DYClassicBatteryView exists");
        if (!sSetState || !NSClassFromString(@"DYClassicBatteryView")) return 1;

        printf("drawing (2 px per point, PNGs in %s)\n", dir.UTF8String);
        Drawing *half = Draw(@"dark-50", dir, 0.5, 0, 0, 0, YES);
        NSArray *runs = Runs(half);
        Check(runs.count >= 2, [NSString stringWithFormat:@"number and battery are separate (%lu runs)", (unsigned long)runs.count]);
        NSRange battery = [runs.lastObject rangeValue], text = [runs[runs.count - 2] rangeValue];
        double gap = (battery.location - NSMaxRange(text)) / half.scale;
        Check(gap >= 3.5 && gap <= 6, [NSString stringWithFormat:@"gap between number and battery: %.1f pt (3.5–6)", gap]);
        NSRange bRows = Rows(half, battery.location, NSMaxRange(battery) - 1);
        NSRange tRows = Rows(half, 0, NSMaxRange(text) - 1);
        double bw = (battery.length) / half.scale, bh = bRows.length / half.scale;
        Check(bw / bh > 2.0 && bw / bh < 2.6, [NSString stringWithFormat:@"battery %.1f × %.1f pt incl. nub (%.2f:1)", bw, bh, bw / bh]);
        double centreGap = fabs((bRows.location + bRows.length / 2.0) - (tRows.location + tRows.length / 2.0)) / half.scale;
        Check(centreGap <= 0.75, [NSString stringWithFormat:@"number centred on the battery (off by %.1f pt)", centreGap]);
        double capRatio = tRows.length / (double)bRows.length;
        Check(capRatio > 0.65 && capRatio < 0.9, [NSString stringWithFormat:@"number's height / battery's: %.2f (older macOS ≈ 0.76)", capRatio]);

        FillInfo f50 = Fill(half, battery, bRows);
        FillInfo f100 = Fill(Draw(@"dark-100", dir, 1.0, 0, 0, 0, YES), battery, bRows);
        FillInfo f25 = Fill(Draw(@"dark-25", dir, 0.25, 0, 0, 0, YES), battery, bRows);
        Check(f100.fill > 0 && fabs(f50.fill / (double)f100.fill - 0.5) < 0.08,
              [NSString stringWithFormat:@"fill follows the level: 25%% %ld px, 50%% %ld px, 100%% %ld px", (long)f25.fill,
                                         (long)f50.fill, (long)f100.fill]);
        Check(f100.r > 0.85 && f100.g > 0.85 && f100.b > 0.85, @"dark menu bar: the fill is light");

        FillInfo low = Fill(Draw(@"dark-5-battery", dir, 0.05, 0, 0, 0, YES), battery, bRows);
        Check(low.fill > 0 && low.r > 0.8 && low.g < 0.5, [NSString stringWithFormat:@"5%% on battery: red fill (%.2f %.2f %.2f)", low.r, low.g, low.b]);
        FillInfo lowAC = Fill(Draw(@"dark-5-plugged", dir, 0.05, 0, 1, 0, YES), battery, bRows);
        Check(!(lowAC.r > 0.8 && lowAC.g < 0.5), @"5% on power: not red");
        FillInfo lpm = Fill(Draw(@"dark-60-lowpower", dir, 0.6, 0, 0, 1, YES), battery, bRows);
        Check(lpm.r > 0.8 && lpm.g > 0.6 && lpm.b < 0.4, [NSString stringWithFormat:@"Low Power Mode: yellow fill (%.2f %.2f %.2f)", lpm.r, lpm.g, lpm.b]);
        FillInfo bolt = Fill(Draw(@"dark-80-charging", dir, 0.8, 1, 1, 0, YES), battery, bRows);
        Check(bolt.holes >= 2, [NSString stringWithFormat:@"charging: the bolt is cut out of the fill (%ld clear px)", (long)bolt.holes]);
        FillInfo plug = Fill(Draw(@"dark-80-plugged", dir, 0.8, 0, 1, 0, YES), battery, bRows);
        Check(plug.holes >= 2, [NSString stringWithFormat:@"held at a limit: the plug is cut out of the fill (%ld clear px)", (long)plug.holes]);

        Drawing *light = Draw(@"light-50", dir, 0.5, 0, 0, 0, NO);
        FillInfo lf = Fill(light, battery, bRows);
        Check(lf.fill > 0 && lf.r < 0.3 && lf.g < 0.3 && lf.b < 0.3, @"light menu bar: the fill is dark");
        BOOL darkText = NO;
        for (NSInteger x = 0; x < (NSInteger)NSMaxRange(text) && !darkText; x++)
            for (NSInteger y = 0; y < light.rep.pixelsHigh && !darkText; y++) {
                NSColor *c = Px(light, x, y);
                darkText = c.alphaComponent > 0.7 && c.redComponent < 0.2;
            }
        Check(darkText, @"light menu bar: the number is dark");
        Draw(@"light-80-charging", dir, 0.8, 1, 1, 0, NO);
        Draw(@"light-5-battery", dir, 0.05, 0, 0, 0, NO);

        printf("settings\n");
        sSetSettings = (SetSettingsFn)dlsym(RTLD_DEFAULT, "CBTestSetSettings");
        Check(sSetSettings != NULL, @"the test copy exports CBTestSetSettings");
        if (sSetSettings) {
            NSView *probe = [[NSClassFromString(@"DYClassicBatteryView") alloc] initWithFrame:NSZeroRect];
            sSetState(0.5, 0, 0, 0);
            CGFloat classicWidth = probe.intrinsicContentSize.width;

            sSetSettings(1, 0, 12);   // classic, no percentage
            Drawing *bare = Draw(@"dark-50-nopercent", dir, 0.5, 0, 0, 0, YES);
            NSArray *bareRuns = Runs(bare);
            Check(bareRuns.count == 1, [NSString stringWithFormat:@"no percentage: only the battery (%lu runs)", (unsigned long)bareRuns.count]);
            CGFloat bareWidth = probe.intrinsicContentSize.width;
            Check(fabs(bareWidth - (kBatteryOnly)) < 0.01, [NSString stringWithFormat:@"no percentage: %.1f pt wide (%.1f)", bareWidth, kBatteryOnly]);

            sSetSettings(1, 1, 15);   // classic, bigger number
            Drawing *big = Draw(@"dark-50-15pt", dir, 0.5, 0, 0, 0, YES);
            NSArray *bigRuns = Runs(big);
            double bigText = bigRuns.count >= 2 ? [bigRuns[bigRuns.count - 2] rangeValue].length : 0;
            Check(bigText > text.length * 1.12, [NSString stringWithFormat:@"15 pt number is wider than 12 pt (%.0f vs %lu px)", bigText, (unsigned long)text.length]);
            Check(probe.intrinsicContentSize.width > classicWidth, @"15 pt number: the item is wider");

            sSetSettings(0, 1, 12);   // Apple's battery: only the number is ours, before macOS's 26-point battery
            Drawing *apple = Draw(@"dark-50-apple", dir, 0.5, 0, 0, 0, YES);
            NSArray *appleRuns = Runs(apple);
            NSInteger lastInk = appleRuns.count ? (NSInteger)NSMaxRange([appleRuns.lastObject rangeValue]) : 0;
            Check(appleRuns.count >= 1 && lastInk <= (64 - 26) * 2,
                  [NSString stringWithFormat:@"Apple's: the number ends before macOS's battery (at %.1f pt, battery from %d)", lastInk / 2.0, 64 - 26]);
            CGFloat appleWidth = probe.intrinsicContentSize.width;
            Check(appleWidth > 26 + 15 && appleWidth < classicWidth,
                  [NSString stringWithFormat:@"Apple's: %.1f pt wide (macOS's 26 plus the number)", appleWidth]);
            sSetSettings(1, 1, 12);   // back to the defaults
        }

        printf("what it uses in ControlCenter\n");
        dlopen("/System/Library/PrivateFrameworks/MenuBarClient.framework/MenuBarClient", RTLD_LAZY);
        Class assertion = NSClassFromString(@"MBControlCenterItemAssertionXPC");
        SEL init = NSSelectorFromString(@"initWithID:behavior:isPrimary:isSpringLoaded:canDropOnBentoBox:encodedHighlight:"
                                        @"sortOrder:persistenceID:displayableID:systemIdentifier:accessibilityToken:");
        Method m = assertion ? class_getInstanceMethod(assertion, init) : NULL;
        Check(m && strcmp(method_getTypeEncoding(m) ?: "", "") != 0
              && [assertion instancesRespondToSelector:NSSelectorFromString(@"assertionID")],
              [NSString stringWithFormat:@"MBControlCenterItemAssertionXPC -initWithID:…systemIdentifier:accessibilityToken: "
                                         @"(%s) -assertionID", m ? method_getTypeEncoding(m) : "missing"]);
        Class hosted = NSClassFromString(@"NSHostedViewScene");
        Check(hosted && [hosted instancesRespondToSelector:NSSelectorFromString(@"setView:")]
              && [hosted instancesRespondToSelector:NSSelectorFromString(@"view")]
              && [hosted instancesRespondToSelector:NSSelectorFromString(@"viewHierarchyDidChange")]
              && [hosted instancesRespondToSelector:NSSelectorFromString(@"_FBSScene")],
              @"NSHostedViewScene -setView: -view -viewHierarchyDidChange -_FBSScene");
        Check([NSApp respondsToSelector:NSSelectorFromString(@"connectedScenes")], @"NSApplication -connectedScenes");

        printf("%d checks, %d failed\n", sChecks, sFailures);
        return sFailures ? 1 : 0;
    }
}
