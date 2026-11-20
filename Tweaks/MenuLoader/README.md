# MenuLoader

The Apple-menu counterpart of iOS's PreferenceLoader. Tweaks **declare** items for the Apple menu () in
their Workbench manifest, and this one small global tweak adds them to the Apple menu of every app it is
injected into. No tweak writes menu code. MenuLoader is pure infrastructure: it has no items of its own.

```
 About This Mac
 ───────────────
 System Settings…
 App Store…
 ───────────────
 Dynject            ▸   (Respring…, Safe Mode…, Open Dynject Workbench: Workbench's own group)
 Glass              ▸   (a tweak with appleMenuPlacement = submenu)
 Tweaks             ▸   GLASS CALCULATOR
 ───────────────        Glass Calculator   ✓
 Recent Items       ▸   Open Tweak Website ⌥⌘K
 …                      ──────────────────
                        CLEANUP
                        Run Cleanup Shortcut
```

## For tweak authors

Add an `appleMenu` array to your manifest (`*.workbench.plist`); the full format is in
[docs/tweak-format.md](../../docs/tweak-format.md). Where the items go is your choice, with three optional
top-level keys:

```xml
<key>appleMenuPlacement</key><string>submenu</string>   <!-- own "Title ▸" entry; default shared -->
<key>appleMenuTitle</key><string>Glass</string>          <!-- default: the tweak's name -->
<key>appleMenuSymbol</key><string>sparkles</string>      <!-- own entry's icon, optional -->
```

`shared` (the default) makes your items one section of the shared entry ("Tweaks" unless the user renamed it, or a
flat section of the Apple menu), headed by your title when other tweaks share it too. `submenu` gives the tweak its
own entry below App Store…, for tweaks whose items are their main interface.

```xml
<key>appleMenu</key>
<array>
  <dict>
    <key>id</key><string>toggle</string>
    <key>title</key><string>Glass Calculator</string>
    <key>action</key><string>notify:com.you.glass.toggle</string>   <!-- or url:, shortcut:, app: -->
    <key>symbol</key><string>sparkles</string>                     <!-- SF Symbol, optional -->
    <key>checkedBy</key><string>enabled</string>                   <!-- a switch of your manifest, optional -->
    <key>apps</key><array><string>com.apple.calculator</string></array>   <!-- optional; default every app -->
    <key>keyEquivalent</key><string>g</string>                     <!-- optional -->
    <key>modifiers</key><array><string>option</string><string>command</string></array>
  </dict>
</array>
```

| Action | What MenuLoader does (on the main thread, in the app the menu belongs to) |
| --- | --- |
| `notify:<name>` | `notify_post(name)`: a Darwin notification your tweak (or a helper) observes. Works from sandboxed apps. |
| `url:<absolute URL>` | `NSWorkspace openURL:` |
| `shortcut:<name>` | Opens `shortcuts://run-shortcut?name=<name>` (percent-encoded like Workbench: query characters minus `&=+?#/`). |
| `app:<bundle ID>` | Finds the app with `URLForApplicationWithBundleIdentifier:` and opens/activates it with `openApplicationAtURL:`. |

`checkedBy` is display only: the item shows a checkmark while that setting is on for the current app (same
resolution as `DTPrefBool`: per-app override, value, default). Toggling is the action's job, e.g. your tweak
observes the notification and Workbench changes the setting. Checkmarks update live when your tweak's settings
change (`dynject.tweak.<id>.changed`).

## What Workbench publishes, what MenuLoader reads

Workbench collects every manifest's `appleMenu` items, adds its own **Dynject** group, and writes them to the
global preferences key `dynject.menuloader` (readable from sandboxed apps), then posts `dynject.menuloader.changed`:

```
{ formatVersion: 1,
  items: [ { id, title, action, symbol?, apps?, checkedBy?, checkedByDefault?, keyEquivalent?, modifiers?, tweakID, tweakName }, … ],
  contributors: [ { tweakID, title, placement: "submenu" | "shared", symbol? }, … ],
  placement: "submenu" | "section",     // the shared entry's style, default "submenu"
  submenuTitle: "Tweaks" }              // the shared entry's title, default "Tweaks"
```

The Dynject group is contributor `local.dynject.workbench` (`submenu`, `puzzlepiece.extension`): **Respring…**
(`url:dynject-workbench://respring`, Workbench's Respring sheet, see [docs/respring.md](../../docs/respring.md)),
**Safe Mode…** (`url:dynject-workbench://safemode`, Workbench's Safe Mode page) and **Open Dynject Workbench**
(`app:local.dynject.workbench`). Workbench's Apple-menu options (the Apple-logo button under the tweak list) hide it.

`contributors` was added without changing `formatVersion`: an older MenuLoader ignores it and puts everything in
its one submenu, and this MenuLoader treats an item without a `contributors` entry (an older Workbench's list) as
`shared`, titled with its `tweakName`. A `placement` other than `submenu`, or an invalid contributor entry, means
`shared`.

MenuLoader skips invalid items (missing `id`/`title`/`action`/`tweakID`, unknown action scheme, duplicates) and
items whose `apps` don't include the current app, and ignores a list whose `formatVersion` is not 1.
It re-checks every shortcut, since the key can be hand-edited or written by an older Workbench, and drops (keeping
the item) one that isn't a single visible character, is a function key (U+F700–U+F8FF or other private use), or
lacks Command: the Apple menu is checked for key equivalents in every app before the focused view gets the key, so
a bare key, Shift+key, Option+key or Control+key (⌃A, ⌃E, ⌃K in text views and terminals) shortcut would take that
key from typing everywhere. A Shift
letter is installed as the uppercase letter with Shift (AppKit matches `"j"` with a Shift mask as plain ⌘J), and of
two items with the same shortcut the first keeps it.
A checkmark falls back to `checkedByDefault` (the switch's manifest default) while the tweak has no settings
payload, so it matches what Workbench shows.

Layout, in one block right after the section that holds App Store…, followed by a separator (then Recent Items):

1. one entry per `submenu` contributor that has items for this app, "`title` ▸" with its `symbol`, in published
   order (Workbench publishes the Dynject group first, then by title);
2. the shared entry, if any shared contributor has items for this app:
   - **submenu**: one item, `submenuTitle` with the `puzzlepiece` symbol; inside it a section per contributor,
     separated, each headed by an AppKit section header (`+[NSMenuItem sectionHeaderWithTitle:]`) with the
     contributor's title when there is more than one;
   - **section**: the shared items directly in the Apple menu, a section per contributor (separators between them
     and after the own entries; no headers).
3. Nothing for this app (or MenuLoader switched off): nothing is inserted, not even a separator.

Since macOS 27 AppKit hides menu-item images by default; MenuLoader marks items that declare a `symbol`
`preferredImageVisibility = .visible`, as AppKit does for About This Mac and App Store….

## MenuLoader's own settings

`MenuLoader.workbench.plist` (identifier `local.dynject.menuloader`, takes effect live). It declares no Apple-menu
items (up to version 1.0 it carried **Respring…**, now in Workbench's Dynject group). Copy the updated manifest to
`~/Library/Application Support/Dynject Workbench/Tweaks/` (`dw tweak install Tweaks/MenuLoader` does it) so Workbench
stops publishing the old item.

| Key | Type | Meaning |
| --- | --- | --- |
| `enabled` | switch, per app | Off removes everything MenuLoader adds (the Dynject group too), live. |
| `placement` | choice, per app | Style of the shared entry: `auto` (use what Workbench publishes), `submenu`, `section`. Own entries are unaffected. |
| `submenuTitle` | text | Title of the shared entry. Empty: use the published title. |
| `diagnostics` | switch | Logs the item list and the resulting Apple menu after each change. |

## How it works

AppKit builds the Apple menu inside every app, as an instance of the private class `_NSAppleMenu` (an `NSMenu`
that is its own delegate). It is filled lazily: the first time the menu is opened *or a key equivalent is
checked*, NSMenu's populate path calls `-[_NSAppleMenu updateMenu:withEvent:withFlags:]`, which calls
`-_addAppleMenuItems` **only while the menu has no items**. So the items are built once per process, and every
later open just updates titles and visibility (Force Quit "<App>", Log Out "<User>", Location, Recent Items).
This was measured in the test host on macOS 27.2 (instrumented hooks, and AppKit's disassembly shows the
`numberOfItems == 0` test).

MenuLoader hooks both methods with a DynjectHook hook class:

- after `-_addAppleMenuItems`: remove MenuLoader's items, insert the current ones;
- after `-updateMenu:withEvent:withFlags:` for the Apple menu itself (it is also the delegate of its Location
  and Recent Items submenus): a cheap check, a generation counter and one `indexOfItemWithTag:`, that rebuilds
  only if the items are missing or out of date.

Every item MenuLoader adds to the Apple menu (items, submenu items, separators) carries the tag `'dmlr'`, so a rebuild removes
exactly MenuLoader's items first: they are present once whether AppKit builds the menu once or many times.
MenuLoader never inserts into an empty Apple menu, because AppKit only adds its own items to an empty one.

The list and settings are read lazily, on the first build, and again after `dynject.menuloader.changed` or
MenuLoader's settings notification. Opening the menu costs nothing beyond that check. If `_NSAppleMenu` or one
of the two methods is missing, MenuLoader logs one line and does nothing. Everything runs on the main thread,
and no exception leaves a hook or an action.

Logs: `log stream --level default --predicate 'subsystem == "local.dynject.menuloader"'`.

## Build

```sh
./build.sh           # build/libMenuLoader.dylib (x86_64, arm64, arm64e; ad-hoc signed; 0 exported symbols)
./build.sh test      # build/test/libMenuLoader.dylib, compiled with -DML_TEST (below)
./build.sh install   # prints the install steps; runs nothing
```

`-DML_TEST` changes: published key `dynject.menuloader.test`, notification `dynject.menuloader.test.changed`,
tweak ID `local.dynject.menuloader.test`; all settings payloads (MenuLoader's and those `checkedBy` reads) come
from the preferences domain `local.dynject.menuloader.testprefs` instead of the global domain, so tests never
touch real `dynject.tweak.*` keys; `url:`/`shortcut:` log the URL instead of opening it and `app:` logs the bundle
ID instead of launching. `notify:` really posts. It also prints each rebuilt Apple menu and action to stderr.

## Test (no Dynject involved)

```sh
testhost/run.sh
```

Builds the test dylib, an AppKit test host (`local.dynject.menuloader.testhost`, accessory app: it never takes
focus) and `mltool` (the "Workbench side" in a separate process: publishes the test list, writes test settings,
observes notifications), then runs the host with `DYLD_INSERT_LIBRARIES`. The host drives AppKit's real populate
path on its own `_NSAppleMenu` and inspects the menu object: placement, the order of own entries (a Dynject group
listed after shared items still comes first) and the shared entry, contributor titles and symbols, section headers,
titles, icons, checkmarks, separators, app filtering (incl. an own-entry contributor with nothing for this app),
invalid items and contributor entries, a list without `contributors` (older Workbench), live list changes,
style/title overrides, enabled off/on (incl. per-app), an AppKit rebuild from scratch, and every action type,
the Dynject group's `dynject-workbench://` links and `app:` included (the `notify:` one is received by another
process; the ⌥⌘K key equivalent fires through the Apple menu). A second, sandboxed copy of the host
(`local.dynject.menuloader.testhost.sandboxed`, app-sandbox entitlement) checks that the list is readable and a
`notify:` action gets out of the sandbox. Test keys are deleted at the end.

`ML_SHOT=<dir>` makes the host pop up a copy of its populated Apple menu (and of MenuLoader's first entry) whose items do
nothing, and capture it.

## Install

`dw tweak install Tweaks/MenuLoader --for <bundleID>` (or Workbench → Tweaks → Install Tweak…) copies the dylib to
`/opt/dynject/lib/tweaks/`, declares it in `dynjectd.conf` (`dylib:/opt/dynject/lib/tweaks/libMenuLoader.dylib:deny`),
enables it for each `--for` app and restarts dynjectd under one password prompt, then copies the manifest to
`~/Library/Application Support/Dynject Workbench/Tweaks/`. Turn it on for more apps on the Apps & Injection page (or
make it `:allow` for every app in the raw config), and relaunch the apps (`dw respring`). `./build.sh install` prints
the manual steps.
