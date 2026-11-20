oled finder
===========

example tweak: finder's browser windows in pure black (#000000), for oled screens.
no settings page; the colours are constants. tweak id `local.dynject.oledfinder`,
loads only in `com.apple.finder` (`DH_CTOR` bundle filter), logs under that id.

built with dynject-workbench's sdk: free and noncommercial; don't sell tweaks built with it.


what it does
------------

in every finder browser window (class `TBrowserWindow`):

- dark appearance (DarkAqua) and a black window background, so text and icons stay
  light even when the system is in light mode.
- translucent backgrounds get an opaque black view at the bottom of their subviews:
  `NSVisualEffectView`s with a background material (window, content, sidebar,
  titlebar, header), liquid glass used as a background (`NSGlassEffectView`, the
  sidebar) and the scroll edge effect under the titlebar and list header
  (`NSScrollPocket`, so rows scrolled under them are still hidden, now by black).
- scroll, clip, table, outline, collection and column views draw black. no row stripes.
  grid lines and split view dividers use the separator colour.
- left alone: selection highlights (selection material), the toolbar's glass buttons,
  menus, popovers, sheets.

how: `-[NSView viewDidMoveToWindow]` is hooked; one class check per view decides
whether it's in a browser window, and only those views are touched, once. the setters
for the same properties (`setBackgroundColor:`, `setBackgroundColors:`,
`setDrawsBackground:`, `setUsesAlternatingRowBackgroundColors:`, `setGridColor:`,
`setMaterial:`, `setAppearance:`, glass `setContentView:`) are hooked so finder can't
put grey back later; outside browser windows they pass straight through. nothing runs
per frame or per draw.

never touched: the desktop (class `TDesktopWindow`, and any window below the normal
window level), get info, quick look, preferences and every other window class. if
finder renames `TBrowserWindow` the tweak logs it and does nothing.


the constants
-------------

top of `OLEDFinder.m`, `0xRRGGBB`:

    kOLEDBackground   0x000000   every background
    kOLEDSeparator    0x1C1C1E   grid lines, split view dividers

edit, rebuild, install again.


build
-----

    ./build.sh          build/libOLEDFinder.dylib (x86_64 arm64 arm64e, no exports)
    SIGN_IDENTITY="Apple Development: …" ./build.sh
    ./build.sh test     offline test, no dynject, finder untouched (below)


install
-------

    dw tweak install Examples/OLEDFinder --for com.apple.finder
    dw respring --include com.apple.finder     # or: dw respring --only com.apple.finder

respring leaves finder out unless you name it. install prints "No usable settings
items." for the manifest; that's expected, there are none.


undo
----

    dw tweak uninstall local.dynject.oledfinder
    dw respring --include com.apple.finder

or keep it installed and switch it off for finder: `dw disable
/opt/dynject/lib/tweaks/libOLEDFinder.dylib com.apple.finder`, or
`dw safemode disable local.dynject.oledfinder com.apple.finder`, then respring.
holding shift while finder launches skips it for that launch.


test
----

`./build.sh test` builds a test copy (`-DOLF_TEST_BUNDLE`, which adds the test host's
bundle id `local.dynject.oledfinder.testhost` to the filter) and `TestHost.m`, an
appkit app that mimics a browser window: a `TBrowserWindow` with a unified toolbar,
a split view whose sidebar is a source-list outline view in an `NSVisualEffectView`
(.sidebar) inside appkit's glass sidebar, a list (`NSTableView`, scrolled under its
header), an icon view (`NSCollectionView`), a column view (`NSBrowser`) and a glass
status pill. beside it a borderless `TDesktopWindow` at desktop level and a
`TInfoWindow`. it runs once without the tweak and once with `DYLD_INSERT_LIBRARIES`,
captures each window (`screencapture -l`, ids from `CGWindowListCopyWindowInfo`) and
samples pixels: backgrounds must be #000000, text bright, the other two windows
unchanged. screenshots: `<repo>/.build/oledfinder-test/{before,after}-*.png`
(`OLF_TEST_DIR` to change). the windows show on screen for a few seconds.


caveats
-------

- tested against the host above on macOS 27, not inside finder: finder's own views
  (`TSidebarView`, `TListView`, `TIconCollectionView`, `TColumnView`, path and
  status bars, tab bar, gallery view) are subclasses of the appkit classes it
  handles, but their exact layout wasn't reproduced. something finder draws itself
  may stay grey.
- the list header keeps its 1 px separator line; the sidebar titlebar edge can show a
  1 px #121212 line.
- sidebar labels are vibrant: on black they're as bright as the stock colours allow,
  not brighter (inactive window: #7A7A7A, like stock contrast).
- a background colour chosen in finder's view options is replaced by black. a
  background picture stays.
- the sidebar's black backdrop takes the glass's `cornerRadius`; if appkit rounds the
  sidebar some other way the black may show square corners.
- quick look previews inside the window (column / gallery preview) are drawn by
  another process and keep their own colours.
- private class names (`TBrowserWindow`, `TDesktopWindow`, `NSScrollPocket`) can change
  with any macos update. check after updating.
