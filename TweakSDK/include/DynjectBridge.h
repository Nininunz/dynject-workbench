// DynjectBridge.h — ask the DynjectBridge broker to do a few things a sandboxed app can't.
//
// A tweak injected into a sandboxed app (Calculator, Notes, ...) runs under that app's sandbox: it can read
// its settings (DynjectTweak.h) but not write them, post most notifications or open other apps' URLs. The
// broker, `dw bridge serve`, runs unsandboxed as your user (LaunchAgent local.dynject.bridge; Workbench ->
// Bridge -> Install) and performs a short list of actions for tweaks that declare them in their manifest:
//
//   <key>bridge</key>
//   <array><string>settings.set</string><string>notify</string><string>open:https</string></array>
//
// Compile DynjectBridge.m into your tweak dylib next to your own code (clang -fobjc-arc, Foundation). Every
// symbol is hidden and no Objective-C class is defined, so several tweaks in one process can each carry a
// copy. Nothing here throws, aborts or blocks the calling thread: every failure arrives as an NSError.
//
//   #import "DynjectBridge.h"
//
//   DBRequest("com.you.mytweak", "notify", @{@"name": @"com.you.mytweak.refresh"}, NULL,
//             ^(NSDictionary *result, NSError *error) {
//       if (error) NSLog(@"bridge: %@", error.localizedDescription);
//   });
//   DBSetSetting("com.you.mytweak", @"enabled", @NO, nil, NULL);
//
// The broker decides who you are from the app you run in, not from the tweak ID you pass: any code in the
// same app could pass the same ID. That is why the actions are narrow. Details: docs/bridge.md.
//
// Requires macOS 14 or later (arm64, arm64e, x86_64).
#ifndef DYNJECT_BRIDGE_H
#define DYNJECT_BRIDGE_H

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

/// Applied to every DynjectBridge symbol so two tweaks' copies never interpose on each other.
#define DB_HIDDEN __attribute__((visibility("hidden")))

#ifdef __cplusplus
extern "C" {
#endif

/// NSError domain of every DynjectBridge error.
DB_HIDDEN extern NSString *const DBErrorDomain;

/// userInfo key: the broker's error code string ("not-injected", "capability-missing", ...) when the broker
/// refused the request (DBErrorDenied). docs/bridge.md lists them.
DB_HIDDEN extern NSString *const DBErrorReasonKey;

typedef NS_ENUM(NSInteger, DBErrorCode) {
    /// tweakID or action is NULL or empty, args isn't a property list, or the request is larger than 1 MB.
    DBErrorInvalidArgument = 1,
    /// The broker has never run for this user: its token isn't in the global preferences.
    DBErrorNotInstalled = 2,
    /// The service couldn't be reached (not running, or this process can't look it up).
    DBErrorConnection = 3,
    /// No reply within the timeout (5 s).
    DBErrorTimeout = 4,
    /// The broker answered no. DBErrorReasonKey has its code; localizedDescription its message.
    DBErrorDenied = 5,
    /// The reply couldn't be read.
    DBErrorBadReply = 6,
};

/// Called exactly once, on the queue given to DBRequest. On success `error` is nil and `result` is the action's
/// result (nil for actions that return none). On failure `result` is nil.
typedef void (^DBReplyBlock)(NSDictionary *result, NSError *error);

/// YES when the broker has published a token for its service, i.e. it is installed and has run since. Reads one
/// global preferences key; doesn't contact the broker. A YES doesn't promise a request will be allowed.
DB_HIDDEN BOOL DBIsAvailable(void);

/// Sends one request: {v: 1, tweak: tweakID, action: action, args: args}. Returns at once; `reply` runs on
/// `queue` (NULL: the main queue) when the broker answers, after 5 s without an answer, or right away for a bad
/// argument or a missing broker. `args` may be nil; it must be a property list (strings, numbers, booleans,
/// dates, data, arrays and dictionaries with string keys).
///
/// Actions (each but ping needs the capability of the same name in the tweak's manifest):
///   ping              {}                          result {protocol, broker, brokerPID, app, capabilities}
///   settings.set      {key, value, app?}          a setting of this tweak, declared in its manifest; the value
///                                                 must fit the item's type and range. app: a per-app override,
///                                                 only for the app the tweak runs in, only for perApp items.
///                                                 Posts dynject.tweak.<id>.changed. result {key, value}
///   notify            {name}                      posts the Darwin notification `name`, which must be the
///                                                 tweak ID or start with "<tweak ID>.", and not fall inside
///                                                 another installed tweak's ID (com.you.glass.pro.*)
///   open              {url}                       opens the URL; needs open:<its scheme> in the manifest.
///                                                 file:, javascript:, data:, x-apple*, shortcuts:, tel: and
///                                                 other local, script or action-taking schemes never open.
///   pasteboard.write  {string}                    puts the string on the general pasteboard
///
/// The first request in a process reads the token and consumes it (once per process); only a token for exactly
/// this service is accepted. The connection is reused. After dynject.bridge.changed the next request re-reads the
/// token and moves to a new connection only if the token changed; requests still on the old one get their answers.
/// An invalidated connection is rebuilt at the next request. A request in flight while the broker restarts fails
/// with DBErrorConnection; send it again.
DB_HIDDEN void DBRequest(const char *tweakID, const char *action, NSDictionary *args, dispatch_queue_t queue,
                         DBReplyBlock reply);

/// settings.set: sets `key` to `value` (an NSNumber, NSString or NSArray of strings), for every app when `app`
/// is nil, else as an override for `app`, which must be the bundle ID of the app the tweak runs in. `done` runs
/// on the main queue and may be NULL.
DB_HIDDEN void DBSetSetting(const char *tweakID, NSString *key, id value, NSString *app, void (^done)(NSError *error));

#ifdef __cplusplus
}
#endif

#endif
