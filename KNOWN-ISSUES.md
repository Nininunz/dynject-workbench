known issues
============

alpha. this list is honest, not complete.

platform
- injection is inherited by child processes an app spawns (chess's engine helper got it).
  DH_CTOR's bundle filter keeps DynjectHook tweaks out; other tweaks would run there too.
- dynject_loader needs amfid running when it starts dynjectd and fails with "amfid not
  found" if launchd has stopped the idle amfid. the restart helper now starts amfid first;
  a reboot or a restart outside workbench/dw can still hit it (`sudo launchctl kickstart
  system/com.apple.MobileFileIntegrity`, then start dynject again).
- the engine needs SIP relaxed (`--without fs --without debug`). that weakens the whole
  machine, not just injected apps; see README "what you're giving up". macOS updates may
  re-enable SIP or break the engine.
- dynject never injects loginwindow (which draws the lock screen): its per-session instances
  aren't started through the xpcproxy launch dynjectd watches. `dw why` says so.
- Examples/ClassicBattery looks off on external displays (seen, not investigated yet).
- only tested on macOS 27 on apple silicon. the package says 14+; nobody has run it there.
- x86_64 slices of the tweaks are built but have never been run.
- Inspector loads into real apps through dynject, but its picker and panels have only been
  exercised in its own test host (`Tweaks/Inspector/build.sh test`). while ⌃⌥⌘ are held it takes L and clicks, so apps
  with ⌃⌥⌘L or ⌃⌥⌘-click shortcuts lose them (turn off its hotkey for those apps).
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
- the watcher's notifications have not been seen on a real crash yet. the shift bypass was
  verified on a real launch (MenuLoader in AppCleaner, 2026-11-19).
- the watcher runs a copy of dw in `~/Library/Application Support/Dynject Workbench/bin/`.
  after updating workbench, reinstall the watcher (safe mode -> reinstall) or it keeps
  running the old one.
- turning the panic switch off isn't dated, so respring doesn't notice it.
- `defaults write -g dynject.safemode '{...}'` replaces every entry. use dw or workbench.

doctor
- dynjectd's log has times without dates. `dw doctor` dates its lines backwards from the
  file's modification time, so an error is placed a day off if the log skipped a whole day.
- `dw doctor --apis` loads the frameworks tweaks name into dw (their initializers run) and
  only knows what manifests declare: a tweak without `requires`, or one that leaves out what
  it hooks, gets no warning. a class living only in an app can only be checked as a string.
- the apps section is respring's plan, so it shares its limits (lsof, see respring).

install / uninstall
- `dw tweak install/uninstall` are used live for every tweak here. workbench's install tweak...
  button shares the code but hasn't been clicked live. `--dry-run` first is still a good habit.
- uninstall removes a global `allow:<App>` line only when nothing else needs it (`--keep-rules`
  keeps them all).
- uninstall refuses to remove the config's last dylib (dynjectd won't start without one).
- uninstall keeps the tweak's settings key `dynject.tweak.<id>`.

bridge
- it stands on private spi: `sandbox_extension_issue_mach` / `sandbox_extension_consume`
  and `xpc_connection_get_audit_token`. a macos update can remove or change them; then
  sandboxed tweaks can't reach the broker (or the broker identifies nobody and denies
  everything). nothing crashes. docs/bridge.md#private-spi.
- verified live 2026-11-20 with the real agent and a test tweak injected by dynject into
  calculator (sandboxed, `anchor apple`): token consumed (mach-lookup denied before,
  allowed after), caller identified as com.apple.calculator, ping p50 0.7 ms, settings.set
  written, notify delivered outside the sandbox, `open file:` denied, rate limit enforced.
  developer id and app store callers were only checked statically against installed
  apps, not running injected ones. if an injected app is denied as `untrusted-caller`
  (os_log only), check `log stream --predicate 'subsystem == "local.dynject.bridge"'`.
- apple's own apps from the app store (pages, numbers, keynote, xcode) have `com.apple.`
  ids but aren't `anchor apple`, so the bridge refuses them. so does any app without the
  hardened runtime, any app with the dyld-variables, library-validation-off or
  get-task-allow entitlements, and any app installed outside /Applications,
  /System/Applications, ~/Applications and /System/Library/CoreServices.
- an override pattern only grants the bridge when it names the app exactly (bundle id,
  `application.<id>.` or the launchd label). hand-written broader patterns (`Notes`,
  `com.apple.`) inject the tweak but don't give it the bridge.
- the launch check is ppid 1 plus "its own responsible process", the latter via private
  spi. an app launched by another app (some helpers, updaters) is refused. without the
  spi a shell-started process that was reparented to launchd would pass the ppid check.
- the tweak id in a request is self-asserted. the broker knows the app, not which dylib
  in it is asking, so any code in an app can use the capabilities of every tweak the
  config injects there. capabilities are kept narrow for that reason.
- the caller's code signature is validated once per connection (again if the audit token
  changes), not for every request.
- the decision log only holds trusted callers. an unknown process's attempts are in
  os_log only, rate-limited, so a flood of them is summarized rather than kept.
- workbench re-reads a tweak's settings when the bridge changes them, except while it
  has an unsaved change of its own, which then overwrites the bridge's write.
- `open` uses NSWorkspace from a background agent: the opened app comes to the front.

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
