// MenuLoader injection test host (bundle ID local.dynject.menuloader.testhost). Run it through run.sh, which
// injects ../build/test/libMenuLoader.dylib (built with -DML_TEST) with DYLD_INSERT_LIBRARIES. No Dynject involved.
//
// The host plays the user: it makes AppKit build its Apple menu (the real _NSAppleMenu of this process) the way
// opening the menu bar does, then inspects that menu object directly. The "Workbench side" (publishing the item
// list, changing settings, observing notifications) is mltool, a separate process, so changes cross processes the
// way they do in real use. It never activates itself (accessory app: no Dock icon, no focus change), and actions
// are test builds' logged stand-ins, except notify:, which posts a test-only notification.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <objc/message.h>

static const NSInteger kMLTag = 0x646D6C72;          // 'dmlr', MenuLoader's items
static const NSInteger kAppStoreTag = 0x736F6674;    // 'soft'
static const NSInteger kRecentItemsTag = 1919118964; // Recent Items
static NSString *gBundleID;
static NSString *gBuildDir, *gTool;
static int gFailures = 0, gChecks = 0;
static NSUInteger gAddCalls = 0;
static NSMutableArray<NSDictionary *> *gActions;

static void check(BOOL ok, NSString *what) {
    gChecks++;
    printf("  [%s] %s\n", ok ? "PASS" : "FAIL", what.UTF8String);
    fflush(stdout);
    if (!ok) gFailures++;
}

static NSMenu *appleMenu(void) {
    Class c = NSClassFromString(@"_NSAppleMenu");
    return c ? ((id (*)(id, SEL))objc_msgSend)(c, NSSelectorFromString(@"sharedMenu")) : nil;
}

/// Makes AppKit populate/update the Apple menu exactly as it does when the menu bar opens it or checks a key
/// equivalent: NSMenu's populate path calls the menu's delegate method -updateMenu:withEvent:withFlags:.
static void openMenu(void) {
    NSMenu *m = appleMenu();
    SEL populate = NSSelectorFromString(@"_populateWithEventRef:");
    if ([m respondsToSelector:populate]) ((void (*)(id, SEL, void *))objc_msgSend)(m, populate, NULL);
    else check(NO, @"NSMenu has _populateWithEventRef:");
}

static NSString *sym(NSMenuItem *i) {
    if (i.isSeparatorItem) return @"---";
    return [NSString stringWithFormat:@"%@%@%@", i.state == NSControlStateValueOn ? @"✓" : @"", i.title, i.hasSubmenu ? @"▸" : @""];
}

static NSString *describe(NSMenu *m) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSMenuItem *i in m.itemArray) if (!i.hidden) [a addObject:[(i.tag == kMLTag ? @"*" : @"") stringByAppendingString:sym(i)]];
    return [a componentsJoinedByString:@" | "];
}

static NSArray<NSMenuItem *> *ours(NSMenu *m) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSMenuItem *i in m.itemArray) if (i.tag == kMLTag) [a addObject:i];
    return a;
}

static NSArray<NSString *> *titles(NSMenu *m) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSMenuItem *i in m.itemArray) [a addObject:sym(i)];
    return a;
}

static NSMenuItem *find(NSMenu *m, NSString *title) {
    for (NSMenuItem *i in m.itemArray) {
        if ([i.title isEqual:title]) return i;
        NSMenuItem *sub = i.submenu ? find(i.submenu, title) : nil;
        if (sub) return sub;
    }
    return nil;
}

static NSInteger appleItemCount(NSMenu *m) { return m.numberOfItems - (NSInteger)ours(m).count; }

/// Our block sits right after the separator that ends App Store's section and is followed by our separator.
static void checkPlacement(NSMenu *m, NSUInteger blockCount) {
    NSArray<NSMenuItem *> *o = ours(m);
    NSInteger first = [m indexOfItem:o.firstObject], store = [m indexOfItemWithTag:kAppStoreTag];
    BOOL contiguous = YES;
    for (NSUInteger k = 0; k < o.count; k++) if ([m indexOfItem:o[k]] != first + (NSInteger)k) contiguous = NO;
    check(o.count == blockCount + 1 && contiguous, [NSString stringWithFormat:@"exactly one block of %lu item(s) + 1 separator (got %lu)", (unsigned long)blockCount, (unsigned long)o.count]);
    BOOL sectionAfterStore = store >= 0 && first > store + 1 && [m itemAtIndex:first - 1].isSeparatorItem;
    for (NSInteger i = store + 1; sectionAfterStore && i < first - 1; i++) if ([m itemAtIndex:i].isSeparatorItem) sectionAfterStore = NO;
    check(sectionAfterStore, @"inserted right after the separator that closes the App Store section");
    NSInteger last = first + (NSInteger)o.count - 1;
    check(o.lastObject.isSeparatorItem && last + 1 < m.numberOfItems && [m itemAtIndex:last + 1].tag == kRecentItemsTag,
          @"followed by its own separator, then Recent Items");
}

static NSString *writeFixture(NSString *name, NSDictionary *d) {
    NSString *path = [gBuildDir stringByAppendingPathComponent:[name stringByAppendingString:@".plist"]];
    [[NSPropertyListSerialization dataWithPropertyList:d format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL] writeToFile:path atomically:YES];
    return path;
}

static int tool(NSArray<NSString *> *args) {
    NSTask *t = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:gTool] arguments:args error:NULL terminationHandler:nil];
    [t waitUntilExit];
    return t.terminationStatus;
}

static void publish(NSString *name, NSDictionary *list) { tool(@[@"publish", writeFixture(name, list)]); }
static void settings(NSString *tweakID, NSDictionary *payload) {
    tool(@[@"settings", tweakID, writeFixture([@"settings-" stringByAppendingString:tweakID], payload)]);
}

static NSDictionary *item(NSString *tweakID, NSString *tweakName, NSDictionary *fields) {
    NSMutableDictionary *d = [fields mutableCopy];
    d[@"tweakID"] = tweakID;
    d[@"tweakName"] = tweakName;
    return d;
}

static NSDictionary *mlSettings(NSDictionary *values, NSDictionary *perApp) {
    return @{@"formatVersion": @1, @"values": values ?: @{}, @"perApp": perApp ?: @{},
             @"defaults": @{@"enabled": @YES, @"placement": @"auto", @"submenuTitle": @"", @"diagnostics": @NO}};
}

static void sendKey(NSString *chars, unsigned short keyCode, NSEventModifierFlags mods) {
    NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:mods timestamp:0
                              windowNumber:0 context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:keyCode];
    [NSApp sendEvent:e];
}

static NSDictionary *lastAction(void) { return gActions.lastObject; }

#pragma mark - Steps

typedef double (^Step)(void);   // returns the delay before the next step

static NSArray<Step> *steps(void) {
    NSString *A = @"local.test.alpha", *B = @"local.test.beta", *G = @"local.test.gamma", *ML = @"local.dynject.menuloader.test";
    NSDictionary *a1 = item(A, @"Alpha Tweak", @{@"id": @"ping", @"title": @"Alpha Notify", @"action": @"notify:local.dynject.menuloader.test.ping",
                                                @"symbol": @"bell", @"checkedBy": @"on"});
    NSDictionary *a2 = item(A, @"Alpha Tweak", @{@"id": @"web", @"title": @"Alpha Web", @"action": @"url:https://example.com/menuloader-test",
                                                @"symbol": @"globe", @"keyEquivalent": @"k", @"modifiers": @[@"option", @"command"]});
    NSDictionary *b1 = item(B, @"Beta Tweak", @{@"id": @"sc", @"title": @"Beta Shortcut", @"action": @"shortcut:My Test & Shortcut/1",
                                               @"checkedBy": @"flag"});
    NSDictionary *b2 = item(B, @"Beta Tweak", @{@"id": @"app", @"title": @"Beta App", @"action": @"app:com.apple.TextEdit", @"symbol": @"app.badge"});
    NSDictionary *b3 = item(B, @"Beta Tweak", @{@"id": @"else", @"title": @"Only Elsewhere", @"action": @"notify:x.y", @"apps": @[@"com.example.other"]});
    NSDictionary *b4 = item(B, @"Beta Tweak", @{@"id": @"here", @"title": @"Only Here", @"action": @"notify:x.y", @"apps": @[@"com.example.other", gBundleID]});
    NSDictionary *g1 = item(G, @"Gamma Tweak", @{@"id": @"g", @"title": @"Gamma Item", @"action": @"notify:x.y", @"symbol": @"star"});
    NSDictionary *bad1 = item(G, @"Gamma Tweak", @{@"id": @"bad1", @"title": @"Bad Scheme", @"action": @"ftp:x"});
    NSDictionary *bad2 = item(G, @"Gamma Tweak", @{@"id": @"bad2", @"action": @"notify:x"});
    __block NSInteger appleCount = 0;
    __block NSMenuItem *betaShortcut = nil;
    __block NSTask *observer = nil;
    __block NSPipe *observerOut = nil;

    return @[
        ^double{
            printf("Setup: publish the list, settings in the test domain\n");
            settings(ML, mlSettings(@{@"diagnostics": @YES}, nil));
            settings(A, @{@"formatVersion": @1, @"values": @{@"on": @YES}, @"defaults": @{@"on": @NO}});
            settings(B, @{@"formatVersion": @1, @"values": @{}, @"defaults": @{@"flag": @NO}});
            publish(@"list-a", @{@"formatVersion": @1, @"placement": @"submenu", @"submenuTitle": @"Tweaks Test",
                                 @"items": @[a1, a2, b1, b2, b3, b4]});
            check(appleMenu().numberOfItems == 0, @"the Apple menu is still unbuilt before the first open");
            return 0.3;
        },
        ^double{
            printf("Phase 1: first open builds the Apple menu with MenuLoader's submenu\n");
            openMenu();
            NSMenu *m = appleMenu();
            printf("    %s\n", describe(m).UTF8String);
            appleCount = appleItemCount(m);
            check(appleCount > 10 && [m indexOfItemWithTag:kAppStoreTag] >= 0, @"AppKit's own items are there");
            check(gAddCalls == 1, [NSString stringWithFormat:@"_addAppleMenuItems ran once (%lu)", (unsigned long)gAddCalls]);
            checkPlacement(m, 1);
            NSMenuItem *sub = ours(m).firstObject;
            check([sub.title isEqual:@"Tweaks Test"] && sub.hasSubmenu, @"submenu titled with the published submenuTitle");
            check(sub.image != nil, @"submenu item has an icon (puzzlepiece.extension)");
            if (@available(macOS 27.0, *)) {
                check(sub.preferredImageVisibility == NSMenuItemImageVisibilityVisible
                      && find(sub.submenu, @"Alpha Notify").preferredImageVisibility == NSMenuItemImageVisibilityVisible
                      && find(sub.submenu, @"Beta Shortcut").preferredImageVisibility == NSMenuItemImageVisibilityAutomatic,
                      @"macOS 27: icons marked always visible (like About This Mac), items without one left automatic");
            }
            NSArray *want = @[@"✓Alpha Notify", @"Alpha Web", @"---", @"Beta Shortcut", @"Beta App", @"Only Here"];
            check([titles(sub.submenu) isEqual:want], [NSString stringWithFormat:@"submenu grouped by tweak, filtered for this app: %@",
                                                       [titles(sub.submenu) componentsJoinedByString:@" | "]]);
            check(find(sub.submenu, @"Alpha Notify").image && find(sub.submenu, @"Alpha Web").image && find(sub.submenu, @"Beta App").image
                  && !find(sub.submenu, @"Beta Shortcut").image, @"SF Symbol icons where declared, none otherwise");
            NSMenuItem *web = find(sub.submenu, @"Alpha Web");
            check([web.keyEquivalent isEqual:@"k"] && web.keyEquivalentModifierMask == (NSEventModifierFlagOption | NSEventModifierFlagCommand),
                  @"key equivalent ⌥⌘K");
            check(find(m, @"Only Elsewhere") == nil, @"item limited to another app is absent");
            return 0.1;
        },
        ^double{
            printf("Phase 2: opening again (x5) never duplicates or rebuilds\n");
            NSMenuItem *before = ours(appleMenu()).firstObject;
            for (int i = 0; i < 5; i++) openMenu();
            NSMenu *m = appleMenu();
            check(ours(m).count == 2 && ours(m).firstObject == before, @"same single submenu item after 5 more opens");
            check(appleItemCount(m) == appleCount, @"AppKit's items unchanged");
            check(gAddCalls == 1, [NSString stringWithFormat:@"_addAppleMenuItems still ran only once (%lu)", (unsigned long)gAddCalls]);
            return 0.1;
        },
        ^double{
            printf("Phase 3: actions\n");
            observer = [NSTask new];
            observer.executableURL = [NSURL fileURLWithPath:gTool];
            observer.arguments = @[@"observe", @"local.dynject.menuloader.test.ping", @"5"];
            observerOut = [NSPipe pipe];
            observer.standardOutput = observerOut;
            [observer launchAndReturnError:NULL];
            NSData *ready = [observerOut.fileHandleForReading readDataOfLength:6];   // "READY\n"
            check([[[NSString alloc] initWithData:ready encoding:NSUTF8StringEncoding] hasPrefix:@"READY"], @"observer process is listening");
            NSMenu *sub = ours(appleMenu()).firstObject.submenu;
            [sub performActionForItemAtIndex:[sub indexOfItem:find(sub, @"Alpha Notify")]];
            return 0.3;
        },
        ^double{
            [observer waitUntilExit];
            NSString *out = [[NSString alloc] initWithData:[observerOut.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
            check(observer.terminationStatus == 0 && [out containsString:@"RECEIVED"], @"notify: another process received local.dynject.menuloader.test.ping");
            NSMenu *sub = ours(appleMenu()).firstObject.submenu;
            [sub performActionForItemAtIndex:[sub indexOfItem:find(sub, @"Alpha Web")]];
            check([lastAction()[@"value"] isEqual:@"https://example.com/menuloader-test"] && [lastAction()[@"kind"] isEqual:@"open"],
                  [NSString stringWithFormat:@"url: logged, not opened (%@)", lastAction()[@"value"]]);
            [sub performActionForItemAtIndex:[sub indexOfItem:find(sub, @"Beta Shortcut")]];
            check([lastAction()[@"value"] isEqual:@"shortcuts://run-shortcut?name=My%20Test%20%26%20Shortcut%2F1"],
                  [NSString stringWithFormat:@"shortcut: percent-encoded URL logged, not opened (%@)", lastAction()[@"value"]]);
            [sub performActionForItemAtIndex:[sub indexOfItem:find(sub, @"Beta App")]];
            check([lastAction()[@"kind"] isEqual:@"app"] && [lastAction()[@"value"] isEqual:@"com.apple.TextEdit"], @"app: bundle ID logged, not launched");
            NSUInteger n = gActions.count;
            sendKey(@"k", kVK_ANSI_K, NSEventModifierFlagOption | NSEventModifierFlagCommand);
            check(gActions.count == n + 1 && [lastAction()[@"id"] isEqual:@"web"], @"⌥⌘K key equivalent triggers Alpha Web through the Apple menu");
            return 0.1;
        },
        ^double{
            printf("Phase 4: checkmarks follow the tweaks' settings live (incl. per-app override)\n");
            betaShortcut = find(appleMenu(), @"Beta Shortcut");
            settings(B, @{@"formatVersion": @1, @"values": @{@"flag": @YES}, @"defaults": @{@"flag": @NO}});
            settings(A, @{@"formatVersion": @1, @"values": @{@"on": @YES}, @"perApp": @{gBundleID: @{@"on": @NO}}, @"defaults": @{@"on": @NO}});
            return 0.6;
        },
        ^double{
            NSMenuItem *bs = find(appleMenu(), @"Beta Shortcut");
            check(bs.state == NSControlStateValueOn, @"Beta Shortcut checked after its tweak's flag turned on");
            check(find(appleMenu(), @"Alpha Notify").state == NSControlStateValueOff, @"Alpha Notify unchecked by a per-app override");
            check(bs == betaShortcut, @"checkmarks updated in place (no rebuild)");
            printf("Phase 5: list change → section placement, invalid items skipped\n");
            publish(@"list-b", @{@"formatVersion": @1, @"placement": @"section", @"items": @[a1, g1, bad1, bad2, b3]});
            return 0.6;
        },
        ^double{
            NSMenu *m = appleMenu();
            printf("    %s\n", describe(m).UTF8String);
            checkPlacement(m, 2);
            check([[ours(m) valueForKey:@"title"] isEqual:@[@"Alpha Notify", @"Gamma Item", @""]] && !ours(m).firstObject.hasSubmenu,
                  @"items directly in the Apple menu as their own section");
            check(find(m, @"Bad Scheme") == nil && find(m, @"Beta App") == nil, @"invalid and removed items are gone");
            check(appleItemCount(m) == appleCount, @"AppKit's items unchanged");
            printf("Phase 6: MenuLoader's own settings override placement and title\n");
            settings(ML, mlSettings(@{@"diagnostics": @YES, @"placement": @"submenu", @"submenuTitle": @"Override"}, nil));
            return 0.6;
        },
        ^double{
            NSMenu *m = appleMenu();
            checkPlacement(m, 1);
            NSMenuItem *sub = ours(m).firstObject;
            check([sub.title isEqual:@"Override"] && [titles(sub.submenu) isEqual:(@[@"Alpha Notify", @"---", @"Gamma Item"])],
                  [NSString stringWithFormat:@"submenu \"Override\": %@", [titles(sub.submenu) componentsJoinedByString:@" | "]]);
            printf("Phase 7: enabled off removes the items live; a per-app override turns them back on\n");
            settings(ML, mlSettings(@{@"enabled": @NO}, nil));
            return 0.6;
        },
        ^double{
            NSMenu *m = appleMenu();
            check(ours(m).count == 0 && appleItemCount(m) == appleCount, @"no MenuLoader items, AppKit's intact");
            openMenu();
            check(ours(appleMenu()).count == 0, @"still none after opening");
            settings(ML, mlSettings(@{@"enabled": @NO}, @{gBundleID: @{@"enabled": @YES}}));
            return 0.6;
        },
        ^double{
            checkPlacement(appleMenu(), 2);   // placement override dropped: the published "section" again
            printf("Phase 8: AppKit rebuilds the menu from scratch → items again, exactly once\n");
            [appleMenu() removeAllItems];
            openMenu();
            NSMenu *m = appleMenu();
            printf("    %s\n", describe(m).UTF8String);
            check(gAddCalls == 2, [NSString stringWithFormat:@"_addAppleMenuItems ran again for the empty menu (%lu)", (unsigned long)gAddCalls]);
            check(appleItemCount(m) == appleCount, @"AppKit's items rebuilt");
            checkPlacement(m, 2);
            printf("Phase 9: nothing for this app → nothing inserted\n");
            publish(@"list-c", @{@"formatVersion": @1, @"items": @[b3]});
            return 0.6;
        },
        ^double{
            NSMenu *m = appleMenu();
            check(ours(m).count == 0 && appleItemCount(m) == appleCount, @"no items, no stray separators");
            printf("Phase 10: unsupported formatVersion is ignored\n");
            publish(@"list-d", @{@"formatVersion": @2, @"items": @[g1]});
            return 0.6;
        },
        ^double{
            check(ours(appleMenu()).count == 0, @"formatVersion 2 list ignored");
            publish(@"list-e", @{@"formatVersion": @1, @"items": @[g1]});
            return 0.6;
        },
        ^double{
            check(find(appleMenu(), @"Gamma Item") != nil, @"back with a valid list");
            printf("Phase 11: shortcuts from a hand-edited list: none without Command, no function keys,\n"
                   "          a Shift letter is the uppercase letter, a repeated shortcut stays with the first item\n");
            NSDictionary *(^sc)(NSString *, NSString *, NSString *, id) = ^NSDictionary *(NSString *tweak, NSString *iid, NSString *key, id mods) {
                NSMutableDictionary *f = [@{@"id": iid, @"title": iid, @"action": [@"url:https://example.com/menuloader-test/" stringByAppendingString:iid],
                                            @"keyEquivalent": key} mutableCopy];
                if (mods) f[@"modifiers"] = mods;
                return item(tweak, tweak, f);
            };
            publish(@"list-f", @{@"formatVersion": @1, @"items": @[
                sc(G, @"NoMods", @"e", @[]), sc(G, @"OptionOnly", @"l", @[@"option"]), sc(G, @"ShiftOnly", @"9", @[@"shift"]),
                sc(G, @"UpArrow", @"\uF700", @[@"command"]), sc(G, @"PrivateUse", @"\U000F0000", nil), sc(G, @"Delete", @"\x7F", nil),
                sc(G, @"Upper", @"J", @[@"command"]), sc(G, @"UpperOption", @"K", @[@"option"]), sc(G, @"Control", @"k", @[@"control"]),
                sc(G, @"ControlCmd", @"k", @[@"control", @"command"]), sc(G, @"LowerShift", @"m", @[@"shift", @"control", @"command"]), sc(A, @"Duplicate", @"j", @[@"shift", @"command"]),
            ]});
            return 0.6;
        },
        ^double{
            NSMenu *m = appleMenu();
            NSMutableArray *noKey = [NSMutableArray array];
            for (NSString *t in @[@"NoMods", @"OptionOnly", @"ShiftOnly", @"UpArrow", @"PrivateUse", @"Delete", @"UpperOption", @"Duplicate", @"Control"]) {
                NSMenuItem *i = find(m, t);
                if (i && i.keyEquivalent.length == 0) [noKey addObject:t];
            }
            check(noKey.count == 9, [NSString stringWithFormat:@"items kept without a shortcut: %@", [noKey componentsJoinedByString:@", "]]);
            NSMenuItem *upper = find(m, @"Upper"), *control = find(m, @"ControlCmd");
            check([upper.keyEquivalent isEqual:@"J"] && upper.keyEquivalentModifierMask == (NSEventModifierFlagShift | NSEventModifierFlagCommand),
                  [NSString stringWithFormat:@"\"J\" + command → \"J\" with ⇧⌘ (got '%@' 0x%lx)", upper.keyEquivalent, (unsigned long)upper.keyEquivalentModifierMask]);
            NSMenuItem *lowerShift = find(m, @"LowerShift");
            check([lowerShift.keyEquivalent isEqual:@"M"] && lowerShift.keyEquivalentModifierMask == (NSEventModifierFlagShift | NSEventModifierFlagControl | NSEventModifierFlagCommand),
                  [NSString stringWithFormat:@"\"m\" + shift, control, command → \"M\" with ⌃⇧⌘ (got '%@' 0x%lx)", lowerShift.keyEquivalent, (unsigned long)lowerShift.keyEquivalentModifierMask]);
            check([control.keyEquivalent isEqual:@"k"] && control.keyEquivalentModifierMask == (NSEventModifierFlagControl | NSEventModifierFlagCommand), @"⌃⌘K kept; control-only ⌃K dropped");
            NSUInteger n = gActions.count;
            sendKey(@"e", kVK_ANSI_E, 0);
            sendKey(@"l", kVK_ANSI_L, NSEventModifierFlagOption);
            sendKey(@"9", kVK_ANSI_9, NSEventModifierFlagShift);
            sendKey(@"\uF700", kVK_UpArrow, NSEventModifierFlagFunction | NSEventModifierFlagNumericPad);
            sendKey(@"\uF700", kVK_UpArrow, NSEventModifierFlagCommand | NSEventModifierFlagFunction | NSEventModifierFlagNumericPad);
            sendKey(@"j", kVK_ANSI_J, NSEventModifierFlagCommand);
            sendKey(@"m", kVK_ANSI_M, NSEventModifierFlagControl);
            sendKey(@"k", kVK_ANSI_K, NSEventModifierFlagControl);
            NSArray *ran = [[gActions subarrayWithRange:NSMakeRange(n, gActions.count - n)] valueForKey:@"id"];
            check(ran.count == 0, [NSString stringWithFormat:@"plain e, ⌥L, ⇧9, ↑, ⌘↑ and ⌘J run nothing, nor ⌃M or ⌃K (ran: %@)", [ran componentsJoinedByString:@", "]]);
            n = gActions.count;
            sendKey(@"J", kVK_ANSI_J, NSEventModifierFlagShift | NSEventModifierFlagCommand);
            check(gActions.count == n + 1 && [lastAction()[@"id"] isEqual:@"Upper"], @"⇧⌘J runs \"Upper\", not the later duplicate");
            sendKey(@"k", kVK_ANSI_K, NSEventModifierFlagControl | NSEventModifierFlagCommand);
            check(gActions.count == n + 2 && [lastAction()[@"id"] isEqual:@"ControlCmd"], @"⌃⌘K runs \"ControlCmd\"");
            sendKey(@"M", kVK_ANSI_M, NSEventModifierFlagControl | NSEventModifierFlagShift | NSEventModifierFlagCommand);
            check(gActions.count == n + 3 && [lastAction()[@"id"] isEqual:@"LowerShift"], @"⌃⇧⌘M runs \"LowerShift\"");
            printf("    final: %s\n", describe(appleMenu()).UTF8String);
            return 0;
        },
    ];
}

static void finish(void) {
    tool(@[@"clean"]);
    printf("%d checks, %s\n", gChecks, gFailures == 0 ? "ALL PASSED" : "FAILED");
    exit(gFailures == 0 ? 0 : 1);
}

static void run(NSArray<Step> *list, NSUInteger i) {
    if (i == list.count) { finish(); return; }
    double delay = list[i]();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ run(list, i + 1); });
}

@interface Host : NSObject <NSApplicationDelegate>
@end

@implementation Host
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    (void)n;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        check(NO, @"finished within 30 s");
        finish();
    });
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:@"local.dynject.menuloader.test.action" object:nil queue:nil usingBlock:^(NSNotification *note) {
        [gActions addObject:note.userInfo];
    }];
    [nc addObserverForName:@"local.dynject.menuloader.test.built" object:nil queue:nil usingBlock:^(NSNotification *note) {
        gAddCalls = [note.userInfo[@"addAppleMenuItemsCalls"] unsignedIntegerValue];
    }];
    if (getenv("ML_SHOT")) { dispatch_async(dispatch_get_main_queue(), ^{ [self shot:@(getenv("ML_SHOT"))]; }); return; }
    if (getenv("ML_SMOKE")) { dispatch_async(dispatch_get_main_queue(), ^{ [self smoke]; }); return; }
    dispatch_async(dispatch_get_main_queue(), ^{ run(steps(), 0); });
}

- (void)noop:(id)sender { (void)sender; }
- (BOOL)validateMenuItem:(NSMenuItem *)item { (void)item; return YES; }

/// A copy of `menu` whose items all do nothing (no AppKit or MenuLoader action can run from it).
- (NSMenu *)defanged:(NSMenu *)menu {
    NSMenu *copy = [menu copy];
    copy.delegate = nil;
    for (NSMenuItem *i in copy.itemArray) {
        if (i.submenu) { i.submenu = [self defanged:i.submenu]; continue; }
        if (i.isSeparatorItem) continue;
        i.target = self;
        i.action = @selector(noop:);
    }
    return copy;
}

/// Screenshots (opt-in, ML_SHOT=<directory>): pops up a defanged copy of the populated Apple menu, and then of
/// MenuLoader's submenu, inside this host (no activation, nothing can be chosen), and captures just that region.
- (void)shot:(NSString *)dir {
    openMenu();
    NSMenu *real = appleMenu();
    NSMenu *sub = [self defanged:ours(real).firstObject.submenu ?: [NSMenu new]];
    NSMenu *whole = [self defanged:real];
    CGFloat H = NSScreen.screens.firstObject.frame.size.height;
    NSArray *menus = @[whole, sub], *names = @[@"apple-menu.png", @"submenu.png"];
    for (NSUInteger k = 0; k < menus.count; k++) {
        NSMenu *menu = menus[k];
        NSPoint p = NSMakePoint(60 + 320 * k, H - 60);
        NSSize size = menu.size;
        NSString *rect = [NSString stringWithFormat:@"%d,%d,%d,%d", (int)p.x - 16, (int)(H - p.y) - 16, (int)size.width + 32, (int)size.height + 32];
        NSString *path = [dir stringByAppendingPathComponent:names[k]];
        NSTimer *t = [NSTimer timerWithTimeInterval:0.8 repeats:NO block:^(NSTimer *timer) {
            (void)timer;
            NSTask *cap = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/sbin/screencapture"]
                                                      arguments:@[@"-x", @"-R", rect, path] error:NULL terminationHandler:nil];
            [cap waitUntilExit];
            printf("captured %s (%s)\n", path.UTF8String, rect.UTF8String);
            [menu cancelTracking];
        }];
        [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
        [menu popUpMenuPositioningItem:nil atLocation:p inView:nil];
    }
    exit(0);
}

/// Sandboxed smoke test (run.sh publishes the list and observes the notification from outside the sandbox):
/// the published list is readable from inside the sandbox, items appear, and a notify: action gets out.
- (void)smoke {
    const char *container = getenv("APP_SANDBOX_CONTAINER_ID");
    check(container != NULL, [NSString stringWithFormat:@"running inside the App Sandbox (container %s)", container ?: "none"]);
    openMenu();
    NSMenu *m = appleMenu();
    printf("    %s\n", describe(m).UTF8String);
    NSMenuItem *parent = ours(m).firstObject;
    check([parent.title isEqual:@"Sandboxed Test"] && parent.hasSubmenu && ours(m).count == 2, @"submenu from the published list");
    NSMenuItem *ping = find(m, @"Ping");
    check(ping != nil, @"item present");
    if (ping) [ping.menu performActionForItemAtIndex:[ping.menu indexOfItem:ping]];
    check([lastAction()[@"kind"] isEqual:@"notify"], @"notify action ran");
    printf("%d checks, %s\n", gChecks, gFailures == 0 ? "ALL PASSED" : "FAILED");
    exit(gFailures == 0 ? 0 : 1);
}
@end

int main(void) {
    @autoreleasepool {
        if (!getenv("DYLD_INSERT_LIBRARIES")) { fprintf(stderr, "run through run.sh (DYLD_INSERT_LIBRARIES)\n"); return 2; }
        gBundleID = [[NSBundle mainBundle] bundleIdentifier];
        gBuildDir = [[[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent] copy];
        gTool = [gBuildDir stringByAppendingPathComponent:@"mltool"];
        gActions = [NSMutableArray array];
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;   // no Dock icon, never takes focus
        NSMenu *main = [NSMenu new];
        NSMenuItem *appItem = [NSMenuItem new];
        appItem.submenu = [[NSMenu alloc] initWithTitle:@"MenuLoader Test Host"];
        [appItem.submenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        [main addItem:appItem];
        app.mainMenu = main;
        Host *host = [Host new];
        app.delegate = host;
        [app run];
    }
    return 0;
}
