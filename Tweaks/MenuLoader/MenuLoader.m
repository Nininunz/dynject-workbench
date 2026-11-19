// MenuLoader — the Apple-menu analogue of iOS PreferenceLoader for Dynject.
//
// Tweaks declare Apple-menu items in their manifest ("appleMenu"); Dynject Workbench publishes the combined list
// to the global preferences key "dynject.menuloader" and posts "dynject.menuloader.changed". This one global
// tweak, injected everywhere, reads that list and adds the items to the Apple menu of the app it runs in.
// No tweak writes menu code. Contract: docs/tweak-format.md and README.md next to this file.
//
// How it hooks AppKit (private, macOS 14 to 27): every app builds its own Apple menu, an instance of the private
// class _NSAppleMenu (an NSMenu that is its own delegate). AppKit populates it lazily, the first time the menu bar
// is opened or a key equivalent is checked: -updateMenu:withEvent:withFlags: (called on every open and every
// key-equivalent check) calls -_addAppleMenuItems only while the menu has no items, so in practice once per
// process. MenuLoader hooks both methods:
//  - after -_addAppleMenuItems: (re)inserts its items, so a rebuilt menu gets them again;
//  - after -updateMenu:withEvent:withFlags: for the Apple menu itself: a cheap check (a generation counter
//    and one indexOfItemWithTag:) that its items are present and current, rebuilding only when they are not.
// Its items carry one tag (kMLTag), so they are found and removed again before every rebuild: they are present
// exactly once whether or not AppKit rebuilds the menu. Settings and list changes arrive as Darwin
// notifications and rebuild just MenuLoader's items. MenuLoader never inserts into an empty Apple menu, since
// AppKit only adds its own items while the menu is empty.
//
// Build: ./build.sh (release) or ./build.sh test (-DML_TEST: test key, test notification, test tweak ID,
// actions logged instead of performed).
#import <AppKit/AppKit.h>
#import <notify.h>
#import <os/log.h>
#import "DynjectHook.h"
#import "DynjectTweak.h"

#ifdef ML_TEST
#define ML_TWEAK_ID "local.dynject.menuloader.test"
#define ML_PUBLISHED_KEY CFSTR("dynject.menuloader.test")
#define ML_CHANGED_NOTIFICATION "dynject.menuloader.test.changed"
// Tests must not touch real "dynject.tweak.*" keys, so test builds read every tweak's settings payload
// (MenuLoader's own and the ones checkedBy refers to) from this preferences domain instead of the global one.
// Resolution is otherwise the same as DTPrefBool.
#define ML_SETTINGS_DOMAIN CFSTR("local.dynject.menuloader.testprefs")
#else
#define ML_TWEAK_ID "local.dynject.menuloader"
#define ML_PUBLISHED_KEY CFSTR("dynject.menuloader")
#define ML_CHANGED_NOTIFICATION "dynject.menuloader.changed"
#define ML_SETTINGS_DOMAIN kCFPreferencesAnyApplication
#endif

#define ML_ID @ML_TWEAK_ID

/// Tag of every item MenuLoader adds to the Apple menu (items, submenu item, separators): 'dmlr'.
static const NSInteger kMLTag = 0x646D6C72;
/// Tags AppKit gives the Apple menu's own items (four-char codes, stable since at least macOS 13).
static const NSInteger kMLAppStoreTag = 0x736F6674;        // 'soft'  App Store…
static const NSInteger kMLSystemSettingsTag = 0x73797373;  // 'syss'  System Settings…

#pragma mark - State (main thread only)

/// One validated item of the published list that applies to this app.
@interface DMLR_Entry : NSObject
@property (copy) NSString *itemID, *title, *action, *symbol, *checkedBy, *keyEquivalent, *tweakID, *tweakName;
@property NSEventModifierFlags modifiers;
/// The checkedBy switch's manifest default, published by Workbench: used while the tweak has no settings payload.
@property BOOL checkedByDefault;
@end
@implementation DMLR_Entry
@end

/// Target of every MenuLoader menu item.
@interface DMLR_Target : NSObject <NSMenuItemValidation>
- (void)dmlr_perform:(NSMenuItem *)sender;
@end

static NSArray<DMLR_Entry *> *gEntries;   // the items for this app, in published order
static NSString *gPlacement = @"submenu"; // "submenu" or "section"
static NSString *gSubmenuTitle = @"Dynject";
static BOOL gEnabled = YES, gDiagnostics = NO, gLoaded = NO;
static NSUInteger gGeneration = 1, gAppliedGeneration = 0;
static NSUInteger gAddAppleMenuItemsCalls = 0;
static __weak NSMenu *gAppleMenu;          // the _NSAppleMenu instance, captured in the hooks
static DMLR_Target *gTarget;
static NSMutableDictionary<NSString *, NSNumber *> *gSettingsTokens;   // tweak ID -> notify token

static os_log_t MLLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create(ML_TWEAK_ID, "menu"); });
    return log;
}

#define MLInfo(fmt, ...) os_log(MLLog(), fmt, ##__VA_ARGS__)

static NSString *MLBundleID(void) {
    static NSString *bundleID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @""; });
    return bundleID;
}

#ifdef ML_TEST
/// Test builds also print to stderr and post in-process notifications the test host checks.
static void MLTestEvent(NSString *name, NSDictionary *info, NSString *line) {
    fprintf(stderr, "[MenuLoader] %s\n", line.UTF8String);
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil userInfo:info];
}
#endif

#pragma mark - Settings

/// The settings payload of `tweakID` (cached per reload, since each read synchronizes preferences).
static NSDictionary *MLPayload(NSString *tweakID, NSMutableDictionary *cache) {
    id cached = cache[tweakID];
    if (cached) return cached == [NSNull null] ? nil : cached;
    NSDictionary *payload = DTPayloadInDomain(tweakID, ML_SETTINGS_DOMAIN);
    cache[tweakID] = payload ?: [NSNull null];
    return payload;
}

/// Same resolution as DTPrefValue: per-app override, value, manifest default, fallback.
static id MLSetting(NSString *tweakID, NSString *key, NSMutableDictionary *cache) {
    return DTResolve(MLPayload(tweakID, cache), key, MLBundleID(), nil);
}

static BOOL MLSettingBool(NSString *tweakID, NSString *key, BOOL fallback, NSMutableDictionary *cache) {
    id v = MLSetting(tweakID, key, cache);
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : fallback;
}

static NSString *MLSettingString(NSString *tweakID, NSString *key, NSMutableDictionary *cache) {
    id v = MLSetting(tweakID, key, cache);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

#pragma mark - Published list

static NSString *MLString(NSDictionary *d, NSString *key) {
    id v = d[key];
    return [v isKindOfClass:[NSString class]] && [v length] ? v : nil;
}

static BOOL MLValidAction(NSString *action) {
    NSRange colon = [action rangeOfString:@":"];
    if (colon.location == NSNotFound || colon.location + 1 >= action.length) return NO;
    NSString *scheme = [action substringToIndex:colon.location];
    return [@[@"notify", @"url", @"shortcut", @"app"] containsObject:scheme];
}

/// Characters that never make a key equivalent: whitespace, control and format characters, surrogates and
/// private-use characters, which include AppKit's function keys (arrows, F-keys, Delete: U+F700-U+F8FF).
static NSCharacterSet *MLBadKeyCharacters(void) {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *s = [[NSCharacterSet controlCharacterSet] mutableCopy];   // Cc and Cf
        [s formUnionWithCharacterSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [s addCharactersInRange:NSMakeRange(0xD800, 0x800)];     // surrogates (a lone one)
        [s addCharactersInRange:NSMakeRange(0xE000, 0x1900)];    // private use, incl. the function keys
        [s addCharactersInRange:NSMakeRange(0xF0000, 0x20000)];  // supplementary private use (planes 15 and 16)
        set = [s copy];
    });
    return set;
}

/// Validates and normalizes a published shortcut into `e`, with the rules Workbench's parser applies
/// (docs/tweak-format.md), enforced again because the published key can be hand-edited or come from an older
/// Workbench. The Apple menu is checked for key equivalents in every app it is injected into, before the key
/// reaches the focused view, so a shortcut must use Command: a bare key, Shift+key, Option+key (how accented
/// characters are typed) or Control+key (text editing and terminal keys such as ⌃A, ⌃E, ⌃K) would be taken from
/// typing everywhere. Returns NO (with *why) when there is no
/// shortcut.
static BOOL MLParseShortcut(NSString *key, id mods, DMLR_Entry *e, NSString **why) {
    if (!key) { *why = nil; return NO; }
    // One character, which may be more than one UTF-16 unit.
    if ([key rangeOfComposedCharacterSequenceAtIndex:0].length != key.length) { *why = @"keyEquivalent is not one character"; return NO; }
    if ([key rangeOfCharacterFromSet:MLBadKeyCharacters()].location != NSNotFound) {
        *why = @"keyEquivalent is not a visible character";
        return NO;
    }
    NSEventModifierFlags mask = NSEventModifierFlagCommand;   // NSMenuItem's default when none are given
    if (mods) {
        if (![mods isKindOfClass:[NSArray class]]) { *why = @"modifiers is not an array"; return NO; }
        mask = 0;
        for (id m in mods) {
            if ([m isEqual:@"command"]) mask |= NSEventModifierFlagCommand;
            else if ([m isEqual:@"option"]) mask |= NSEventModifierFlagOption;
            else if ([m isEqual:@"shift"]) mask |= NSEventModifierFlagShift;
            else if ([m isEqual:@"control"]) mask |= NSEventModifierFlagControl;
            else { *why = @"unknown modifier"; return NO; }   // no shortcut rather than a wrong one
        }
    }
    // AppKit matches a letter key equivalent by its case: "J" is ⇧⌘J (Shift implied), while "j" with a Shift mask
    // is matched as plain ⌘J. So a Shift letter is always the uppercase letter plus Shift, as Workbench publishes it.
    NSString *lower = key.lowercaseString, *upper = key.uppercaseString;
    if (![lower isEqualToString:key] && [upper isEqualToString:key]) {
        mask |= NSEventModifierFlagShift;
    } else if (![upper isEqualToString:key] && [lower isEqualToString:key] && (mask & NSEventModifierFlagShift)
               && upper.length && [upper rangeOfComposedCharacterSequenceAtIndex:0].length == upper.length) {
        key = upper;
    }
    if (!(mask & NSEventModifierFlagCommand)) {
        *why = @"shortcut without command";
        return NO;
    }
    e.keyEquivalent = key;
    e.modifiers = mask;
    return YES;
}

/// Parses one published item. Returns nil (and says why in *why) for an invalid one; *filtered is set for a
/// valid item that does not apply to this app.
static DMLR_Entry *MLParseItem(id raw, NSString **why, BOOL *filtered) {
    *filtered = NO;
    if (![raw isKindOfClass:[NSDictionary class]]) { *why = @"not a dictionary"; return nil; }
    NSDictionary *d = raw;
    DMLR_Entry *e = [DMLR_Entry new];
    e.itemID = MLString(d, @"id");
    e.title = MLString(d, @"title");
    e.action = MLString(d, @"action");
    e.tweakID = MLString(d, @"tweakID");
    if (!e.itemID || !e.title || !e.action || !e.tweakID) { *why = @"id, title, action and tweakID are required"; return nil; }
    if (!MLValidAction(e.action)) { *why = [NSString stringWithFormat:@"unknown action \"%@\"", e.action]; return nil; }
    e.tweakName = MLString(d, @"tweakName") ?: e.tweakID;
    e.symbol = MLString(d, @"symbol");
    e.checkedBy = MLString(d, @"checkedBy");
    id checkedDefault = d[@"checkedByDefault"];
    e.checkedByDefault = [checkedDefault isKindOfClass:[NSNumber class]] && [checkedDefault boolValue];

    id apps = d[@"apps"];
    if (apps) {
        if (![apps isKindOfClass:[NSArray class]]) { *why = @"apps is not an array"; return nil; }
        if (![apps containsObject:MLBundleID()]) { *filtered = YES; return nil; }
    }

    NSString *shortcutWhy = nil;
    if (!MLParseShortcut(MLString(d, @"keyEquivalent"), d[@"modifiers"], e, &shortcutWhy) && shortcutWhy && gDiagnostics)
        MLInfo("item %{public}@: %{public}@; no shortcut", e.itemID, shortcutWhy);
    return e;
}

static void MLObserveSettings(NSSet<NSString *> *tweakIDs);

/// Re-reads the published list and MenuLoader's own settings. Cheap enough for a change notification; never
/// called per menu open.
static void MLReload(void) {
    NSMutableDictionary *cache = [NSMutableDictionary dictionary];
    gEnabled = MLSettingBool(ML_ID, @"enabled", YES, cache);
    gDiagnostics = MLSettingBool(ML_ID, @"diagnostics", NO, cache);

    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    id published = CFBridgingRelease(CFPreferencesCopyValue(ML_PUBLISHED_KEY, kCFPreferencesAnyApplication,
                                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    NSDictionary *list = [published isKindOfClass:[NSDictionary class]] ? published : nil;
    NSMutableArray<DMLR_Entry *> *entries = [NSMutableArray array];
    NSUInteger invalid = 0, filtered = 0;
    if (list && ![list[@"formatVersion"] isEqual:@1]) {
        MLInfo("published list has formatVersion %{public}@, expected 1; ignored", [list[@"formatVersion"] description]);
        list = nil;
    }
    NSArray *items = [list[@"items"] isKindOfClass:[NSArray class]] ? list[@"items"] : @[];
    NSMutableSet<NSString *> *seen = [NSMutableSet set], *shortcuts = [NSMutableSet set];
    for (id raw in items) {
        NSString *why = nil;
        BOOL skip = NO;
        DMLR_Entry *e = MLParseItem(raw, &why, &skip);
        if (skip) { filtered++; continue; }
        if (!e) { invalid++; MLInfo("skipped an invalid item: %{public}@", why); continue; }
        NSString *uid = [NSString stringWithFormat:@"%@\n%@", e.tweakID, e.itemID];
        if ([seen containsObject:uid]) { invalid++; MLInfo("skipped duplicate item %{public}@", e.itemID); continue; }
        [seen addObject:uid];
        if (e.keyEquivalent) {
            // Two items with one shortcut: the first (in published order) keeps it, as Workbench publishes it.
            NSString *shortcut = [NSString stringWithFormat:@"%@\n%lu", e.keyEquivalent, (unsigned long)e.modifiers];
            if ([shortcuts containsObject:shortcut]) {
                if (gDiagnostics) MLInfo("item %{public}@: shortcut already used by an earlier item; no shortcut", e.itemID);
                e.keyEquivalent = nil;
            } else {
                [shortcuts addObject:shortcut];
            }
        }
        [entries addObject:e];
    }
    gEntries = entries;

    NSString *placement = MLSettingString(ML_ID, @"placement", cache);
    if (![placement isEqual:@"submenu"] && ![placement isEqual:@"section"]) placement = MLString(list, @"placement");
    gPlacement = [placement isEqual:@"section"] ? @"section" : @"submenu";
    NSString *title = MLSettingString(ML_ID, @"submenuTitle", cache);
    title = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!title.length) title = [MLString(list, @"submenuTitle") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    gSubmenuTitle = title.length ? title : @"Dynject";

    NSMutableSet<NSString *> *observe = [NSMutableSet set];
    for (DMLR_Entry *e in entries) if (e.checkedBy) [observe addObject:e.tweakID];
    MLObserveSettings(observe);

    gLoaded = YES;
    gGeneration++;
    if (gDiagnostics) {
        MLInfo("loaded %lu item(s) for %{public}@ (%lu for other apps, %lu invalid), enabled=%d placement=%{public}@ title=\"%{public}@\"",
               (unsigned long)entries.count, MLBundleID(), (unsigned long)filtered, (unsigned long)invalid, gEnabled,
               gPlacement, gSubmenuTitle);
    }
}

#pragma mark - Building the items

static NSImage *MLSymbol(NSString *name) {
    if (!name.length) return nil;
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!image && gDiagnostics) MLInfo("no SF Symbol named %{public}@", name);
    return image;
}

/// Sets an item's icon. From macOS 27 AppKit hides menu item images unless asked to show them; the Apple menu
/// shows its own top items' icons this way (About This Mac, App Store…), so declared symbols are shown too.
static void MLSetImage(NSMenuItem *item, NSString *symbol) {
    item.image = MLSymbol(symbol);
    if (@available(macOS 27.0, *)) {
        if (item.image) item.preferredImageVisibility = NSMenuItemImageVisibilityVisible;
    }
}

static NSMenuItem *MLSeparator(void) {
    NSMenuItem *sep = [NSMenuItem separatorItem];
    sep.tag = kMLTag;
    return sep;
}

static NSMenuItem *MLItemFor(DMLR_Entry *e, NSMutableDictionary *cache) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:e.title action:@selector(dmlr_perform:)
                                           keyEquivalent:e.keyEquivalent ?: @""];
    if (e.keyEquivalent) item.keyEquivalentModifierMask = e.modifiers;
    item.target = gTarget;
    item.tag = kMLTag;
    item.representedObject = e;
    MLSetImage(item, e.symbol);
    item.toolTip = e.tweakName;
    if (e.checkedBy) item.state = MLSettingBool(e.tweakID, e.checkedBy, e.checkedByDefault, cache) ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}

/// Where MenuLoader's block goes: after the section that holds "App Store…" (falling back to the one with
/// "System Settings…"). Returns the insertion index and whether a separator is needed above.
static NSInteger MLInsertionIndex(NSMenu *menu, BOOL *needsSeparatorAbove) {
    NSInteger anchor = [menu indexOfItemWithTag:kMLAppStoreTag];
    if (anchor < 0) anchor = [menu indexOfItemWithTag:kMLSystemSettingsTag];
    NSInteger count = menu.numberOfItems;
    if (anchor >= 0) {
        for (NSInteger i = anchor + 1; i < count; i++) {
            if ([menu itemAtIndex:i].isSeparatorItem) { *needsSeparatorAbove = NO; return i + 1; }
        }
    }
    *needsSeparatorAbove = YES;   // no anchor: a section at the end of the menu
    return count;
}

static NSUInteger MLRemoveItems(NSMenu *menu) {
    NSUInteger removed = 0;
    for (NSInteger i = menu.numberOfItems - 1; i >= 0; i--) {
        if ([menu itemAtIndex:i].tag == kMLTag) { [menu removeItemAtIndex:i]; removed++; }
    }
    return removed;
}

static void MLLogMenu(NSMenu *menu, NSString *reason) {
#ifndef ML_TEST
    if (!gDiagnostics) return;
#endif
    NSMutableArray *titles = [NSMutableArray array];
    for (NSMenuItem *item in menu.itemArray) {
        if (item.hidden) continue;
        NSString *t = item.isSeparatorItem ? @"---" : item.title;
        if (item.tag == kMLTag) t = [@"*" stringByAppendingString:t];
        if (item.submenu && item.tag == kMLTag) {
            NSMutableArray *sub = [NSMutableArray array];
            for (NSMenuItem *s in item.submenu.itemArray) [sub addObject:s.isSeparatorItem ? @"---" : [NSString stringWithFormat:@"%@%@", s.state == NSControlStateValueOn ? @"✓" : @"", s.title]];
            t = [NSString stringWithFormat:@"%@ ▸ [%@]", t, [sub componentsJoinedByString:@" | "]];
        } else if (item.state == NSControlStateValueOn) {
            t = [@"✓" stringByAppendingString:t];
        }
        [titles addObject:t];
    }
    NSString *line = [NSString stringWithFormat:@"Apple menu after %@: %@", reason, [titles componentsJoinedByString:@" | "]];
    MLInfo("%{public}@", line);
#ifdef ML_TEST
    MLTestEvent(@"local.dynject.menuloader.test.built",
                @{@"reason": reason, @"addAppleMenuItemsCalls": @(gAddAppleMenuItemsCalls)}, line);
#endif
}

/// Removes MenuLoader's items from the Apple menu and inserts the current ones. Never touches an empty menu.
static void MLRebuild(NSMenu *menu, NSString *reason) {
    if (!menu || menu.numberOfItems == 0) return;
    if (!gLoaded) MLReload();
    MLRemoveItems(menu);
    gAppliedGeneration = gGeneration;
    if (!gEnabled || gEntries.count == 0 || menu.numberOfItems == 0) { MLLogMenu(menu, reason); return; }

    NSMutableDictionary *cache = [NSMutableDictionary dictionary];
    NSMutableArray<NSMenuItem *> *block = [NSMutableArray array];
    if ([gPlacement isEqual:@"section"]) {
        for (DMLR_Entry *e in gEntries) [block addObject:MLItemFor(e, cache)];
    } else {
        NSMenu *submenu = [[NSMenu alloc] initWithTitle:gSubmenuTitle];
        NSString *lastTweak = nil;
        for (DMLR_Entry *e in gEntries) {
            if (lastTweak && ![lastTweak isEqual:e.tweakID]) [submenu addItem:[NSMenuItem separatorItem]];
            lastTweak = e.tweakID;
            [submenu addItem:MLItemFor(e, cache)];
        }
        NSMenuItem *parent = [[NSMenuItem alloc] initWithTitle:gSubmenuTitle action:NULL keyEquivalent:@""];
        parent.tag = kMLTag;
        MLSetImage(parent, @"puzzlepiece.extension");
        parent.submenu = submenu;
        [block addObject:parent];
    }

    BOOL separatorAbove = NO;
    NSInteger index = MLInsertionIndex(menu, &separatorAbove);
    if (separatorAbove) [menu insertItem:MLSeparator() atIndex:index++];
    for (NSMenuItem *item in block) [menu insertItem:item atIndex:index++];
    // A separator below, unless the block already ends the menu.
    if (!separatorAbove) [menu insertItem:MLSeparator() atIndex:index];
    MLLogMenu(menu, reason);
}

/// Called on every open of the Apple menu: cheap unless something changed.
static void MLEnsure(NSMenu *menu) {
    if (menu.numberOfItems == 0) return;
    if (!gLoaded) MLReload();
    BOOL wantItems = gEnabled && gEntries.count > 0;
    BOOL haveItems = [menu indexOfItemWithTag:kMLTag] >= 0;
    if (gAppliedGeneration != gGeneration || wantItems != haveItems) MLRebuild(menu, @"open");
}

/// Updates checkmarks in place after a tweak's settings changed.
static void MLRefreshChecks(NSString *tweakID) {
    NSMenu *menu = gAppleMenu;
    if (!menu) return;
    NSMutableDictionary *cache = [NSMutableDictionary dictionary];
    NSMutableArray<NSMenuItem *> *items = [NSMutableArray array];
    for (NSMenuItem *item in menu.itemArray) {
        if (item.tag != kMLTag) continue;
        [items addObject:item];
        if (item.submenu) [items addObjectsFromArray:item.submenu.itemArray];
    }
    for (NSMenuItem *item in items) {
        DMLR_Entry *e = [item.representedObject isKindOfClass:[DMLR_Entry class]] ? item.representedObject : nil;
        if (!e.checkedBy || ![e.tweakID isEqual:tweakID]) continue;
        item.state = MLSettingBool(e.tweakID, e.checkedBy, e.checkedByDefault, cache) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    MLLogMenu(menu, [@"settings change of " stringByAppendingString:tweakID]);
}

static void MLChanged(NSString *reason) {
    @try {
        NSMenu *menu = gAppleMenu;
        // Before the Apple menu is first built there is nothing to update: read the list lazily then.
        if (menu.numberOfItems == 0) { gLoaded = NO; return; }
        MLReload();
        MLRebuild(menu, reason);
    } @catch (NSException *e) {
        MLInfo("exception while updating: %{public}@: %{public}@", e.name, e.reason);
    }
}

/// Keeps one settings observer per tweak whose items have checkmarks.
static void MLObserveSettings(NSSet<NSString *> *tweakIDs) {
    if (!gSettingsTokens) gSettingsTokens = [NSMutableDictionary dictionary];
    for (NSString *tweakID in gSettingsTokens.allKeys) {
        if ([tweakIDs containsObject:tweakID] || [tweakID isEqual:ML_ID]) continue;
        notify_cancel(gSettingsTokens[tweakID].intValue);
        [gSettingsTokens removeObjectForKey:tweakID];
    }
    for (NSString *tweakID in tweakIDs) {
        if (gSettingsTokens[tweakID] || [tweakID isEqual:ML_ID]) continue;
        int token = DTPrefObserve(tweakID, dispatch_get_main_queue(), ^{
            @try { MLRefreshChecks(tweakID); } @catch (NSException *e) { MLInfo("exception: %{public}@", e.reason); }
        });
        if (token != -1) gSettingsTokens[tweakID] = @(token);
    }
}

#pragma mark - Actions

static NSString *MLShortcutQuery(NSString *name) {
    // Same encoding as Workbench (AppleMenuItem.Action.openURL): URL query characters minus &=+?#/.
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"&=+?#/"];
    return [name stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

static void MLOpenURL(NSURL *url, DMLR_Entry *e) {
#ifdef ML_TEST
    MLTestEvent(@"local.dynject.menuloader.test.action", @{@"id": e.itemID, @"kind": @"open", @"value": url.absoluteString},
                [NSString stringWithFormat:@"TEST: would open %@ (item %@)", url.absoluteString, e.itemID]);
#else
    (void)e;
    if (![[NSWorkspace sharedWorkspace] openURL:url]) MLInfo("could not open %{public}@", url.absoluteString);
#endif
}

static void MLPerform(DMLR_Entry *e) {
    NSRange colon = [e.action rangeOfString:@":"];
    NSString *scheme = [e.action substringToIndex:colon.location];
    NSString *value = [e.action substringFromIndex:colon.location + 1];
    if (gDiagnostics) MLInfo("%{public}@ chose \"%{public}@\" (%{public}@)", e.tweakID, e.title, e.action);

    if ([scheme isEqual:@"notify"]) {
        uint32_t status = notify_post(value.UTF8String);
        if (status != NOTIFY_STATUS_OK) MLInfo("notify_post %{public}@ failed: %u", value, status);
#ifdef ML_TEST
        MLTestEvent(@"local.dynject.menuloader.test.action", @{@"id": e.itemID, @"kind": @"notify", @"value": value},
                    [NSString stringWithFormat:@"TEST: posted %@ (status %u, item %@)", value, status, e.itemID]);
#endif
    } else if ([scheme isEqual:@"url"]) {
        NSURL *url = [NSURL URLWithString:value];
        if (!url.scheme.length) { MLInfo("not an absolute URL: %{public}@", value); return; }
        MLOpenURL(url, e);
    } else if ([scheme isEqual:@"shortcut"]) {
        NSString *query = MLShortcutQuery(value);
        NSURL *url = query ? [NSURL URLWithString:[@"shortcuts://run-shortcut?name=" stringByAppendingString:query]] : nil;
        if (!url) { MLInfo("bad Shortcut name: %{public}@", value); return; }
        MLOpenURL(url, e);
    } else if ([scheme isEqual:@"app"]) {
        NSURL *appURL = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:value];
#ifdef ML_TEST
        MLTestEvent(@"local.dynject.menuloader.test.action", @{@"id": e.itemID, @"kind": @"app", @"value": value},
                    [NSString stringWithFormat:@"TEST: would launch %@ at %@ (item %@)", value, appURL.path ?: @"(not found)", e.itemID]);
#else
        if (!appURL) { MLInfo("no app with bundle ID %{public}@", value); return; }
        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
        config.activates = YES;
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:appURL configuration:config
                                          completionHandler:^(NSRunningApplication *app, NSError *error) {
            (void)app;
            if (error) MLInfo("could not open %{public}@: %{public}@", value, error.localizedDescription);
        }];
#endif
    }
}

@implementation DMLR_Target
- (void)dmlr_perform:(NSMenuItem *)sender {
    @try {
        DMLR_Entry *e = [sender.representedObject isKindOfClass:[DMLR_Entry class]] ? sender.representedObject : nil;
        if (!e) return;
        if ([NSThread isMainThread]) MLPerform(e);
        else dispatch_async(dispatch_get_main_queue(), ^{ @try { MLPerform(e); } @catch (NSException *x) { MLInfo("action failed: %{public}@", x.reason); } });
    } @catch (NSException *x) {
        MLInfo("action failed: %{public}@: %{public}@", x.name, x.reason);
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    return item.action == @selector(dmlr_perform:);
}
@end

#pragma mark - Hooks

/// Hook class for _NSAppleMenu (never instantiated; `self` is the Apple menu).
@interface DMLR_AppleMenuHook : NSObject
@end

@implementation DMLR_AppleMenuHook
- (void)_addAppleMenuItems {
    DH_ORIG(void (*)(id, SEL));
    if (![NSThread isMainThread]) return;
    @try {
        gAddAppleMenuItemsCalls++;
        gAppleMenu = (NSMenu *)self;
        MLRebuild((NSMenu *)self, [NSString stringWithFormat:@"_addAppleMenuItems #%lu", (unsigned long)gAddAppleMenuItemsCalls]);
    } @catch (NSException *e) {
        MLInfo("exception after _addAppleMenuItems: %{public}@: %{public}@", e.name, e.reason);
    }
}

- (BOOL)updateMenu:(NSMenu *)menu withEvent:(id)event withFlags:(NSUInteger)flags {
    BOOL result = DH_ORIG(BOOL (*)(id, SEL, NSMenu *, id, NSUInteger), menu, event, flags);
    // The Apple menu is also the delegate of its Location and Recent Items submenus: only act for itself.
    if (menu != (id)self || ![NSThread isMainThread]) return result;
    @try {
        gAppleMenu = (NSMenu *)self;
        MLEnsure((NSMenu *)self);
    } @catch (NSException *e) {
        MLInfo("exception after updateMenu: %{public}@: %{public}@", e.name, e.reason);
    }
    return result;
}
@end

DH_CTOR(ML_TWEAK_ID) {
    Class appleMenu = DHClass("_NSAppleMenu");
    SEL add = NSSelectorFromString(@"_addAppleMenuItems");
    SEL update = NSSelectorFromString(@"updateMenu:withEvent:withFlags:");
    if (!appleMenu || ![appleMenu instancesRespondToSelector:add] || ![appleMenu instancesRespondToSelector:update]) {
        MLInfo("MenuLoader inactive: %{public}s", !appleMenu ? "class _NSAppleMenu not found"
               : "_NSAppleMenu lacks _addAppleMenuItems or updateMenu:withEvent:withFlags:");
        return;
    }
    gTarget = [DMLR_Target new];
    NSUInteger hooked = DHHookClass([DMLR_AppleMenuHook class], appleMenu, NULL);
    if (hooked == 0) { MLInfo("MenuLoader inactive: could not hook _NSAppleMenu"); return; }
    if (hooked != 2) MLInfo("MenuLoader: hooked only %lu of 2 _NSAppleMenu methods", (unsigned long)hooked);
    // Changes arrive on the main queue; nothing is read until the Apple menu is first built.
    int token;
    notify_register_dispatch(ML_CHANGED_NOTIFICATION, &token, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        MLChanged(@"list change");
    });
    DTPrefObserve(ML_ID, dispatch_get_main_queue(), ^{ MLChanged(@"MenuLoader settings change"); });
}
