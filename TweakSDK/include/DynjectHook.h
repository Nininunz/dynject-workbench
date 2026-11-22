// DynjectHook.h — Objective-C method hooking for tweaks injected by Dynject.
//
// Compile DynjectHook.m into your tweak dylib next to your own code (clang -fobjc-arc, linking
// Foundation and CoreGraphics). Every symbol is hidden, so several tweaks in one process can each
// carry their own copy. DynjectHook defines no Objective-C classes and never throws or aborts: bad
// input returns NULL / NO / 0 and is logged (see DHLog).
//
//   #import "DynjectHook.h"
//
//   // 1. Hook one method. Keep the handle and call the original through its exact C type.
//   static DHHook *sSetTitle;
//   static void CSSetTitle(NSWindow *self, SEL _cmd, NSString *title) {
//       DH_CALL_ORIG(sSetTitle, void (*)(id, SEL, NSString *), self, _cmd, title.uppercaseString);
//   }
//
//   // 2. Or write a hook class, an ordinary Objective-C class of your tweak (here CSGlass, an
//   //    NSObject subclass): each method it defines replaces the same method of the target.
//   - (void)setCornerRadius:(CGFloat)radius {              // a method of CSGlass
//       DH_ORIG(void (*)(id, SEL, CGFloat), radius * 2);   // self is the target object here
//   }
//
//   DH_CTOR("local.dynject.calcskin", "com.apple.calculator") {
//       sSetTitle = DHHookMessage(DHClass("NSWindow"), @selector(setTitle:), (IMP)CSSetTitle, NULL);
//       DHHookClass([CSGlass class], DHClass("CALayer"), NULL);
//   }
//
// ABI RULE for DH_CALL_ORIG and DH_ORIG: FN_TYPE must be the exact, non-variadic C function pointer
// type of the original method, including the leading `id` and `SEL` and the real argument and return
// types, e.g. `NSRect (*)(id, SEL, NSRect, BOOL)`. Never call an original through `IMP`, `id (*)(id,
// SEL, ...)` or any other variadic or approximate type: on arm64 variadic arguments are passed on
// the stack while methods expect them in registers, and float, double and struct values travel in
// different registers than integers and pointers.
//
// ARC OWNERSHIP for methods that return a retained object (the alloc, new, copy, mutableCopy and
// init families). The rule differs between the two styles, and the wrong type over-releases:
//  - In a hook-class method (DH_ORIG) the method you write is in the family itself, so FN_TYPE must
//    say that the original returns +1, and for init that it consumes self:
//      typedef id (*CopyFn)(id, SEL, NSZone *) __attribute__((ns_returns_retained));
//      typedef id (*InitFn)(id __attribute__((ns_consumed)), SEL, NSRect) __attribute__((ns_returns_retained));
//  - In a C replacement (DH_CALL_ORIG) use the plain type, `id (*)(id, SEL, NSZone *)`, with no
//    attributes: a C function returns an unretained object, and ARC's retain and autorelease around
//    the call pass the original's +1 on to the caller.
//
// Requires macOS 14 or later (arm64, arm64e, x86_64).
#ifndef DYNJECT_HOOK_H
#define DYNJECT_HOOK_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/// Applied to every DynjectHook symbol so two tweaks' copies never interpose on each other.
#define DH_HIDDEN __attribute__((visibility("hidden")))

/// The version of this SDK, the same as Dynject Workbench's. DynjectHook.m embeds it in every dylib
/// it is compiled into as the C string "dynject.sdk:<version>"; Workbench, `dw tweak list` and
/// `dw doctor` read it back and suggest a rebuild when it is older than theirs. Don't edit it.
#define DH_SDK_VERSION "0.1.3"

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Logging

/// Sets the os_log subsystem DHLog writes to. The default is "dynject.hook"; DH_CTOR sets it to the
/// tweak ID. NULL or "" restores the default.
DH_HIDDEN void DHSetLogSubsystem(const char *subsystem);

/// Implementation detail of DHLog: formats and logs one message.
DH_HIDDEN void DHLogFormat(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// Logs an NSString-style formatted message with os_log at the default level, as public text, to the
/// current subsystem with category "hook". Example: DHLog(@"hooked %@", NSStringFromClass(cls));
#define DHLog(fmt, ...) DHLogFormat((fmt), ##__VA_ARGS__)

#pragma mark - Groups

/// A set of hooks that is switched on and off together. Opaque; lives for the rest of the process.
/// Wherever a group is expected, NULL means "ungrouped": always enabled.
typedef struct DHGroup DHGroup;

/// Creates a group, initially enabled. `name` is used in log messages only and may be NULL.
DH_HIDDEN DHGroup *DHGroupCreate(const char *name);

/// Enables or disables every hook of the group. Setting the state the group already has does nothing.
///
/// Disabling walks the group's hooks in reverse install order. A hook whose replacement is still the
/// method's current implementation is uninstalled: a method the class defines gets its saved original
/// back; a method the hook added to the class (it was only inherited) cannot be removed again, so it
/// is pointed at the superclass implementation as of now, and re-pointed whenever this copy of
/// DynjectHook later changes that. A hook that somebody else has since hooked on top of cannot be removed
/// safely: it stays installed, its replacement keeps being called through that other hook, and it is
/// only marked inactive (check DHHookIsActive in the replacement to pass straight through).
///
/// Enabling walks the hooks in install order: a hook is put back if the method's implementation is
/// still the one written when it was disabled, hooks created while the group was disabled are
/// installed now, and every hook is marked active again. Changes this copy of DynjectHook made to the
/// method in the meantime do not keep a hook out: if hooks beneath it were disabled or enabled it goes
/// back on top of what is there now, and if other hooks of this copy were installed or enabled above
/// it, it goes back into the chain beneath them (hooks keep their install order, the latest
/// outermost). Only when code outside this copy changed the method does the hook stay out: it is
/// marked active, this is logged, and switching the group off and on again installs it once the
/// method is back to what DynjectHook restored.
DH_HIDDEN void DHGroupSetEnabled(DHGroup *group, BOOL enabled);

/// Whether the group is enabled. YES for NULL.
DH_HIDDEN BOOL DHGroupIsEnabled(DHGroup *group);

#pragma mark - Hooking one method

/// A handle to one installed hook. Opaque; lives for the rest of the process.
typedef struct DHHook DHHook;

/// Replaces the implementation of `sel` on `cls` with `replacement`, a C function taking
/// (id self, SEL _cmd, ...the method's arguments) and returning the method's return type.
///
/// - To hook a class method, pass the metaclass: object_getClass(cls).
/// - If `cls` itself implements `sel`, its implementation is swapped and the original is the one
///   that was there. That may be another hook's replacement: hooks chain, the latest one outermost.
/// - If `cls` only inherits `sel`, the replacement is added to `cls` as an override, so the
///   superclass and its other subclasses are unaffected. The original is then looked up in the
///   superclass on every call, so hooks installed on the superclass later are honoured. (That also
///   holds for a hook installed while all earlier hooks on such an override are disabled.)
/// - If `group` is currently disabled, the hook is registered but installed only when the group is
///   enabled.
///
/// Returns NULL (and logs) if `cls`, `sel` or `replacement` is NULL, if `cls` does not respond to
/// `sel`, or if `replacement` already is the implementation `cls` has for `sel`, its own or an
/// inherited one (the hook would be its own original). So after hooking a class, hooking a subclass
/// that inherits the method with the same function returns NULL: the subclass already runs it. Do
/// not use one replacement function for a class and for its subclasses in the other order either:
/// the subclass's original is the superclass's implementation, which would then be the function
/// itself.
///
/// Store the returned handle where the replacement can reach it, typically a static variable, and
/// install hooks before other threads can call the method (DH_CTOR runs before main()). The handle
/// is returned only after the replacement is live, so for a method that may already be in use,
/// call DHHookMessageEx instead.
DH_HIDDEN DHHook *DHHookMessage(Class cls, SEL sel, IMP replacement, DHGroup *group);

/// DHHookMessage for a method that other threads may already be calling (a hook installed after
/// launch, e.g. from a DHWhenClassLoads block). The handle is also written to `*outHook`, and that
/// happens before the replacement becomes reachable, so a call racing in from another thread never
/// finds the handle variable still NULL (as with MSHookMessageEx's `&orig`):
///
///   static DHHook *sLayout;   // read by the replacement
///   DHHookMessageEx(cls, @selector(layout), (IMP)MyLayout, NULL, &sLayout);
///
/// On failure NULL is returned and `*outHook` keeps the value it had. `outHook` may be NULL.
DH_HIDDEN DHHook *DHHookMessageEx(Class cls, SEL sel, IMP replacement, DHGroup *group, DHHook **outHook);

/// The implementation to call as "the original" right now. NULL only for a NULL hook. Cast it to the
/// exact function type before calling it (see the ABI rule above), or use DH_CALL_ORIG.
DH_HIDDEN IMP DHOriginal(DHHook *hook);

/// NO for NULL and for every hook whose group is disabled, YES otherwise.
DH_HIDDEN BOOL DHHookIsActive(DHHook *hook);

/// Calls the original implementation behind `hook`. FN_TYPE is the exact non-variadic function
/// pointer type of the method, followed by all arguments including self and _cmd:
///
///   DH_CALL_ORIG(h, void (*)(id, SEL, CGFloat), self, _cmd, r);
///
/// For originals that return a retained object (alloc, new, copy, mutableCopy, init families) keep
/// the plain type here, without ownership attributes (see ARC OWNERSHIP above). To hook -dealloc,
/// declare the replacement's self `__unsafe_unretained`, use the same in FN_TYPE, and get the
/// selector from sel_registerName("dealloc").
#define DH_CALL_ORIG(hook, FN_TYPE, ...) ((FN_TYPE)DHOriginal(hook))(__VA_ARGS__)

#pragma mark - Hook classes

/// Hooks `target` with every method that `source` itself defines: its instance methods replace the
/// same instance methods of `target`, its class methods the same class methods (installed on
/// target's metaclass), each through DHHookMessage. .cxx_construct, .cxx_destruct, +load and
/// +initialize are never installed; methods `target` does not respond to are skipped and logged.
/// Returns the number of methods hooked.
///
/// -dealloc is not installed either (skipped and logged): under ARC the compiler ends it with
/// [super dealloc], bound to the source class's superclass, so on the target it would skip the
/// target's own dealloc chain or, after DH_ORIG, deallocate the object twice. Hook dealloc with
/// DHHookMessage and a C function (see DH_CALL_ORIG).
///
/// Inside a source method `self` is the target object (or class): call the original with DH_ORIG,
/// and do not use the source class's own instance variables or `super`. Give source classes names
/// that are unique to your tweak, in the source: DH_ORIG finds the class by the name the compiler
/// puts in __PRETTY_FUNCTION__, so a source class must not be renamed for the runtime with
/// __attribute__((objc_runtime_name(...))). Each source class hooks one target: a second call with
/// the same `source` returns 0 and logs.
DH_HIDDEN NSUInteger DHHookClass(Class source, Class target, DHGroup *group);

/// Implementation detail of DH_ORIG: the original implementation behind the hook-class method whose
/// __PRETTY_FUNCTION__ is `prettyFunction` ("-[CSGlass setCornerRadius:]", "+[CSGlass layerClass]",
/// "-[CSGlass(Extra) foo:bar:]", or one of those inside a block's name). The hook is the one that
/// class registered for the selector spelled in that name, the selector the method was compiled for.
/// `sel`, the selector the method was called with, is used only if the class has no hook for the
/// spelled one: the two differ once other code moves the installed method to another selector
/// (method_exchangeImplementations and other alias-selector swizzling). Returns NULL (and logs) if
/// that class was not passed to DHHookClass or hooked neither selector. `self` is used for
/// diagnostics, and to tell an instance method from a class method where the name does not (the
/// name clang gives a C++ lambda, "auto CSGlass::frame::(anonymous class)::operator()() const").
DH_HIDDEN IMP DHOriginalForSource(const char *prettyFunction, SEL sel, id self);

/// Calls the original implementation from inside a method of a hook class (see DHHookClass), or
/// from a block written inside such a method. FN_TYPE is the exact non-variadic function pointer
/// type of the method, including id and SEL; self and _cmd are passed for you, so list only the
/// method's own arguments:
///
///   - (void)setCornerRadius:(CGFloat)r { DH_ORIG(void (*)(id, SEL, CGFloat), r); }
///   - (NSRect)frame                    { return DH_ORIG(NSRect (*)(id, SEL)); }
///
/// It keeps working when other code later swizzles the same method, including by exchanging
/// implementations, which makes _cmd an alias selector here: the live _cmd is passed on.
///
/// In a method of the alloc, new, copy, mutableCopy or init family FN_TYPE needs ARC ownership
/// attributes (see ARC OWNERSHIP at the top of this file).
///
/// If the original cannot be found, the call goes through a NULL pointer, so keep to the supported
/// places: the method body and blocks in it. In Objective-C++, a C++ lambda written directly in a
/// method of the hook class's main @implementation is recognised by the name clang gives it, but
/// not one in a category method, and other compilers may name it differently; in a lambda prefer
/// to capture the original from the method body:
///
///   IMP original = DHOriginalForSource(__PRETTY_FUNCTION__, _cmd, self);   // then cast and call it
#define DH_ORIG(FN_TYPE, ...) \
    ((FN_TYPE)DHOriginalForSource(__PRETTY_FUNCTION__, _cmd, self))(self, _cmd, ##__VA_ARGS__)

#pragma mark - Hooking C functions (imports)

/// A handle to one import hook. Opaque; lives for the rest of the process.
typedef struct DHImportHook DHImportHook;

/// Redirects the calls to the C function `symbol` that go through an image's imports to `replacement`, a C
/// function of the same type. An image calls a function of another library through a pointer in its own
/// imports (the __got / __auth_got / __la_symbol_ptr sections); this rewrites those pointers. No code is
/// patched, so it works under the hardened runtime and with pointer authentication (arm64e).
///
/// - `symbol` is the name as C and dlsym spell it: "getenv", "CGEventSourceFlagsState", or a Swift
///   function's mangled name such as "$s7SwiftUI4ViewPAAE7opacityyQrSdF".
/// - `library` limits it to imports bound to one library, matched against the image's load command by
///   full path or file name: "libSystem.B.dylib", "SwiftUI", "AppKit". NULL: any library.
/// - Covered: the main executable and every other image outside the dyld shared cache (an app's own
///   frameworks and plug-ins, other tweaks), including images loaded later, which are patched as they
///   load. Images that are unloaded are forgotten.
/// - Not in Apple's own apps: macOS keeps the imports of its platform binaries read-only once they are
///   bound (Calculator, Finder and the rest, on macOS 27), so nothing there can be patched; this is
///   logged. Third-party apps (arm64, arm64e and x86_64) and their frameworks work.
/// - Not covered: calls inside one image (a function calling a function of its own image), calls
///   between libraries of the dyld shared cache (the system frameworks call each other directly),
///   calls through a pointer from dlsym, inlined calls, and calls from your own tweak: the image that
///   contains `replacement` is skipped, so the tweak keeps calling what the imports held. Still call
///   the original through the hook from the replacement: another tweak may have hooked it first.
/// - The original is what the first patched import held (image load order, the main executable
///   first): the function itself, or another hook's replacement, so hooks chain with the latest
///   outermost. Before any import is patched it is the function dlsym finds, and NULL if there is
///   none. A lazy import that was never called yet holds the binder, and dlsym's answer is used then.
/// - Groups: disabling the group puts back every import that still points at the replacement; an
///   import another hook has since been put on top of stays (the hook is marked inactive, see
///   DHImportHookIsActive). Enabling installs it again, on top of what each import holds then.
///
/// Returns NULL (and logs) if `symbol` or `replacement` is NULL. A hook is returned, and logged, even
/// when no loaded image imports the function yet (DHImportHookSiteCount is 0 then). Install hooks before
/// other threads call the function, typically in DH_CTOR; otherwise use DHHookImportEx.
///
///   static DHImportHook *sCopyValue;
///   static CFPropertyListRef MyCopyValue(CFStringRef key, CFStringRef app) {
///       DHLog(@"reads %@ of %@", key, app);
///       return DH_CALL_IMPORT_ORIG(sCopyValue, CFPropertyListRef (*)(CFStringRef, CFStringRef), key, app);
///   }
///   DH_CTOR("com.you.tweak", "com.apple.TextEdit") {
///       sCopyValue = DHHookImport("CFPreferencesCopyAppValue", NULL, (void *)MyCopyValue, NULL);
///   }
///
/// The ABI rule above applies: the replacement and FN_TYPE must have the function's exact type. Don't
/// hook variadic functions (open, printf, NSLog): on arm64 their variadic arguments are on the stack,
/// where a C replacement can't reach them to pass them on. Hook a non-variadic form (vprintf) instead.
DH_HIDDEN DHImportHook *DHHookImport(const char *symbol, const char *library, void *replacement, DHGroup *group);

/// DHHookImport for a function other threads may already be calling: `*outHook` is written before the
/// first import is patched, so a call racing in never finds the handle variable still NULL. On failure
/// NULL is returned and `*outHook` keeps its value. `outHook` may be NULL.
DH_HIDDEN DHImportHook *DHHookImportEx(const char *symbol, const char *library, void *replacement, DHGroup *group,
                                       DHImportHook **outHook);

/// The function to call as "the original" (see DHHookImport). NULL for a NULL hook, and while no import
/// was patched and dlsym found nothing.
DH_HIDDEN void *DHImportOriginal(DHImportHook *hook);

/// NO for NULL and for every hook whose group is disabled, YES otherwise.
DH_HIDDEN BOOL DHImportHookIsActive(DHImportHook *hook);

/// How many imports point at the replacement right now: 0 when no loaded image imports the function (or
/// none bound to `library`), or while the group is disabled.
DH_HIDDEN NSUInteger DHImportHookSiteCount(DHImportHook *hook);

/// Calls the original behind an import hook. FN_TYPE is the function's exact non-variadic type:
///
///   DH_CALL_IMPORT_ORIG(sCopyValue, CFPropertyListRef (*)(CFStringRef, CFStringRef), key, app);
#define DH_CALL_IMPORT_ORIG(hook, FN_TYPE, ...) ((FN_TYPE)DHImportOriginal(hook))(__VA_ARGS__)

#pragma mark - Class lookup

/// objc_getClass(name); NULL if there is no such class or `name` is NULL.
DH_HIDDEN Class DHClass(const char *name);

/// A top-level Swift class `name` of module `module`, looked up as "Module.Name" and then by its
/// mangled name "_TtC<length>Module<length>Name". NULL if absent.
DH_HIDDEN Class DHSwiftClass(const char *module, const char *name);

/// The first class of the image at `imagePath` (NULL: the main executable) whose runtime name ends
/// with `suffix`. Meant for private and nested Swift classes, whose mangled names cannot be spelled
/// reliably: a suffix such as "22CalculatorNSButtonCell" or "CalculatorNSButtonCell" finds them.
/// `imagePath` must be the path dyld loaded the image from. NULL if nothing matches.
DH_HIDDEN Class DHFindClassWithSuffix(const char *imagePath, const char *suffix);

/// Runs `block` exactly once with the class named `name`: synchronously, before returning, if the
/// class already exists; otherwise later, when an image that contains it is loaded (on the loading
/// thread, or on the main queue shortly after) or when DHCheckPendingClasses() finds it.
DH_HIDDEN void DHWhenClassLoads(const char *name, void (^block)(Class cls));

/// Checks all pending DHWhenClassLoads registrations now and runs the blocks whose class exists.
/// Call it after creating classes at run time (objc_allocateClassPair).
DH_HIDDEN void DHCheckPendingClasses(void);

#pragma mark - Tweak entry point and load policy

/// Whether the tweak `tweakID` should set itself up in this process. Returns NO, and logs why, when
///  1. `bundleIDs` (NULL, or a NULL-terminated array) is not empty and does not contain the main
///     bundle's identifier;
///  2. Safe Mode is on for this tweak here: the user's global preferences hold a dictionary under
///     "dynject.safemode" that maps tweak IDs to arrays of bundle IDs, and the array for `tweakID`,
///     or the array under the key "*" (which applies to every tweak: the panic switch), contains
///     this app's bundle ID or "*". So {"*": ["*"]} stops every DynjectHook tweak in every app.
///     Values of any other shape are ignored;
///  3. the Shift key is held down while the tweak loads, unless the environment variable
///     DH_DISABLE_SHIFT_BYPASS is set (to any value);
///  or when `tweakID` is NULL or empty. Otherwise returns YES.
DH_HIDDEN BOOL DHShouldLoad(const char *tweakID, const char *const *bundleIDs);

/// Implementation detail of DH_CTOR's marker: the arguments' text after macro expansion, so a tweak ID or bundle
/// list written as a macro (#define MY_ID "local.me.tweak") is marked by its value, not its name.
#define DH_STRINGIFY_(...) DH_STRINGIFY_IMPL_(__VA_ARGS__)
#define DH_STRINGIFY_IMPL_(...) #__VA_ARGS__

/// Defines the tweak's entry point. Use it once per tweak, followed by the body:
///
///   DH_CTOR("local.dynject.calcskin", "com.apple.calculator", "com.apple.TextEdit") { ... }
///   DH_CTOR("local.dynject.everywhere") { ... }      // no bundle IDs: every app
///
/// When the dylib is loaded (before main()), this sets the log subsystem to TWEAK_ID, asks
/// DHShouldLoad(TWEAK_ID, the listed bundle IDs) and, if it says YES, runs the body. Exceptions
/// raised by the body are logged with their name and reason and never propagate into the app.
///
/// It also compiles in the C string `dynject.ctor:<TWEAK_ID>|<the bundle IDs>` (macros expanded), e.g.
/// `dynject.ctor:"local.dynject.calcskin"|"com.apple.calculator", "com.apple.TextEdit"`, so `dw why` can read which
/// apps the tweak targets without loading it. Keep the "dynject.ctor:" prefix exactly as it is.
#define DH_CTOR(TWEAK_ID, ...) \
    __attribute__((used)) static const char DHCtorMarker_[] = \
        "dynject.ctor:" DH_STRINGIFY_(TWEAK_ID) "|" DH_STRINGIFY_(__VA_ARGS__); \
    static void DHTweakBody_(void); \
    __attribute__((constructor)) static void DHTweakConstructor_(void) { \
        static const char *const dhBundleIDs_[] = { NULL, ##__VA_ARGS__, NULL }; \
        DHSetLogSubsystem(TWEAK_ID); \
        if (!DHShouldLoad(TWEAK_ID, dhBundleIDs_ + 1)) return; \
        @try { \
            DHTweakBody_(); \
        } @catch (NSException *dhException_) { \
            DHLog(@"%s: exception in tweak constructor: %@: %@", TWEAK_ID, dhException_.name, \
                  dhException_.reason); \
        } @catch (...) { \
            DHLog(@"%s: unknown exception in tweak constructor", TWEAK_ID); \
        } \
    } \
    static void DHTweakBody_(void)

#pragma mark - System version

/// Whether the running macOS is `version` or later. `version` is "27", "27.0" or "27.2.1"; missing
/// components count as 0. NO (and logged) for NULL or anything else. An app linked against a macOS
/// 10.15 or older SDK is told "10.16" by the system; that is read as "unknown" and answers YES.
DH_HIDDEN BOOL DHSystemVersionAtLeast(const char *version);

/// Implementation detail of DH_REQUIRE_SYSTEM: DHSystemVersionAtLeast, logging when it says NO.
DH_HIDDEN BOOL DHRequireSystemVersion(const char *version);

/// Load-time guard for the top of a DH_CTOR body: when the running macOS is older than VERSION,
/// logs "requires macOS VERSION or later ..." and returns from the body, so nothing is hooked.
///
///   DH_CTOR("com.you.tweak", "com.apple.finder") {
///       DH_REQUIRE_SYSTEM("27.0");
///       ...
///   }
///
/// Use the same version as the manifest's minimumSystemVersion. Installs already refuse below it,
/// but a sandboxed tweak can't read its manifest, and a macOS downgrade or a copied dylib skips the
/// install check. Declare the real minimum (the first release with the classes and methods you
/// hook); there is no maximum: a newer macOS is checked with testedSystemVersions, which only warns.
#define DH_REQUIRE_SYSTEM(VERSION) \
    do { if (!DHRequireSystemVersion(VERSION)) return; } while (0)

/// TEST ONLY. Sends the lines a hook report (`dw hooks`) writes to `sink` instead of the log; NULL restores the log.
DH_HIDDEN void DHSetReportSinkForTesting(void (*sink)(const char *line));

/// TEST ONLY. Answers a hook report request right away, on this thread: low 32 bits the request ID, bit 32 the scan.
DH_HIDDEN void DHReportForTesting(uint64_t request);

/// TEST ONLY. Makes DHSystemVersionAtLeast compare against `version` ("26.4") instead of the
/// running macOS. NULL restores the default.
DH_HIDDEN void DHSetSystemVersionForTesting(const char *version);

/// TEST ONLY. Makes DHShouldLoad read Safe Mode from preferences domain `domain` instead of the
/// global domain (kCFPreferencesAnyApplication). NULL restores the default.
DH_HIDDEN void DHSetPreferencesDomainForTesting(CFStringRef domain);

/// TEST ONLY. Makes DHShouldLoad treat `bundleID` as the main bundle's identifier. NULL restores
/// the default.
DH_HIDDEN void DHSetBundleIdentifierForTesting(const char *bundleID);

#ifdef __cplusplus
}
#endif

#endif
