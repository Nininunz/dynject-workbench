notch padding
=============

keeps the menu bar's contents a set distance from the notch: 40 points on each side by default.

tweak id `local.dynject.notchpadding`, dylib `/opt/dynject/lib/tweaks/libNotchPadding.dylib`. it loads only into
MenuBarAgent (`com.apple.MenuBarAgent`), the process that draws and lays out the whole menu bar: the front app's
menus, every app's status items, and the « that collects the items that don't fit. MenuBarAgent places them around
the notch it gets from `-[NSScreen _notchFrame]`; the tweak makes that notch wider by the padding on each side. AppKit
works out `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`, the strips beside the notch, from the same method, so
they follow. on a mac without a notch `_notchFrame` is empty and nothing changes.

what happens with a padding (seen live, macOS 27.2): app menus that no longer fit before the notch move to the right
of it, as macOS does when they overflow; status items that no longer fit after it go into the «. with 40 points and a
menu bar that isn't crowded, nothing moves: it only matters once something would sit close to the notch.

ControlCenter only draws some of the status items (battery, wi-fi, clock…), as scenes MenuBarAgent hosts. widening the
notch there changes nothing; this tweak was first tried there.

built with dynject-workbench's sdk: free and noncommercial; don't sell tweaks built with it.


install
-------

    ./build.sh test                                       # build, and check it in a local test app
    dw tweak install . --for com.apple.MenuBarAgent
    killall MenuBarAgent                                  # launchd starts it again at once, with the tweak

launchd starts MenuBarAgent under its own label, `com.apple.MenuBarAgent`, not as an `application.` service, so
dynjectd lets it through only with an allow rule: `dw tweak install --for` adds `allow:MenuBarAgent`. that rule lets
every allow-by-default tweak into MenuBarAgent; deny the ones that don't belong there
(`dylib-override:<dylib>:deny:com.apple.MenuBarAgent`).

the menu bar disappears for a moment while MenuBarAgent restarts. `dw respring` leaves it alone.


demo
----

    ./build.sh demo

builds `build/NotchDemo.app` from `demo/NotchDemo.m` and opens it. it crowds the menu bar so the padding shows: 14 status items (icons, − / + to
change) fill the right of the notch, and while it's the front app its 14 menus (− / +) fill the left. the padding
buttons (off, 0, 40, 80, 120) write the tweak's setting the way Workbench does; quitting puts your setting back.

with padding 0 the menus run into the notch ("Extras" cut to "Extr", "Options" half hidden past it); with 40 both
sides keep a 40-point gap, the menus that don't fit move past the notch and the status items go into the «.


settings
--------

    enabled    on      off: the real notch
    padding    40      points on each side of the notch, 0 to 200

both live: a change makes MenuBarAgent lay the menu bar out again, no relaunch.


how it's checked
----------------

`./build.sh test` builds a test copy (its own tweak id, so it never reads your settings) and runs `testhost/` with it
injected: the two notch methods are hooked, and with a notch, padding 30 makes it 60 points wider and the strips
beside it 30 shorter each; padding 0 and switched off give the real notch. without a notch everything must stay
empty.

`requires` in the manifest lists `-[NSScreen _notchFrame]` and `-_notchFrameForSpace:`, so `dw doctor --apis` says so
after a macOS update that removes them.
