// Inspector test host: shared declarations of TestHost.m and TestHostThrow.mm.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

/// A struct the hook writer doesn't know by name (it has to write a typedef with the same layout).
typedef struct ITPair { double weight; int count; } ITPair;
/// A union: no hook class can be written for a method taking one.
typedef union ITUnion { double d; long long q; } ITUnion;

extern int gITRiskyCalls;

@interface ITLeafView : NSView
/// Counts its calls: the inspector must not read it until asked.
@property (nonatomic, readonly) NSInteger riskyValue;
/// Raises an NSException.
@property (nonatomic, readonly) NSString *throwingValue;
- (ITPair)pair;
- (void)setPair:(ITPair)pair flag:(BOOL)flag;
- (void)takeUnion:(ITUnion)u;
@end

@interface ITLeafView (ITCxx)
/// Throws a C++ exception (TestHostThrow.mm).
@property (nonatomic, readonly) NSString *cxxThrowingValue;
@end
