inspector
=========

an in-app inspector for macOS apps, in the spirit of FLEX. point at a view or a core
animation layer in any app it's injected into and see what it is: class, image,
superclass chain, view/layer hierarchy, properties, methods with readable signatures,
ivars, and every class loaded in the process. copy a DynjectHook skeleton for any
method. read-only.

tweak id `local.dynject.inspector`, dylib `/opt/dynject/lib/tweaks/libInspector.dylib`,
logs under that id. no `DH_CTOR` bundle filter: the config decides which apps get it,
so enable it only for the apps you want to look inside. it hooks nothing.

built with dynject-workbench's sdk: free and noncommercial; don't sell tweaks built with it.

![inspector](../../docs/screenshots/inspector-panel.png)


enable for an app
-----------------

    Tweaks/Inspector/build.sh
    dw tweak install Tweaks/Inspector --for com.apple.TextEdit     # --dry-run first if you like
    dw respring                                                    # or quit and reopen the app

more apps later: `dw enable /opt/dynject/lib/tweaks/libInspector.dylib <bundleID>`, or
workbench's apps & injection page. off again: `dw disable ...` for one app,
`dw tweak uninstall local.dynject.inspector` for all.


use
---

- hold ⌃⌥⌘ while the app is frontmost: pick mode. the deepest view under the pointer
  is outlined and labelled (class, frame in window coordinates, accessibility id and
  role, layer class).
- L (keep holding, or in toggle mode just press it): layer mode. every visible core
  animation layer under the pointer in the whole window, frontmost first, labelled
  `[n/total]`, class, bounds, cornerRadius. the window's whole tree, not just the view
  under the pointer: what you see often comes from another branch (calculator's key
  glass lives in the keypad's SwiftUI.SDFLayer, not under the key's view).
- tab / shift-tab (layer mode): one layer deeper / back up. in calculator, tab a few
  times on a key to reach its `CASDFElementLayer` (60x48, cornerRadius 24) and the
  keypad's tint `CASDFLayer`s.
  L again: back to views.
- click: inspect it. the panel opens and pick mode ends. the click never reaches the app.
- let go of ⌃⌥⌘ without clicking, or press esc: cancel. ⌃⌥⌘ with another key (an app's
  shortcut) cancels too and the key goes to the app.
- apple menu → tweaks → inspect this app (needs MenuLoader): toggles pick mode in the
  frontmost app without holding keys; esc or a click ends it. it posts
  `local.dynject.inspector.toggle`; only the frontmost app with the tweak acts on it.
- the panel's pick button does the same.

the panel (floating utility window, resizable):

    header        class, pointer, image (framework or dylib) and its path, protocols.
                  superclass chain: click a class to show its properties, methods and
                  ivars ("class context").
    ◀ ▶           back / forward through what you've inspected.
    hierarchy     ancestors and children (superview/subviews, superlayer/sublayers,
                  a layer's delegate and mask, a window's views, a responder chain).
                  click to go there.
    properties    overview: a fixed set of safe getters, read automatically (frame,
                  bounds, alpha, hidden, layer, identifiers, accessibility, window title;
                  for layers position, cornerRadius/curve, opacity, masksToBounds, colors,
                  border, filters, contents class, sublayers, delegate; for CASDF* glass
                  classes their own properties). then every objective-c property of the
                  class chain with its type. click a row to read it. objects in values
                  are links.
    methods       class and instance methods of the class context as
                  `- (void)setCornerRadius:(double)arg1`, with the image each one comes
                  from ("AppKit (not QuartzCore)" = a category or someone's hook).
                  select one, Copy Hook (or right-click).
    ivars         name, type, offset, for the whole chain.
    runtime       search every class in the process by substring; click to open the
                  class without an instance.
    filter        filters the current tab.

copy class name, copy description (`-description`, only when you click it) and copy
hook write to the clipboard.

copy hook gives you a hook class for DynjectHook with the exact types from the type
encoding:

    // -[CALayer setCornerRadius:]   QuartzCore   encoding v24@0:8d16
    @interface MYCALayerHook : NSObject @end
    @implementation MYCALayerHook
    - (void)setCornerRadius:(double)arg1 {
        DH_ORIG(void (*)(id, SEL, double), arg1);
    }
    @end
    // in your DH_CTOR body:
    //   DHHookClass([MYCALayerHook class], DHClass("CALayer"), NULL);

structs by value (CGRect, NSRange, CATransform3D, ...) by name, unknown structs as a
typedef with the same layout, `ns_returns_retained` / `ns_consumed` for alloc, new,
copy and init methods (docs/hooking.md), the target's nearest public superclass as the
hook's superclass so `self.frame` compiles. unions, bitfields, C arrays, structs
without a layout, `-dealloc`, retain/release and methods that look variadic (`...Format:`,
`...WithObjects:`) get a comment saying why instead. rename `MY` to your prefix. needs
`#import <QuartzCore/QuartzCore.h>` for CA types.


settings
--------

    enabled          on    off: no pick mode, the panel closes, the menu item does nothing
    hotkeyEnabled    on    off: only the apple-menu item / pick button start picking

both per app, both live.


safety
------

- read-only. nothing is set. the overview only calls getters known to be cheap and
  side-effect free on NSView, CALayer and NSWindow; any other property is read only
  when you click its row: one getter call (KVC for numbers and structs, a typed call for
  objects and pointers), on the main thread, in `@try` catching objective-c and c++
  exceptions. values are described without calling `-description` on arbitrary
  objects (strings, numbers, geometry, collections by count, colors; everything else
  as `<Class 0x...>`).
- ivars are listed, never read.
- events: a local event monitor only (events this app already gets). no global
  monitor, no event tap, no accessibility api. while picking it swallows the click
  that selects, right clicks, L, tab (in layer mode) and esc; everything else passes through.
- the overlay is a borderless, transparent panel over the hovered window. it ignores
  the mouse, can't become key or main, and is ordered out when picking ends or the
  app goes to the background. the inspector panel is the only window that takes focus.
- the class list is collected on a background queue once (class names per image,
  without realizing every class).
- sandboxed apps: works; it only reads its settings and writes the clipboard, both
  allowed in the sandbox.
- nothing runs at load except scheduling setup on the main queue.


build
-----

    ./build.sh          build/libInspector.dylib (x86_64 arm64 arm64e, no exports)
    SIGN_IDENTITY="Apple Development: …" ./build.sh
    ./build.sh test     offline test, no dynject, no real apps (below)


test
----

`./build.sh test` builds a test copy (`-DDYI_TEST`: an in-process test channel that
needs `DYI_TEST=1`, a private pasteboard instead of the clipboard, and its own toggle
notification `local.dynject.inspector.test.toggle`), and a test host app
(`local.dynject.inspector.testhost`, ad-hoc, not hardened) with nested views, a
button, a table and a swiftui view (shapes and a liquid glass capsule) in an
NSHostingView. it runs the host with `DYLD_INSERT_LIBRARIES`. the host posts real
events (⌃⌥⌘ flagsChanged, L, esc, a click) and drives the rest through the test
channel: the class picked at several points (a swiftui shape layer and a glass layer
included), overlay focus rules, the panel's header, chain, hierarchy and overview,
a counting getter that must not be read until clicked, getters that raise objective-c
and c++ exceptions, back/forward, the runtime search and the class view. every hook
skeleton it copies is compiled against `DynjectHook.h` with `-Wall -Werror` under arc.
screenshots (`screencapture -l`) of the overlay (composited over the window) and the
panel: `<repo>/.build/inspector-test/*.png` (`DYI_TEST_DIR` to change). the windows show
on screen for about ten seconds.


limits
------

- objective-c only: swift properties and methods that aren't `@objc` don't show up;
  swift class names are shown mangled.
- the hierarchy is AppKit's and Core Animation's. swiftui views have no objects to
  inspect; their layers do.
- the deepest view is found by walking subviews (hidden and transparent views skipped,
  clipping respected), not with `-hitTest:`, so labels and other views that refuse
  clicks can be picked too.
- layer mode follows layer geometry (bounds, sublayers, masksToBounds); it doesn't
  account for transforms with perspective or for layers rendered in another process.
- variadic methods are recognized by name only; a method that takes a format string
  without being variadic gets the comment too.
- holding ⌃⌥⌘ takes over L and clicks while held. apps with ⌃⌥⌘L or ⌃⌥⌘-click
  lose them: turn off `hotkeyEnabled` for those apps.
- the inspected objects stay alive while they're in the panel's history (cleared when
  the panel closes).
- tested in the test host above on macOS 27 (arm64), not yet in real apps. the x86_64
  slice is built but has never run.
