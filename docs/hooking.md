# DynjectHook: Objective-C method hooking for Dynject tweaks

DynjectHook is a small Objective-C method-hooking library for tweaks that Dynject injects into macOS apps.
Think of it as a slimmed-down Substrate/Logos with ZKSwizzle-style hook classes, built for
the arm64 calling convention. It is two files that you compile into your tweak dylib:

- [`TweakSDK/include/DynjectHook.h`](../TweakSDK/include/DynjectHook.h): the public API
- [`TweakSDK/DynjectHook.m`](../TweakSDK/DynjectHook.m): the implementation (ARC, no Objective-C classes)

It works alongside [`DynjectTweak.h`](../TweakSDK/include/DynjectTweak.h), which reads the settings
Dynject Workbench publishes for your tweak (see [Tweak format](tweak-format.md)).

**Use it when** you need to change what an existing Objective-C method does: an AppKit method, a method on
one of the app's own classes, or an `@objc` method on a Swift class. **You don't need it when** public API already does
the job. For example, the [TitleBadge](../Examples/TitleBadge) example only adds a titlebar accessory and
swizzles nothing. It still compiles DynjectHook in, but only for `DH_CTOR`, so that it honours Safe Mode and the Shift
bypass (see [Entry point and load policy](#entry-point-and-load-policy-dh_ctor)). Every tweak should start that way.

Requirements: macOS 14+, arm64 / arm64e / x86_64, compiled with `-fobjc-arc`. It depends only on Foundation,
CoreFoundation and CoreGraphics (CoreGraphics is used only for the Shift-key check).

## Quick start

A complete tweak that appends a suffix to window titles in TextEdit. The `enabled` and `suffix` settings come
from Workbench and take effect live.

```objc
// TitleSuffix.m
#import <AppKit/AppKit.h>
#import "DynjectHook.h"
#import "DynjectTweak.h"

#define kID @"com.you.titlesuffix"
static DHGroup *gMain;

// Hook class. It is never instantiated. Its methods are installed on the target class, so at run time
// `self` is an NSWindow, not a TSFX_NSWindowHook. The class name carries a prefix unique to this tweak.
@interface TSFX_NSWindowHook : NSObject
@end

@implementation TSFX_NSWindowHook
- (void)setTitle:(NSString *)title {
    if (DHGroupIsEnabled(gMain) && title.length) {
        title = [title stringByAppendingString:DTPrefString(kID, @"suffix", @" (edited)")];
    }
    DH_ORIG(void (*)(id, SEL, NSString *), title);   // exact type of -[NSWindow setTitle:]
}
@end

DH_CTOR("com.you.titlesuffix", "com.apple.TextEdit") {
    gMain = DHGroupCreate("main");
    DHGroupSetEnabled(gMain, DTPrefBool(kID, @"enabled", YES));   // set the state before installing hooks
    DHHookClass([TSFX_NSWindowHook class], DHClass("NSWindow"), gMain);

    DTPrefObserve(kID, nil, ^{                                    // runs on the main queue
        DHGroupSetEnabled(gMain, DTPrefBool(kID, @"enabled", YES));
    });
}
```

Build it as a universal, ad-hoc signed dylib (same as [`Examples/TitleBadge/build.sh`](../Examples/TitleBadge/build.sh)):

```sh
SDK=$(xcrun --show-sdk-path)
xcrun clang -fobjc-arc -O2 -isysroot "$SDK" -I TweakSDK/include \
  -arch x86_64 -arch arm64 -arch arm64e -dynamiclib -install_name @rpath/libTitleSuffix.dylib \
  TitleSuffix.m TweakSDK/DynjectHook.m \
  -framework Foundation -framework CoreGraphics -framework AppKit -o libTitleSuffix.dylib
codesign --force --sign - --timestamp=none libTitleSuffix.dylib
```

Then declare the dylib in `dynjectd.conf` (or let `dw tweak install` do it, see [TWEAKS.md](../TWEAKS.md)). To get a settings page, add a manifest with a `switch` named `enabled`, a
`text` named `suffix`, and `takesEffect: live` ([Tweak format](tweak-format.md)).

To watch what DynjectHook does, stream its logs. They use your tweak ID as the subsystem and the category `hook`:

```sh
log stream --level default --predicate 'subsystem == "com.you.titlesuffix"'
```

## The ABI rule: always call the original through its exact type

`DH_ORIG` and `DH_CALL_ORIG` take an explicit **non-variadic** function-pointer type. The type must match the
original method exactly, including the leading `id` and `SEL`:

```objc
// -[CSGlass setCornerRadius:(CGFloat)r]
DH_ORIG(void (*)(id, SEL, CGFloat), r);                        // in a hook class
DH_CALL_ORIG(h, void (*)(id, SEL, CGFloat), self, _cmd, r);    // with a DHHook handle

// -[CSGlass frameForBounds:(NSRect)b] -> NSRect
NSRect f = DH_ORIG(NSRect (*)(id, SEL, NSRect), b);
// no arguments
id v = DH_ORIG(id (*)(id, SEL));
```

The C compiler has to know where each argument and the return value go. On Apple arm64, **variadic arguments are
passed on the stack**, but a method reads its declared arguments from registers. A variadic cast therefore compiles
cleanly and then fails at run time:

```objc
// WRONG: variadic type. On arm64 the 12.0 goes on the stack; the method reads d0 and gets garbage.
((void (*)(id, SEL, ...))orig)(self, _cmd, 12.0);
// WRONG: wrong return type. On arm64 an NSRect comes back in d0-d3 and a struct of five doubles
// through a hidden pointer (x8), so calling a struct-returning method through any other type corrupts the result.
id r = ((id (*)(id, SEL, NSRect))orig)(self, _cmd, b);

// RIGHT
((void (*)(id, SEL, CGFloat))orig)(self, _cmd, 12.0);
NSRect f = ((NSRect (*)(id, SEL, NSRect))orig)(self, _cmd, b);
```

Other mistakes the same rule catches: passing a `float` where the method takes `float` (a variadic call promotes it to
`double`), and declaring `BOOL` or `char` returns as `id`. If you have the method's declaration, copy its types. If
you don't, check the encoding with `method_getTypeEncoding`.

### ARC ownership: methods that return a retained object

The cast type also decides how ARC treats the result. It matters for the families that return +1: `alloc`, `new`,
`copy`, `mutableCopy` and `init` (which also consumes `self`). **The rule is different for the two styles**, and
using one style's type in the other over-releases the object, which crashes.

**In a hook-class method (`DH_ORIG`)** the method you write belongs to the family itself, so ARC treats *its* result
as +1. The type has to say that the original does the same, and for `init` that it consumes `self`:

```objc
// copy, mutableCopy, new, alloc families
typedef id (*CopyWithZoneFn)(id, SEL, NSZone *) __attribute__((ns_returns_retained));
- (id)copyWithZone:(NSZone *)zone { return DH_ORIG(CopyWithZoneFn, zone); }

// init family: self is consumed, the result is retained
typedef id (*InitWithFrameFn)(id __attribute__((ns_consumed)), SEL, NSRect) __attribute__((ns_returns_retained));
- (instancetype)initWithFrame:(NSRect)frame { return DH_ORIG(InitWithFrameFn, frame); }
```

With the plain type here, a `copy` hook leaks every copy, and an `init` hook crashes as soon as the original returns
`nil` or a different object.

**In a C replacement (`DH_CALL_ORIG`)** use the plain type, with no attributes, for every family:

```objc
static id MyCopy(id self, SEL _cmd, NSZone *zone) {
    return DH_CALL_ORIG(gCopy, id (*)(id, SEL, NSZone *), self, _cmd, zone);
}
static id MyInit(id self, SEL _cmd, NSRect frame) {
    return DH_CALL_ORIG(gInit, id (*)(id, SEL, NSRect), self, _cmd, frame);
}
```

A C function returns an unretained object, so ARC retains the original's result and autoreleases it on return, which
hands the original's +1 on to the caller. With `ns_returns_retained` here ARC would autorelease an object the caller
also releases.

If all you need is to run code after an object is set up, hooking a later method (`awakeFromNib`, `viewDidLoad`, the
designated setup selector) is still simpler than hooking `init`.

To hook **`dealloc`**, use a C replacement whose `self` is `__unsafe_unretained` (nothing may retain an object that is
being deallocated), and get the selector from `sel_registerName` because ARC rejects `@selector(dealloc)`:

```objc
static void MyDealloc(__unsafe_unretained id self, SEL _cmd) {
    /* clean up per-object state */
    DH_CALL_ORIG(gDealloc, void (*)(__unsafe_unretained id, SEL), self, _cmd);
}
gDealloc = DHHookMessage(cls, sel_registerName("dealloc"), (IMP)MyDealloc, NULL);
```

A hook class cannot hook `dealloc` (see [Hook classes](#hook-classes-dhhookclass-and-dh_orig)).

## Hooking one method: `DHHookMessage`

```objc
static DHHook *gHook;
static void MyLayout(id self, SEL _cmd) {
    DH_CALL_ORIG(gHook, void (*)(id, SEL), self, _cmd);
    /* ... */
}
gHook = DHHookMessage(DHClass("CSGlassView"), @selector(layout), (IMP)MyLayout, group /* or NULL */);
```

- For class methods, pass the metaclass: `object_getClass(cls)`.
- The call returns `NULL` and logs if `cls`, `sel` or `replacement` is `NULL`, if `cls` doesn't respond to `sel`, or
  if `replacement` already is the implementation `cls` has for `sel`, whether its own or an inherited one (it would
  become its own original). DynjectHook never throws or aborts.
- **One replacement function, one class in each class chain.** After you hook a class, hooking a subclass that
  inherits the method with the same function returns `NULL`, because the subclass already runs it. Don't do it in the
  other order either (subclass first, then its superclass): the subclass hook's original is the superclass
  implementation, which would then be the function itself. If you loop over a class list, skip classes whose
  `class_getMethodImplementation(cls, sel)` already is your function.
- Install hooks in `DH_CTOR`, before other threads can call the method: `DHHookMessage` returns the handle only after
  the replacement is in place, so a call racing in from another thread could find your handle variable still `NULL`.
  For a hook you install later, while the app is running, use `DHHookMessageEx` (below).
- `DHOriginal(hook)` returns the IMP to call for the original *right now*. `DHHookIsActive(hook)` reports whether the hook is active
  (see [Groups](#groups)). Handles are never freed, so you can keep them in globals.

### Hooking a method that is already in use: `DHHookMessageEx`

`DHHookMessageEx(cls, sel, replacement, group, &handle)` is `DHHookMessage` with one more argument: the variable your
replacement reads the handle from. DynjectHook writes the handle there **before** the replacement becomes reachable,
so a thread that is calling the method at that moment never sees a `NULL` handle. (This is the order
`MSHookMessageEx` writes its `&orig` in.) On failure it returns `NULL` and leaves the variable as it was.

```objc
static DHHook *gHook;   // read by MyLayout
DHWhenClassLoads("CSGlassView", ^(Class cls) {
    DHHookMessageEx(cls, @selector(layout), (IMP)MyLayout, NULL, &gHook);
});
```

Use it whenever a hook is installed after launch, for example from a `DHWhenClassLoads` block or a settings observer.
Hook classes don't need it: `DH_ORIG` finds its hook through the registry, which is filled in before the method is
replaced. (Creating the hook in a disabled group, storing the handle and then enabling the group has the same
effect, since nothing is installed until the group is enabled.)

### Own vs inherited methods

| The class… | What DynjectHook does | What "original" means |
| --- | --- | --- |
| **defines** `sel` itself | `class_replaceMethod` on the class (it only swaps the implementation; unlike `method_setImplementation` it flushes just that class's method caches) | The IMP that was there before. It may be another hook's replacement (chaining). |
| **only inherits** `sel` | `class_addMethod` on the class, with the inherited method's type encoding | Resolved on every `DHOriginal` call as `class_getMethodImplementation(superclass, sel)` |

Hooking an inherited method affects only that class and its subclasses. The superclass is unchanged. Because the
original is looked up again on each call (a dynamic `super`), a hook added to the superclass later still runs when
your hook calls the original.

### Chaining

Hooks stack. The **most recently installed hook is outermost**: it runs first, and its call to the original
reaches the hook installed before it, and so on down to the real implementation. This also holds across tweaks
and other swizzling code.

That includes code that swizzles by **exchanging implementations** (`method_exchangeImplementations` with an alias
selector such as `xxx_layout`, then `[self xxx_layout]` for the original). Because `DH_CTOR` runs before the app's own
`+load` methods and startup code, such a swizzle usually lands on top of your hook, and your replacement is then
entered with the alias as `_cmd`. Both styles handle that: a `DHHook` handle doesn't depend on `_cmd`, and `DH_ORIG`
identifies the hook-class method by its own name, not by `_cmd`. Pass the `_cmd` you were called with on to the
original (`DH_ORIG` does), since that is what the swizzler's original expects.

## Hook classes: `DHHookClass` and `DH_ORIG`

A hook class is a ZKSwizzle-style container. You write a normal Objective-C class whose methods have the same
selectors as the target's methods, and DynjectHook installs them:

```objc
NSUInteger n = DHHookClass([MYT_CSGlassHook class], DHClass("CSGlassView"), group);
```

- Every method the source class **itself** defines is installed with `DHHookMessage`: instance methods on the target,
  `+` methods on the target's metaclass. `.cxx_construct`, `.cxx_destruct`, `+load` and `+initialize` are excluded.
- **`-dealloc` is excluded too** (skipped and logged). Under ARC the compiler ends every `-dealloc` with
  `[super dealloc]`, bound to the *hook class's* superclass. Installed on the target, that would skip the target's
  own `dealloc` chain, or, if you called `DH_ORIG` first, deallocate the object a second time. Hook `dealloc` with
  `DHHookMessage` and a C function instead (see [ARC ownership](#arc-ownership-methods-that-return-a-retained-object)).
- Methods the target doesn't respond to are skipped and logged. Hook classes cannot add new methods; for that, call `class_addMethod` yourself.
- It returns the number of methods hooked.
- **One target per source class.** A second `DHHookClass` call with the same source returns 0 and logs. To hook
  two targets, write two hook classes.

Inside a hook-class method, `DH_ORIG(FN_TYPE, args...)` calls the original with `self` and `_cmd` filled in. It finds the
original from `__PRETTY_FUNCTION__` (for example `-[MYT_CSGlassHook setCornerRadius:]`, `+[MYT_CSGlassHook layerClass]`, or
the category form `-[MYT_CSGlassHook(Extra) foo:bar:]`): the class name, the instance/class kind and the selector
spelled there identify the hook, whatever `_cmd` the method was entered with (it is an alias selector after an
exchange-style swizzle, see [Chaining](#chaining)). Only if the class has no hook for the spelled selector is `_cmd`
looked up instead. If no hook is found, it logs and returns `NULL`, **and `DH_ORIG` then calls through that `NULL`
pointer**, so keep to the rules below. `DHOriginalForSource` is the function behind it.

Rules for hook-class methods:

- At run time `self` is an instance of the **target** class. Cast it (`[(NSWindow *)self title]`) or declare the
  target's methods in a category interface on the hook class (with no implementation).
- **Don't use `super`.** It dispatches to the hook class's superclass. Call `DH_ORIG` instead.
- **Don't declare ivars or synthesized properties** in a hook class, because target instances don't have that storage. Use
  `objc_setAssociatedObject` for per-object state.
- Call `DH_ORIG` in the method body or in a block written inside it (there `__PRETTY_FUNCTION__` is
  `__NN-[MYT_CSGlassHook sel]_block_invoke`, which DynjectHook also understands). It can't be used in a helper C
  function, which has no `self` or `_cmd` and whose name says nothing about the hook class.
- **Objective-C++: prefer a block to a C++ lambda.** A lambda compiles (`self` and `_cmd` are captured), but its
  `__PRETTY_FUNCTION__` has no `-[Class selector]` in it. DynjectHook recognises the name clang gives a lambda written
  directly in a method of the hook class's main `@implementation`
  (`auto MYT_CSGlassHook::sel::(anonymous class)::operator()() const`), but not a lambda in a category method (clang
  names the category there, not the class), and other compilers may spell it differently. To be independent of that,
  fetch the original in the method body and capture it:
  `IMP orig = DHOriginalForSource(__PRETTY_FUNCTION__, _cmd, self);`, then cast and call `orig` in the lambda.
- **Don't rename a hook class with `__attribute__((objc_runtime_name("…")))`.** `__PRETTY_FUNCTION__` carries the
  source-level name while the runtime knows the class by the other one, so `DH_ORIG` can't find the hook class. Make
  the name unique in the source instead (`TSFX_NSWindowHook`).
- A hook class can't hook `dealloc` (see above).
- If the hook class defines the same selector twice (in the class and in a category), only one is installed: the one
  the runtime itself would call, normally the category's.

## Groups

A group is a switch that controls a set of hooks at once. Use one per setting or feature.

```objc
DHGroup *g = DHGroupCreate("corners");     // never freed
DHGroupSetEnabled(g, NO);
BOOL on = DHGroupIsEnabled(g);
```

A new group starts enabled. A `NULL` group means ungrouped, which is always enabled. A hook created while its group
is disabled is registered but isn't installed until the group is enabled. Setting a group to the state it's already
in does nothing.

**What disable actually does.** DynjectHook processes the group's hooks in reverse install order. For each one:

- **If the method's current IMP is still this hook's replacement** (nobody hooked on top), DynjectHook removes the hook.
  For an own method, it puts the saved original back. For an inherited method, it sets the added method's IMP to the superclass's
  implementation as of disable time. The class then behaves as it would without the hook.
- **Otherwise** (another hook was installed on top), removing the hook would break the other hook's chain, so it stays
  installed and is only **marked inactive**.

`DHHookIsActive` returns `NO` for every hook of a disabled group, whether or not that hook was removed. A replacement
that is still installed keeps running, so **every hook body must pass straight through to the original when its group is off**:

```objc
- (void)setCornerRadius:(CGFloat)r {
    if (!DHGroupIsEnabled(gCorners)) { DH_ORIG(void (*)(id, SEL, CGFloat), r); return; }
    DH_ORIG(void (*)(id, SEL, CGFloat), 12.0);
}
```

(With a `DHHook` handle, check `DHHookIsActive(h)` instead.)

**Re-enable** reverses this, walking the hooks in install order. If the current IMP is still the one DynjectHook
restored, the replacement goes back in, and in every case the hook is marked active.

**Several groups on one method.** Two settings may each hook the same method through their own group. DynjectHook
knows all the hooks your tweak has on a method, so the groups can be switched in any order: an enabled group's hook
runs, and the hooks keep their install order (the later one outermost).

- If the hooks *beneath* a disabled hook were disabled or enabled meanwhile, it goes back on top of whatever your
  tweak left there, and that becomes its original.
- If hooks of your tweak were installed or enabled *above* it meanwhile, it goes back into the chain directly beneath
  them.
- A class that only inherited the method keeps counting as "only inherits" while all hooks on it are off: a hook you
  add to it then still gets the dynamic superclass lookup as its original.

Two edge cases remain, and both follow from "only touch what we still own":

- The method DynjectHook added for an inherited-method hook can't be removed again, so while its hooks are disabled it
  holds a copy of the superclass implementation. Your copy of DynjectHook keeps that copy current whenever it changes
  an implementation itself (another of your hooks on the superclass being installed, enabled or disabled). A hook that
  a different tweak or library puts on the superclass during that window is not seen through this class until you
  re-enable.
- If code **outside your tweak** changes the method while your group is disabled and restored (another library hooks
  it, or another tweak removes a hook of its own that was beneath yours), DynjectHook can't tell what is safe to
  build on, so re-enabling leaves your hook out: it is reported as active, but its replacement doesn't run for that
  method (DynjectHook logs this). Switching the group off and on again installs it once the method is back to what
  DynjectHook restored.

Switching a group changes method implementations, and each change makes the Objective-C runtime flush method caches.
Do it in response to a setting or a user action, not on a hot path.

## Finding classes

```objc
Class a = DHClass("NSWindow");                                  // objc_getClass; NULL if absent
Class b = DHSwiftClass("Calculator", "MainWindowController");   // top-level Swift class
Class c = DHFindClassWithSuffix(NULL, "22CalculatorNSButtonCell");
DHWhenClassLoads("CSGlassView", ^(Class cls) { DHHookClass([MYT_CSGlassHook class], cls, NULL); });
```

- **`DHSwiftClass(module, name)`** tries `Module.Name`, then the mangled form `_TtC` + length + module + length + name
  (`_TtC10Calculator20MainWindowController`). It handles top-level classes only.
- **`DHFindClassWithSuffix(imagePath, suffix)`** scans the classes of one image (`NULL` = the main executable;
  otherwise the path as dyld reports it) and returns the first class whose name ends with `suffix`. Use it for Swift
  `private`/`fileprivate` classes, whose names contain a per-file discriminator
  (`_TtC10CalculatorP33_…22CalculatorNSButtonCell`). Include the length prefix (`22CalculatorNSButtonCell`) so the
  suffix can't also match a longer name such as `MyCalculatorNSButtonCell`.
- **`DHWhenClassLoads(name, block)`** runs `block` exactly once. If the class already exists, it runs immediately.
  Otherwise it runs when an image containing the class is loaded (checked from a dyld add-image callback, with a
  follow-up check on the main queue if the class isn't resolvable yet), or when you call `DHCheckPendingClasses()`. Use
  it for classes in bundles or plug-ins the app loads later. Don't assume the block runs on the main thread. The block may
  install hooks, because the registry is thread-safe; other threads may already be calling the class's methods by
  then, so install with `DHHookClass` or `DHHookMessageEx`, not with `handle = DHHookMessage(…)`. An exception the
  block raises is logged, not propagated. dyld
  usually reports an image before the runtime has registered its classes, so in practice the main-queue check delivers
  the block: a process that never runs its main queue has to call `DHCheckPendingClasses()` itself.

## Entry point and load policy: `DH_CTOR`

```objc
DH_CTOR("com.you.tweak", "com.apple.calculator", "com.apple.TextEdit") { ... }   // only these apps
DH_CTOR("com.you.tweak") { ... }                                                  // any app it's injected into
```

`DH_CTOR` generates an `__attribute__((constructor))` function that:

1. calls `DHSetLogSubsystem(TWEAK_ID)` so `DHLog` and DynjectHook's own messages use your tweak ID;
2. asks `DHShouldLoad(TWEAK_ID, bundleIDs)`, and returns without running the body if the answer is NO (it logs why);
3. runs your body inside `@try/@catch`. An exception is logged with its name and reason and is never rethrown.

The body runs while dyld loads your dylib, before the app's `main`. Install hooks there, and defer UI work (for example with
`dispatch_async(dispatch_get_main_queue(), …)`). Use one `DH_CTOR` per tweak.

`DHShouldLoad` (also callable directly) returns NO for a `NULL` or empty tweak ID, and in these cases:

- **Bundle filter.** A bundle-ID list was given and the app's `CFBundleIdentifier` isn't in it. This filter runs inside the
  processes Dynject has already injected; `dynjectd.conf` still decides which apps load the dylib at all.
- **Safe Mode.** The user's global preferences (`kCFPreferencesAnyApplication`, current user, any host) contain
  `dynject.safemode`: a dictionary that maps tweak IDs to arrays of bundle IDs. If the array for your tweak ID contains
  the current bundle ID or `"*"`, the tweak is skipped. The tweak-ID key `"*"` is the panic switch: its array applies
  to every tweak, so `"*" = ("*")` skips every DynjectHook tweak in every app, and `"*" = ("com.apple.calculator")`
  skips all of them in Calculator only. DynjectHook synchronizes the domain before reading it. Values of the wrong type
  are ignored (a malformed entry for your tweak doesn't hide a valid `"*"` entry, or the other way round). The domain is
  readable from sandboxed apps.

  Change the key with `dw safemode` or Workbench's Safe Mode page rather than `defaults`. They read, change and
  write back only the entry concerned (under the same lock as the crash watcher), post `dynject.safemode.changed`,
  and record why, since when and the re-enable time, so crashes from before a re-enable stop counting:

  ```sh
  dw safemode disable com.you.tweak com.apple.calculator   # one app
  dw safemode enable  com.you.tweak com.apple.calculator   # re-enable
  dw safemode panic on                                     # panic: no DynjectHook tweak loads anywhere
  dw safemode panic off                                    # per-app entries are kept
  dw safemode status
  ```

  `defaults write -g dynject.safemode '{ ... }'` with a literal dictionary **replaces every Safe Mode entry**,
  including the ones the watcher added after crashes, and `defaults delete -g dynject.safemode` removes them all.
  If you must use `defaults`, add one entry with `defaults write -g dynject.safemode -dict-add '*' '("*")'`.

  Builds of DynjectHook that know the `"*"` entry carry the string `dynject.safemode:all-tweaks`, which is how
  Safe Mode tells them from older builds that ignore the panic switch.

  Only tweaks built on DynjectHook (or that read the key themselves) honour Safe Mode. A dylib that doesn't is still
  loaded wherever `dynjectd.conf` says; turn it off there. The setting takes effect at the next launch of the app.

- **Shift bypass.** Shift is held down when the tweak loads. Hold Shift while launching an app to start it without any
  DynjectHook tweaks, which helps if a tweak crashes the app at launch. Set the environment variable
  `DH_DISABLE_SHIFT_BYPASS` (any value) to turn this check off.

### macOS version guard: `DH_REQUIRE_SYSTEM`

```objc
DH_CTOR("com.you.tweak", "com.apple.finder") {
    DH_REQUIRE_SYSTEM("27.0");   // the manifest's minimumSystemVersion
    ...
}
```

At the top of a `DH_CTOR` body it returns from the body, logging "requires macOS 27.0 or later, this is …: not
loading", when the running macOS is older. Installs already refuse a tweak below its manifest's
`minimumSystemVersion` ([tweak-format.md](tweak-format.md#versions-and-dependencies)), but a sandboxed tweak can't read
its manifest, and a copied dylib or a macOS downgrade never sees that check. `DHSystemVersionAtLeast("27.2")` is the
same test as a function. Versions are "27", "27.0" or "27.2.1"; anything else is logged and counts as too old. An app
linked against a macOS 10.15 or older SDK is told "10.16"; that counts as unknown and the guard lets the tweak load.

### SDK version

`DH_SDK_VERSION` is this copy's version (Workbench's). DynjectHook.m puts `dynject.sdk:<version>` into every dylib it is
compiled into; `dw tweak list`, Workbench's tweak page and `dw doctor` read it and suggest a rebuild when it is older
than theirs, or missing (a build from before the marker).

Test-only overrides: `DHSetPreferencesDomainForTesting(CFStringRef)`, `DHSetBundleIdentifierForTesting(const char *)`
and `DHSetSystemVersionForTesting(const char *)`. Passing `NULL` restores the defaults. Don't call them in shipping
tweaks.

## Logging

`DHLog(@"format %@", arg)` takes an NSString-style format (an `@"…"` literal) and logs with `os_log` at the default
level, as `%{public}@`, under the current subsystem and the category `hook`. The subsystem defaults to `dynject.hook`.
`DH_CTOR` sets it to your tweak ID, and you can also set it with `DHSetLogSubsystem` (`NULL` restores the default).

## Several tweaks in one process

Each tweak compiles its own copy of DynjectHook, so the copies must not interfere with each other:

- **Hidden symbols.** Every DynjectHook function and global is `__attribute__((visibility("hidden")))`. Each tweak has
  its own registry, and two copies never interpose. Hooks from different tweaks interact only by stacking (see
  [Chaining](#chaining)). Consider building your own code with `-fvisibility=hidden` as well.
- **One shared lock.** Installing, disabling and enabling a hook each read a method's implementation and then write
  it. So that two tweaks doing this to the same method on different threads can't overwrite each other's
  replacement, all copies in a process take one common lock around it. They find it without sharing a symbol: it is
  published as an associated object of the `NSObject` class under the selector `dynject.hook.process-lock.v1`.
- **Groups see only their own tweak.** A group's disable and enable follow what *that* copy did to a method. If tweak
  A's hook is beneath tweak B's, and B's group is switched off, then A's, then B's on again, B's hook stays out (the
  method is no longer what B restored; B logs this) until B's group is switched off and on while A's hook is back.
  Last-off-first-on order across tweaks always works.
- **No Objective-C classes in DynjectHook.** The Objective-C runtime has a single flat class namespace. For the same reason,
  **prefix your hook classes** with something unique to your tweak (`TSFX_NSWindowHook`, not `NSWindowHook`). If two dylibs define the same
  class name, the runtime uses one of them and logs a "Class X is implemented in both…" warning.
- **One `DH_CTOR` per tweak** and **one target per hook class**.

## Tests

The library's tests are the `DynjectHookTests` target (Objective-C XCTest, with Swift fixtures in
`DynjectHookSwiftFixtures`). Because every symbol is hidden, the test bundle compiles its own copy of `DynjectHook.m`
(`Tests/DynjectHookTests/DHTLibrary.m`), the same way a tweak does. A second copy with prefixed symbols
(`DHTSecondCopy.m`) plays a second tweak in the same process. One test compiles a small dylib with `xcrun clang` and
loads it, to exercise `DHWhenClassLoads` through dyld; it is skipped if no compiler is available.

```sh
swift test --filter DynjectHookTests   # the DynjectHook tests only
swift test                             # everything
```

## Limits

- **Objective-C methods only.** DynjectHook can't hook C functions or Swift functions (there is no `MSHookFunction` / `%hookf`
  equivalent). The hardened runtime and code signing block inline patching of executable pages. Chained fixups and the dyld
  shared cache, whose calls between system libraries are bound directly, make symbol rebinding (fishhook-style) unreliable.
- **Swift methods** can be hooked only when they are reached through `objc_msgSend`: `@objc` methods called from
  Objective-C (for example AppKit calling an `@objc override`), or `@objc dynamic` methods. Swift-to-Swift calls use the
  vtable or direct dispatch and bypass the hook.
- **No unhooking.** Hooks and groups live for the life of the process. Use a group to turn hooks off.
- **Hook classes only replace methods.** To add new methods or per-object state, use `class_addMethod` and associated objects.

## From Logos / Substrate / ZKSwizzle

| Logos / Substrate / ZKSwizzle | DynjectHook |
| --- | --- |
| `%hook Target … %end` | Hook class `PFX_TargetHook` + `DHHookClass([PFX_TargetHook class], DHClass("Target"), group)` |
| `%orig` / `%orig(args)` | `DH_ORIG(ret (*)(id, SEL, …), args)`. Arguments are always explicit. |
| `ZKOrig(type, args)` / `ZKSwizzle(src, target)` | `DH_ORIG(type, args)` / `DHHookClass(src, target, group)` |
| `MSHookMessageEx(cls, sel, imp, &orig)` | `h = DHHookMessage(cls, sel, imp, group)` in `DH_CTOR`, or `DHHookMessageEx(cls, sel, imp, group, &h)` once the app is running (like `&orig`, `h` is written before the hook goes live). Then `DH_CALL_ORIG(h, type, self, _cmd, …)`. |
| `+` method in `%hook` | `+` method in the hook class (installed on the metaclass) |
| `%c(Name)` / `objc_getClass` | `DHClass("Name")`, `DHSwiftClass`, `DHFindClassWithSuffix` |
| `%init(Target = expr)` | Pass any `Class` as the `DHHookClass` target |
| `%group G` / `%init(G)` | `g = DHGroupCreate("G"); DHGroupSetEnabled(g, NO);` before installing the group's hooks, then `DHGroupSetEnabled(g, YES)` where Logos calls `%init(G)`. A new group starts **enabled**, so without the `NO` its hooks are live as soon as they are installed and the later `YES` does nothing. For `if (cond) %init(G);` you can also just write `DHGroupSetEnabled(g, cond)` before installing. Groups can also be turned off at run time. |
| `%ctor` + filter plist | `DH_CTOR("tweak.id", "bundle.id", …)` (plus `dynjectd.conf` for injection) |
| Substrate safe mode | `dynject.safemode` key and the Shift bypass |
| `%new` | Not supported; use `class_addMethod` |
| `%property` | `objc_setAssociatedObject` |
| `%hookf` / `MSHookFunction` | Not supported (see [Limits](#limits)) |
| `%log` / `NSLog` | `DHLog(@"…")` |
