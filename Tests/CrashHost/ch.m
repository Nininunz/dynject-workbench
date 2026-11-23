// The tweak of the crash test (run.sh): hooks -[CHTarget value] with a hook class whose method calls a helper that
// crashes, so the crash is in the tweak, one frame above its hook.
#import <Foundation/Foundation.h>
#import "DynjectHook.h"

@interface CHValueHook : NSObject
- (int)value;
@end

__attribute__((noinline)) static int CHExplode(volatile int *p) {
    return *p;   // CRASH HERE
}

@implementation CHValueHook
- (int)value {
    volatile int *nowhere = (volatile int *)(uintptr_t)8;
    return CHExplode(nowhere) + DH_ORIG(int (*)(id, SEL));
}
@end

__attribute__((constructor)) static void CHInstall(void) {
    Class target = NSClassFromString(@"CHTarget");
    if (target) DHHookClass([CHValueHook class], target, NULL);
}
