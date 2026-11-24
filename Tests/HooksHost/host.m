// The host for `dw hooks`: a process with HHTarget, three tweaks injected (DYLD_INSERT_LIBRARIES), waiting to be asked.
#import <Foundation/Foundation.h>
#import <unistd.h>

@interface HHTarget : NSObject
- (int)value;
- (int)other;
- (int)third;
@end
@implementation HHTarget
- (int)value { return 1; }
- (int)other { return 2; }
- (int)third { return 3; }
@end

// Hooked inline (DHHookFunction) by A, then by B on top. Straight-line and long enough for the 16-byte jump.
__attribute__((noinline, visibility("default"))) int hh_compute(int x) {
    volatile int a = x;
    a += 3;
    a *= 7;
    return a - 1;
}

int main(void) {
    @autoreleasepool {
        HHTarget *t = [HHTarget new];
        printf("ready pid=%d value=%d other=%d third=%d ppid=%d compute=%d\n", getpid(), t.value, t.other, t.third,
               getppid() == 424242, hh_compute(1));
        fflush(stdout);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(0); });
        dispatch_main();
    }
}
