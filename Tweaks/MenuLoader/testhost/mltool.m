// mltool — the "Workbench side" of the MenuLoader injection test, as a separate process.
//
//   mltool publish <plist>              writes the plist's dictionary to the global key "dynject.menuloader.test"
//                                       and posts "dynject.menuloader.test.changed"
//   mltool settings <tweakID> <plist>   writes a tweak settings payload ("dynject.tweak.<tweakID>") into the TEST
//                                       domain local.dynject.menuloader.testprefs (never the global domain) and
//                                       posts "dynject.tweak.<tweakID>.changed"
//   mltool observe <name> <seconds>     waits for the Darwin notification <name>; prints RECEIVED and exits 0, or
//                                       prints TIMEOUT and exits 1
//   mltool clean                        deletes "dynject.menuloader.test" and the test domain
//
// It refuses every key other than the test ones.
#import <Foundation/Foundation.h>
#import <notify.h>

static CFStringRef const kTestKey = CFSTR("dynject.menuloader.test");
static CFStringRef const kTestDomain = CFSTR("local.dynject.menuloader.testprefs");

static void set(CFStringRef key, id value, CFStringRef domain) {
    CFPreferencesSetValue(key, (__bridge CFPropertyListRef)value, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

static id load(const char *path) {
    NSData *data = [NSData dataWithContentsOfFile:@(path)];
    id plist = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
    if (![plist isKindOfClass:[NSDictionary class]]) { fprintf(stderr, "mltool: %s is not a dictionary plist\n", path); exit(2); }
    return plist;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *cmd = argc > 1 ? @(argv[1]) : @"";
        if ([cmd isEqual:@"publish"] && argc == 3) {
            set(kTestKey, load(argv[2]), kCFPreferencesAnyApplication);
            notify_post("dynject.menuloader.test.changed");
            return 0;
        }
        if ([cmd isEqual:@"settings"] && argc == 4) {
            NSString *key = [@"dynject.tweak." stringByAppendingString:@(argv[2])];
            set((__bridge CFStringRef)key, load(argv[3]), kTestDomain);
            notify_post([key stringByAppendingString:@".changed"].UTF8String);
            return 0;
        }
        if ([cmd isEqual:@"observe"] && argc == 4) {
            int token;
            __block BOOL got = NO;
            notify_register_dispatch(argv[2], &token, dispatch_get_main_queue(), ^(int t) { (void)t; got = YES; });
            printf("READY\n");
            fflush(stdout);
            NSDate *end = [NSDate dateWithTimeIntervalSinceNow:atof(argv[3])];
            while (!got && [end timeIntervalSinceNow] > 0)
                [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            printf("%s\n", got ? "RECEIVED" : "TIMEOUT");
            return got ? 0 : 1;
        }
        if ([cmd isEqual:@"clean"]) {
            set(kTestKey, nil, kCFPreferencesAnyApplication);
            CFArrayRef keys = CFPreferencesCopyKeyList(kTestDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
            for (NSString *key in (__bridge NSArray *)keys) set((__bridge CFStringRef)key, nil, kTestDomain);
            if (keys) CFRelease(keys);
            return 0;
        }
        fprintf(stderr, "usage: mltool publish <plist> | settings <tweakID> <plist> | observe <name> <seconds> | clean\n");
        return 2;
    }
}
