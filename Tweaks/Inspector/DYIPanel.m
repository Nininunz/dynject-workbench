// Inspector: the panel. An ordinary window of the app (in Mission Control, Spaces and ⌘`), built in code (no nibs, no SwiftUI): a header with the class,
// pointer, image and superclass chain (click a class to show its methods, ivars and properties), back/forward history
// and five tabs in one table: hierarchy, properties, methods, ivars and a runtime class browser.
//
// Read-only. Properties in the curated overview are read with plain, known-safe getters; every other property is read
// only when its row is clicked, one getter call in @try. Nothing is ever set or invoked otherwise.
#import "DYIInternal.h"

typedef NS_ENUM(NSInteger, DYITab) { DYITabHierarchy, DYITabProperties, DYITabMethods, DYITabIvars, DYITabRuntime };
static NSArray<NSString *> *DYITabNames(void) { return @[@"Hierarchy", @"Properties", @"Methods", @"Ivars", @"Runtime"]; }

@interface DYIRow : NSObject
@property (nonatomic, copy) NSString *left;
@property (nonatomic, copy) NSString *right;
@property (nonatomic) BOOL group;
@property (nonatomic) BOOL emphasized;               // "self" in the hierarchy
@property (nonatomic, strong, nullable) id target;   // object to inspect on click
@property (nonatomic, unsafe_unretained, nullable) Class targetClass;   // class to open on click
@property (nonatomic, strong, nullable) DYIPropertyInfo *property;     // evaluable property
@property (nonatomic) BOOL evaluated;
@property (nonatomic, strong, nullable) DYIMethodInfo *method;
@property (nonatomic) NSInteger indent;
@end
@implementation DYIRow
+ (instancetype)group:(NSString *)title {
    DYIRow *r = [DYIRow new];
    r.left = title;
    r.right = @"";
    r.group = YES;
    return r;
}
+ (instancetype)left:(NSString *)left right:(NSString *)right {
    DYIRow *r = [DYIRow new];
    r.left = left ?: @"";
    r.right = right ?: @"";
    return r;
}
@end

/// One entry of the history: an object (with its class) or a class without an instance.
@interface DYITarget : NSObject
@property (nonatomic, strong, nullable) id object;
@property (nonatomic, unsafe_unretained) Class cls;
@property (nonatomic, unsafe_unretained) Class context;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray *> *evaluated;   // "Class.prop" -> @[text, value]
@end
@implementation DYITarget
@end

@interface DYIInspectorPanel : NSWindow
@end
@implementation DYIInspectorPanel
@end

@interface DYIPanelController () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSMenuDelegate>
@property (nonatomic, readwrite, strong, nullable) NSWindow *panel;
@property (nonatomic, strong) NSTextField *header;
@property (nonatomic, strong) NSPathControl *chain;
@property (nonatomic, strong) NSSegmentedControl *tabs;
@property (nonatomic, strong) NSButton *backButton, *forwardButton, *pickButton, *hookButton;
@property (nonatomic, strong) NSSearchField *search;
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, strong) NSMutableArray<DYITarget *> *history;
@property (nonatomic) NSInteger index;
@property (nonatomic, strong) NSArray<DYIRow *> *rows;
@property (nonatomic) DYITab tab;
@property (nonatomic, strong, nullable) NSArray<NSString *> *classNames;
@property (nonatomic) BOOL placed;
@end

@implementation DYIPanelController

+ (instancetype)shared {
    static DYIPanelController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [DYIPanelController new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _history = [NSMutableArray array];
        _index = -1;
        _rows = @[];
        _tab = DYITabProperties;
    }
    return self;
}

- (nullable DYITarget *)current {
    return (self.index >= 0 && self.index < (NSInteger)self.history.count) ? self.history[(NSUInteger)self.index] : nil;
}

#pragma mark Building the panel

static NSButton *DYIButton(NSString *title, NSString *symbol, id target, SEL action) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    if (symbol) {
        b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
        b.imagePosition = title.length ? NSImageLeading : NSImageOnly;
    }
    b.controlSize = NSControlSizeSmall;
    b.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    b.bezelStyle = NSBezelStyleRounded;
    [b sizeToFit];
    return b;
}

- (void)buildPanel {
    CGFloat W = 640, H = 700;
    DYIInspectorPanel *p = [[DYIInspectorPanel alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    // A normal window of the app, not a floating utility panel: it shows in Mission Control and the app's
    // window list, stays put when the app is in the background, and lives on its own Space like the app's other
    // windows (a floating panel that hides on deactivate and follows the active Space vanished from Mission
    // Control and jumped around).
    p.hidesOnDeactivate = NO;
    p.releasedWhenClosed = NO;
    p.tabbingMode = NSWindowTabbingModeDisallowed;
    p.minSize = NSMakeSize(420, 360);
    p.delegate = self;
    p.excludedFromWindowsMenu = NO;
    p.collectionBehavior = NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorParticipatesInCycle;
    NSString *app = NSRunningApplication.currentApplication.localizedName ?: NSProcessInfo.processInfo.processName;
    p.title = [NSString stringWithFormat:@"Inspector — %@", app];
    NSView *root = p.contentView;

    CGFloat y = H - 34;
    self.backButton = DYIButton(@"", @"chevron.left", self, @selector(goBack:));
    self.backButton.frame = NSMakeRect(8, y, 28, 24);
    self.forwardButton = DYIButton(@"", @"chevron.right", self, @selector(goForward:));
    self.forwardButton.frame = NSMakeRect(38, y, 28, 24);
    self.tabs = [NSSegmentedControl segmentedControlWithLabels:DYITabNames() trackingMode:NSSegmentSwitchTrackingSelectOne
                                                        target:self action:@selector(tabChanged:)];
    self.tabs.controlSize = NSControlSizeSmall;
    self.tabs.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    [self.tabs sizeToFit];
    self.tabs.frame = NSMakeRect(74, y + 1, NSWidth(self.tabs.frame), 22);
    self.pickButton = DYIButton(@"Pick", @"scope", self, @selector(pick:));
    self.pickButton.frame = NSMakeRect(W - NSWidth(self.pickButton.frame) - 10, y, NSWidth(self.pickButton.frame), 24);
    self.pickButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    for (NSView *v in @[self.backButton, self.forwardButton, self.tabs]) v.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;

    y -= 66;
    self.header = [NSTextField wrappingLabelWithString:@""];
    self.header.selectable = YES;
    self.header.frame = NSMakeRect(12, y, W - 24, 60);
    self.header.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.header.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.header.lineBreakMode = NSLineBreakByTruncatingMiddle;

    y -= 26;
    self.chain = [[NSPathControl alloc] initWithFrame:NSMakeRect(8, y, W - 16, 22)];
    self.chain.pathStyle = NSPathStyleStandard;
    self.chain.editable = NO;
    self.chain.controlSize = NSControlSizeSmall;
    self.chain.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    self.chain.target = self;
    self.chain.action = @selector(chainClicked:);
    self.chain.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.chain.toolTip = @"superclass chain: click a class to show its properties, methods and ivars";

    y -= 30;
    CGFloat x = 8;
    NSArray *buttons = @[DYIButton(@"Copy Class Name", @"doc.on.doc", self, @selector(copyClassName:)),
                         DYIButton(@"Copy Description", @"text.quote", self, @selector(copyDescription:)),
                         DYIButton(@"Copy Hook", @"curlybraces", self, @selector(copyHook:))];
    self.hookButton = buttons[2];
    for (NSButton *b in buttons) {
        b.frame = NSMakeRect(x, y, NSWidth(b.frame) + 6, 24);
        b.autoresizingMask = NSViewMinYMargin | NSViewMaxXMargin;
        x += NSWidth(b.frame) + 6;
        [root addSubview:b];
    }
    self.hookButton.toolTip = @"a DynjectHook hook class for the selected method";

    y -= 30;
    self.search = [[NSSearchField alloc] initWithFrame:NSMakeRect(8, y, W - 16, 24)];
    self.search.placeholderString = @"Filter";
    self.search.sendsSearchStringImmediately = YES;
    self.search.target = self;
    self.search.action = @selector(searchChanged:);
    self.search.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 24, W, y - 30)];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    for (NSString *ident in @[@"left", @"right"]) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
        NSTextFieldCell *cell = [[NSTextFieldCell alloc] initTextCell:@""];
        cell.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        cell.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.truncatesLastVisibleLine = YES;
        col.dataCell = cell;
        col.editable = NO;
        col.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
        [self.table addTableColumn:col];
    }
    self.table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    self.table.usesAlternatingRowBackgroundColors = YES;
    self.table.style = NSTableViewStylePlain;
    self.table.rowHeight = 18;
    self.table.intercellSpacing = NSMakeSize(8, 2);
    self.table.allowsMultipleSelection = NO;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.target = self;
    self.table.action = @selector(tableClicked:);
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Inspector"];
    menu.delegate = self;
    self.table.menu = menu;
    scroll.documentView = self.table;

    self.status = [NSTextField labelWithString:@""];
    self.status.frame = NSMakeRect(10, 4, W - 20, 16);
    self.status.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    self.status.textColor = [NSColor secondaryLabelColor];
    self.status.lineBreakMode = NSLineBreakByTruncatingTail;
    self.status.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;

    for (NSView *v in @[self.backButton, self.forwardButton, self.tabs, self.pickButton, self.header, self.chain,
                        self.search, scroll, self.status]) [root addSubview:v];
    self.panel = p;
}

- (void)showPanel {
    if (!self.panel) [self buildPanel];
    if (!self.placed) {
        NSScreen *screen = NSApp.keyWindow.screen ?: NSApp.mainWindow.screen ?: NSScreen.mainScreen;
        NSRect vis = screen.visibleFrame;
        NSRect f = self.panel.frame;
        f.size.height = MIN(f.size.height, vis.size.height - 40);
        f.origin = NSMakePoint(NSMaxX(vis) - NSWidth(f) - 24, NSMaxY(vis) - NSHeight(f) - 24);
        [self.panel setFrame:f display:NO];
        self.placed = YES;
    }
    [self.panel makeKeyAndOrderFront:nil];
    if (!NSApp.isActive) [self.panel orderFrontRegardless];
}

- (void)close {
    [self.panel orderOut:nil];
    [self clearHistory];
}

- (void)clearHistory {
    [self.history removeAllObjects];
    self.index = -1;
    self.rows = @[];
    [self.table reloadData];
}

- (void)windowWillClose:(NSNotification *)note {
    (void)note;
    [self clearHistory];   // don't keep the inspected objects alive
}

#pragma mark Navigation

- (void)push:(DYITarget *)t {
    if (self.index + 1 < (NSInteger)self.history.count)
        [self.history removeObjectsInRange:NSMakeRange((NSUInteger)(self.index + 1), self.history.count - (NSUInteger)(self.index + 1))];
    [self.history addObject:t];
    while (self.history.count > 64) [self.history removeObjectAtIndex:0];
    self.index = (NSInteger)self.history.count - 1;
    self.search.stringValue = @"";
    if (self.tab == DYITabRuntime) self.tab = DYITabProperties;
    [self showPanel];
    [self refresh];
}

- (void)inspectObject:(id)object {
    if (!object || !DYIEnabled()) return;
    DYITarget *t = [DYITarget new];
    t.object = object;
    t.cls = object_getClass(object);
    t.context = t.cls;
    t.evaluated = [NSMutableDictionary dictionary];
    [self push:t];
}

- (void)inspectClass:(Class)cls {
    if (!cls || !DYIEnabled()) return;
    DYITarget *t = [DYITarget new];
    t.cls = cls;
    t.context = cls;
    t.evaluated = [NSMutableDictionary dictionary];
    if (self.tab == DYITabRuntime || self.tab == DYITabHierarchy) self.tab = DYITabMethods;
    [self push:t];
}

- (void)goBack:(id)sender {
    (void)sender;
    if (self.index > 0) { self.index--; [self refresh]; }
}

- (void)goForward:(id)sender {
    (void)sender;
    if (self.index + 1 < (NSInteger)self.history.count) { self.index++; [self refresh]; }
}

- (void)tabChanged:(id)sender {
    (void)sender;
    self.tab = (DYITab)self.tabs.selectedSegment;
    self.search.stringValue = @"";
    [self refresh];
}

- (void)searchChanged:(id)sender {
    (void)sender;
    [self rebuildRows];
}

- (void)pick:(id)sender {
    (void)sender;
    [[DYIPicker shared] beginWithHold:NO];
}

- (void)chainClicked:(id)sender {
    (void)sender;
    NSPathControlItem *item = self.chain.clickedPathItem;
    NSUInteger i = item ? [self.chain.pathItems indexOfObject:item] : NSNotFound;
    DYITarget *t = self.current;
    if (!t || i == NSNotFound) return;
    NSArray *classes = DYIClassChain(t.cls);
    if (i < classes.count) [self setContext:classes[i]];
}

- (void)setContext:(Class)cls {
    DYITarget *t = self.current;
    if (!t || !cls) return;
    t.context = cls;
    [self refresh];
}

#pragma mark Content

- (void)refresh {
    DYITarget *t = self.current;
    self.backButton.enabled = self.index > 0;
    self.forwardButton.enabled = self.index + 1 < (NSInteger)self.history.count;
    self.tabs.selectedSegment = self.tab;
    [self updateHeader:t];
    [self updateColumns];
    [self rebuildRows];
}

- (void)updateHeader:(nullable DYITarget *)t {
    if (!t) { self.header.stringValue = @""; self.chain.pathItems = @[]; return; }
    NSString *clsName = NSStringFromClass(t.cls);
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] init];
    NSDictionary *bold = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightBold],
                           NSForegroundColorAttributeName: [NSColor labelColor]};
    NSDictionary *plain = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
                            NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:clsName attributes:bold]];
    NSString *ptr = t.object ? [NSString stringWithFormat:@"  %p", (__bridge void *)t.object] : @"  class (no instance)";
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:ptr attributes:plain]];
    NSString *image = DYIImageOfClass(t.context);
    NSMutableString *more = [NSMutableString stringWithFormat:@"\nimage: %@  %@", DYIShortImageName(image), image.length ? image : @"(created at runtime)"];
    if (t.context != t.cls) [more appendFormat:@"\nshowing: %@", NSStringFromClass(t.context)];
    NSArray *protocols = DYIProtocolsOfClass(t.context);
    if (protocols.count > 6)
        [more appendFormat:@"\nprotocols: %@ (+%lu more)", [[protocols subarrayWithRange:NSMakeRange(0, 6)] componentsJoinedByString:@", "],
                           (unsigned long)protocols.count - 6];
    else if (protocols.count) [more appendFormat:@"\nprotocols: %@", [protocols componentsJoinedByString:@", "]];
    [s appendAttributedString:[[NSAttributedString alloc] initWithString:more attributes:plain]];
    self.header.attributedStringValue = s;

    NSMutableArray *items = [NSMutableArray array];
    for (Class c in DYIClassChain(t.cls)) {
        NSPathControlItem *item = [NSPathControlItem new];
        NSDictionary *attrs = @{NSFontAttributeName: c == t.context ? [NSFont boldSystemFontOfSize:NSFont.smallSystemFontSize]
                                                                   : [NSFont systemFontOfSize:NSFont.smallSystemFontSize]};
        item.attributedTitle = [[NSAttributedString alloc] initWithString:NSStringFromClass(c) attributes:attrs];
        [items addObject:item];
    }
    self.chain.pathItems = items;
}

- (void)updateColumns {
    NSArray *titles;
    switch (self.tab) {
        case DYITabHierarchy:  titles = @[@"Object", @"Frame / Info"]; break;
        case DYITabProperties: titles = @[@"Property", @"Value (click to evaluate)"]; break;
        case DYITabMethods:    titles = @[@"Signature", @"Image"]; break;
        case DYITabIvars:      titles = @[@"Ivar", @"Type · Offset"]; break;
        case DYITabRuntime:    titles = @[@"Class", @"Image"]; break;
    }
    NSTableColumn *l = self.table.tableColumns[0], *r = self.table.tableColumns[1];
    l.title = titles[0];
    r.title = titles[1];
    CGFloat total = NSWidth(self.table.enclosingScrollView.frame) - 30;
    CGFloat split = (self.tab == DYITabMethods) ? 0.72 : (self.tab == DYITabProperties ? 0.38 : 0.5);
    l.width = floor(total * split);
    r.width = floor(total * (1 - split));
    self.hookButton.enabled = self.tab == DYITabMethods;
    self.search.placeholderString = self.tab == DYITabRuntime ? @"Search all classes in this process" : @"Filter";
}

- (void)rebuildRows {
    DYITarget *t = self.current;
    NSArray<DYIRow *> *all = @[];
    if (self.tab == DYITabRuntime) all = [self runtimeRows];
    else if (t) {
        switch (self.tab) {
            case DYITabHierarchy:  all = [self hierarchyRows:t]; break;
            case DYITabProperties: all = [self propertyRows:t]; break;
            case DYITabMethods:    all = [self methodRows:t]; break;
            case DYITabIvars:      all = [self ivarRows:t]; break;
            case DYITabRuntime:    break;
        }
    }
    NSString *q = self.search.stringValue;
    if (q.length && self.tab != DYITabRuntime) {
        NSMutableArray *filtered = [NSMutableArray array];
        DYIRow *pendingGroup = nil;
        for (DYIRow *r in all) {
            if (r.group) { pendingGroup = r; continue; }
            BOOL match = [r.left rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound ||
                         [r.right rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound;
            if (!match) continue;
            if (pendingGroup) { [filtered addObject:pendingGroup]; pendingGroup = nil; }
            [filtered addObject:r];
        }
        all = filtered;
    }
    self.rows = all;
    [self.table reloadData];
    [self.table deselectAll:nil];
}

static NSString *DYIIndent(NSInteger n) { return [@"" stringByPaddingToLength:(NSUInteger)MAX(n, 0) * 2 withString:@" " startingAtIndex:0]; }

static DYIRow *DYILinkRow(NSString *left, id object, NSString *right, NSInteger indent) {
    DYIRow *r = [DYIRow left:[DYIIndent(indent) stringByAppendingString:left] right:right];
    r.target = object;
    r.indent = indent;
    return r;
}

static NSString *DYIViewInfo(NSView *v) {
    __block NSString *s = @"";
    DYITry(^{ s = [NSString stringWithFormat:@"%@%@", NSStringFromRect(v.frame), v.isHidden ? @" hidden" : @""]; });
    return s;
}

static NSString *DYILayerInfo(CALayer *l) {
    __block NSString *s = @"";
    DYITry(^{ s = [NSString stringWithFormat:@"%@%@", NSStringFromRect(l.frame), l.hidden ? @" hidden" : @""]; });
    return s;
}

- (NSArray<DYIRow *> *)hierarchyRows:(DYITarget *)t {
    NSMutableArray *rows = [NSMutableArray array];
    id o = t.object;
    if (!o) {   // a class: its superclass chain
        [rows addObject:[DYIRow group:@"Superclasses"]];
        NSArray *chain = DYIClassChain(t.cls);
        NSInteger depth = 0;
        for (Class c in chain.reverseObjectEnumerator) {
            DYIRow *r = [DYIRow left:[DYIIndent(depth++) stringByAppendingString:NSStringFromClass(c)] right:DYIShortImageName(DYIImageOfClass(c))];
            r.targetClass = c;
            r.emphasized = (c == t.cls);
            [rows addObject:r];
        }
        return rows;
    }
    NSString *err = DYITry(^{
        if ([o isKindOfClass:[NSView class]]) {
            NSView *v = o;
            NSMutableArray *ancestors = [NSMutableArray array];
            for (NSView *s = v.superview; s && ancestors.count < 200; s = s.superview) [ancestors insertObject:s atIndex:0];
            [rows addObject:[DYIRow group:@"Ancestors"]];
            if (v.window) [rows addObject:DYILinkRow(NSStringFromClass(object_getClass(v.window)), v.window, [NSString stringWithFormat:@"window \"%@\"", v.window.title ?: @""], 0)];
            NSInteger depth = 0;
            for (NSView *a in ancestors) [rows addObject:DYILinkRow(NSStringFromClass(object_getClass(a)), a, DYIViewInfo(a), depth++)];
            DYIRow *me = [DYIRow left:[DYIIndent(depth) stringByAppendingString:[@"▶ " stringByAppendingString:NSStringFromClass(object_getClass(v))]] right:DYIViewInfo(v)];
            me.emphasized = YES;
            [rows addObject:me];
            [rows addObject:[DYIRow group:[NSString stringWithFormat:@"Subviews (%lu)", (unsigned long)v.subviews.count]]];
            for (NSView *s in v.subviews) [rows addObject:DYILinkRow(NSStringFromClass(object_getClass(s)), s, DYIViewInfo(s), 0)];
            if (v.layer) {
                [rows addObject:[DYIRow group:@"Layer"]];
                [rows addObject:DYILinkRow(NSStringFromClass(object_getClass(v.layer)), v.layer, DYILayerInfo(v.layer), 0)];
            }
        } else if ([o isKindOfClass:[CALayer class]]) {
            CALayer *l = o;
            NSMutableArray *ancestors = [NSMutableArray array];
            for (CALayer *s = l.superlayer; s && ancestors.count < 200; s = s.superlayer) [ancestors insertObject:s atIndex:0];
            [rows addObject:[DYIRow group:@"Ancestors"]];
            NSInteger depth = 0;
            for (CALayer *a in ancestors) [rows addObject:DYILinkRow(NSStringFromClass(object_getClass(a)), a, DYILayerInfo(a), depth++)];
            DYIRow *me = [DYIRow left:[DYIIndent(depth) stringByAppendingString:[@"▶ " stringByAppendingString:NSStringFromClass(object_getClass(l))]] right:DYILayerInfo(l)];
            me.emphasized = YES;
            [rows addObject:me];
            [rows addObject:[DYIRow group:[NSString stringWithFormat:@"Sublayers (%lu)", (unsigned long)l.sublayers.count]]];
            for (CALayer *s in l.sublayers) [rows addObject:DYILinkRow(NSStringFromClass(object_getClass(s)), s, DYILayerInfo(s), 0)];
            id delegate = l.delegate;
            if (delegate || l.mask) [rows addObject:[DYIRow group:@"Related"]];
            if (delegate) [rows addObject:DYILinkRow(NSStringFromClass(object_getClass(delegate)), delegate, @"delegate", 0)];
            if (l.mask) [rows addObject:DYILinkRow(NSStringFromClass(object_getClass(l.mask)), l.mask, @"mask", 0)];
        } else if ([o isKindOfClass:[NSWindow class]]) {
            NSWindow *w = o;
            [rows addObject:[DYIRow group:@"Views"]];
            NSView *frameView = w.contentView.superview;
            if (frameView) [rows addObject:DYILinkRow(NSStringFromClass(object_getClass(frameView)), frameView, @"frame view", 0)];
            if (w.contentView) [rows addObject:DYILinkRow(NSStringFromClass(object_getClass(w.contentView)), w.contentView, @"content view", 1)];
            if (w.childWindows.count || w.parentWindow) [rows addObject:[DYIRow group:@"Windows"]];
            if (w.parentWindow) [rows addObject:DYILinkRow(NSStringFromClass(object_getClass(w.parentWindow)), w.parentWindow, @"parent window", 0)];
            for (NSWindow *c in w.childWindows) [rows addObject:DYILinkRow(NSStringFromClass(object_getClass(c)), c, @"child window", 0)];
        } else if ([o isKindOfClass:[NSResponder class]]) {
            [rows addObject:[DYIRow group:@"Responder chain"]];
            NSInteger n = 0;
            for (NSResponder *r = [(NSResponder *)o nextResponder]; r && n < 50; r = r.nextResponder, n++)
                [rows addObject:DYILinkRow(NSStringFromClass(object_getClass(r)), r, @"next responder", 0)];
        } else {
            [rows addObject:[DYIRow left:@"(no view or layer hierarchy for this object)" right:@""]];
        }
    });
    if (err) [rows addObject:[DYIRow left:@"exception" right:err]];
    return rows;
}

/// Overview rows: a fixed set of getters known to be cheap and side-effect free for these classes.
- (NSArray<DYIRow *> *)curatedRows:(DYITarget *)t {
    NSMutableArray *rows = [NSMutableArray array];
    id o = t.object;
    if (!o) return rows;
    [rows addObject:[DYIRow group:@"Overview (safe getters, read automatically)"]];
    void (^add)(NSString *, NSString *) = ^(NSString *k, NSString *v) { [rows addObject:[DYIRow left:k right:v ?: @"nil"]]; };
    void (^link)(NSString *, id) = ^(NSString *k, id v) {
        DYIRow *r = [DYIRow left:k right:v ? DYIPointerString(v) : @"nil"];
        r.target = v;
        [rows addObject:r];
    };
    add(@"class", NSStringFromClass(t.cls));
    add(@"pointer", [NSString stringWithFormat:@"%p", (__bridge void *)o]);
    NSString *err = DYITry(^{
        if ([o isKindOfClass:[NSView class]]) {
            NSView *v = o;
            add(@"frame", NSStringFromRect(v.frame));
            add(@"frame in window", v.window ? NSStringFromRect([v convertRect:v.bounds toView:nil]) : @"(not in a window)");
            add(@"bounds", NSStringFromRect(v.bounds));
            add(@"alphaValue", [NSString stringWithFormat:@"%g", v.alphaValue]);
            add(@"isHidden", v.isHidden ? @"YES" : @"NO");
            add(@"isFlipped", v.isFlipped ? @"YES" : @"NO");
            add(@"wantsLayer", v.wantsLayer ? @"YES" : @"NO");
            link(@"layer", v.layer);
            add(@"identifier", v.identifier ?: @"nil");
            add(@"accessibilityIdentifier", v.accessibilityIdentifier.length ? v.accessibilityIdentifier : @"(none)");
            add(@"accessibilityRole", v.accessibilityRole ?: @"(none)");
            add(@"accessibilityLabel", v.accessibilityLabel.length ? [NSString stringWithFormat:@"\"%@\"", v.accessibilityLabel] : @"(none)");
            link(@"window", v.window);
            add(@"window title", v.window ? [NSString stringWithFormat:@"\"%@\"", v.window.title ?: @""] : @"(none)");
            link(@"superview", v.superview);
            add(@"subviews", [NSString stringWithFormat:@"%lu", (unsigned long)v.subviews.count]);
            add(@"effectiveAppearance", v.effectiveAppearance.name ?: @"nil");
        }
        if ([o isKindOfClass:[CALayer class]]) {
            CALayer *l = o;
            add(@"frame", NSStringFromRect(l.frame));
            add(@"bounds", NSStringFromRect(l.bounds));
            add(@"position", NSStringFromPoint(l.position));
            add(@"anchorPoint", NSStringFromPoint(l.anchorPoint));
            add(@"zPosition", [NSString stringWithFormat:@"%g", l.zPosition]);
            add(@"cornerRadius", [NSString stringWithFormat:@"%g", l.cornerRadius]);
            add(@"cornerCurve", l.cornerCurve ?: @"nil");
            add(@"opacity", [NSString stringWithFormat:@"%g", l.opacity]);
            add(@"isHidden", l.hidden ? @"YES" : @"NO");
            add(@"masksToBounds", l.masksToBounds ? @"YES" : @"NO");
            add(@"backgroundColor", DYIDescribeCGColor(l.backgroundColor));
            add(@"borderColor", DYIDescribeCGColor(l.borderColor));
            add(@"borderWidth", [NSString stringWithFormat:@"%g", l.borderWidth]);
            add(@"filters", l.filters ? DYIDescriptionOf(l.filters, 400) : @"nil");
            add(@"compositingFilter", l.compositingFilter ? DYIDescriptionOf(l.compositingFilter, 400) : @"nil");
            add(@"backgroundFilters", l.backgroundFilters ? DYIDescriptionOf(l.backgroundFilters, 400) : @"nil");
            id contents = l.contents;
            add(@"contents", contents ? [NSString stringWithFormat:@"%s %p", object_getClassName(contents), (__bridge void *)contents] : @"nil");
            add(@"sublayers", [NSString stringWithFormat:@"%lu", (unsigned long)l.sublayers.count]);
            add(@"transform", CATransform3DIsIdentity(l.transform) ? @"identity" : DYIDescribe([NSValue valueWithCATransform3D:l.transform]));
            add(@"name", l.name ?: @"nil");
            link(@"delegate", l.delegate);
            link(@"superlayer", l.superlayer);
            link(@"mask", l.mask);
        }
        if ([o isKindOfClass:[NSWindow class]]) {
            NSWindow *w = o;
            add(@"title", [NSString stringWithFormat:@"\"%@\"", w.title ?: @""]);
            add(@"frame", NSStringFromRect(w.frame));
            add(@"level", [NSString stringWithFormat:@"%ld", (long)w.level]);
            add(@"styleMask", [NSString stringWithFormat:@"0x%lx", (unsigned long)w.styleMask]);
            add(@"isVisible", w.isVisible ? @"YES" : @"NO");
            add(@"isKeyWindow", w.isKeyWindow ? @"YES" : @"NO");
            add(@"alphaValue", [NSString stringWithFormat:@"%g", w.alphaValue]);
            add(@"windowNumber", [NSString stringWithFormat:@"%ld", (long)w.windowNumber]);
            link(@"contentView", w.contentView);
        }
    });
    if (err) add(@"exception", err);
    // Core Animation's SDF classes (Liquid Glass shapes and effects): their own declared properties are plain values.
    for (Class c in DYIClassChain(t.cls)) {
        NSString *name = NSStringFromClass(c);
        if (![name hasPrefix:@"CASDF"]) continue;
        NSArray *props = DYIPropertiesOfClass(c);
        if (!props.count) continue;
        [rows addObject:[DYIRow group:[NSString stringWithFormat:@"%@ (read automatically)", name]]];
        for (DYIPropertyInfo *p in props) {
            id value = nil;
            NSString *text = DYIEvaluateProperty(o, p, &value);
            DYIRow *r = [DYIRow left:p.name right:text];
            r.target = value;
            [rows addObject:r];
        }
    }
    return rows;
}

- (NSArray<DYIRow *> *)propertyRows:(DYITarget *)t {
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObjectsFromArray:[self curatedRows:t]];
    for (Class c in DYIClassChain(t.context)) {
        NSArray<DYIPropertyInfo *> *props = DYIPropertiesOfClass(c);
        if (!props.count) continue;
        [rows addObject:[DYIRow group:[NSString stringWithFormat:@"%@ (%lu)", NSStringFromClass(c), (unsigned long)props.count]]];
        for (DYIPropertyInfo *p in props) {
            NSString *typeInfo = p.attributes.length ? [NSString stringWithFormat:@"%@ · %@", p.readableType, p.attributes] : p.readableType;
            DYIRow *r = [DYIRow left:p.name right:typeInfo];
            if (t.object) {
                r.property = p;
                NSArray *done = t.evaluated[[NSString stringWithFormat:@"%@.%@", NSStringFromClass(c), p.name]];
                if (done) {
                    r.evaluated = YES;
                    r.right = done[0];
                    r.target = done[1] == [NSNull null] ? nil : done[1];
                } else {
                    r.right = [@"▸ evaluate   " stringByAppendingString:typeInfo];
                }
            }
            [rows addObject:r];
        }
    }
    return rows;
}

- (NSArray<DYIRow *> *)methodRows:(DYITarget *)t {
    NSMutableArray *rows = [NSMutableArray array];
    NSString *classImage = DYIShortImageName(DYIImageOfClass(t.context));
    for (NSNumber *isClass in @[@YES, @NO]) {
        NSArray<DYIMethodInfo *> *methods = DYIMethodsOfClass(t.context, isClass.boolValue);
        [rows addObject:[DYIRow group:[NSString stringWithFormat:@"%@ methods of %@ (%lu)", isClass.boolValue ? @"Class" : @"Instance",
                                       NSStringFromClass(t.context), (unsigned long)methods.count]]];
        for (DYIMethodInfo *m in methods) {
            // An implementation from another image is a category or a hook: worth seeing.
            NSString *image = [m.image isEqualToString:classImage] ? m.image : [NSString stringWithFormat:@"%@ (not %@)", m.image, classImage];
            DYIRow *r = [DYIRow left:m.signature right:image];
            r.method = m;
            [rows addObject:r];
        }
    }
    return rows;
}

- (NSArray<DYIRow *> *)ivarRows:(DYITarget *)t {
    NSMutableArray *rows = [NSMutableArray array];
    for (Class c in DYIClassChain(t.context)) {
        NSArray<DYIIvarInfo *> *ivars = DYIIvarsOfClass(c);
        if (!ivars.count) continue;
        [rows addObject:[DYIRow group:[NSString stringWithFormat:@"%@ (%lu)", NSStringFromClass(c), (unsigned long)ivars.count]]];
        for (DYIIvarInfo *i in ivars)
            [rows addObject:[DYIRow left:i.name right:[NSString stringWithFormat:@"%@ · @%td", i.readableType, i.offset]]];
    }
    return rows;
}

- (NSArray<DYIRow *> *)runtimeRows {
    NSMutableArray *rows = [NSMutableArray array];
    if (!self.classNames) {
        [rows addObject:[DYIRow group:@"Loading the class list…"]];
        __weak DYIPanelController *weakSelf = self;
        DYILoadClassNames(^(NSArray<NSString *> *names) {
            DYIPanelController *me = weakSelf;
            if (!me || me.classNames) return;
            me.classNames = names;
            if (me.tab == DYITabRuntime) [me rebuildRows];
        });
        return rows;
    }
    NSString *q = self.search.stringValue;
    if (q.length == 0) {
        [rows addObject:[DYIRow group:[NSString stringWithFormat:@"%lu classes loaded. Type to search.", (unsigned long)self.classNames.count]]];
        return rows;
    }
    NSMutableArray *hits = [NSMutableArray array];
    for (NSString *name in self.classNames)
        if ([name rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) [hits addObject:name];
    [rows addObject:[DYIRow group:[NSString stringWithFormat:@"%lu of %lu classes match%@", (unsigned long)hits.count,
                                   (unsigned long)self.classNames.count, hits.count > 1000 ? @" (first 1000 shown)" : @""]]];
    NSUInteger n = 0;
    for (NSString *name in hits) {
        if (n++ >= 1000) break;
        Class c = objc_lookUpClass(name.UTF8String);
        DYIRow *r = [DYIRow left:name right:c ? DYIShortImageName(DYIImageOfClass(c)) : @""];
        r.targetClass = c;
        [rows addObject:r];
    }
    return rows;
}

#pragma mark Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)self.rows.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView;
    if (row < 0 || row >= (NSInteger)self.rows.count) return @"";
    DYIRow *r = self.rows[(NSUInteger)row];
    if (r.group) return [column.identifier isEqualToString:@"left"] ? r.left : @"";
    return [column.identifier isEqualToString:@"left"] ? r.left : r.right;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row {
    (void)tableView;
    return row >= 0 && row < (NSInteger)self.rows.count && self.rows[(NSUInteger)row].group;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return ![self tableView:tableView isGroupRow:row];
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView;
    if (![cell isKindOfClass:[NSTextFieldCell class]] || row < 0 || row >= (NSInteger)self.rows.count) return;
    NSTextFieldCell *c = cell;
    DYIRow *r = self.rows[(NSUInteger)row];
    BOOL left = [column.identifier isEqualToString:@"left"];
    c.font = r.group ? [NSFont boldSystemFontOfSize:11]
                     : [NSFont monospacedSystemFontOfSize:11 weight:r.emphasized ? NSFontWeightBold : NSFontWeightRegular];
    NSColor *color = [NSColor labelColor];
    if (r.group) color = [NSColor secondaryLabelColor];
    else if (self.tab == DYITabHierarchy && left && (r.target || r.targetClass)) color = [NSColor linkColor];
    else if (self.tab == DYITabRuntime && left) color = [NSColor linkColor];
    else if (!left && r.property && !r.evaluated) color = [NSColor tertiaryLabelColor];
    else if (!left && r.target) color = [NSColor linkColor];
    else if (!left) color = [NSColor secondaryLabelColor];
    c.textColor = color;
}

- (NSString *)tableView:(NSTableView *)tableView toolTipForCell:(NSCell *)cell rect:(NSRectPointer)rect
            tableColumn:(NSTableColumn *)column row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation {
    (void)tableView; (void)cell; (void)rect; (void)mouseLocation;
    if (row < 0 || row >= (NSInteger)self.rows.count) return @"";
    DYIRow *r = self.rows[(NSUInteger)row];
    return [column.identifier isEqualToString:@"left"] ? r.left : r.right;
}

- (void)tableViewSelectionDidChange:(NSNotification *)note {
    (void)note;
    DYIRow *r = [self selectedRow];
    if (self.tab == DYITabMethods && r.method) self.status.stringValue = r.method.signature;
}

- (nullable DYIRow *)selectedRow {
    NSInteger i = self.table.selectedRow;
    return (i >= 0 && i < (NSInteger)self.rows.count) ? self.rows[(NSUInteger)i] : nil;
}

- (nullable DYIRow *)clickedRow {
    NSInteger i = self.table.clickedRow;
    return (i >= 0 && i < (NSInteger)self.rows.count) ? self.rows[(NSUInteger)i] : nil;
}

- (void)tableClicked:(id)sender {
    (void)sender;
    [self activateRow:[self clickedRow] column:self.table.clickedColumn];
}

/// A click: evaluates a property row, or opens the object or class the row points at.
- (void)activateRow:(nullable DYIRow *)r column:(NSInteger)column {
    if (!r || r.group) return;
    DYITarget *t = self.current;
    if (r.property && !r.evaluated && t.object) {
        id value = nil;
        NSString *text = DYIEvaluateProperty(t.object, r.property, &value);
        r.evaluated = YES;
        r.right = text;
        r.target = value;
        t.evaluated[[NSString stringWithFormat:@"%@.%@", NSStringFromClass(r.property.cls), r.property.name]] = @[text, value ?: [NSNull null]];
        self.status.stringValue = [NSString stringWithFormat:@"%@ = %@", r.property.name, text];
        [self.table reloadData];
        return;
    }
    BOOL valueClick = column != 0 || self.tab == DYITabHierarchy;   // on property rows, only the value column navigates
    if (r.target && valueClick) { [self inspectObject:r.target]; return; }
    if (r.targetClass) { [self inspectClass:r.targetClass]; return; }
}

#pragma mark Menu and copying

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    DYIRow *r = [self clickedRow];
    if (!r || r.group) return;
    if (r.method) {
        [[menu addItemWithTitle:@"Copy Hook" action:@selector(menuCopyHook:) keyEquivalent:@""] setTarget:self];
        [[menu addItemWithTitle:@"Copy Signature" action:@selector(menuCopyLeft:) keyEquivalent:@""] setTarget:self];
        [[menu addItemWithTitle:@"Copy Selector" action:@selector(menuCopySelector:) keyEquivalent:@""] setTarget:self];
        return;
    }
    [[menu addItemWithTitle:@"Copy Name" action:@selector(menuCopyLeft:) keyEquivalent:@""] setTarget:self];
    [[menu addItemWithTitle:@"Copy Value" action:@selector(menuCopyRight:) keyEquivalent:@""] setTarget:self];
    if (r.target || r.targetClass) [[menu addItemWithTitle:@"Inspect" action:@selector(menuInspect:) keyEquivalent:@""] setTarget:self];
}

- (void)copyString:(NSString *)s what:(NSString *)what {
    NSPasteboard *pb = DYIPasteboard();
    [pb clearContents];
    [pb setString:s forType:NSPasteboardTypeString];
    self.status.stringValue = [NSString stringWithFormat:@"copied %@", what];
}

- (void)menuCopyLeft:(id)sender { (void)sender; DYIRow *r = [self clickedRow]; if (r) [self copyString:[r.left stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] what:@"name"]; }
- (void)menuCopyRight:(id)sender { (void)sender; DYIRow *r = [self clickedRow]; if (r) [self copyString:r.right what:@"value"]; }
- (void)menuCopySelector:(id)sender { (void)sender; DYIRow *r = [self clickedRow]; if (r.method) [self copyString:NSStringFromSelector(r.method.selector) what:@"selector"]; }
- (void)menuInspect:(id)sender { (void)sender; DYIRow *r = [self clickedRow]; if (r) [self activateRow:r column:1]; }
- (void)menuCopyHook:(id)sender { (void)sender; DYIRow *r = [self clickedRow]; if (r.method) [self copyHookFor:r.method]; }

- (void)copyHookFor:(DYIMethodInfo *)m {
    [self copyString:DYIHookSkeleton(m) what:[NSString stringWithFormat:@"hook for %@[%@ %@]", m.classMethod ? @"+" : @"-",
                                              NSStringFromClass(m.cls), NSStringFromSelector(m.selector)]];
}

- (void)copyHook:(id)sender {
    (void)sender;
    DYIRow *r = [self selectedRow];
    if (r.method) [self copyHookFor:r.method];
    else self.status.stringValue = @"select a method on the Methods tab first";
}

- (void)copyClassName:(id)sender {
    (void)sender;
    DYITarget *t = self.current;
    if (t) [self copyString:NSStringFromClass(t.context) what:@"class name"];
}

- (void)copyDescription:(id)sender {
    (void)sender;
    DYITarget *t = self.current;
    if (!t) return;
    NSString *d = t.object ? DYIDescriptionOf(t.object, 20000)
                           : [NSString stringWithFormat:@"%@ (%@)", NSStringFromClass(t.cls), DYIImageOfClass(t.cls)];
    [self copyString:d what:@"description"];
}

#ifdef DYI_TEST
#pragma mark Test commands

- (NSDictionary *)testCommand:(NSDictionary *)cmd {
    NSString *name = cmd[@"cmd"];
    NSMutableDictionary *reply = [NSMutableDictionary dictionary];
    if ([name isEqualToString:@"tab"]) {
        NSUInteger i = [DYITabNames() indexOfObject:cmd[@"name"]];
        if (i != NSNotFound) { self.tab = (DYITab)i; self.search.stringValue = @""; [self refresh]; }
    } else if ([name isEqualToString:@"evaluate"]) {
        for (DYIRow *r in self.rows) if (r.property && [r.left isEqualToString:cmd[@"name"]]) {
            [self activateRow:r column:1];
            reply[@"value"] = r.right;
            break;
        }
    } else if ([name isEqualToString:@"navigate"]) {   // the first row whose left text contains "contains" and that links somewhere
        for (DYIRow *r in self.rows) if ((r.target || r.targetClass) && [r.left containsString:cmd[@"contains"]]) {
            reply[@"navigated"] = r.left;
            [self activateRow:r column:1];
            break;
        }
    } else if ([name isEqualToString:@"back"]) {
        [self goBack:nil];
    } else if ([name isEqualToString:@"forward"]) {
        [self goForward:nil];
    } else if ([name isEqualToString:@"context"]) {
        [self setContext:NSClassFromString(cmd[@"class"])];
    } else if ([name isEqualToString:@"copyHook"]) {
        self.tab = DYITabMethods;
        self.search.stringValue = @"";
        [self refresh];
        BOOL classMethod = [cmd[@"classMethod"] boolValue];
        [DYIPasteboard() clearContents];
        for (NSUInteger i = 0; i < self.rows.count; i++) {
            DYIMethodInfo *m = self.rows[i].method;
            if (m && m.classMethod == classMethod && [NSStringFromSelector(m.selector) isEqualToString:cmd[@"sel"]]) {
                [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
                [self.table scrollRowToVisible:(NSInteger)i];
                [self copyHook:nil];
                break;
            }
        }
        reply[@"text"] = [DYIPasteboard() stringForType:NSPasteboardTypeString] ?: @"";
    } else if ([name isEqualToString:@"copyName"]) {
        [self copyClassName:nil];
        reply[@"text"] = [DYIPasteboard() stringForType:NSPasteboardTypeString] ?: @"";
    } else if ([name isEqualToString:@"copyDescription"]) {
        [self copyDescription:nil];
        reply[@"text"] = [DYIPasteboard() stringForType:NSPasteboardTypeString] ?: @"";
    } else if ([name isEqualToString:@"search"]) {
        self.search.stringValue = cmd[@"text"] ?: @"";
        [self rebuildRows];
    } else if ([name isEqualToString:@"runtime"]) {
        self.tab = DYITabRuntime;
        [self refresh];
        self.search.stringValue = cmd[@"query"] ?: @"";
        [self rebuildRows];
        reply[@"loading"] = @(self.classNames == nil);
    } else if ([name isEqualToString:@"openClass"]) {
        [self inspectClass:NSClassFromString(cmd[@"name"])];
    } else if ([name isEqualToString:@"close"]) {
        [self.panel performClose:nil];
    }
    // Panel state for every command.
    DYITarget *t = self.current;
    reply[@"header"] = self.header.stringValue ?: @"";
    NSMutableArray *chain = [NSMutableArray array];
    for (NSPathControlItem *item in self.chain.pathItems) [chain addObject:item.title ?: @""];
    reply[@"chain"] = chain;
    reply[@"tab"] = DYITabNames()[(NSUInteger)self.tab];
    reply[@"context"] = t ? NSStringFromClass(t.context) : @"";
    reply[@"targetClass"] = t ? NSStringFromClass(t.cls) : @"";
    reply[@"hasInstance"] = @(t.object != nil);
    reply[@"historyIndex"] = @(self.index);
    reply[@"historyCount"] = @(self.history.count);
    reply[@"status"] = self.status.stringValue ?: @"";
    reply[@"panelIsKey"] = @(self.panel.isKeyWindow);
    NSMutableArray *rows = [NSMutableArray array];
    for (DYIRow *r in self.rows) {
        [rows addObject:@{@"left": r.left ?: @"", @"right": r.right ?: @"", @"group": @(r.group),
                          @"link": @(r.target != nil || r.targetClass != nil), @"property": @(r.property != nil),
                          @"evaluated": @(r.evaluated), @"self": @(r.emphasized)}];
        if (rows.count >= 3000) break;
    }
    reply[@"rows"] = rows;
    return reply;
}
#endif

@end
