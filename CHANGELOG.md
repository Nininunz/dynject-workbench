changelog
=========

newest first. for testers; the commit log has the details.


unreleased
----------

- `scripts/test-all.sh`: every test that leaves the live system alone, one summary. unit
  tests, the app, each bundled tweak's build and test host, and a fresh `dw new` tweak taken
  through build, install, list and uninstall in a fake root. `--quick`, `--all` (adds the e2e
  scripts and the ui smoke test), `--stop`.
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
