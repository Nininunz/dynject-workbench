// The bridge end-to-end test's host: a do-nothing process. Bundled and sandboxed it plays an app the test config
// injects the test tweak into (or, under another bundle ID, one it doesn't); linked with TestTweak.m and run bare it
// is the unsandboxed, unbundled probe. The tweak does the work and exits; this only keeps the main queue running.
#import <Foundation/Foundation.h>

int main(void) {
    @autoreleasepool {
        printf("host %s pid %d\n", NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "(no bundle)", getpid());
        fflush(stdout);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:90]];
        printf("host timed out\n");
        return 3;
    }
}
