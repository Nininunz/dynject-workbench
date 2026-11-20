// Inspector test host: a getter that throws a C++ exception, to check the inspector catches it.
#import "TestHost.h"
#include <stdexcept>

@implementation ITLeafView (ITCxx)
- (NSString *)cxxThrowingValue {
    throw std::runtime_error("cxx getter");
}
@end
