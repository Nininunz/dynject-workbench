// DynjectTweak.h — settings access for tweaks managed by Dynject Workbench.
//
// Drop this header into your tweak. Workbench stores your settings under the key
// "dynject.tweak.<identifier>" in the user's global preferences domain, which sandboxed apps can
// read too, and posts the Darwin notification "dynject.tweak.<identifier>.changed" after each change.
//
//   if (DTPrefBool(@"com.example.tweak", @"enabled", NO)) { ... }
//   double r = DTPrefDouble(@"com.example.tweak", @"radius", 8);
//   DTPrefObserve(@"com.example.tweak", nil, ^{ /* re-read and redraw */ });
//
// Values resolve for the app the tweak runs in: per-app override → global value → manifest default
// → your fallback. Format spec: docs/tweak-format.md (format version 1).
#ifndef DYNJECT_TWEAK_H
#define DYNJECT_TWEAK_H

#import <Foundation/Foundation.h>
#import <notify.h>

/// The whole payload Workbench published for a tweak, read from `domain`
/// (pass kCFPreferencesAnyApplication; other domains are for tests).
static inline NSDictionary *DTPayloadInDomain(NSString *tweakID, CFStringRef domain) {
    if (tweakID.length == 0) return nil;
    NSString *key = [@"dynject.tweak." stringByAppendingString:tweakID];
    // Drop any cached copy so a change announced by the notification is seen.
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    id value = CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key, domain,
                                                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

/// Resolves `key` in a payload: perApp[bundleID][key] → values[key] → defaults[key] → fallback.
static inline id DTResolve(NSDictionary *payload, NSString *key, NSString *bundleID, id fallback) {
    id value = nil;
    if (bundleID.length) {
        NSDictionary *perApp = payload[@"perApp"];
        NSDictionary *app = [perApp isKindOfClass:[NSDictionary class]] ? perApp[bundleID] : nil;
        if ([app isKindOfClass:[NSDictionary class]]) value = app[key];
    }
    if (!value) {
        NSDictionary *values = payload[@"values"];
        if ([values isKindOfClass:[NSDictionary class]]) value = values[key];
    }
    if (!value) {
        NSDictionary *defaults = payload[@"defaults"];
        if ([defaults isKindOfClass:[NSDictionary class]]) value = defaults[key];
    }
    return value ?: fallback;
}

/// The value of `key` for the current app.
static inline id DTPrefValue(NSString *tweakID, NSString *key, id fallback) {
    return DTResolve(DTPayloadInDomain(tweakID, kCFPreferencesAnyApplication), key,
                     [[NSBundle mainBundle] bundleIdentifier], fallback);
}

static inline BOOL DTPrefBool(NSString *tweakID, NSString *key, BOOL fallback) {
    id v = DTPrefValue(tweakID, key, nil);
    return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : fallback;
}

static inline double DTPrefDouble(NSString *tweakID, NSString *key, double fallback) {
    id v = DTPrefValue(tweakID, key, nil);
    return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : fallback;
}

/// Strings, including colors ("#RRGGBB", "#RRGGBBAA", or "auto") and choice values.
static inline NSString *DTPrefString(NSString *tweakID, NSString *key, NSString *fallback) {
    id v = DTPrefValue(tweakID, key, nil);
    return [v isKindOfClass:[NSString class]] ? v : fallback;
}

/// App lists (arrays of bundle IDs). Handy for "exclude these apps" settings.
static inline NSArray<NSString *> *DTPrefList(NSString *tweakID, NSString *key) {
    id v = DTPrefValue(tweakID, key, nil);
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}

/// Calls `handler` on `queue` (main queue if nil) whenever Workbench changes this tweak's settings.
/// Returns the notify token (pass it to notify_cancel to stop), or -1 on failure.
static inline int DTPrefObserve(NSString *tweakID, dispatch_queue_t queue, dispatch_block_t handler) {
    int token = -1;
    NSString *name = [NSString stringWithFormat:@"dynject.tweak.%@.changed", tweakID];
    uint32_t status = notify_register_dispatch(name.UTF8String, &token, queue ?: dispatch_get_main_queue(),
                                               ^(int t) { (void)t; handler(); });
    return status == NOTIFY_STATUS_OK ? token : -1;
}

#endif
