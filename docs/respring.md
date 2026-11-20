# Respring

dynjectd sets `DYLD_INSERT_LIBRARIES` only when a process starts. After a config change, a tweak update or a Safe
Mode change, running apps keep the tweaks they launched with until they are relaunched, much like an iOS device
needs a respring. `dw respring` finds those apps and relaunches them, and Workbench's Respring sheet does the same.
Neither needs admin rights or writes the config.

## What counts as pending

For every running regular app (NSWorkspace, activation policy `.regular`), the planner compares what a launch now
would inject (the config's policy for the app's service name, as on the Configuration page) with the tweak dylibs
`lsof` shows mapped in the process:

| Reason | Meaning |
| --- | --- |
| `missing <tweak>` | The config injects it here, but the process doesn't have it. |
| `unwanted <tweak>` | Loaded, but the config no longer injects it (or it was removed from the config). |
| `updated <tweak>` | Loaded, and the file on disk changed after the app launched (the later of its modification and inode-change times, so a copy that keeps the old date still counts). |
| `Safe Mode off/on again: <tweak>` | A DynjectHook tweak whose Safe Mode entry changed after the app launched. The dylib stays injected either way, so only the dates in Safe Mode's `state.json` show this. Turning the panic switch off isn't dated and isn't detected. |

Tweaks are named by their manifest's identifier, or by file name if they have no manifest. Apps with no Dynject
involvement either way are never pending. Apps `lsof` can't read are listed as unknown.

## What gets relaunched

By default: the pending apps, minus these (each can be named with `--include` or checked in the sheet):

- the app that runs the respring: `dw`'s terminal or editor, found by walking the parent process chain from
  `getpid()` (an editor's integrated terminal leads back through a helper inside the editor's bundle);
- terminals and editors (Terminal, iTerm2, Ghostty, Warp, kitty, Alacritty, WezTerm, VS Code, Cursor, Xcode,
  JetBrains IDEs, Android Studio, Zed, Nova, BBEdit, Sublime Text);
- Dynject Workbench itself;
- Finder, which only quits through an Apple Event (needs Automation permission). `--all` includes it;
- an app that launched after the config took effect (the later of the config's write and dynjectd's start) and still
  lacks a tweak whose file predates its launch: something other than timing keeps it out, so a relaunch won't help.

`loginwindow` is never relaunched. `--all` takes every running regular app (minus the first three groups) and
includes Finder. `--exclude` always wins. `--only <id>` considers just the named apps.

## How an app is relaunched

One app at a time, in name order, with Workbench and then the app hosting the caller last:

1. Ask it to quit (`NSRunningApplication.terminate`; Finder: `tell application id "com.apple.finder" to quit`).
2. Poll its pid for up to `--timeout` seconds (default 15). If it is still running (unsaved changes, a dialog), it is
   skipped and left alone. If it quits later, it isn't reopened.
3. If launchd already restarted it (Finder), use that process. Otherwise reopen it with
   `NSWorkspace.openApplication` without activating it (hidden if it was hidden).
4. Poll `lsof` for up to 5 s until the new process has the expected tweaks and no unwanted ones, then report
   `verified`, or what is still missing or still loaded.

The app hosting the caller (Workbench when it relaunches itself, or `dw`'s editor named with `--include`) can't
reopen itself. A detached `/bin/sh` in its own session waits for it to exit and then runs `open -g`. It gives up
if the app is still running after the timeout.

```
dw respring --dry-run                    the plan, nothing quit
dw respring                              relaunch pending apps
dw respring --all --dry-run              every running app, Finder included
dw respring --include com.mitchellh.ghostty --exclude com.apple.Notes
dw respring --only com.apple.calculator  just this app, pending or not
```

`dw respring` exits 1 when any app was skipped or failed verification.

## In Workbench

The sidebar footer shows **Respring: N apps pending** (every pending app, excluded ones too) and opens the Respring
sheet, as does the toolbar's **Respring…**. The sheet lists the pending apps with their reasons, each with a
checkbox. Apps left out by default start unchecked, with a note saying why; loginwindow can't be checked. **Show all
running apps** lists the up-to-date ones too (to relaunch them anyway, like `--all`). **Respring Selected** runs the
engine off the main thread with the chosen quit timeout and shows each app's progress and result. **Stop After This
App** lets the current app finish and cancels the rest. If Workbench itself is checked, it goes last and a detached
helper reopens it.

The plan uses the saved config, not unsaved edits (dynjectd only reads what is on disk). It is refreshed when the
config is saved, dynjectd is restarted, Safe Mode changes, the manifests are reloaded, an app launches or quits, the
config or a file in the tweaks directory changes on disk (checked every 15 s, so `dw install` and `dw config apply`
are noticed), and with the sheet's **Refresh** or the toolbar's Refresh.

`dynject-workbench://respring` (`CFBundleURLTypes` in `Resources/Info.plist`) opens the sheet, launching Workbench
if needed. If the save review is up, the sheet opens after it closes. A link never relaunches anything; only the
button does. MenuLoader's own manifest declares the Apple-menu item **Respring…** (`arrow.clockwise`,
`url:dynject-workbench://respring`), so the sheet is one click away from any app MenuLoader is injected into. Launch
Services learns the scheme once the new build of Workbench has been launched (or opened in Finder).

In fixture mode, in the smoke test and with `-DWRespringFixture <json>` (`AppEnvironment.isolatesRespring`), the
sheet never sees or touches real apps. It plans over a `RespringFixtureWorld`: the apps in the JSON file, or a few
scanned apps the config injects into plus Finder, a terminal and Workbench as the host. It relaunches them with
`SimulatedAppController` and a manual clock. A simulated relaunch gives the app a new pid with its new tweaks, so the
next plan shows it up to date. The sheet says "Simulated" in that mode.

## End-to-end test

`scripts/respring-e2e.sh` runs the real engine (`WorkspaceAppController`, `lsof`) without touching any app but its
own. It builds two test apps and a test dylib under `.build/respring/e2e/`: **RespringE2E Plain** quits when asked,
and **RespringE2E Stubborn** answers `NSTerminateLater` and quits 8 s later. The planner gets a fake config that
gives the test apps the dylib and sees only apps under that folder. Every quit and open goes through a wrapper that
aborts the run before acting on anything else. dynjectd isn't involved: the relaunch gets the dylib through
`DYLD_INSERT_LIBRARIES` in the open call's environment (`Respringer.Settings.environment`), and the dylib's
constructor logs the pid that loaded it.

It checks, in about 25 s: both apps pending as `missing`; a dry run that calls nothing; Plain quit, reopened in the
background and verified by `lsof` and the constructor's log; Stubborn skipped after a 3 s timeout and not reopened
when it quits later; `updated` after the dylib is replaced by a date-keeping copy; `unwanted` after the config
denies it; a failed verification when the relaunch doesn't get the dylib; and no test app left running or real app
quit. It exits 1 if any check fails.

## Code

`Sources/DynjectCore/RespringPlanner.swift` holds the planner and the selection rules.
`Sources/DynjectCore/Respringer.swift` holds the engine, the `AppController` protocol and `SimulatedAppController`.
`Sources/DynjectCore/RespringSystem.swift` holds the real sources (NSWorkspace, lsof, sysctl), the controller and
`RespringPlanner.live`. The CLI is in `Sources/dw/RespringCommand.swift`, and Workbench's sheet in
`Sources/DynjectWorkbench/RespringModel.swift` and `Views/RespringView.swift`. The planner reads only through
injected sources (running apps, lsof, clock, file dates, config, service names, Safe Mode events), and the engine
changes processes only through `AppController`. Tests and Workbench's fixture and smoke-test modes use
`SimulatedAppController`, which never touches a real process.

```swift
let planner = RespringPlanner.live(configText: text, configPath: path, logText: log, manifests: manifests,
                                   safeModeState: SafeModeStateStore().load(), daemon: DaemonInspector.status(configPath: path))
let plan = planner.plan()                      // plan.pending, plan.defaultSelection, candidate.reasons
let engine = Respringer(controller: WorkspaceAppController(),  // SimulatedAppController(plan: plan) in fixture mode
                        settings: .init(quitTimeout: 15, tweakDylibs: planner.tweakDylibs))
let results = engine.run(plan.defaultSelection) { progress in … }   // blocking; call it off the main thread
```
