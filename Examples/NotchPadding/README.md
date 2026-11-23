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

`./build.sh sweep [paddings…]` checks the real menu bar (live: needs the tweak installed). it builds the demo and
`demo/Sweep.swift`, which drives the demo through a notification: 0 to 20 status items with 3 menus, then 0 to 24 menus
with 14 items, at each padding (default 0 20 40). after each step it reads MenuBarAgent's frames with
`dw inspect MenuBarAgent --tree` and fails if a menu, a shown status item or the « is drawn inside the notch widened by
the padding. it also says what's under Clerestory's notch window, when that's on screen. the demo comes to the front
while it runs; at the end the setting is put back.

seen (macOS 27.2, 14" notch at 918–1138, Clerestory's window 878–1178): 138 steps, none inside the padded notch.
MenuBarAgent keeps its own 20 points from the notch: menus that move past it start 20 points after it, and nothing
came closer than 20 on either side. so with padding 0 menus ended up under Clerestory (12 steps); with 20 or 40,
nothing did. status items never went left of the notch.

`requires` in the manifest lists `-[NSScreen _notchFrame]` and `-_notchFrameForSpace:`, so `dw doctor --apis` says so
after a macOS update that removes them.
