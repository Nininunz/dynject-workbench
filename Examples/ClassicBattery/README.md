classic battery
===============

the menu bar battery as it looked before macOS 26: the percentage, then a thin-outline battery whose fill shows the
level. a bolt while charging, a plug while it's plugged in but held at a limit, yellow in Low Power Mode, red at 10%
or less on battery. clicking it opens the usual battery menu.

tweak id `local.dynject.classicbattery`, dylib `/opt/dynject/lib/tweaks/libClassicBattery.dylib`. it loads only into
ControlCenter (`com.apple.controlcenter`), which draws the battery item.

built with dynject-workbench's sdk: free and noncommercial; don't sell tweaks built with it.


install
-------

    ./build.sh test                                       # build, and check it in a local test app
    dw tweak install . --for com.apple.controlcenter --also com.apple.controlcenter.PreloginSystemBannerRenderer
    dw respring --only com.apple.controlcenter            # SIGTERM; launchd starts it again at once, with the tweak

`--also`: dynjectd matches service names by substring, so enabling it for ControlCenter also lets it into
ControlCenter's prelogin banner helper. the tweak's DH_CTOR names only ControlCenter, so it stays out of the helper.


settings
--------

in Workbench, or in System Settings → Tweaks with SettingsLoader (Tweaks/SettingsLoader). they apply live.

- **Enabled**: off gives the menu bar macOS's battery back (ControlCenter's own view, unwrapped).
- **Battery**: Classic (the older battery, drawn by the tweak) or Apple's (macOS's battery, with the number before
  it). with Apple's, turn off Control Center's Show Percentage so the number isn't shown twice; with Classic it
  makes no difference, macOS's drawing is hidden.
- **Show percentage**: the number, or the battery alone.
- **Text size**: 9 to 15 points, 12 by default (the menu bar's text is 13; older macOS drew the percentage a little
  smaller).


how it works
------------

everything happens in ControlCenter, with objective-c hooks only. each ControlCenter item in the menu bar is an
`NSHostedViewScene` (AppKit), one per display: AppKit shows the scene's `view`, a SwiftUI `NSHostingView`, in
MenuBarAgent's menu bar, and reports that view's size, which MenuBarAgent lays the menu bar out with.

1. which scenes are the battery. ControlCenter makes an `MBControlCenterItemAssertionXPC` for each of its items
   (`-initWithID:behavior:…:systemIdentifier:accessibilityToken:`, hooked); the battery's has `systemIdentifier`
   "battery", and its `assertionID` is the `controlCenterItemIDRawValue` in the settings of every battery scene. it's
   made before the scenes.
2. the battery scenes' view is replaced by a `DYClassicBatteryView`, with ControlCenter's SwiftUI view inside it:
   invisible, still getting every click, so the menu and the highlight are macOS's own. `-[NSHostedViewScene
   setView:]` is hooked, so the views ControlCenter puts there (at launch, for a new display) are wrapped as they
   come.
3. the wrapper draws the item and is exactly as wide as it, so MenuBarAgent lays it out like any other item
   (57 points for "41%"). when the number's width changes (9% → 10%, 99% → 100%) the wrapper's size changes, the scene
   publishes it, and MenuBarAgent moves the items over (seen live: 60 → 80 → 50 points). with Apple's battery, the
   SwiftUI view stays visible at the wrapper's right end, as wide as it wants to be, and the wrapper draws only the
   number before it. settings changes come with the tweak's notification (`DTPrefObserve`): the wrappers are laid out
   again and resized, or, turned off, ControlCenter's view goes back into the scene.

the level, charging and power come from IOKit power sources, and redraw when they change; Low Power Mode from
`NSProcessInfo`.

the look, measured on macOS 27.2: the number is 12 points by default (the menu bar's text is 13; older macOS drew the
percentage a little smaller); the battery is 25 × 11.5 points plus a 1.5-point nub, 4 points after the number,
centred on the same line as the icons beside it (search, Control Center), with the number centred on the battery;
the ink is 92% white on a dark menu bar and 85% black on a light one, like the clock and the icons.

an earlier version ran in MenuBarAgent: it hid ControlCenter's drawing in the slot, drew over it, and widened the
slot by answering MenuBarAgent's size reads, so the slot was always as wide as "100%" needed. working in ControlCenter
removes all of that.


how it's checked
----------------

`./build.sh test` builds a test copy (its own tweak id; it also loads into the test host and exports
`CBTestSetState`) and runs `testhost/` with it injected. the host draws the item off screen at 2 pixels per point in
each state, dark and light, and checks the pixels: the gap, the battery's proportions, the number centred on it, the
fill against the level (25, 50, 100%), red at 5% on battery and not on power, yellow in Low Power Mode, the bolt and
the plug cut out of the fill, dark ink on a light menu bar; then, through `CBTestSetSettings`, the battery alone
without the percentage, a wider number at 15 points, and Apple's style (the number ending before macOS's battery). it
saves every drawing in `build/test/render/`. it also
checks that what the tweak uses in ControlCenter still exists: `MBControlCenterItemAssertionXPC`'s initializer (and
its type encoding) and `-assertionID`, `NSHostedViewScene` (`-setView:`, `-view`, `-viewHierarchyDidChange`,
`-_FBSScene`) and `NSApplication -connectedScenes`.

`requires` in the manifest lists the same classes and methods, so `dw doctor --apis` says so after a macOS update that
removes them.
