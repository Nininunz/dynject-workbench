# Dynject Workbench (the app)

A native macOS app for managing the installed Dynject injection engine:

- See which installed apps each configured dylib applies to, and why.
- Turn a configured dylib on or off for one app. The edit is minimal and leaves unrelated config lines alone.
- Edit the whole `dynjectd.conf` as raw text, with diagnostics based on dynjectd's own parser.
- Edit any property list as XML. It is validated, backed up, and saved in its original on-disk format.
- Restart `dynjectd` safely: exactly one daemon, never duplicates.
- Give tweaks a settings page (similar to iOS's PreferenceLoader): a tweak ships a small manifest, and Workbench
  draws its settings, with per-app overrides. See [tweak-format.md](tweak-format.md).
- Let tweaks add items to the Apple menu by declaring them in that manifest (MenuLoader). See
  [Tweaks/MenuLoader](../Tweaks/MenuLoader/README.md).
- Respring: relaunch the running apps whose tweaks no longer match the config, then check them with `lsof`, from
  `dw respring`, Workbench's Respring sheet or the Apple menu's **Dynject ▸ Respring…**. See [respring.md](respring.md).
- Install a built tweak folder in one step (dylib, config, restart: one password prompt), uninstall it again, and start
  a new tweak from a template: `dw tweak install|uninstall|list`, `dw new`, or **Tweaks → Install Tweak…**. See
  [TWEAKS.md](../TWEAKS.md).
- Safe Mode: install the crash watcher, flip the panic switch, see and re-enable what was turned off. See
  [safe-mode.md](safe-mode.md).
- Bridge: install the DynjectBridge agent, which does a few declared things for tweaks in sandboxed apps, and see
  what it allowed and denied. See [bridge.md](bridge.md).

It manages the existing engine at `/opt/dynject` ([dynject](https://github.com/ut0mt8/dynject) by ut0mt8, installed
separately). It is not an injector, not a theme UI, and not a binary/hex editor.

Launched normally, the app reads the **live** paths (`/opt/dynject/etc/dynjectd.conf`,
`/opt/dynject/log/dynjectd.log`). Nothing is written until you click Save in the review sheet. For fixture mode
(`-DWConfigPath` and friends) see [HACKING.md](../HACKING.md#fixture-mode-and-isolation).

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

**Dylibs → Add Dylib…** declares a newly installed dylib in the config (deny by default); **Tweaks → Install Tweak…**
(or `dw tweak install`) does the whole install.

## Writing protected files and restarting

- Before every write, the current file is backed up to `~/Library/Application Support/Dynject Workbench/Backups/`.
- Writable files are replaced atomically (temp file in the same directory, fsync, rename) and keep their permissions.
- Protected files (the live config is `root:wheel 644`) go through `osascript … with administrator privileges`.
  The only code that runs as root is [`HelperScript.swift`](../Sources/DynjectCore/HelperScript.swift), passed
  inline to `/bin/sh -c`, so there is no script file on disk to tamper with. The helper:
  refuses to write if the target changed since you loaded it (SHA-256), copies the staged file into root-owned space,
  checks its hash again (so a swapped staged file is rejected), keeps the owner and mode, and renames atomically.
- **Restart.** The launchd job runs `dynject_loader`, which spawns a *detached* `dynjectd` and exits. launchd
  then reports the job as "not running", so `launchctl kickstart -k` cannot stop the old daemon, and every kickstart
  adds another one. The helper instead waits for any running loader to finish, sends SIGTERM to **every** `dynjectd`
  (SIGKILL after 5 s), aborts if any survive, starts the job **once** (`kickstart` without `-k`, or `bootstrap`
  if it isn't loaded), confirms that exactly one daemon is running, and stops extras if two appeared.
  Save & Restart does the write and the restart under a single password prompt.
- **Several files, one prompt.** The helper takes a list of operations (`install` a file, `remove` a tweak dylib)
  and an optional `restart`. It checks all of them first (conflict hashes; a removal must be a regular `*.dylib`
  directly in a real, root-owned `/opt/dynject/lib/tweaks`, not a symlink), stages and verifies every new file next
  to its target, and only then renames and removes, so a failed check writes nothing. Tweak install and uninstall use
  this.
- **One password for a while.** The first privileged step also opens an approval window: a small root server, started
  by that prompt, that runs the helper for later tweak-install steps (write `dynjectd.conf`, install or remove a plain
  `*.dylib` in `/opt/dynject/lib/tweaks`, restart dynjectd) without asking again, until it has been idle for 5 minutes
  (at most an hour). It checks that a request is one of those; anything else (the plist editor's protected files)
  asks for the password as before. Workbench and `dw` share it. While it's open, any program running as you could ask
  it for those steps too. `dw auth status` shows it, `dw auth end` closes it, `DW_NO_AUTH_WINDOW=1` turns it off for
  `dw`. Details: HACKING.md, `PrivilegedSession.swift`.

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

## Tweaks page

A tweak with a manifest is listed under **Tweaks**. Workbench draws native controls (switch, slider, number, color,
choice, text, app list) and adds a "<Tweak> for <App>" panel with per-app overrides to each app's detail pane.
Changes save instantly (snapshot first, **Revert Session** to undo). Workbench then posts `dynject.tweak.<id>.changed`
and runs the tweak's optional apply command. Details: [tweak-format.md](tweak-format.md#how-workbench-behaves).

A tweak that declares `appleMenu` items gets an "Apple menu" section with a **Show in Apple menu** switch. Workbench
publishes the combined list for MenuLoader, with its own **Dynject ▸** group first: Respring…, Safe Mode…
(`dynject-workbench://safemode`) and Open Dynject Workbench; the Apple-logo button under the tweak list hides it and
sets the shared entry's style and title. Workbench warns about common app shortcuts and drops a shortcut an earlier
item already has.

**Tweaks → Install Tweak…** (choose a folder or manifest, pick apps, review the changes, then one prompt) and
**Uninstall…** in a tweak's header (lists what will be removed; option to keep the file) use the same code as
`dw tweak`.

## Safe Mode page

Installs or removes the watcher, has the panic switch, lists what is disabled where and why (with the crash report
and Re-enable), shows recent tweak-related crashes and which tweaks support Safe Mode, and offers "Disable in
Config…" (the usual review, save and restart) for tweaks that ignore it. See [safe-mode.md](safe-mode.md#the-workbench-panel).

## Bridge page

Installs or removes the bridge agent (`local.dynject.bridge`), says whether its token is published, lists the tweaks
that declare bridge capabilities and the broker's last 100 decisions with their reasons. A tweak's page has a Bridge
section with its capabilities and recent decisions, and Install Tweak's review lists the capabilities. When a tweak
changes its settings through the bridge, an open settings page re-reads them (unless it has an unsaved change).
See [bridge.md](bridge.md#workbench).

## Respring sheet

The sidebar footer shows how many running apps are pending; it and the toolbar's **Respring…** open a sheet listing
them with their reasons and checkboxes (excluded apps start unchecked, with a note), a quit timeout,
**Respring Selected**, live progress and a result per app. The count refreshes when the config is saved, dynjectd is
restarted, Safe Mode changes, apps launch or quit, the config or a tweak dylib changes on disk, and on demand.
The link `dynject-workbench://respring` (registered in `Resources/Info.plist`) opens the same sheet. A link never
relaunches anything: only the button does. `dynject-workbench://safemode` shows the Safe Mode page.
See [respring.md](respring.md#in-workbench).
