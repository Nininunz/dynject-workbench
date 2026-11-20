live
====

drive and observe a real app with your tweak loaded, from a shell script: find its window,
put the pointer somewhere, press keys, take screenshots, read the tweak's log. for the part
of testing that unit tests and test hosts can't do: the real app, injected by dynject.

    tools/live/live help

the native bits (window lookup, pointer warp, crop) are one swift file, built on first use
into `.build/live/livetool`. everything else is screencapture, osascript (system events),
notifyutil and log.

commands
--------

    live window <app>                    id x y w h of the frontmost window (points, top-left origin)
    live front <app>                     bring the app to the front (steals focus)
    live point <app> <dx> <dy>           pointer to a point inside the app's window
    live key <name|code> [mods]          one key press; names: tab esc return space left right up
                                         down or one character; mods: cmd,opt,ctrl,shift
    live hold <mods> <seconds>           hold modifiers for a while, always released after
    live release                         release stuck modifiers
    live notify <name>                   post a darwin notification (tweak toggles, menu actions)
    live shot <app> <out.png> [pad]      the window's screen region, overlays and labels included
    live window-shot <app> <out.png>     the window alone (no overlays, no menus)
    live burst <dir> [count] [sec]       full-screen captures (menus), display kept awake
    live crop <in> <out> <x> <y> <w> <h> crop in pixels
    live log <subsystem> [seconds]       your tweak's os_log lines

`<app>` is a name ("Calculator") or a bundle id (com.apple.calculator).

example: examples/inspector-calculator.sh drives Inspector's layer mode in calculator and
screenshots each tab step.

things that bite
----------------

- permissions: the process running this (your terminal, or the editor hosting it) needs
  screen recording for screenshots and accessibility for `key`, `hold` and system events.
  macos asks the first time.
- `key x cmd` presses and releases the modifiers around the key. you can't hold ⌃⌥⌘ in one
  call and press a key in the next: the key event releases them. if your tweak has a hold-to-
  activate gesture, give it a notification or menu toggle for scripts (Inspector does).
- `front` steals focus from whatever you're doing. scripts that type should run when you're
  not typing.
- menus aren't windows: `window-shot` and `shot` won't show an open menu. use `burst` and open
  the menu by hand during it, then crop.
- a sleeping display captures as black frames. `burst` keeps the display awake; for longer
  runs wrap your script in `caffeinate -d`.
- screencapture is started without `DYLD_INSERT_LIBRARIES`, so a test that injects with that
  variable doesn't inject screencapture too.
- screenshots of your desktop contain your stuff: other windows, the menu bar, your name in
  "log out …", device names in finder's sidebar. crop before you commit or share one.
- `point` coordinates are relative to the window's top-left in points. screenshots are in
  pixels (2x on retina).

where things go
---------------

reusable driving and capture tools: here. throwaway probes and test tweaks for an
experiment: outside the repo (e.g. a playground folder), installed with `dw tweak install`
and removed with `dw tweak uninstall` when you're done.
