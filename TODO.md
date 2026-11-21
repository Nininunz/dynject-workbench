todo
====

- packages: dylib + manifest + version in one file, .deb-like, with install/upgrade/remove.
- a repo/source format to list and fetch packages.
- signed and notarized builds.
- restrict `url:` menu actions to a scheme allowlist.
- a `toggle:` menu action handled by the safe mode agent, so a menu item can flip a setting
  from sandboxed apps.
- a dynject menu bar extra (status, panic switch, respring).
- tweaks for Dock and ControlCenter, and restarting them in respring.
- `dw diagnose`: bundle logs, config, state.json and crash reports for bug reports.
- reinstall the safe mode watcher automatically when workbench is updated.
- test on intel.
- more `dw new` templates (no hooks, hooks only, menu-only, settings-heavy).
- settings presets (export/import), image settings, suggested injection targets in the
  manifest (see docs/tweak-format.md#not-in-version-1).
