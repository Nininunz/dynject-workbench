# Dynject Workbench

A native macOS app for managing the installed [Dynject](#how-dynject-decides) injection engine:

- See which installed apps each configured dylib applies to, and why.
- Turn a configured dylib on or off for one app. The edit is minimal and leaves unrelated config lines alone.
- Edit the whole `dynjectd.conf` as raw text, with diagnostics based on dynjectd's own parser.
- Edit any property list as XML. It is validated, backed up, and saved in its original on-disk format.
- Restart `dynjectd` safely: exactly one daemon, never duplicates.

It manages the existing engine at `/opt/dynject`. It is not an injector, not a theme UI, and not a binary/hex editor.

## Status

Version 0.1, built and tested against fixtures. The privileged write and restart paths have **not** yet been
exercised against the live install (see [Live trial checklist](#live-trial-checklist)).

| Area | State |
| --- | --- |
| Config parser, evaluator, minimal editor | Done. Unit-tested against fixtures, including a byte copy of the live config. |
| App discovery, configured vs. loaded status | Done. "Loaded" is confirmed with `lsof` on running apps. |
| Raw config editor and diagnostics | Done. |
| Plist editor (XML/binary, backup, format-preserving) | Done. |
| Privileged helper (atomic install, single-daemon restart) | Done. Tested with stubbed `pgrep`/`kill`/`launchctl`, not yet as root. |
| UI smoke test | Done. Drives the built app through accessibility against fixtures. |

## Getting started

Requires macOS 14+ and Xcode / Swift 6 command-line tools.

```sh
swift test                    # 60 unit tests (parser, editor, helper script, writer, plists)
./scripts/build-app.sh        # → build/Dynject Workbench.app (release, ad-hoc signed)
./scripts/ui-smoke-test.sh    # UI smoke test against config fixtures
open "build/Dynject Workbench.app"
```

Launched normally, the app reads the **live** paths (`/opt/dynject/etc/dynjectd.conf`,
`/opt/dynject/log/dynjectd.log`). Nothing is written until you click Save in the review sheet.

### Fixture mode

Any of these launch arguments switch to fixture mode. In fixture mode restarts are simulated, relaunching apps
is disabled, and an administrator prompt can never appear. A purple strip marks the window.

```sh
"build/Dynject Workbench.app/Contents/MacOS/DynjectWorkbench" \
  -DWConfigPath /path/to/copy.conf \
  -DWLogPath /path/to/dynjectd.log \
  -DWSupportDir /tmp/dw-support \
  -DWAppRoots /Applications:/System/Applications
```

`-DWSmokeTest <dir>` runs the UI smoke test. It refuses to run unless fixture mode is on.

## How Dynject decides

Ported from `dynjectd.c` (whose source matches the installed binary byte for byte). For each app launch,
dynjectd applies three filters in order. The app's detail pane shows the result of each one.

1. **XPC service filter** (on the service name, e.g. `application.com.apple.TextEdit.<n>.<n>` or `com.apple.Finder`):
   built-in system-daemon list → `allow:` substring → `deny:` substring → built-in UI patterns (`application.`, `com.apple.Finder`, …).
2. **Process filter** (on the executable name and path): `skip_helpers` (" Helper") → `deny:` → `allow:` →
   `ui_apps` (the app lives under `/Applications`, `/System/Applications`, or `/System/Library/CoreServices`).
3. **Per-dylib policy**: the first `dylib-override` whose pattern is a substring of the service name wins.
   Otherwise the dylib's default (`dylib:<path>:allow|deny`) applies.

Details that matter, all enforced and diagnosed by the app:

- Matching is **case-sensitive substring** matching. Finder's bundle ID is `com.apple.finder`, but dynjectd sees
  `com.apple.Finder`. The app resolves service names from the log first, then known launchd labels, then the
  LaunchServices pattern, and shows which source it used.
- A `dylib-override` that appears **above** its `dylib:` line is silently ignored.
- Any policy other than exactly `allow` means deny (`Allow` is deny).
- `allow:Finder` also matches "Path Finder". The editor lists every other installed app an edit affects.
- With no `dylib:` line, dynjectd refuses to start, so the app blocks that save.
- dynjectd reads its config **only at startup**, and injection happens **only at app launch**.

## Configured vs. loaded

Each app/dylib pair shows three separate facts:

- **Configured.** The policy (in the window, or saved on disk) says dynjectd would inject it.
- **Log MATCH.** dynjectd logged that it set `DYLD_INSERT_LIBRARIES` for that launch. That is an attempt, not proof.
- **Loaded.** `lsof` shows the dylib mapped into the running process. This is the only confirmation. It works for
  your own processes, and the app says so when it can't inspect one.

The detail pane lists the remaining steps in order: save → restart Dynject → quit and relaunch the app. A
running app keeps whatever it launched with; nothing is added to or removed from a live process.

## How toggles edit the config

Toggling one dylib for one app changes as little as possible:

1. If the deciding `dylib-override` only matches this app, the editor flips its policy in place, or deletes the
   line when the next rule already gives the wanted result.
2. Otherwise it inserts a narrow override for this app **above** the deciding line (first match wins), using
   the bundle ID or, if that would also match another installed app, `application.<bundleID>.`.
3. If the process filter blocks the app (for example, `ui_apps:no`), it adds `allow:<executable>`. When you turn
   injection off again, it removes that line only if no installed app's result changes as a consequence.
4. It refuses, with an explanation, when a global `deny:`, `skip_helpers`, or a duplicate `dylib:` line is in the way.
   Those are for the raw editor.

Turning injection on and then off restores the original bytes exactly (tested, including CRLF files and files
without a final newline). The toggles and the raw editor share one buffer, and every save goes through a review sheet
that shows the diff and which installed apps change.

## Writing protected files and restarting

- Before every write, the current file is backed up to `~/Library/Application Support/Dynject Workbench/Backups/`.
- Writable files are replaced atomically (temp file in the same directory, fsync, rename) and keep their permissions.
- Protected files (the live config is `root:wheel 644`) go through `osascript … with administrator privileges`.
  The only code that runs as root is [`HelperScript.swift`](Sources/DynjectCore/HelperScript.swift), passed
  inline to `/bin/sh -c`, so there is no script file on disk to tamper with. The helper:
  refuses to write if the target changed since you loaded it (SHA-256), copies the staged file into root-owned space,
  checks its hash again (so a swapped staged file is rejected), keeps the owner and mode, and renames atomically.
- **Restart.** The launchd job runs `dynject_loader`, which spawns a *detached* `dynjectd` and exits. launchd
  then reports the job as "not running", so `launchctl kickstart -k` cannot stop the old daemon, and every kickstart
  adds another one. The helper instead waits for any running loader to finish, sends SIGTERM to **every** `dynjectd`
  (SIGKILL after 5 s), aborts if any survive, starts the job **once** (`kickstart` without `-k`, or `bootstrap`
  if it isn't loaded), confirms that exactly one daemon is running, and stops extras if two appeared.
  Save & Restart does the write and the restart under a single password prompt.

## Plist editor

- Open any plist. Binary and XML files are shown as XML. OpenStep-format files are read-only, because
  Foundation can't write them.
- Every edit is validated. Saving backs up the original and writes in the **original format**. XML is written
  exactly as you typed it. Binary is re-encoded and verified, and values you didn't touch keep their exact
  original form (sub-second dates, keyed-archiver UIDs).
- Workbench does not guess where a dylib keeps its settings. You associate plists with dylibs by hand (Dylibs
  page or plist toolbar). Associations are stored in `associations.json` in Application Support.
- Preference files are cached by `cfprefsd`, and the owning app may overwrite your edit. The editor warns when
  the app is running. Quit it before saving.

## Repository layout

```
Sources/DynjectCore/       Parser, evaluator, editor, log/ps/lsof/launchctl readers, writer, helper script, plists
Sources/DynjectWorkbench/  SwiftUI app and the smoke-test runner (SmokeTest.swift)
Tests/DynjectCoreTests/    Unit tests and fixtures (live.conf is a byte copy of the live config)
Resources/Info.plist       App bundle metadata
scripts/                   build-app.sh, ui-smoke-test.sh
```

## Testing notes

- The helper script tests run the **real** script as your user, with stub `pgrep`/`kill`/`launchctl`/`sleep`. The
  script honours stubs only when it is not running as root. One test reproduces this machine's two-daemon state.
- The UI smoke test launches the built app on copies of the fixtures. It drives it as an accessibility client of
  its own process (no Accessibility permission needed): it flips the TextEdit switch, reviews and saves, toggles
  back to the original bytes, checks diagnostics, edits and saves a binary plist, and checks every result on disk.
  The script then confirms that the live config hash and the set of `dynjectd` PIDs did not change.
  Screenshots in `build/smoke-report/` are approximate, because `cacheDisplay` can't render vibrancy layers.

## Live trial checklist

Not run yet. Each step needs your approval because it touches the live install.

1. Open the app normally. Confirm the Daemon page shows the running `dynjectd` processes and the Finder row shows
   Configured + Loaded.
2. In Raw Config, make a no-op edit (for example, add a comment) → Save Only. Expect one administrator prompt, a
   backup in Application Support, and an unchanged owner and mode (`root:wheel 644`).
3. Daemon → Restart Dynject. Expect one prompt, then exactly one `dynjectd` (check with `pgrep -x dynjectd`).
   Any duplicates are gone.
4. Toggle a test app (for example, TextEdit) → Save & Restart → relaunch it → confirm it shows Loaded. Then turn it
   off, Save & Restart, relaunch, and confirm Not loaded.
5. Cancel the password prompt once and confirm nothing was written.
