// Inspector: shared declarations of the tweak's own files. Everything is hidden (-fvisibility=hidden, and DYI_HIDDEN
// on the C functions for good measure): nothing here is visible to the app or to other tweaks.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#define DYI_ID_C "local.dynject.inspector"
#define DYI_ID @DYI_ID_C
#define DYI_HIDDEN __attribute__((visibility("hidden")))

#ifdef DYI_TEST   // test build (./build.sh test): its own Darwin notification name, never shipped
#define DYI_TOGGLE_NOTIFICATION DYI_ID_C ".test.toggle"
#else
#define DYI_TOGGLE_NOTIFICATION DYI_ID_C ".toggle"
#endif

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Inspector.m

DYI_HIDDEN void DYILog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
/// The `enabled` setting (live), and `enabled && hotkeyEnabled`.
DYI_HIDDEN BOOL DYIEnabled(void);
DYI_HIDDEN BOOL DYIHotkeyEnabled(void);
/// The pasteboard Copy Hook / Copy Class Name / Copy Description write to: the general pasteboard, or in a test
/// run (DYI_TEST build with DYI_TEST=1) a private one, so a test never replaces the user's clipboard.
DYI_HIDDEN NSPasteboard *DYIPasteboard(void);
/// Runs `block` in @try, catching Objective-C and C++ exceptions. Returns the exception's description, or nil.
DYI_HIDDEN NSString *_Nullable DYITry(NS_NOESCAPE void (^block)(void));

#pragma mark - DYITrace.m: the method tracer

/// Starts tracing the method (see DYITrace.m). nil on success, else why it can't be traced.
DYI_HIDDEN NSString *_Nullable DYITraceMethod(Class cls, SEL sel, BOOL classMethod);
DYI_HIDDEN void DYIUntraceMethod(Class cls, SEL sel, BOOL classMethod);
/// Traces every method `cls` itself defines (class methods with `classMethods`). Returns how many; the ones that
/// can't be traced go to *outRefused.
DYI_HIDDEN NSUInteger DYITraceClass(Class cls, BOOL classMethods, NSUInteger *_Nullable outRefused);
DYI_HIDDEN void DYIUntraceAll(void);
DYI_HIDDEN BOOL DYITraceIsActive(Class cls, SEL sel, BOOL classMethod);
DYI_HIDDEN NSUInteger DYITraceActiveCount(void);
/// The last trace lines (also in the log, category "trace"), oldest first.
DYI_HIDDEN NSArray<NSString *> *DYITraceRecentLines(void);
DYI_HIDDEN void DYITraceClearRecent(void);
/// Adds a short backtrace to every line.
DYI_HIDDEN void DYITraceSetBacktraces(BOOL on);
DYI_HIDDEN BOOL DYITraceBacktraces(void);

#pragma mark - DYIRuntime.m: introspection, never calls anything but getters the caller asks for

/// The image (framework or dylib) that defines `cls`, and the one an implementation lives in.
DYI_HIDDEN NSString *DYIImageOfClass(Class cls);
DYI_HIDDEN NSString *DYIImageOfIMP(IMP _Nullable imp);
/// "QuartzCore" for ".../QuartzCore.framework/Versions/A/QuartzCore", "libfoo.dylib" for dylibs.
DYI_HIDDEN NSString *DYIShortImageName(NSString *path);
/// cls, its superclass, ... up to the root class.
DYI_HIDDEN NSArray<Class> *DYIClassChain(Class cls);
/// Readable type for an encoding (display), e.g. "double", "NSString *", "CGRect", "struct Foo *".
DYI_HIDDEN NSString *DYIReadableType(const char *encoding);

@interface DYIMethodInfo : NSObject
@property (nonatomic, readonly) Class cls;           // the class (not the metaclass) it was listed on
@property (nonatomic, readonly) BOOL classMethod;
@property (nonatomic, readonly) SEL selector;
@property (nonatomic, readonly, copy) NSString *encoding;
@property (nonatomic, readonly, copy) NSString *signature;   // "- (void)setCornerRadius:(double)arg1"
@property (nonatomic, readonly, copy) NSString *image;       // short image name of the IMP
@property (nonatomic, readonly, copy) NSString *imagePath;
@end

@interface DYIPropertyInfo : NSObject
@property (nonatomic, readonly) Class cls;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *typeEncoding;
@property (nonatomic, readonly, copy) NSString *readableType;
@property (nonatomic, readonly, copy) NSString *attributes;   // "readonly, copy"
@property (nonatomic, readonly) SEL getter;
@property (nonatomic, readonly, copy) NSString *declaration;  // "@property (readonly) double cornerRadius"
@end

@interface DYIIvarInfo : NSObject
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *readableType;
@property (nonatomic, readonly) ptrdiff_t offset;
@end

DYI_HIDDEN NSArray<DYIMethodInfo *> *DYIMethodsOfClass(Class cls, BOOL classMethods);
DYI_HIDDEN NSArray<DYIPropertyInfo *> *DYIPropertiesOfClass(Class cls);
DYI_HIDDEN NSArray<DYIIvarInfo *> *DYIIvarsOfClass(Class cls);
DYI_HIDDEN NSArray<NSString *> *DYIProtocolsOfClass(Class cls);

/// A DynjectHook hook-class skeleton for the method (see README). Methods whose types can't be written exactly get
/// an explanatory comment instead of code.
DYI_HIDDEN NSString *DYIHookSkeleton(DYIMethodInfo *method);

/// A short, side-effect-free description of a value: strings, numbers, NSValue geometry, collections (count only),
/// colors; any other object as <Class 0x...> without calling it. Never calls -description on arbitrary objects.
DYI_HIDDEN NSString *DYIDescribe(id _Nullable value);
/// "<Class 0x...>"
DYI_HIDDEN NSString *DYIPointerString(id _Nullable object);
/// -description of an object, in @try, truncated. Only for explicit user actions (Copy Description, curated rows).
DYI_HIDDEN NSString *DYIDescriptionOf(id _Nullable object, NSUInteger maxLength);
/// sRGB components of a CGColor, "#RRGGBB aA" or "(none)".
DYI_HIDDEN NSString *DYIDescribeCGColor(CGColorRef _Nullable color);

/// Calls the property's getter on `object` (main thread, @try, KVC for objects/scalars/structs, a typed call for
/// pointers). Returns the value (boxed) in *outValue when it is an object worth navigating to, and the text to show.
DYI_HIDDEN NSString *DYIEvaluateProperty(id object, DYIPropertyInfo *property, id _Nullable *_Nullable outValue);

/// Class names of every image loaded in the process, collected on a background queue the first time; `done` runs on
/// the main queue with the sorted list (cached after that).
DYI_HIDDEN void DYILoadClassNames(void (^done)(NSArray<NSString *> *names));

#pragma mark - DYIPicker.m

@interface DYIPicker : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly, getter=isActive) BOOL active;
@property (nonatomic, readonly) BOOL layerMode;
/// YES while the pick was started by holding ⌃⌥⌘ (releasing them cancels).
@property (nonatomic, readonly) BOOL holdMode;
/// The current candidate and its outline label.
@property (nonatomic, readonly, nullable) NSView *hoveredView;
@property (nonatomic, readonly, nullable) CALayer *hoveredLayer;
@property (nonatomic, readonly, copy) NSString *labelText;
@property (nonatomic, readonly, nullable) NSWindow *overlayWindow;
/// Installs the local event monitor (hotkey, keys and clicks while picking). Main thread.
- (void)installMonitor;
- (void)beginWithHold:(BOOL)hold;
- (void)cancel;
- (void)toggleLayerMode;
/// Selects the current candidate: opens the inspector on it and leaves pick mode.
- (void)selectCurrent;
/// Recomputes the candidate for a screen point (test runs feed points here; normally the mouse position).
- (void)updateForScreenPoint:(NSPoint)point;
#ifdef DYI_TEST
/// Test runs: use this point instead of the mouse position. NAN/NAN: use the mouse again.
@property (nonatomic) NSPoint testCursor;
#endif
@end

/// Deepest visible view at a point in window coordinates, starting at the window's frame view.
DYI_HIDDEN NSView *_Nullable DYIDeepestView(NSWindow *window, NSPoint windowPoint);
/// Deepest frontmost layer at a point in `view`'s coordinates, in the layer tree of `view` (or its nearest
/// layer-backed ancestor).
DYI_HIDDEN CALayer *_Nullable DYIDeepestLayer(NSView *view, NSPoint windowPoint, NSView *_Nullable *_Nullable outHost);
/// Every visible layer under the point in the whole window, frontmost first (layer mode steps through it with Tab).
DYI_HIDDEN NSArray<CALayer *> *DYILayerStack(NSWindow *window, NSPoint windowPoint, NSView *_Nullable *_Nullable outHost);
/// The layer's bounds in window coordinates, through `host` (the view whose layer tree contains it).
DYI_HIDDEN NSRect DYILayerRectInWindow(CALayer *layer, NSView *host);

#pragma mark - DYIPanel.m

@interface DYIPanelController : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly, nullable) NSWindow *panel;
/// Shows the panel inspecting `object` (an instance) and pushes it on the history.
- (void)inspectObject:(id)object;
/// Shows the panel on a class (no instance).
- (void)inspectClass:(Class)cls;
- (void)close;
#ifdef DYI_TEST
/// Test hook: answers one command (see testhost/TestHost.m). Returns the reply.
- (NSDictionary *)testCommand:(NSDictionary *)command;
#endif
@end

NS_ASSUME_NONNULL_END
