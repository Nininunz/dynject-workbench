known issues
============

alpha. this list is honest, not complete.

platform
- only tested on macOS 27 on apple silicon. the package says 14+; nobody has run it there.
- x86_64 slices of the tweaks are built but have never been run.
- MenuLoader relies on the private `_NSAppleMenu` and two of its methods. if a macOS update
  changes them it logs one line and does nothing. since macOS 27 appkit hides menu-item
  images by default; MenuLoader forces them visible for items with a symbol.

safe mode
- only stops tweaks built on DynjectHook (`DH_CTOR`). everything else has to be turned off in
  the config. tweaks built with an older DynjectHook ignore the panic switch until rebuilt.
- it acts after the crash: the tweak stays out from the app's next launch, not the current one.
- a crash only counts as "crash in tweak" when the tweak's frames are near the top of the
  faulting thread. tail-called or deeply nested crashes may only count as "repeated crashes"
  (2 within 10 minutes).
- crashes during a shift launch, or in an app outside a tweak's `DH_CTOR` bundle list, still
  count toward "repeated crashes" for tweaks that were loaded but didn't run.
- the watcher's notifications and the shift bypass have not been verified on a real launch.
- the watcher runs a copy of dw in `~/Library/Application Support/Dynject Workbench/bin/`.
  after updating workbench, reinstall the watcher (safe mode -> reinstall) or it keeps
  running the old one.
- turning the panic switch off isn't dated, so respring doesn't notice it.
- `defaults write -g dynject.safemode '{...}'` replaces every entry. use dw or workbench.

install / uninstall
- the live privileged path of `dw tweak install/uninstall` (and workbench's install tweak...)
  hasn't been exercised on a real system yet. `dw install`, `dw enable` and `dw config apply`
  have. use `--dry-run` first.
- uninstall leaves global `allow:<App>` lines that were added for the tweak.
- uninstall refuses to remove the config's last dylib (dynjectd won't start without one).
- uninstall keeps the tweak's settings key `dynject.tweak.<id>`.

respring
- relaunching finder goes through an apple event, so macos may ask for automation permission.
- apps come back without their windows if "close windows when quitting an application" is on
  in system settings.
- an app that doesn't quit within the timeout (unsaved changes, a dialog) is skipped and not
  reopened, even if it quits later.
- the app hosting the caller is reopened by a detached shell that gives up after the timeout.

menus
- `url:` menu actions accept any scheme, `file://` included. a manifest can make a menu item
  open anything. don't install manifests you don't trust.
- an app's own shortcuts win over apple-menu shortcuts.

workbench
- preference files are cached by cfprefsd; a running app may overwrite a plist edit. quit it
  first.
- openstep-format plists are read-only.
- live settings updates in an app with a stale preferences cache are best-effort; a relaunch
  always picks up the latest values.
- the ui smoke test needs accessibility to expose the window in time and is flaky in some
  environments ("apps-table missing" on the first steps). rerun it.
- smoke-test screenshots don't render vibrancy.

DynjectHook
- objective-c methods only. no C or swift function hooks.
- swift methods only when reached through `objc_msgSend`.
- no unhooking; groups switch hooks off. a group can't fully remove a hook another tweak
  stacked on top of; that hook just goes inactive.
