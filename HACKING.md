hacking
=======

for people changing the tools themselves. if you only want to write tweaks, see
TWEAKS.md. read CONTRIBUTING.md before sending anything.


layout
------

    Package.swift                 swift 6 tools, macOS 14+, swift 5 language mode
    Sources/DynjectCore/          everything that isn't ui: config parser, evaluator (port of dynjectd's
                                  filters), minimal editor, validator, log/ps/lsof/launchctl readers,
                                  writer + privileged helper script, plists, tweak manifests and settings,
                                  apple menu publishing, safe mode, respring, tweak installer and template,
                                  the bridge (Bridge.swift: rules, actions, limits, log; BridgeSystem.swift:
                                  xpc, code identity, token, agent), version and notices (WorkbenchInfo.swift)
    Sources/DynjectWorkbench/     the swiftui app. AppEnvironment.swift: launch arguments.
                                  RespringModel.swift: the respring sheet. SafeModeModel.swift. BridgeModel.swift.
                                  TweakInstallModel.swift. SmokeTest.swift: the ui smoke test runner.
                                  Views/: the pages.
    Sources/dw/                   the cli. main.swift (install, enable/disable, relaunch, config apply, log),
                                  TweakCommands.swift (tweak install/uninstall/list, new),
                                  SafeModeCommands.swift, RespringCommand.swift, BridgeCommands.swift
    Sources/DynjectLiveTrial/     live privileged trial runner against /opt/dynject. run only when you mean it.
    TweakSDK/                     DynjectTweak.h (settings, header only), DynjectHook.h + DynjectHook.m
                                  (hooking), DynjectBridge.h + DynjectBridge.m (the bridge client). also the
                                  DynjectTweakSDK target, so tests can compile against it.
    Tweaks/MenuLoader/            the apple-menu loader tweak, its build.sh and testhost/
    Tweaks/Inspector/             the in-app inspector tweak, its build.sh (`test` runs testhost/)
    Examples/                     ExampleTweak.workbench.plist (every item type), TitleBadge/ and
                                  OLEDFinder/ (example tweaks)
    Tests/DynjectCoreTests/       unit tests + Fixtures/ (live.conf is a byte copy of a real config)
    Tests/DynjectHookTests/       objective-c tests for DynjectHook, and the bridge sdk's local refusals
    Tests/DynjectHookSwiftFixtures/  swift classes for DynjectHook's swift class lookup tests
    Tests/DynjectWorkbenchTests/  the app's launch arguments, the respring sheet's model, install tweak
                                  in fixture mode, the bridge page's isolation
    Resources/Info.plist          app bundle metadata, url scheme dynject-workbench://
    scripts/                      bootstrap.sh, build-app.sh, ui-smoke-test.sh, respring-e2e.sh (+ respring-e2e/),
                                  bridge-e2e.sh (+ bridge-e2e/)
    docs/                         reference: workbench.md, tweak-format.md, hooking.md, safe-mode.md, respring.md,
                                  bridge.md
    build/                        output, gitignored


building and tests
------------------

    swift build
    swift test                          # 354 tests, ~20 s
    swift test --filter DynjectHookTests
    ./scripts/build-app.sh              # build/Dynject Workbench.app, release, ad-hoc unless SIGN_IDENTITY
    ./scripts/ui-smoke-test.sh          # drives the built app against fixtures
    ./scripts/respring-e2e.sh           # respring engine end to end against test apps it builds (~25 s)
    ./scripts/bridge-e2e.sh             # bridge end to end: temporary agent, sandboxed test app (~40 s)
    Tweaks/MenuLoader/testhost/run.sh   # MenuLoader in an appkit test host, sandboxed copy included
    (cd Examples/TitleBadge && ./build.sh test)   # TitleBadge in a local test app
    Examples/OLEDFinder/build.sh test             # OLEDFinder in a finder-like test app, screenshots
    Tweaks/Inspector/build.sh test                # Inspector in an appkit + swiftui test app, screenshots
    open "build/Dynject Workbench.app"

current counts (2026-11-20): 245 DynjectCore (parser, editor, helper script, writer,
plists, tweaks, apple menu, safe mode, respring, tweak install and template, version
notice, bridge), 84 DynjectHook (3 of them the bridge sdk), 25 DynjectWorkbench (launch
arguments, the respring sheet's model and links, install tweak in fixture mode, bridge
isolation).

`build-app.sh` builds the app and `dw`, copies `dw` to `Contents/MacOS/dw` (safe mode's
install watcher copies it from there), copies the sdk to `Contents/Resources/TweakSDK`
(for `dw new`), signs `dw` first and then the bundle, hardened runtime, no
entitlements. not sandboxed: it has to read /opt/dynject, run ps/lsof/launchctl and
hand protected writes to osascript.

the version is `WorkbenchInfo.version` in DynjectCore and `CFBundleShortVersionString`
in Resources/Info.plist; a test fails if they disagree.

testing notes:

- the helper script tests run the real script as your user, with stub
  `pgrep`/`kill`/`launchctl`/`sleep`. the script honours stubs (and
  `DW_TEST_TWEAKS_DIR` in place of `/opt/dynject/lib/tweaks`) only when not running as
  root. one test reproduces a two-daemon state; others cover multi-file transactions
  and every refused removal (symlinks, other folders, hidden files, `..`, changed
  contents).
- tweak installer tests work in temporary folders with made-up mach-o files; one runs
  the helper script for the files (not the restart) to check that install and
  uninstall each take one invocation. one generates a tweak with `TweakTemplate` and
  compiles it with its own `build.sh` (no warnings, no exported symbols).
- DynjectHook tests compile their own copy of DynjectHook.m (`DHTLibrary.m`), the way a
  tweak does; `DHTSecondCopy.m` plays a second tweak in the same process. one test
  compiles a dylib with `xcrun clang` and loads it; skipped without a compiler.
- safe mode tests use `MemoryTweakBackend` or the domain `local.dynject.safemode.test`,
  temp state and report dirs, synthetic `.ips` files plus one trimmed real report, and
  `RecordingLaunchctlRunner`.
- the ui smoke test launches the built app on copies of the fixtures and drives it as
  an accessibility client of its own process (no accessibility permission needed): it
  flips the textedit switch, reviews and saves, toggles back to the original bytes,
  checks diagnostics, edits and saves a binary plist, switches the example tweak's
  apple-menu items off and on (published to the fixture file under the test key), and
  checks every result on disk. then it opens the respring sheet with a
  `dynject-workbench://respring` apple event sent to itself, checks default checkboxes
  and exclusion notes over the made-up apps of `-DWRespringFixture`, includes finder,
  runs the simulated respring (one app never quits, so the timeout path is covered)
  and checks results and the new plan. safe mode is covered with synthetic reports in a
  scratch folder. the script then confirms the live config hash, the real
  `dynject.menuloader` key, the set of dynjectd pids and the running regular apps
  (`lsappinfo`) didn't change. accessibility is sometimes slow to expose the window and
  the first steps fail with "apps-table missing" (the model checks still run): rerun.
  screenshots in `build/smoke-report/` are approximate; `cacheDisplay` can't render
  vibrancy.
- respring e2e: docs/respring.md#end-to-end-test. MenuLoader testhost and `-DML_TEST`:
  Tweaks/MenuLoader/README.md.


the rule
--------

tests, the smoke test and fixture mode never touch the live config, /opt/dynject, the
real `dynject.*` global keys, the real LaunchAgent or real apps. they use fixture
copies, test domains and keys (`dynject.menuloader.test`, `local.dynject.safemode.test`,
`local.dynject.menuloader.testprefs`, `local.bridge-e2e.*`), temp dirs, stubs and simulated
controllers. if
you add a feature that writes somewhere, add its isolation in the same patch.


fixture mode and isolation
--------------------------

    "build/Dynject Workbench.app/Contents/MacOS/DynjectWorkbench" \
      -DWConfigPath /path/to/copy.conf \
      -DWLogPath /path/to/dynjectd.log \
      -DWSupportDir /tmp/dw-support \
      -DWAppRoots /Applications:/System/Applications

    -DWConfigPath P       fixture mode: this config. restarts simulated, relaunching apps
                          disabled, no admin prompt can appear. purple strip on the window.
    -DWLogPath P          dynjectd log         -DWErrorLogPath P   dynjectd error log
    -DWAppRoots A:B       where to scan for apps
    -DWSupportDir D       support folder (instead of ~/Library/Application Support/Dynject Workbench)
    -DWTweaksDir D        a folder of manifests to preview
    -DWReportsDir D       crash reports to scan
    -DWTweakDylibDir D    installed dylibs to list
    -DWDwBinary P         the dw that install watcher copies (default Contents/MacOS/dw)
    -DWRespringFixture J  made-up running apps for the respring sheet
    -DWSmokeTest D        run the ui smoke test, report in D. refuses unless fixture mode is on.

with `-DWSupportDir` or `-DWTweaksDir` the apple-menu list is kept out of the global
preferences (in `menuloader-preview.plist` in the support folder, or the fixture's
`tweak-prefs.plist` in fixture mode), so previewing never replaces what the installed
tweaks publish.

safe mode is isolated in the same cases, and also with `-DWReportsDir` or
`-DWTweakDylibDir`: its key goes to that plist file under the test notification name;
`state.json`, the LaunchAgent plist and the `dw` copy go under the support folder
(under `SafeModePreview/` in it when `-DWSupportDir` isn't given, so they never share
the real `SafeMode/state.json` or `bin/dw`), and launchctl is simulated.

the bridge page is isolated whenever safe mode is: its agent plist and `dw-bridge` copy
go under the same folder with the label `local.dynject.bridge.preview` and preview names
in the plist's arguments, launchctl is simulated, the token lives in memory (never read
from or removed in the global domain) and the decision log is that folder's
`Bridge/log.json`. `dw bridge serve --test` refuses the real names and needs its own
config, Tweaks folder, settings file and log (`--app-roots` names where callers must be
installed); `dw bridge agent` takes `--launch-agents-dir` and `--bin-dir` only together
with `--no-launchctl`, which also leaves the token keys alone.

in fixture mode, in the smoke test and with `-DWRespringFixture <json>`, the respring
sheet lists made-up running apps (from that file, or a few scanned apps the config
injects into plus finder, a terminal and workbench) and relaunches them with a
simulated controller: nothing real is quit, opened or inspected. format: `RespringFixture`
in `Sources/DynjectWorkbench/RespringModel.swift`.

install tweak / uninstall in fixture mode use the fixture config and put dylibs and
manifests under the support folder (or `SafeModePreview/` in the real one), with a
simulated restart and no prompt; previewing other manifests, reports or dylibs against
the live config turns them off. `dw tweak --root DIR` does the same for the cli
(DIR/etc/dynjectd.conf, DIR/lib/tweaks, DIR/Tweaks, a safe mode file in DIR).
`dw safemode` takes `--domain`, `--state-dir`, `--reports-dir`, `--tweaks-dir`,
`--dylib-dir`, `--launch-agents-dir`, `--bin-dir`, `--no-launchctl`.


how the pieces talk
-------------------

    workbench / dw ──(one osascript prompt per change)──> helper script as root
                                                          writes /opt/dynject/etc/dynjectd.conf,
                                                          /opt/dynject/lib/tweaks/*.dylib, restarts dynjectd
    workbench / dw ──> global prefs (user, any app):
        dynject.tweak.<id>     tweak settings          notify: dynject.tweak.<id>.changed
        dynject.menuloader     apple-menu list         notify: dynject.menuloader.changed
        dynject.safemode       what's off where        notify: dynject.safemode.changed
    tweaks (DynjectTweak.h, DH_CTOR), MenuLoader ──> read those keys, observe those notifications
    LaunchAgent local.dynject.safemode ──> dw safemode watch ──> DiagnosticReports ──> dynject.safemode
                                                                 + SafeMode/state.json
    LaunchAgent local.dynject.bridge ──> dw bridge serve: publishes dynject.bridge.token (+ .version,
        notify dynject.bridge.changed); tweaks (DynjectBridge.h) consume it, xpc to local.dynject.bridge;
        broker checks the live config + manifests, writes dynject.tweak.<id> / posts / opens; Bridge/log.json

config and privileged helper. the only root code is `HelperScript.swift`, passed inline
to `/bin/sh -c` through `osascript ... with administrator privileges`. it takes a list of
operations (`install` a file, `remove` a tweak dylib) plus an optional `restart`, checks
everything first (sha-256 conflict hashes, removal targets), stages and verifies every
new file next to its target, then renames and removes. a failed check writes nothing.
one user-visible change = one helper call = one password prompt. the restart stops
every dynjectd and starts exactly one, because the loader detaches and
`kickstart -k` piles up daemons. details: docs/workbench.md#writing-protected-files-and-restarting.

the global keys live in the global preferences domain because it's readable from
sandboxed apps. workbench publishes, tweaks read. MenuLoader's list format and
backwards-compat rules: Tweaks/MenuLoader/README.md.

safe mode state: `~/Library/Application Support/Dynject Workbench/SafeMode/state.json`
(why, since when, which report, recent crashes, re-enable times, processed reports,
settings), written atomically under `state.lock` (flock). every key change, the
watcher's, workbench's and dw's, holds that lock. the LaunchAgent is
`~/Library/LaunchAgents/local.dynject.safemode.plist` (RunAtLoad, KeepAlive) running
the copy of dw in `.../Dynject Workbench/bin/dw`. docs/safe-mode.md.

bridge: `~/Library/LaunchAgents/local.dynject.bridge.plist` (RunAtLoad, KeepAlive,
MachServices) running `.../Dynject Workbench/bin/dw-bridge`; decisions in
`.../Dynject Workbench/Bridge/log.json`. the only place tweaks get to write anything
outside their sandbox, so every rule is in one function (`BridgeService.handle`) and
the authorization table is tested case by case. docs/bridge.md.

other app state in Application Support: `Backups/`, `Tweaks/` (installed manifests),
`associations.json` (plist <-> dylib).


conventions
-----------

- DynjectHook: every function and global `visibility("hidden")`; no objective-c classes
  in it (flat namespace); cross-copy coordination only through runtime objects (the
  shared lock is an associated object on NSObject under `dynject.hook.process-lock.v1`).
  never throw or abort from a hook path; log and return.
- manifests are parsed and validated by `TweakManifestParser` everywhere: workbench,
  `dw tweak`, safe mode's catalog. MenuLoader re-validates what it reads, since the key
  can be hand-edited.
- one helper call per user-visible change. never two password prompts for one action.
- config edits are minimal and reversible: on then off restores the original bytes.
  refuse rather than make a wide edit.
- new writers back up first and go through `ProtectedFileWriter`.
- anything that can quit or open apps goes through `AppController`, so tests can
  use `SimulatedAppController`.
- keep `swift test` and `scripts/build-app.sh` green.


process
-------

- commits: one logical change each. imperative one-line subject, a body that says why.
  run `swift test` before committing.
- branches: work on a branch, merge to `main` when it builds and tests pass. `main`
  stays buildable. no force-pushes to `main`.
- versions: `0.x` while alpha; bump the minor for anything a tester would notice.
  `WorkbenchInfo.version` and `Resources/Info.plist` must match (a test checks).
  tag releases `vX.Y.Z` on `main`.
- CHANGELOG.md: a few lines per version, newest first, written for testers, not for
  the commit log. add to the `unreleased` section as you go.
- docs move with the code: a change that alters behaviour updates README, TWEAKS,
  HACKING, KNOWN-ISSUES or docs/ in the same commit.


status
------

version 0.1.0.

    config parser, evaluator, minimal editor   unit-tested against fixtures incl. a byte copy of a live config
    app discovery, configured vs loaded        "loaded" confirmed with lsof on running apps
    raw config editor and diagnostics          done
    plist editor                               xml/binary, backup, format-preserving
    privileged helper                          tested with stubs, then live as root
    ui smoke test                              drives the built app against fixtures
    tweak settings + sdk                       verified live with TitleBadge in sandboxed calculator
    respring                                   unit-tested with fakes, smoke test with simulated apps;
                                               real controller checked on test apps only
    dw tweak install/uninstall, dw new         unit-tested in temp folders, real helper script run as the
                                               user; not yet run against the live engine. the template was
                                               built and injected into a test app.


live trial
----------

`swift run DynjectLiveTrial` runs the privileged paths against /opt/dynject with the
same DynjectCore code as the app (`ConfigEditor`, `ProtectedFileWriter`,
`PrivilegedRestarter` via osascript) and checks each step from outside. every admin
dialog is labelled with its step. `--original <file>` names the config to return to;
`--skip-restart` skips step 2; `--titlebadge ...` runs the TitleBadge check. only run it
when you mean to touch the live install.

results, 2026-11-19, test app calculator (not running), with a third-party test dylib:

    cancel the password prompt            reported as cancelled; nothing written
    restart with two detached daemons     both stopped; exactly one new dynjectd with the current config
    enable for calculator, save+restart   two lines added; root:wheel 644 kept; backup made; one daemon
                                          (log: deny-all, 2 override(s)); log MATCH; lsof: loaded
    disable, save+restart                 config byte-identical to the original; one daemon; not loaded
    conflict guard (unplanned)            file changed between load and write: helper refused

the first run went wrong because the password was typed at the "click cancel" step.
that appended a test comment to the config, and the conflict guard then correctly
blocked the next write. a second run started from a pre-trial copy and left the
config byte-identical to it.

later that day, through the app's own switch, review sheet and save & restart button,
for notes while notes was running: exactly two lines added
(`dylib-override:...:allow:com.apple.Notes`, `allow:Notes`), `root:wheel 644` kept,
backup made, one prompt, exactly one dynjectd (`deny-all, 2 override(s)`). after
relaunching notes: log MATCH and lsof loaded. a notes launch before the restart was
still skipped (`SKIP (no_gui)`), which confirms the save -> restart -> relaunch order.

TitleBadge, same day: injected by dynject into sandboxed calculator; its own log lines
confirmed it read settings written by workbench, picked up live changes and a per-app
override, and went back to defaults on revert.

since then `dw install`, `dw enable` and `dw config apply` have been used live;
`dw tweak install/uninstall` has not. see KNOWN-ISSUES.md.
