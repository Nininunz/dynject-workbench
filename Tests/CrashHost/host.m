// The host of the crash test (run.sh): calls -[CHTarget value] after a moment (the hook map has to be in the log).
#import <Foundation/Foundation.h>

@interface CHTarget : NSObject
- (int)value;
@end
@implementation CHTarget
- (int)value { return 1; }
@end

int main(void) {
    @autoreleasepool {
        usleep(500000);
        printf("value=%d\n", [CHTarget new].value);
    }
    return 0;
}
