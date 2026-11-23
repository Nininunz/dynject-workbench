// NotchDemo: crowds the menu bar so NotchPadding's effect shows. Status items (icons) fill the right of the notch, the app's
// own menus the left (while it's the front app), and the padding buttons switch the tweak's setting the way Workbench
// does. Quitting removes the items and puts the setting back as it was.
//
//   ../build.sh demo     builds build/NotchDemo.app and opens it
#import <AppKit/AppKit.h>
#import <notify.h>

static NSString *const kKey = @"dynject.tweak.local.dynject.notchpadding";
static const char *kNotify = "dynject.tweak.local.dynject.notchpadding.changed";

// Menu titles of different widths, like a real app's.
static NSArray<NSString *> *MenuTitles(void) {
    return @[@"File", @"Edit", @"View", @"History", @"Bookmarks", @"Format", @"Arrange", @"Insert", @"Table", @"Develop",
             @"Tools", @"Extras", @"Options", @"Window", @"Account", @"Library", @"Playback", @"Controls", @"Navigate",
             @"Refactor", @"Debug", @"Source", @"Product", @"Editor", @"Shapes", @"Effects", @"Filters", @"Layers",
             @"Selection", @"Help"];
}

@interface Demo : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window;
@property (strong) NSMutableArray<NSStatusItem *> *items;
@property (strong) NSTextField *itemsLabel, *menusLabel, *paddingLabel;
@property NSInteger menuCount;
@property (strong) id savedSettings;   // the tweak's settings before the demo touched them
@property BOOL touchedSettings;
@end

@implementation Demo

- (NSButton *)button:(NSString *)title action:(SEL)action tag:(NSInteger)tag {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
    b.tag = tag;
    return b;
}

- (NSStackView *)row:(NSArray<NSView *> *)views {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    s.spacing = 8;
    return s;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    self.items = [NSMutableArray array];
    self.savedSettings = CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)kKey, kCFPreferencesAnyApplication,
                                                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    self.itemsLabel = [NSTextField labelWithString:@""];
    self.menusLabel = [NSTextField labelWithString:@""];
    self.paddingLabel = [NSTextField labelWithString:@"Padding: as set in Workbench"];
    NSArray *paddingButtons = @[[self button:@"Off" action:@selector(padding:) tag:-1], [self button:@"0" action:@selector(padding:) tag:0],
                                [self button:@"40" action:@selector(padding:) tag:40], [self button:@"80" action:@selector(padding:) tag:80],
                                [self button:@"120" action:@selector(padding:) tag:120]];
    NSTextField *hint = [NSTextField wrappingLabelWithString:
        @"Status items fill the right of the notch. Click this window to make NotchDemo the front app: its menus fill the "
        @"left. With padding, menus that don't fit move past the notch, and items that don't fit go into the «."];
    hint.preferredMaxLayoutWidth = 380;
    NSStackView *stack = [NSStackView stackViewWithViews:@[
        [self row:@[[self button:@"−" action:@selector(items:) tag:-1], [self button:@"+" action:@selector(items:) tag:1], self.itemsLabel]],
        [self row:@[[self button:@"−" action:@selector(menus:) tag:-1], [self button:@"+" action:@selector(menus:) tag:1], self.menusLabel]],
        [self row:paddingButtons], self.paddingLabel, hint]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 420, 240)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Notch Padding Demo";
    self.window.contentView = stack;
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activate];
    [self rebuildItems:14];
    [self rebuildMenus:14];
}

- (void)rebuildItems:(NSInteger)n {
    n = MAX(0, MIN(40, n));
    while ((NSInteger)self.items.count < n) {
        NSStatusItem *item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        NSUInteger i = self.items.count + 1;
        // An icon only, like most menu bar items: a different SF Symbol for each.
        NSArray<NSString *> *symbols = @[@"star.fill", @"heart.fill", @"bolt.fill", @"cloud.fill", @"flame.fill", @"leaf.fill",
            @"moon.fill", @"sun.max.fill", @"bell.fill", @"bookmark.fill", @"camera.fill", @"gamecontroller.fill",
            @"music.note", @"paperplane.fill", @"tag.fill", @"umbrella.fill", @"drop.fill", @"snowflake", @"globe",
            @"airplane", @"car.fill", @"house.fill", @"gift.fill", @"key.fill", @"lock.fill", @"pin.fill", @"cart.fill",
            @"briefcase.fill", @"puzzlepiece.fill", @"cup.and.saucer.fill", @"pawprint.fill", @"ant.fill", @"hare.fill",
            @"tortoise.fill", @"fish.fill", @"bird.fill", @"tree.fill", @"mountain.2.fill", @"tent.fill", @"crown.fill"];
        NSString *name = symbols[(i - 1) % symbols.count];
        NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:[NSString stringWithFormat:@"NotchDemo item %lu", (unsigned long)i]];
        image.template = YES;
        item.button.image = image;
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
        [menu addItemWithTitle:[NSString stringWithFormat:@"NotchDemo item %lu", (unsigned long)i] action:nil keyEquivalent:@""];
        item.menu = menu;
        [self.items addObject:item];
    }
    while ((NSInteger)self.items.count > n) {
        [NSStatusBar.systemStatusBar removeStatusItem:self.items.lastObject];
        [self.items removeLastObject];
    }
    self.itemsLabel.stringValue = [NSString stringWithFormat:@"%ld status items", (long)n];
}

- (void)rebuildMenus:(NSInteger)n {
    NSArray *titles = MenuTitles();
    n = MAX(0, MIN((NSInteger)titles.count, n));
    self.menuCount = n;
    NSMenu *bar = [[NSMenu alloc] initWithTitle:@"Main"];
    NSMenuItem *appItem = [bar addItemWithTitle:@"NotchDemo" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"NotchDemo"];
    [appMenu addItemWithTitle:@"Quit NotchDemo" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    for (NSInteger i = 0; i < n; i++) {
        NSMenuItem *top = [bar addItemWithTitle:titles[(NSUInteger)i] action:nil keyEquivalent:@""];
        NSMenu *sub = [[NSMenu alloc] initWithTitle:titles[(NSUInteger)i]];
        [sub addItemWithTitle:[NSString stringWithFormat:@"%@ item", titles[(NSUInteger)i]] action:nil keyEquivalent:@""];
        top.submenu = sub;
    }
    NSApp.mainMenu = bar;
    self.menusLabel.stringValue = [NSString stringWithFormat:@"%ld menus (shown while NotchDemo is the front app)", (long)n];
}

- (void)items:(NSButton *)sender { [self rebuildItems:(NSInteger)self.items.count + sender.tag]; }
- (void)menus:(NSButton *)sender { [self rebuildMenus:self.menuCount + sender.tag]; }

/// Writes the tweak's settings the way Workbench does (docs/tweak-format.md) and tells it.
- (void)padding:(NSButton *)sender {
    BOOL on = sender.tag >= 0;
    NSDictionary *payload = @{@"formatVersion": @1, @"perApp": @{}, @"defaults": @{@"enabled": @YES, @"padding": @40},
                              @"values": on ? @{@"enabled": @YES, @"padding": @(sender.tag)} : @{@"enabled": @NO}};
    CFPreferencesSetValue((__bridge CFStringRef)kKey, (__bridge CFPropertyListRef)payload, kCFPreferencesAnyApplication,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    notify_post(kNotify);
    self.touchedSettings = YES;
    self.paddingLabel.stringValue = on ? [NSString stringWithFormat:@"Padding: %ld points each side", (long)sender.tag]
                                       : @"Padding: tweak switched off (the real notch)";
}

- (void)applicationWillTerminate:(NSNotification *)note {
    (void)note;
    if (!self.touchedSettings) return;
    CFPreferencesSetValue((__bridge CFStringRef)kKey, (__bridge CFPropertyListRef)self.savedSettings, kCFPreferencesAnyApplication,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    notify_post(kNotify);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { (void)app; return YES; }

@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        Demo *demo = [Demo new];
        app.delegate = demo;
        [app run];
    }
    return 0;
}
