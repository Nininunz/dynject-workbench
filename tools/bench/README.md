bench
=====

`launch`: what tweaks add to an app's launch.

    tools/bench/launch                  every dylib in /opt/dynject/lib/tweaks: none, each alone, all
    tools/bench/launch a.dylib b.dylib  just these
    tools/bench/launch -n 100           launches per scenario (default 40, plus 3 warm-up)

it builds a minimal appkit app (`launchbench.m`, an accessory app: no dock icon, no focus, its window
off-screen) and runs it straight from the shell, so dynjectd never injects it. each scenario injects its
dylibs with `DYLD_INSERT_LIBRARIES`; the app checks which tweak dylibs actually loaded and the run stops
if that isn't the scenario's set. scenarios run round robin so drift hits them all alike. nothing is
installed or configured; output goes to `.build/bench/`.

two times per launch, both from process start:

- **to main()**: dyld, every initializer, the tweaks' `DH_CTOR` bodies.
- **to first window**: plus NSApplication setup, launch notifications and drawing one window, where hooks
  on appkit show up. this is the one that matters.

results (2026-11-20, macos 27.2.1, apple silicon, 40 launches per scenario, two runs)
-------------------------------------------------------------------------------------

    scenario          to main() median   to first window median   vs none
    none                   4.5 ms              120-129 ms
    libOLEDFinder          5.5 ms              120-130 ms           +0.5 ms
    libMenuLoader         27-28 ms             113-122 ms           -6 to -8 ms
    libInspector          27-28 ms             113-124 ms           -3 to -7 ms
    all three             28-30 ms             113-126 ms           -4 to -7 ms

- **the tweaks don't slow the launch down.** time to first window is the same or a few ms *shorter*
  with them. p90s overlap, so call it no difference.
- **the ~23 ms before main() is the shift-key check**, not the tweaks. `DH_CTOR` reads the keyboard
  state (`CGEventSourceFlagsState`) for the shift-at-launch bypass, and that opens the process's window
  server connection. an appkit app opens that connection on its way to a window anyway, so the time
  moves rather than adds (and starting it early overlaps other work, hence the slightly sooner window).
  it's paid once per process: all three tweaks cost the same as one. a probe dylib whose constructor
  only calls `CGEventSourceFlagsState` shows the same ~20 ms.
- **loading a dylib costs about 1 ms.** OLEDFinder in this app stops at its bundle filter, before the
  shift check: that's dyld mapping, binding and running DynjectHook's checks.
- ruled out with probe dylibs: linking appkit (~0), realizing an appkit class from a constructor (~0),
  reading the safe mode key from cfprefs (~2 ms).

not measured here:

- **dynjectd's own cost per launch** (endpoint security plus the xpcproxy breakpoint). it applies to
  every app launch, injected or not, and needs dynjectd stopped to compare against.
- **processes that never open a window server connection.** there the shift check is a real ~20 ms and a
  connection they wouldn't otherwise make. the default config doesn't inject those (ui apps only,
  `skip_helpers`).
- **real apps.** the tweaks' cost is roughly constant, so it's a smaller share of a heavier app's launch.
- **the apple menu.** MenuLoader's hook runs when the menu bar is built, after launch; this app never shows
  one.
