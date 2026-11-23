changelog
=========

newest first. for testers; the commit log has the details.


unreleased
----------

- `dw respring --system`: also restarts macOS's UI agents tweaks go into (the Dock, Control Center,
  MenuBarAgent, SystemUIServer, Notification Center), or name one with `--only`. they're sent
  SIGTERM and launchd starts them again; respring never opens them (that would make a second copy)
  and checks the new process's tweaks like any app's. bundle IDs after `--only`/`--include` match
  in any case.


0.1.5 (2026-11-23)
------------------

- crashes in tweaks name the source line and the hook: Safe Mode, `dw doctor` and Workbench show
  `libX.dylib: CHExplode (ch.m:11), under its hook of -[CHTarget value]`. builds use `-g`
  (every bundled build.sh and `dw new`'s template), `dw tweak install` keeps each build's dSYM
  (`~/Library/Application Support/Dynject Workbench/Symbols`, the newest 10 per dylib), and Safe
  Mode looks the line up with `atos` when the report lacks it. DynjectHook logs which method each
  hook replacement stands for (`dynject.hooks:map`), so tweaks need a rebuild for the hook part.
- `dw safemode explain <report.ips>`: what Safe Mode makes of one crash report.
- `dw eval <app> <path>`: reads a value in a running app through Inspector, background apps too
  (`dw eval MenuBarAgent NSScreen.mainScreen.frame`). reads only: each step is a declared property,
  an index, a dictionary key or @count/@keys/@class, never another method. the answer is logged at
  debug level, so app data stays out of the log store. reinstall Inspector to use it.
- `dw respring` and Workbench's Respring also relaunch menu bar apps (TokenTracker, Alfred…), which
  it didn't see before; macOS's own (ControlCenter, MenuBarAgent) and helper apps inside other apps
  are still left alone.


0.1.4 (2026-11-23)
------------------

- examples/NotchPadding: keeps the menu bar's contents a set distance from the notch (40 points
  each side by default, live setting). it loads into MenuBarAgent, which lays out the whole menu
  bar around `-[NSScreen _notchFrame]`, and widens that notch: app menus that don't fit move past
  it, status icons that don't fit go into the «. `./build.sh demo` crowds the menu bar to show it;
  `./build.sh sweep` steps that demo through icon and menu counts at several paddings and checks
  MenuBarAgent's own frames (`dw inspect --tree`) never enter the padded notch.
- `dw tweak install --for` / `dw enable` for an app launchd starts under its own label (MenuBarAgent:
  `com.apple.MenuBarAgent`) add `allow:<executable>` so dynjectd's xpc filter lets it through, and
  `dw why` knows the labels of MenuBarAgent and ControlCenter.
- `dw why` finds background apps (ControlCenter, menu bar apps) among the running ones.
- `dw inspect <app>`: drives Inspector in a running app from the terminal, including background
  apps (ControlCenter, the Dock) the hotkey can't reach: open the panel on the app (its windows,
  menu bar), `--pick`, `--stop`, and `--tree` to print its windows and views without ui: status
  items by autosave name and the window each shows, FrontBoard scenes and their settings (where
  ControlCenter draws its menu bar items), accessibility identifiers and labels. `--props` adds
  every property the windows' own classes declare. KVO's hidden subclasses, Swift classes'
  included, show as the class they observe. reinstall Inspector to use it.
- inspector: menus. inspect the menu bar and walk its items and submenus, or pick any menu item
  (menu bar, context menu, or its shortcut) and it opens instead of running. for an item: its
  shortcut, action, target, where the action goes now (`sent to`: its target, or what the
  responder chain resolves), and the method that `runs`, which opens that class's methods or
  traces it. picking hooks `sendAction:to:from:` only while picking.


0.1.3 (2026-11-21)
------------------

- `dw hooks <app>`: what the tweaks in a running app have hooked, per tweak: each method hook's
  state (installed, buried beneath another, restored by a group, pending), whether it's on top,
  its group, and import hooks with their call sites. warns when two tweaks hook one method; lists
  loaded tweak dylibs that didn't answer and why. `--scan` adds methods of other images' classes
  implemented in tweak dylibs (hooks made without DynjectHook). DynjectHook answers a darwin
  notification for its pid by logging the list (`dynject.hooks`), so tweaks need a rebuild.
- `dw dev [folder] [--for <bundleID>]`: the tweak loop. builds, runs the test host, installs
  (skipped when the dylib didn't change), relaunches the apps its `DH_CTOR` lists (or `--for`),
  and shows its log; then watches the folder and does it again on every save. a failed build or
  test installs nothing and shows the errors or the failed checks. `--once` for one round.
- inspector: method tracer. select a method, press trace: every call is logged with receiver,
  arguments, return value, duration and thread (`dw log local.dynject.inspector`), nested
  calls indented, exceptions logged and passed on, 40 lines per method per second. trace all
  methods of a class, stop all, optional backtraces. built on message forwarding and
  DynjectHook groups, so stopping restores the method.


0.1.2 (2026-11-21)
------------------

- `dw why <tweak> <app>`: why a tweak does or doesn't load into an app. every check in the order
  it happens (dynjectd, the config's service and process gates and dylib rule, dyld's
  architecture and signature, the tweak's target apps, safe mode, its macos minimum), then the
  running app and the tweak's last log line about it. names the first check that stops it and
  the command that fixes it; read-only. `--json`, `--no-log`, `--minutes N`.
- `dw new` makes a test host too: `./build.sh test` builds a test copy of the tweak (its own
  tweak id, so the test never touches your settings) and `testhost/`, a small accessory app that
  checks what the tweak does with it injected, natively and under rosetta. `scripts/test-all.sh`
  runs a generated one (`template-host`).
- DynjectHook: `DHHookImport` hooks c and swift functions by rewriting the import pointers of the
  app's executable, its frameworks and later-loaded images (signed `__auth_got` entries on arm64e).
  groups, chaining with other tweaks, `DH_CALL_IMPORT_ORIG`. calls inside the shared cache and
  inside one image aren't reached. `Tests/ImportHost` runs it in arm64e, arm64 and x86_64 processes.
  third-party apps only: a live check in calculator showed macos keeps the imports of its own apps
  read-only after launch (`KERN_PROTECTION_FAILURE`); that's logged, nothing is patched there.
- `DH_CTOR` compiles in its tweak id and target apps (`dynject.ctor:` marker) so `dw why` can
  read them. rebuild tweaks to get it; older builds show the targets as unknown.


0.1.1 (2026-11-20)
------------------

- `scripts/test-all.sh`: every test that leaves the live system alone, one summary. unit
  tests, the app, each bundled tweak's build and test host, and a fresh `dw new` tweak taken
  through build, install, list and uninstall in a fake root. `--quick`, `--all` (adds the e2e
  scripts and the ui smoke test), `--stop`.
- `dw tweak uninstall` (and workbench's uninstall): an `allow:<executable>` rule that only let the
  tweak's apps through goes with it, so install then uninstall leaves the config as it was.
  `--keep-rules` keeps it; a rule other tweaks still reach an app through stays, and the plan names
  them; rules that change nothing are left alone.
- `tools/bench/launch`: times an app's launch with no tweaks, each installed tweak alone and all of them,
  without touching the config. result: no measurable cost to the first window; the ~23 ms they add
  before main() is the shift-key check opening the window server connection appkit opens anyway.
- `dw doctor`: one line per crash, naming the tweak it happened in apart from the ones that were only
  loaded; a deleted report isn't offered as the fix.
- safe mode passed a live crash test (docs/safe-mode.md#live-test): crash in a tweak, disabled at
  once in that app only, skipped on relaunch, re-enable, panic switch.
- ci: github actions runs `scripts/test-all.sh` on every push to main and every pull
  request (macos 27, xcode 27). the `--all` extras stay local.
- `dw doctor`: a read-only health check. engine binaries and launchdaemon, one dynjectd
  running, recent log errors, sip, config diagnostics, every dylib (arm64e, signature),
  manifests, safe mode support, each tweak's macos range, depends, version format and the
  dynjecthook it was built with, the watcher and bridge agents (running, stale dw copy,
  token), the apple-menu list, apps out of date, safe mode entries and crashes, the
  workbench version. `✓ ! ✗`, a fix under each problem, `--json`, `--quiet`, exit 1 on ✗.
- `dw doctor --apis`: after a macos update, checks the private classes, methods, functions
  and strings each installed tweak declares in its manifest's new `requires` key, plus the
  bridge's spi. MenuLoader and OLEDFinder declare theirs. docs/tweak-format.md#requirements.
- bridge: tweaks in sandboxed apps can ask a background agent (`dw bridge serve`,
  workbench -> bridge) to set their own settings, post their own notifications, open
  declared kinds of links or write the clipboard. declared per tweak in the manifest
  (`bridge`), allowed only inside apps the config injects the tweak into, rate-limited
  and logged. sdk: `DynjectBridge.h`. docs/bridge.md.
- Inspector: a flex-style in-app inspector tweak. hold ⌃⌥⌘ in an app it's enabled for,
  point at a view (L: a layer, swiftui and liquid glass layers included), click: class,
  image, superclass chain, hierarchy, safe properties (others on click), methods with
  readable signatures, ivars, a runtime class search. copy hook writes a DynjectHook
  skeleton with exact types. read-only. Tweaks/Inspector.
- tweak versions: manifests' `version` is semver now (others get a warning). install
  says "installed X → new Y", lets upgrades and rebuilds through and refuses a
  downgrade unless you ask (`--allow-downgrade`, a checkbox in workbench).
- macos limits: `minimumSystemVersion` (install refuses below it, `--force`),
  `testedSystemVersions` (warns outside it). `DH_REQUIRE_SYSTEM("27.0")` checks the
  same at load time. MenuLoader, Inspector and OLEDFinder need 27.0, tested on 27.2.
- `depends`: other tweaks (with a minimum version), the bridge or the safe mode
  watcher. install refuses while one is missing and says what to run; uninstall
  refuses to pull one out from under another tweak (`--force`).
- the sdk stamps its version into every dylib (`DH_SDK_VERSION`, "dynject.sdk:0.1.0").
  the tweak page and `dw tweak list` show it with the version, macos range and
  dependencies (✓/✗).


0.1.0 (2026-11-19)
------------------

first alpha. build from source with `./scripts/bootstrap.sh`.

- workbench: which apps each dylib applies to and why, per-app switches with minimal
  config edits, raw config editor with diagnostics, plist editor, safe single-daemon
  restart. every protected write is backed up and needs one password.
- tweak settings: manifests (`*.workbench.plist`) give a tweak a native settings page;
  changes apply live, per-app overrides, settings readable from sandboxed apps.
- DynjectHook: objective-c hooking library compiled into tweaks. hook classes with
  `DH_ORIG`, groups that switch hooks off at runtime, `DH_CTOR` with a bundle filter.
- MenuLoader: tweaks declare apple-menu items in their manifest; each chooses its own
  submenu or the shared "tweaks" entry. workbench adds a "dynject" group (respring,
  safe mode, open workbench).
- safe mode: a crash watcher switches a tweak off for the app it crashes, no password.
  panic switch, re-enable, shift-at-launch bypass.
- respring: relaunch running apps whose tweaks are out of date, gracefully, skipping
  anything that won't quit.
- dw: `tweak install/uninstall/list`, `new`, `enable/disable`, `respring`, `safemode`,
  `config apply`, `log`.
- examples: TitleBadge (every kind of setting) and OLEDFinder (pure black finder
  browser windows with the stock glass titlebar, no settings, offline screenshot test:
  `Examples/OLEDFinder/build.sh test`).

see KNOWN-ISSUES.md before you install anything.
