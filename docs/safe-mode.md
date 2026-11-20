# Safe Mode

Safe Mode keeps a crashing tweak out of the app it crashes, automatically and per app, in the spirit of
Substrate's safe mode on iOS. A user-level watcher reads new crash reports, works out which tweaks were loaded in the
crashed process, and disables a tweak for **that app only**. Tweaks built on DynjectHook honour this the next time
the app launches. Nothing involved needs administrator rights, and Safe Mode never edits the Dynject config or acts
on Dynject itself.

Code: `Sources/DynjectCore/CrashReport.swift` (report parser), `SafeModeAttribution.swift` (tweak identity,
attribution, support check), `SafeMode.swift` (key, state, rules, scanner, watcher), `SafeModeAgent.swift`
(LaunchAgent) and `Sources/dw/SafeModeCommands.swift` (`dw safemode`).

## How a tweak is kept out

The tweak decides for itself at load time. `DH_CTOR` calls `DHShouldLoad`, which returns NO when:

- the user's global preferences hold `dynject.safemode` = `{tweakID: [bundleID | "*"]}` and the array for this tweak
  lists this app's bundle ID or `"*"`;
- the `"*"` entry (every tweak) lists this app or `"*"`. `"*": ["*"]` is the **panic switch**: every DynjectHook
  tweak stays out of every app;
- **Shift is held down while the app launches** (one launch only; set `DH_DISABLE_SHIFT_BYPASS` to turn this off).

The dylib is still injected; it just doesn't set itself up. Changes apply at the app's next launch. After every change
the writer posts the Darwin notification `dynject.safemode.changed`.

A crash report doesn't say whether a loaded DynjectHook tweak actually started, so the watcher only knows about
what the key kept out. **Crashes during a Shift launch, or in an app outside a tweak's `DH_CTOR` bundle list, still
count toward `repeated crashes`** for the tweaks loaded there (never toward `crash in tweak`, since those tweaks
have no frames in the crash). If a Shift launch still crashes, the tweaks aren't the cause: re-enable any the watcher
then turns off. (Third-party crash reporter annotations, `__DATA,__crash_info`, which could have carried that
signal, are not copied into `.ips` reports on macOS 27.)

Change the key with `dw safemode` or Workbench, not `defaults`: `defaults write -g dynject.safemode '{ ... }'`
replaces every entry (the watcher's included) and `defaults delete` removes them all. Entries removed that way are
treated as re-enabled at the next scan (see below).

**Tweaks that aren't built on DynjectHook ignore the key.** External dylibs built without
it are the usual example. The only way to stop such a tweak is to disable it in the Dynject config (Workbench's existing admin-prompt
flow, or `dw disable`). Safe Mode still records their crashes, still adds their entries to the key (which is harmless
and takes effect if they adopt DynjectHook), and warns that they keep loading.

A tweak **supports Safe Mode** when its dylib contains the C string `dynject.safemode` on its own (NUL bytes before
and after). DynjectHook's `CFSTR("dynject.safemode")` literal produces exactly that, while a tweak ID such as
`x.dynject.safemode.y` does not. Builds of DynjectHook from before the panic switch honour their own entries but
not the `"*"` entry; current builds also contain `dynject.safemode:all-tweaks`. So the check returns a level
(`SafeModeSupportChecker.support(dylibAt:)`, cached by size and modification date): `.unsupported`, `.perTweak`
(older DynjectHook: per-app entries work, the panic switch doesn't) or `.perTweakAndPanic`. Workbench and
`dw safemode status` list the `.perTweak` tweaks as still loading under panic; rebuilding them with the current
TweakSDK fixes that.

## What the watcher does

`dw safemode watch` runs as the LaunchAgent `local.dynject.safemode`. It watches `~/Library/Logs/DiagnosticReports`
(a DispatchSource on the directory, debounced by 1 s), rescans every 60 s, and handles each `.ips` report once.

1. **Read.** An `.ips` file is two JSON documents: a one-line header (`bug_type`, `incident_id`, `app_name`,
   `bundleID`, `timestamp`) and the body (`procName`, `procPath`, `bundleInfo.CFBundleIdentifier`, `captureTime`,
   `exception`, `faultingThread`, `threads[i].frames`, `lastExceptionBacktrace`, `usedImages`). Every field is
   optional; unknown fields are ignored. Only real crashes count: `bug_type` 309 without `is_simulated` (so hangs,
   spins and the ExcUserFault_* simulated reports are skipped). The header is read first, so other reports cost
   little. A report changed in the last 2 s is left for the next pass (one whose modification time is in the future,
   after the clock was moved back, counts as settled). A report that isn't valid JSON is retried for 60 s (it may
   still be being written) and then recorded as a problem; the watcher carries on.
2. **Attribute.** Each `usedImages` entry is matched to installed tweaks: by full path when the report kept it (`/opt`
   paths are intact), and by file name when the reporter anonymised it (`/Users/USER/*/libX.dylib`) or left it
   out. Tweaks come from the loaded manifests' `dylib` field. A dylib in `/opt/dynject/lib/tweaks` without a manifest
   becomes `dylib:<file name>`: it is shown, but has no tweak ID to put in the key. When several manifests name one
   dylib, those whose identifier is compiled into it win. The app's own executable is never a tweak.
3. **In the tweak?** The crash happened *in* a tweak when one of the tweak's frames is among the top frames
   (default 6) of the faulting thread or of `lastExceptionBacktrace` (where an Objective-C exception was thrown).
   Leading crash machinery (abort, `pthread_kill`, libc++abi, libobjc, `__exceptionPreprocess`,
   `objc_exception_throw`, ...) is skipped before counting, so the frame that actually failed is in view.
4. **Decide.** For every tweak loaded in the crash and running at the time, a crash record is kept. Then the tweak is
   disabled for the app:
   - **at once** when the crash happened in the tweak (reason `crash in tweak`);
   - otherwise after **2 tweak-loaded crashes of the app within 10 minutes** (reason `repeated crashes`). Crashes
     that another tweak was found at fault for don't count against the tweaks that merely shared the process.

   These never count: crashes from before the last re-enable of that (tweak, app), repeated `incident_id`s, crashes
   of Dynject's own processes (`/opt/dynject/...`), crashes without a bundle ID, reports older than 60 minutes (a
   backlog the first time the watcher runs is listed, not acted on), and tweaks that were loaded but **not running
   when the app crashed** because the key already kept them out at the crash's time. That is judged by when each entry was added (`disabled[].since`, `panicSince` in
   `state.json`), not by the key at scan time, so turning the panic switch on after a crash doesn't discard that
   crash. Entries the state knows nothing about (added with `defaults`) are taken to be older than the crash. A
   frame in the tweak always counts: it proves the tweak ran. Older DynjectHook builds count as running under the
   panic switch, which they ignore.
5. **Act.** Read-modify-write of `dynject.safemode` (other entries are kept), post `dynject.safemode.changed`,
   record why in `state.json` (saved right after the key write, before the pass goes on), and post a notification
   (`osascript display notification`) unless notifications are off. If a pass is stopped between the key write and
   that save, the next pass records the missing reason and notifies. If the key write fails, the report is evaluated
   again on later passes while it is still fresh.

Settings (`dw safemode settings`, or `SafeMode.updateSettings`): `threshold` (2), `windowMinutes` (10), `notify`
(on), `inTweakDepth` (6), `maxReportAgeMinutes` (60).

## Where things live

| What | Where |
|---|---|
| Which tweaks are off where | `dynject.safemode` in the global preferences domain |
| Change notification | Darwin `dynject.safemode.changed` |
| Why, since when, which report; recent crashes; re-enable times; processed reports; settings | `~/Library/Application Support/Dynject Workbench/SafeMode/state.json` |
| Watcher binary | `~/Library/Application Support/Dynject Workbench/bin/dw` |
| LaunchAgent | `~/Library/LaunchAgents/local.dynject.safemode.plist` (RunAtLoad, KeepAlive) |
| Watcher log | unified log, subsystem `local.dynject.safemode` (`log stream --predicate 'subsystem == "local.dynject.safemode"'`) |

`state.json` is written atomically under an exclusive lock (`state.lock`, flock). Every change to the key (the
watcher's, Workbench's, `dw`'s, the panic switch included) is made while holding that lock, so the watcher and
Workbench never lose each other's changes. Processed reports are remembered by file name, size and modification time, so a restarted
watcher does not handle them again. Missing or damaged fields fall back to defaults; an unreadable file is set aside
as `state.json.unreadable`. Entries in the key that `state.json` knows nothing about (added with `defaults`, say) are
shown with an unknown reason. Entries `state.json` lists that are gone from the key (removed with `defaults`) are
dropped at the next scan and count as re-enabled as of when they were disabled, so the crashes that led to them
don't count again.

## Command line

```
dw safemode status                              panic switch, agent, rules, disabled list, recent crashes
dw safemode disable <tweakID> <bundleID|*>      disable by hand ("*" as tweak ID: every DynjectHook tweak in that app)
dw safemode enable  <tweakID> <bundleID|*>      re-enable ("*": everywhere); earlier crashes stop counting. Says
                                                what still keeps it out (every-app entry, "*" entry, panic); refuses
                                                one app of a tweak disabled everywhere
dw safemode disable <tweakID> '*'               replaces the tweak's per-app entries with "*"
dw safemode panic on|off                        "*": ["*"]
dw safemode clear                               re-enable everything, panic off
dw safemode settings [threshold N] [window MIN] [notify on|off] [depth N] [max-age MIN]
dw safemode watch [--once] [--no-notify]        the watcher (--once: one pass, then exit)
dw safemode agent install|uninstall|status      the LaunchAgent (install copies this dw binary into place;
                                                --no-notify is passed on to the agent's watch)
dw safemode help
```

Options for any subcommand: `--domain D` (preferences domain; default global), `--state-dir D`, `--reports-dir D`,
`--tweaks-dir D` (manifests; default Workbench's Tweaks folder and `/opt/dynject/lib/tweaks`), `--dylib-dir D`
(installed dylibs; default `/opt/dynject/lib/tweaks`). `agent install` writes the non-default ones into the plist.
For testing the agent: `--launch-agents-dir D`, `--bin-dir D`, `--no-launchctl` (prints the launchctl commands
instead of running them).

## API for Workbench

```swift
let sm = SafeMode.live()                         // or SafeMode.inDomain(SafeModeNames.testDomain, stateDirectory:)
let catalog = SafeModeCatalog(manifests: model.manifests)   // + unmanifested dylibs in /opt/dynject/lib/tweaks
let snap = sm.snapshot(catalog: catalog)         // panic, settings, disabled rows (merged with state.json), recent crashes
let stillOff = try sm.enable(tweakID: row.tweakID, bundleID: row.bundleID)  // "Re-enable"; [] = loads again
try sm.disable(tweakID: id, bundleID: bundleID)  // manual
try sm.setPanic(true)
try sm.clear()
try sm.updateSettings { $0.threshold = 3 }
SafeModeSupportChecker.shared.support(dylibAt: tweak.dylibPath)   // .unsupported → warning + "Disable in config…"

let agent = SafeModeAgent()                      // inject a LaunchctlRunner in tests and fixture mode
agent.status()                                   // plistInstalled, binaryInstalled, loaded, running, pid, summary
try agent.install(sourceBinary: pathToBundledDw)
try agent.uninstall()
```

To refresh live, observe the Darwin notification `dynject.safemode.changed` (key changes) and poll or watch
`state.json` (crash records the watcher adds).

## The Workbench panel

Workbench's Safe Mode page (`Sources/DynjectWorkbench/SafeModeModel.swift`, `Views/SafeModeView.swift`):

- **Crash watcher:** the agent's status (launchctl print, every 5 s while the page is open), Install Watcher /
  Reinstall / Uninstall (copies the `dw` bundled at `Contents/MacOS/dw`), the rule settings, and Check Reports Now
  (one scanner pass from Workbench, for use without the agent).
- **Panic switch:** "Turn off all DynjectHook tweaks everywhere", with the tweaks that would keep loading anyway.
- **Disabled:** one row per (tweak, app) in the key with app icon and name, reason, since, the frame, Show Crash
  Report and Re-enable; Re-enable All… (`clear`). Rows for tweaks that ignore Safe Mode warn and offer
  "Disable in Config…", which stages "don't inject this dylib into this app" in the working config and opens the
  usual review sheet (save, then restart dynjectd; administrator rights in live mode). Once the saved config keeps
  the tweak out of that app, the row says so instead, and Re-enable explains that the config still keeps it out.
- **Recent tweak-related crashes** (newest 25) and **Tweaks** with a support badge each.
- A footer explains the Shift-at-launch bypass.

The page re-reads the key and `state.json` on the change notification and whenever the state directory changes.
Fixture mode, smoke tests and launches that preview other manifests, reports or dylibs isolate it (see
[HACKING.md](../HACKING.md#fixture-mode-and-isolation)). Isolated files go under `-DWSupportDir`, or, without it, under `SafeModePreview/` in the
support folder, never the real `SafeMode/state.json` or `bin/dw`; the UI smoke test covers it with synthetic reports in a scratch folder.

## Testing

Tests never touch the real key or a real LaunchAgent. They use `MemoryTweakBackend` or the preferences domain
`local.dynject.safemode.test` (notification `local.dynject.safemode.test.changed`), temporary state and report
directories, synthetic `.ips` files shaped like real ones (plus `Tests/DynjectCoreTests/Fixtures/safemode/`, a
trimmed real report), and `RecordingLaunchctlRunner`.
