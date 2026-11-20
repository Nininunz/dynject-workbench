// Test host for OLEDFinder, run WITHOUT Dynject (./build.sh test does all of this):
//   OLF_MODE=before OLF_OUT=<dir> OLEDFinderTestHost.app/Contents/MacOS/OLEDFinderTestHost
//   OLF_MODE=after  OLF_OUT=<dir> DYLD_INSERT_LIBRARIES=<test build of libOLEDFinder.dylib> ...
//
// Its bundle ID is local.dynject.oledfinder.testhost, never Finder's; the test build of the tweak adds that ID to
// DH_CTOR's filter. It mimics a Finder browser window: a TBrowserWindow (Finder's class name) with a unified
// toolbar, a split view whose sidebar is a source-list outline view in an NSVisualEffectView (.sidebar), a list
// (NSTableView), an icon view (NSCollectionView), a column view (NSBrowser) and a Liquid Glass status pill. Beside
// it: a TDesktopWindow at desktop level standing in for the desktop, and a TInfoWindow (a window the tweak doesn't
// recognise). It captures each window with `screencapture -l` (ids from CGWindowListCopyWindowInfo), samples
// pixels, and in "after" mode fails unless the browser's backgrounds are #000000, its text is still bright, and
// the other two windows are untouched.
#import <AppKit/AppKit.h>

// Finder's class names, so the tweak's window filter runs exactly as it would in Finder.
@interface TBrowserWindow : NSWindow @end
@implementation TBrowserWindow @end
@interface TDesktopWindow : NSWindow @end
@implementation TDesktopWindow @end
@interface TInfoWindow : NSWindow @end
@implementation TInfoWindow @end

static int failures = 0;
static void check(BOOL ok, NSString *what) {
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what.UTF8String);
    if (!ok) failures++;
}

@interface HostIconItem : NSCollectionViewItem @end
@implementation HostIconItem
- (void)loadView {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 96, 90)];
    NSImageView *iv = [NSImageView imageViewWithImage:[NSImage imageNamed:NSImageNameFolder]];
    iv.frame = NSMakeRect(16, 26, 64, 64);
    iv.imageScaling = NSImageScaleProportionallyUpOrDown;
    NSTextField *tf = [NSTextField labelWithString:@""];
    tf.frame = NSMakeRect(0, 4, 96, 18);
    tf.alignment = NSTextAlignmentCenter;
    tf.font = [NSFont systemFontOfSize:12];
    [v addSubview:iv];
    [v addSubview:tf];
    self.view = v;
    self.imageView = iv;
    self.textField = tf;
}
@end

@interface Host : NSObject <NSApplicationDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
                            NSTableViewDataSource, NSTableViewDelegate, NSCollectionViewDataSource,
                            NSBrowserDelegate, NSToolbarDelegate>
@property NSWindow *browserWindow, *desktopWindow, *infoWindow;
@property NSOutlineView *sidebar;
@property NSTableView *list;
@property NSCollectionView *icons;
@property NSBrowser *columns;
@property NSGlassEffectView *pill;
@property NSScrollView *desktopScroll, *infoScroll;
@property NSString *mode, *outDir;
@property NSDictionary *sidebarItems;
@property NSArray *sidebarGroups, *files;
@end

@implementation Host

#pragma mark Window construction

- (NSScrollView *)scrollFor:(NSView *)doc {
    NSScrollView *s = [[NSScrollView alloc] init];
    s.documentView = doc;
    s.hasVerticalScroller = YES;
    s.autohidesScrollers = YES;
    return s;
}

- (NSViewController *)vc:(NSView *)view {
    NSViewController *vc = [[NSViewController alloc] init];
    vc.view = view;
    return vc;
}

- (void)buildBrowserWindow {
    self.sidebarGroups = @[@"Favorites", @"Locations"];
    self.sidebarItems = @{@"Favorites": @[@"Desktop", @"Documents", @"Downloads", @"Applications"],
                          @"Locations": @[@"Macintosh HD", @"Network"]};
    self.files = @[@"Invoices and receipts 2026", @"Photos 2026", @"Projects", @"Readme.txt", @"Screenshots", @"Taxes",
                   @"Archive", @"Books", @"Music", @"Notes", @"Recipes", @"Travel", @"Videos", @"Work"];

    NSWindow *w = [[TBrowserWindow alloc] initWithContentRect:NSMakeRect(80, 120, 1100, 640)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                  NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
          backing:NSBackingStoreBuffered defer:NO];
    w.title = @"Documents";
    w.releasedWhenClosed = NO;
    NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"local.dynject.oledfinder.testhost.toolbar"];
    tb.delegate = self;
    tb.displayMode = NSToolbarDisplayModeIconOnly;
    w.toolbar = tb;
    w.toolbarStyle = NSWindowToolbarStyleUnified;

    // Sidebar: source-list outline view inside a .sidebar visual effect view.
    NSOutlineView *ov = [[NSOutlineView alloc] init];
    NSTableColumn *oc = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [ov addTableColumn:oc];
    ov.outlineTableColumn = oc;
    ov.headerView = nil;
    ov.style = NSTableViewStyleSourceList;
    ov.floatsGroupRows = NO;
    ov.dataSource = self;
    ov.delegate = self;
    self.sidebar = ov;
    NSScrollView *ovScroll = [self scrollFor:ov];
    ovScroll.drawsBackground = NO;
    NSVisualEffectView *sidebarFX = [[NSVisualEffectView alloc] init];
    sidebarFX.material = NSVisualEffectMaterialSidebar;
    sidebarFX.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    ovScroll.frame = sidebarFX.bounds;
    ovScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [sidebarFX addSubview:ovScroll];

    // List view.
    NSTableView *tv = [[NSTableView alloc] init];
    for (NSString *col in @[@"Name", @"Date Modified", @"Size"]) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:col];
        c.title = col;
        c.width = [col isEqualToString:@"Name"] ? 220 : 140;
        [tv addTableColumn:c];
    }
    tv.usesAlternatingRowBackgroundColors = YES;
    tv.style = NSTableViewStyleFullWidth;
    tv.dataSource = self;
    tv.delegate = self;
    self.list = tv;
    NSScrollView *listScroll = [self scrollFor:tv];

    // Icon view.
    NSCollectionViewFlowLayout *flow = [[NSCollectionViewFlowLayout alloc] init];
    flow.itemSize = NSMakeSize(96, 90);
    flow.minimumInteritemSpacing = 12;
    flow.sectionInset = NSEdgeInsetsMake(12, 12, 12, 12);
    NSCollectionView *cv = [[NSCollectionView alloc] init];
    cv.collectionViewLayout = flow;
    cv.dataSource = self;
    [cv registerClass:[HostIconItem class] forItemWithIdentifier:@"icon"];
    self.icons = cv;
    NSScrollView *iconScroll = [self scrollFor:cv];

    // Column view, with a Liquid Glass status pill floating over the bottom of the content.
    NSBrowser *br = [[NSBrowser alloc] init];
    br.delegate = self;
    br.minColumnWidth = 160;
    br.titled = NO;
    self.columns = br;
    NSGlassEffectView *pill = [[NSGlassEffectView alloc] init];
    pill.cornerRadius = 14;
    NSTextField *pillLabel = [NSTextField labelWithString:@"14 items, 412 GB available"];
    pillLabel.alignment = NSTextAlignmentCenter;
    pillLabel.font = [NSFont systemFontOfSize:12];
    pill.contentView = pillLabel;
    self.pill = pill;

    NSSplitView *contentSplit = [[NSSplitView alloc] init];
    contentSplit.vertical = NO;
    contentSplit.dividerStyle = NSSplitViewDividerStyleThin;
    [contentSplit addArrangedSubview:listScroll];
    [contentSplit addArrangedSubview:iconScroll];
    [contentSplit addArrangedSubview:br];
    NSView *content = [[NSView alloc] init];
    contentSplit.translatesAutoresizingMaskIntoConstraints = NO;
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:contentSplit];
    [content addSubview:pill];
    [NSLayoutConstraint activateConstraints:@[
        [contentSplit.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [contentSplit.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [contentSplit.topAnchor constraintEqualToAnchor:content.topAnchor],
        [contentSplit.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [pill.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [pill.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-10],
        [pill.widthAnchor constraintEqualToConstant:250],
        [pill.heightAnchor constraintEqualToConstant:28],
    ]];

    NSSplitViewController *split = [[NSSplitViewController alloc] init];
    NSSplitViewItem *side = [NSSplitViewItem sidebarWithViewController:[self vc:sidebarFX]];
    side.minimumThickness = 200;
    side.maximumThickness = 260;
    [split addSplitViewItem:side];
    [split addSplitViewItem:[NSSplitViewItem contentListWithViewController:[self vc:content]]];
    w.contentViewController = split;
    [w setFrame:NSMakeRect(80, 120, 1100, 640) display:NO];
    [contentSplit setPosition:280 ofDividerAtIndex:0];
    [contentSplit setPosition:470 ofDividerAtIndex:1];
    [ov reloadData];
    for (NSString *g in self.sidebarGroups) [ov expandItem:g];
    [ov selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];   // Documents
    [tv reloadData];
    [tv selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    [cv reloadData];
    [br loadColumnZero];
    self.browserWindow = w;
}

- (void)buildDesktopWindow {
    // Stands in for Finder's desktop: borderless, below normal level, with its own colours.
    NSRect r = NSMakeRect(1200, 120, 320, 220);
    NSWindow *w = [[TDesktopWindow alloc] initWithContentRect:r styleMask:NSWindowStyleMaskBorderless
                                                      backing:NSBackingStoreBuffered defer:NO];
    w.level = CGWindowLevelForKey(kCGDesktopWindowLevelKey);
    w.backgroundColor = [NSColor colorWithSRGBRed:0.20 green:0.40 blue:0.80 alpha:1];
    w.releasedWhenClosed = NO;
    NSScrollView *s = [self scrollFor:[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 100)]];
    s.frame = NSMakeRect(10, 10, 300, 100);
    s.drawsBackground = YES;
    s.backgroundColor = [NSColor colorWithSRGBRed:0.20 green:0.40 blue:0.80 alpha:1];
    [w.contentView addSubview:s];
    self.desktopScroll = s;
    self.desktopWindow = w;
}

- (void)buildInfoWindow {
    NSWindow *w = [[TInfoWindow alloc] initWithContentRect:NSMakeRect(1200, 420, 300, 200)
                                                 styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                   backing:NSBackingStoreBuffered defer:NO];
    w.title = @"Readme.txt Info";
    w.releasedWhenClosed = NO;
    NSScrollView *s = [self scrollFor:[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 280, 100)]];
    s.frame = NSMakeRect(10, 10, 280, 150);
    s.drawsBackground = YES;
    s.backgroundColor = [NSColor colorWithSRGBRed:0.85 green:0.85 blue:0.80 alpha:1];
    [w.contentView addSubview:s];
    self.infoScroll = s;
    self.infoWindow = w;
}

#pragma mark Data sources

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item {
    return item ? (NSInteger)[self.sidebarItems[item] count] : (NSInteger)self.sidebarGroups.count;
}
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)i ofItem:(id)item {
    return item ? self.sidebarItems[item][(NSUInteger)i] : self.sidebarGroups[(NSUInteger)i];
}
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(id)item { return self.sidebarItems[item] != nil; }
- (BOOL)outlineView:(NSOutlineView *)ov isGroupItem:(id)item { return self.sidebarItems[item] != nil; }
- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(id)item {
    BOOL group = self.sidebarItems[item] != nil;
    NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 180, 24)];
    NSTextField *tf = [NSTextField labelWithString:item];
    tf.frame = NSMakeRect(group ? 2 : 26, 3, 160, 17);
    tf.font = group ? [NSFont boldSystemFontOfSize:11] : [NSFont systemFontOfSize:13];
    if (group) tf.textColor = [NSColor secondaryLabelColor];
    [cell addSubview:tf];
    cell.textField = tf;
    if (!group) {
        NSImageView *iv = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"folder"
                                                                    accessibilityDescription:nil]];
        iv.frame = NSMakeRect(4, 3, 18, 18);
        iv.contentTintColor = [NSColor controlAccentColor];
        [cell addSubview:iv];
        cell.imageView = iv;
    }
    return cell;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)self.files.count; }
- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    NSString *s = [col.identifier isEqualToString:@"Name"] ? self.files[(NSUInteger)row]
                : [col.identifier isEqualToString:@"Size"] ? @"--" : @"Today at 09:41";
    NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, col.width, 20)];
    NSTextField *tf = [NSTextField labelWithString:s];
    tf.frame = NSMakeRect(4, 2, col.width - 8, 17);
    tf.autoresizingMask = NSViewWidthSizable;
    [cell addSubview:tf];
    cell.textField = tf;
    return cell;
}

- (NSInteger)collectionView:(NSCollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.files.count;
}
- (NSCollectionViewItem *)collectionView:(NSCollectionView *)cv itemForRepresentedObjectAtIndexPath:(NSIndexPath *)ip {
    NSCollectionViewItem *item = [cv makeItemWithIdentifier:@"icon" forIndexPath:ip];
    item.textField.stringValue = self.files[(NSUInteger)ip.item];
    return item;
}

- (NSInteger)browser:(NSBrowser *)b numberOfChildrenOfItem:(id)item { return item ? 3 : (NSInteger)self.files.count; }
- (id)browser:(NSBrowser *)b child:(NSInteger)i ofItem:(id)item {
    return item ? [NSString stringWithFormat:@"%@ %ld", item, (long)i + 1] : self.files[(NSUInteger)i];
}
- (BOOL)browser:(NSBrowser *)b isLeafItem:(id)item { return [item rangeOfString:@" "].location != NSNotFound && ![item hasPrefix:@"Photos"]; }
- (id)browser:(NSBrowser *)b objectValueForItem:(id)item { return item; }

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)tb {
    return @[@"back", @"forward", NSToolbarFlexibleSpaceItemIdentifier, @"view", @"share"];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)tb {
    return [self toolbarDefaultItemIdentifiers:tb];
}
- (NSToolbarItem *)toolbar:(NSToolbar *)tb itemForItemIdentifier:(NSToolbarItemIdentifier)ident
    willBeInsertedIntoToolbar:(BOOL)flag {
    NSDictionary *symbols = @{@"back": @"chevron.left", @"forward": @"chevron.right",
                              @"view": @"square.grid.2x2", @"share": @"square.and.arrow.up"};
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    item.label = ident;
    item.image = [NSImage imageWithSystemSymbolName:symbols[ident] accessibilityDescription:ident];
    item.target = self;
    item.action = @selector(noop:);
    return item;
}
- (void)noop:(id)sender { (void)sender; }

#pragma mark Capture and checks

typedef struct { double black, bright, maxLum, r, g, b; } Sample;

/// Window id from the window server's list of this process's windows (cross-checked with -windowNumber).
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

- (NSBitmapImageRep *)capture:(NSWindow *)w name:(NSString *)name {
    CGWindowID wid = [self windowIDFor:w];
    if (!wid) { check(NO, [NSString stringWithFormat:@"%@: window id found in CGWindowListCopyWindowInfo", name]); return nil; }
    NSString *path = [self.outDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.png", self.mode, name]];
    NSBitmapImageRep *rep = nil;
    // A window that has only just been ordered in sometimes can't be captured yet; give it a moment.
    for (int attempt = 0; attempt < 4 && !rep; attempt++) {
        if (attempt) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        NSTask *t = [[NSTask alloc] init];
        t.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
        t.arguments = @[@"-x", @"-o", [NSString stringWithFormat:@"-l%u", wid], path];
        NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
        [env removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];   // the tweak is for this process, not screencapture
        t.environment = env;
        if (![t launchAndReturnError:nil]) break;
        [t waitUntilExit];
        NSData *png = t.terminationStatus == 0 ? [NSData dataWithContentsOfFile:path] : nil;
        rep = png ? [[NSBitmapImageRep alloc] initWithData:png] : nil;
    }
    if (!rep) { check(NO, [NSString stringWithFormat:@"%@: screencapture produced %@", name, path]); return nil; }
    printf("  %s: window %u -> %s (%ldx%ld px)\n", name.UTF8String, wid, path.UTF8String, (long)rep.pixelsWide, (long)rep.pixelsHigh);
    return rep;
}

/// `r` in the view's coordinates (in the window's if `v` is nil). Fractions of pixels that are pure black (every channel <= 2/255) and bright
/// (luminance >= 0.55), the brightest luminance and the mean colour.
- (Sample)sample:(NSBitmapImageRep *)rep window:(NSWindow *)w view:(NSView *)v rect:(NSRect)r {
    Sample s = {0};
    NSRect wr = v ? [v convertRect:r toView:nil] : r;   // no view: r is in window coordinates
    double scale = (double)rep.pixelsWide / w.frame.size.width;
    NSInteger x0 = (NSInteger)floor(NSMinX(wr) * scale), x1 = (NSInteger)ceil(NSMaxX(wr) * scale);
    NSInteger y0 = (NSInteger)floor((w.frame.size.height - NSMaxY(wr)) * scale);
    NSInteger y1 = (NSInteger)ceil((w.frame.size.height - NSMinY(wr)) * scale);
    x0 = MAX(x0, 0); y0 = MAX(y0, 0); x1 = MIN(x1, rep.pixelsWide); y1 = MIN(y1, rep.pixelsHigh);
    NSUInteger n = 0, nBlack = 0, nBright = 0;
    NSUInteger px[8];
    double maxv = (double)((1u << rep.bitsPerSample) - 1);
    for (NSInteger y = y0; y < y1; y++) for (NSInteger x = x0; x < x1; x++) {
        [rep getPixel:px atX:x y:y];
        double r_ = px[0] / maxv, g_ = px[1] / maxv, b_ = px[2] / maxv;
        double lum = 0.2126 * r_ + 0.7152 * g_ + 0.0722 * b_;
        n++;
        if (r_ <= 2.0 / 255 && g_ <= 2.0 / 255 && b_ <= 2.0 / 255) nBlack++;
        if (lum >= 0.55) nBright++;
        s.maxLum = MAX(s.maxLum, lum);
        s.r += r_; s.g += g_; s.b += b_;
    }
    if (n) { s.black = (double)nBlack / n; s.bright = (double)nBright / n; s.r /= n; s.g /= n; s.b /= n; }
    return s;
}

- (Sample)report:(NSString *)what rep:(NSBitmapImageRep *)rep window:(NSWindow *)w view:(NSView *)v rect:(NSRect)r {
    Sample s = rep ? [self sample:rep window:w view:v rect:r] : (Sample){0};
    printf("    %-28s black %5.1f%%  bright %5.1f%%  max lum %.2f  mean #%02X%02X%02X\n", what.UTF8String,
           s.black * 100, s.bright * 100, s.maxLum, (int)lround(s.r * 255), (int)lround(s.g * 255), (int)lround(s.b * 255));
    return s;
}

- (void)dump:(NSView *)v depth:(int)d {
    NSMutableString *extra = [NSMutableString string];
    if ([v isKindOfClass:[NSVisualEffectView class]])
        [extra appendFormat:@" material=%ld state=%ld blending=%ld", (long)((NSVisualEffectView *)v).material,
         (long)((NSVisualEffectView *)v).state, (long)((NSVisualEffectView *)v).blendingMode];
    if (v.layer.backgroundColor) [extra appendFormat:@" layerBG=%@", [NSColor colorWithCGColor:v.layer.backgroundColor]];
    if (v.hidden || v.alphaValue < 1) [extra appendFormat:@" hidden=%d alpha=%.2f", v.hidden, v.alphaValue];
    printf("%*s%s %s%s\n", d * 2, "", NSStringFromClass([v class]).UTF8String, NSStringFromRect(v.frame).UTF8String, extra.UTF8String);
    for (NSView *s in v.subviews) [self dump:s depth:d + 1];
}

- (void)run {
    BOOL after = [self.mode isEqualToString:@"after"];
    NSView *theme = self.browserWindow.contentView.superview;
    if (getenv("OLF_DUMP")) [self dump:theme depth:0];

    printf("Browser window (%s)\n", self.mode.UTF8String);
    NSWindow *w = self.browserWindow;
    NSBitmapImageRep *rep = [self capture:w name:@"browser"];
    NSRect side = [self.sidebar.enclosingScrollView convertRect:self.sidebar.enclosingScrollView.bounds toView:nil];
    Sample sEmpty = [self report:@"sidebar background" rep:rep window:w view:nil   // below the last row
                           rect:NSMakeRect(NSMinX(side) + 16, NSMinY(side) + 20, NSWidth(side) - 32, 40)];
    Sample sText = [self report:@"sidebar row \"Downloads\"" rep:rep window:w view:self.sidebar rect:[self.sidebar rectOfRow:3]];
    Sample sSel = [self report:@"sidebar selected row" rep:rep window:w view:self.sidebar rect:[self.sidebar rectOfRow:2]];
    // The list is scrolled down by 60 pt, so its first rows sit under the header and the titlebar.
    NSRect rows = NSUnionRect([self.list rectOfRow:4], [self.list rectOfRow:8]);
    Sample lEmpty = [self report:@"list background" rep:rep window:w view:self.list
                           rect:NSMakeRect(600, NSMinY(rows), NSWidth(self.list.bounds) - 620, NSHeight(rows))];
    Sample lStripe = [self report:@"list row 5 (stripe)" rep:rep window:w view:self.list
                            rect:NSInsetRect(NSIntersectionRect([self.list rectOfRow:5], NSMakeRect(300, -1e6, 1e4, 2e6)), 0, 2)];
    Sample lText = [self report:@"list row \"Readme.txt\"" rep:rep window:w view:self.list rect:[self.list frameOfCellAtColumn:0 row:3]];
    NSRect h0 = [self.list.headerView headerRectOfColumn:0];
    Sample lHeader = [self report:@"list header over rows" rep:rep window:w view:self.list.headerView
                            rect:NSMakeRect(NSMinX(h0) + 70, NSMinY(h0) + 3, NSWidth(h0) - 80, NSHeight(h0) - 6)];
    NSCollectionViewItem *firstIcon = [self.icons itemAtIndex:0];
    NSRect lastIcon = [self.icons frameForItemAtIndex:self.files.count - 1];
    NSRect cvVisible = self.icons.visibleRect;
    Sample iEmpty = [self report:@"icon view background" rep:rep window:w view:self.icons   // right of the last icon
                           rect:NSMakeRect(NSMaxX(lastIcon) + 20, NSMinY(lastIcon) + 10, NSMaxX(cvVisible) - NSMaxX(lastIcon) - 40, 40)];
    Sample iText = [self report:@"icon label \"Invoices\"" rep:rep window:w view:firstIcon.view rect:firstIcon.textField.frame];
    NSRect brb = self.columns.bounds;
    Sample cEmpty = [self report:@"column view background" rep:rep window:w view:self.columns
                           rect:NSMakeRect(NSMaxX(brb) - 120, NSMidY(brb) - 15, 100, 30)];
    NSRect topLeft = NSMakeRect(4, self.columns.isFlipped ? 4 : NSMaxY(brb) - 48, 140, 44);
    Sample cText = [self report:@"column 0 rows" rep:rep window:w view:self.columns rect:topLeft];
    Sample tEmpty = [self report:@"titlebar right of items" rep:rep window:w view:theme
                           rect:NSMakeRect(NSMidX(theme.bounds) + 40, NSHeight(theme.bounds) - 46, 160, 40)];
    Sample pill = [self report:@"glass status pill" rep:rep window:w view:self.pill rect:NSInsetRect(self.pill.bounds, 8, 6)];

    printf("Desktop stand-in (level %ld)\n", (long)self.desktopWindow.level);
    NSBitmapImageRep *drep = [self capture:self.desktopWindow name:@"desktop"];
    Sample dWin = [self report:@"desktop window background" rep:drep window:self.desktopWindow view:self.desktopWindow.contentView
                         rect:NSMakeRect(10, 150, 300, 50)];
    Sample dScroll = [self report:@"desktop scroll view" rep:drep window:self.desktopWindow view:self.desktopScroll
                            rect:NSInsetRect(self.desktopScroll.bounds, 10, 10)];
    printf("Unrecognised window (TInfoWindow)\n");
    NSBitmapImageRep *irep = [self capture:self.infoWindow name:@"info"];
    Sample iScroll = [self report:@"info scroll view" rep:irep window:self.infoWindow view:self.infoScroll
                            rect:NSInsetRect(self.infoScroll.bounds, 10, 10)];

    if (!after) { printf("baseline captured\n"); [self finish]; return; }

    printf("Checks\n");
    check(rep != nil, @"browser window captured");
    check([w.appearance.name isEqualToString:NSAppearanceNameDarkAqua], @"browser window appearance is DarkAqua");
    check(sEmpty.black > 0.97, @"sidebar background is #000000");
    // Sidebar labels are vibrant and the window is inactive (the host never takes focus): #7A7A7A on black, about
    // the same contrast as the stock #969696 on #2C2C2C.
    check(sText.maxLum > 0.4, @"sidebar text is still readable");
    check(sSel.maxLum > 0.6 && sSel.black < 0.9, @"sidebar selection is still visible");
    check(lEmpty.black > 0.97, @"list background is #000000");
    check(lHeader.black > 0.97, @"rows scrolled under the list header are hidden by black");
    check(lStripe.black > 0.97, @"list rows are not striped grey");
    check(lText.maxLum > 0.6, @"list text is still bright");
    check(iEmpty.black > 0.97, @"icon view background is #000000");
    check(iText.maxLum > 0.6, @"icon labels are still bright");
    check(cEmpty.black > 0.97, @"column view background is #000000");
    check(cText.maxLum > 0.6, @"column view text is still bright");
    check(tEmpty.black > 0.90, @"titlebar/toolbar background is black");
    check(pill.black > 0.80 || pill.maxLum > 0.6, @"glass pill is black with bright text");
    check(drep != nil && dWin.b > 0.5 && dWin.b > dWin.r + 0.2, @"desktop stand-in window background untouched (blue)");
    check(drep != nil && dScroll.b > 0.5 && dScroll.b > dScroll.r + 0.2, @"desktop stand-in scroll view untouched (blue)");
    check(self.desktopWindow.appearance == nil, @"desktop stand-in appearance untouched");
    check(irep != nil && iScroll.r > 0.6, @"unrecognised window untouched");
    check(self.infoWindow.appearance == nil, @"unrecognised window appearance untouched");
    [self finish];
}

- (void)finish {
    if ([self.mode isEqualToString:@"after"]) printf("%s\n", failures == 0 ? "ALL PASSED" : "FAILED");
    exit(failures == 0 ? 0 : 1);
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    (void)n;
    [self buildBrowserWindow];
    [self buildDesktopWindow];
    [self buildInfoWindow];
    [self.desktopWindow orderFrontRegardless];
    [self.infoWindow orderFrontRegardless];
    [self.browserWindow orderFrontRegardless];
    // Watchdog: never hang.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        check(NO, @"finished within 30 s");
        [self finish];
    });
    // Views added after the window is on screen: the tweak has to catch them too.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.columns selectRow:1 inColumn:0];   // "Photos 2026": opens a second column
        NSClipView *clip = self.list.enclosingScrollView.contentView;
        [clip scrollToPoint:NSMakePoint(0, clip.bounds.origin.y + 60)];
        [self.list.enclosingScrollView reflectScrolledClipView:clip];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self run]; });
}
@end

int main(void) {
    @autoreleasepool {
        Host *host = [Host new];
        host.mode = getenv("OLF_MODE") ? @(getenv("OLF_MODE")) : @"after";
        host.outDir = getenv("OLF_OUT") ? @(getenv("OLF_OUT")) : NSTemporaryDirectory();
        if ([host.mode isEqualToString:@"after"] && !getenv("DYLD_INSERT_LIBRARIES")) {
            fprintf(stderr, "run with DYLD_INSERT_LIBRARIES=<test build of libOLEDFinder.dylib>, or OLF_MODE=before\n");
            return 2;
        }
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;   // no Dock icon, no focus steal
        app.delegate = host;
        [app run];
    }
    return 0;
}
