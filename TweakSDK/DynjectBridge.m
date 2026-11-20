// DynjectBridge.m — implementation of DynjectBridge.h. Compile with -fobjc-arc.
//
// Design notes
// - No Objective-C classes are defined here and every external symbol is hidden (DB_HIDDEN in the header), so
//   several tweaks in one process can each compile this file. Each copy has its own connection.
// - All state (the connection, the token consumed last) lives on one serial queue, sQueue. Public functions
//   validate and serialize on the caller's thread, then hop to sQueue; nothing waits on it.
// - The token is read from the global preferences domain and consumed with libsandbox's
//   sandbox_extension_consume, looked up with dlsym so a macOS without it makes requests fail, not the app.
//   Only a token for exactly this service is consumed: eight ';'-separated fields, the seventh
//   "com.apple.app-sandbox.mach", the eighth DB_SERVICE_NAME. Anything else counts as no token (logged once).
//   A token is consumed once per process (the extension lasts for the life of the process).
// - dynject.bridge.changed (which anyone can post) only marks the token for re-reading. The next request re-reads
//   it, and only a different valid token replaces the connection; the old one is cancelled 6 s later, after any
//   request still on it has had its answer or its timeout. A notification never fails a request.
// - Each request has a 5 s timer on sQueue. Whichever of reply and timer comes first answers; the other is
//   dropped. The caller's block runs on the caller's queue, inside @try, so an exception in it is logged.
// - Test builds pass other names: -DDB_SERVICE_NAME='"..."' -DDB_TOKEN_KEY='"..."' -DDB_CHANGED_NOTIFICATION='"..."'.
#import "DynjectBridge.h"

#import <dlfcn.h>
#import <notify.h>
#import <os/log.h>
#import <stdlib.h>
#import <string.h>
#import <xpc/xpc.h>

#if !__has_feature(objc_arc)
#error DynjectBridge.m must be compiled with -fobjc-arc
#endif

#ifndef DB_SERVICE_NAME
#define DB_SERVICE_NAME "local.dynject.bridge"
#endif
#ifndef DB_TOKEN_KEY
#define DB_TOKEN_KEY "dynject.bridge.token"
#endif
#ifndef DB_CHANGED_NOTIFICATION
#define DB_CHANGED_NOTIFICATION "dynject.bridge.changed"
#endif

#define DB_PROTOCOL_VERSION 1
#define DB_PAYLOAD_KEY "plist"
#define DB_MAX_MESSAGE_BYTES (1 << 20)
#define DB_TIMEOUT_SECONDS 5

NSString *const DBErrorDomain = @"dynject.bridge";
NSString *const DBErrorReasonKey = @"DBErrorReason";

static os_log_t DBLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("dynject.bridge", "sdk"); });
    return log;
}

static NSError *DBMakeError(DBErrorCode code, NSString *message, NSString *reason) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:message ?: @"DynjectBridge error"
                                                                   forKey:NSLocalizedDescriptionKey];
    if (reason) info[DBErrorReasonKey] = reason;
    return [NSError errorWithDomain:DBErrorDomain code:code userInfo:info];
}

#pragma mark - State (sQueue only)

static dispatch_queue_t sQueue;
static xpc_connection_t sConnection;
static char *sConsumedToken;
static int sChangedToken;
static BOOL sRecheckToken;
static BOOL sLoggedBadToken;

/// Lets requests still waiting on `connection` finish (they time out after 5 s), then cancels it.
static void DBRetireConnection(xpc_connection_t connection) {
    if (!connection) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DB_TIMEOUT_SECONDS + 1) * NSEC_PER_SEC), sQueue, ^{
        xpc_connection_cancel(connection);
    });
}

static dispatch_queue_t DBQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sQueue = dispatch_queue_create("dynject.bridge.sdk", DISPATCH_QUEUE_SERIAL);
        // The broker restarted or was reinstalled: re-read the token at the next request.
        uint32_t status = notify_register_dispatch(DB_CHANGED_NOTIFICATION, &sChangedToken, sQueue, ^(int token) {
            (void)token;
            sRecheckToken = YES;
        });
        if (status != NOTIFY_STATUS_OK) os_log(DBLog(), "could not observe %{public}s (%u)", DB_CHANGED_NOTIFICATION, status);
    });
    return sQueue;
}

/// A mach-lookup extension token for exactly DB_SERVICE_NAME.
static BOOL DBIsServiceToken(NSString *token) {
    NSArray<NSString *> *fields = [token componentsSeparatedByString:@";"];
    return fields.count == 8 && [fields[6] isEqualToString:@"com.apple.app-sandbox.mach"]
        && [fields[7] isEqualToString:@DB_SERVICE_NAME] && fields[0].length > 0;
}

static NSString *DBReadToken(void) {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR(DB_TOKEN_KEY), kCFPreferencesAnyApplication);
    if (!value) return nil;
    id object = CFBridgingRelease(value);
    if (![object isKindOfClass:[NSString class]] || [object length] == 0 || [object length] > 4096) return nil;
    if (!DBIsServiceToken(object)) {
        if (!sLoggedBadToken) os_log(DBLog(), "%{public}s holds something other than a token for %{public}s; ignored", DB_TOKEN_KEY, DB_SERVICE_NAME);
        sLoggedBadToken = YES;
        return nil;
    }
    return object;
}

static void DBConsumeToken(NSString *token) {
    const char *utf8 = token.UTF8String;
    if (!utf8 || (sConsumedToken && strcmp(sConsumedToken, utf8) == 0)) return;
    typedef int64_t (*ConsumeFn)(const char *);
    ConsumeFn consume = (ConsumeFn)dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    if (!consume) {
        os_log(DBLog(), "sandbox_extension_consume is unavailable; trying the service without it");
    } else {
        int64_t handle = consume(utf8);
        // Fails harmlessly outside a sandbox; the lookup then needs no extension.
        if (handle < 0) os_log(DBLog(), "sandbox_extension_consume failed (%d); trying the service anyway", errno);
    }
    free(sConsumedToken);
    sConsumedToken = strdup(utf8);
}

static xpc_connection_t DBConnection(NSError **error) {
    if (sConnection && sRecheckToken) {
        sRecheckToken = NO;
        NSString *token = DBReadToken();
        // Same token (a restart) or none usable: keep the connection; libxpc reconnects it after a restart.
        if (!token || (sConsumedToken && strcmp(sConsumedToken, token.UTF8String) == 0)) return sConnection;
        DBRetireConnection(sConnection);
        sConnection = nil;
    }
    if (sConnection) return sConnection;
    sRecheckToken = NO;
    NSString *token = DBReadToken();
    if (!token) {
        *error = DBMakeError(DBErrorNotInstalled, @"DynjectBridge isn't installed (no token in the global preferences)", nil);
        return nil;
    }
    DBConsumeToken(token);
    xpc_connection_t connection = xpc_connection_create_mach_service(DB_SERVICE_NAME, DBQueue(), 0);
    if (!connection) {
        *error = DBMakeError(DBErrorConnection, @"could not create the DynjectBridge connection", nil);
        return nil;
    }
    void *identity = (__bridge void *)connection;   // no strong reference from its own handler
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (event == XPC_ERROR_CONNECTION_INVALID && (__bridge void *)sConnection == identity) sConnection = nil;
    });
    xpc_connection_resume(connection);
    sConnection = connection;
    return connection;
}

#pragma mark - Requests

BOOL DBIsAvailable(void) {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR(DB_TOKEN_KEY), kCFPreferencesAnyApplication);
    if (!value) return NO;
    id object = CFBridgingRelease(value);
    return [object isKindOfClass:[NSString class]] && DBIsServiceToken(object);
}

static void DBDeliver(dispatch_queue_t queue, DBReplyBlock reply, NSDictionary *result, NSError *error) {
    if (!reply) return;
    dispatch_async(queue, ^{
        @try {
            reply(result, error);
        } @catch (NSException *e) {
            os_log(DBLog(), "a DynjectBridge reply block raised %{public}@", e.name);
        } @catch (...) {
            os_log(DBLog(), "a DynjectBridge reply block raised");
        }
    });
}

static void DBHandleReply(xpc_object_t reply, xpc_connection_t connection, dispatch_queue_t queue, DBReplyBlock block) {
    if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
        if (reply == XPC_ERROR_CONNECTION_INVALID) {
            if (sConnection == connection) sConnection = nil;
            DBDeliver(queue, block, nil, DBMakeError(DBErrorConnection, @"DynjectBridge is not reachable (is the agent running?)", nil));
        } else {
            DBDeliver(queue, block, nil, DBMakeError(DBErrorConnection, @"the connection to DynjectBridge was interrupted; send again", nil));
        }
        return;
    }
    size_t length = 0;
    const void *bytes = xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_data(reply, DB_PAYLOAD_KEY, &length) : NULL;
    id object = nil;
    if (bytes && length <= DB_MAX_MESSAGE_BYTES) {
        @try {
            object = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:bytes length:length]
                                                               options:NSPropertyListImmutable format:NULL error:NULL];
        } @catch (...) {
            object = nil;
        }
    }
    if (![object isKindOfClass:[NSDictionary class]]) {
        DBDeliver(queue, block, nil, DBMakeError(DBErrorBadReply, @"unreadable reply from DynjectBridge", nil));
        return;
    }
    NSDictionary *d = object;
    if ([d[@"ok"] isEqual:@YES]) {
        id result = d[@"result"];
        DBDeliver(queue, block, [result isKindOfClass:[NSDictionary class]] ? result : nil, nil);
        return;
    }
    NSString *code = [d[@"error"] isKindOfClass:[NSString class]] ? d[@"error"] : @"failed";
    NSString *message = [d[@"message"] isKindOfClass:[NSString class]] ? d[@"message"] : code;
    DBDeliver(queue, block, nil, DBMakeError(DBErrorDenied, [NSString stringWithFormat:@"%@: %@", code, message], code));
}

void DBRequest(const char *tweakID, const char *action, NSDictionary *args, dispatch_queue_t queue, DBReplyBlock reply) {
    dispatch_queue_t replyQueue = queue ?: dispatch_get_main_queue();
    DBReplyBlock block = [reply copy];
    NSString *tweak = tweakID ? [NSString stringWithUTF8String:tweakID] : nil;
    NSString *name = action ? [NSString stringWithUTF8String:action] : nil;
    if (!tweak.length || !name.length || (args && ![args isKindOfClass:[NSDictionary class]])) {
        DBDeliver(replyQueue, block, nil, DBMakeError(DBErrorInvalidArgument, @"DBRequest needs a tweak ID, an action and a dictionary (or nil) of arguments", nil));
        return;
    }
    NSDictionary *request = @{@"v": @DB_PROTOCOL_VERSION, @"tweak": tweak, @"action": name, @"args": args ?: @{}};
    NSData *data = nil;
    @try {
        data = [NSPropertyListSerialization dataWithPropertyList:request format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    } @catch (...) {
        data = nil;
    }
    if (!data) {
        DBDeliver(replyQueue, block, nil, DBMakeError(DBErrorInvalidArgument, @"the arguments are not a property list", nil));
        return;
    }
    if (data.length > DB_MAX_MESSAGE_BYTES) {
        DBDeliver(replyQueue, block, nil, DBMakeError(DBErrorInvalidArgument, @"the request is larger than 1 MB", nil));
        return;
    }
    dispatch_async(DBQueue(), ^{
        NSError *error = nil;
        xpc_connection_t connection = DBConnection(&error);
        if (!connection) {
            DBDeliver(replyQueue, block, nil, error);
            return;
        }
        xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_data(message, DB_PAYLOAD_KEY, data.bytes, data.length);
        __block BOOL answered = NO;   // sQueue only
        xpc_connection_send_message_with_reply(connection, message, sQueue, ^(xpc_object_t response) {
            if (answered) return;
            answered = YES;
            DBHandleReply(response, connection, replyQueue, block);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)DB_TIMEOUT_SECONDS * NSEC_PER_SEC), sQueue, ^{
            if (answered) return;
            answered = YES;
            DBDeliver(replyQueue, block, nil, DBMakeError(DBErrorTimeout, @"DynjectBridge didn't answer within 5 s", nil));
        });
    });
}

void DBSetSetting(const char *tweakID, NSString *key, id value, NSString *app, void (^done)(NSError *error)) {
    void (^callback)(NSError *) = [done copy];
    NSMutableDictionary *args = [NSMutableDictionary dictionary];
    if ([key isKindOfClass:[NSString class]]) args[@"key"] = key;
    if (value) args[@"value"] = value;
    if ([app isKindOfClass:[NSString class]]) args[@"app"] = app;
    if (!args[@"key"] || !args[@"value"]) {
        if (callback) {
            NSError *e = DBMakeError(DBErrorInvalidArgument, @"DBSetSetting needs a key and a value", nil);
            dispatch_async(dispatch_get_main_queue(), ^{ callback(e); });
        }
        return;
    }
    DBRequest(tweakID, "settings.set", args, dispatch_get_main_queue(), ^(NSDictionary *result, NSError *error) {
        (void)result;
        if (callback) callback(error);
    });
}
