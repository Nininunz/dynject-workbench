changelog
=========

newest first. for testers; the commit log has the details.


unreleased
----------

nothing yet.


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
- examples: TitleBadge.

see KNOWN-ISSUES.md before you install anything.
