# Tweak format (version 1)

How a Dynject tweak gets a settings page in Dynject Workbench, and how the tweak reads those settings.
It covers the same ground as iOS's PreferenceLoader and Cephei, with typed and validated settings,
per-app overrides built in, and one storage location per tweak.

A tweak has three parts:

1. **The dylib**, declared in `dynjectd.conf` as usual. Dynject decides *which apps* load it.
2. **A manifest**, `<anything>.workbench.plist`, which describes the settings. Workbench draws the UI from it.
3. **The SDK header**, [`TweakSDK/include/DynjectTweak.h`](../TweakSDK/include/DynjectTweak.h), which the dylib
   uses to read its settings for the app it is running in.

Tweaks without a manifest still work. Workbench just has no settings page for them (you can still link a
plist to them manually).

## Where manifests go

Workbench loads `*.workbench.plist` from, in order:

- `~/Library/Application Support/Dynject Workbench/Tweaks/` (yours, no admin needed)
- `/opt/dynject/lib/tweaks/` (next to installed dylibs)

If two manifests use the same identifier, the first one found wins and the other is reported as a problem.
Use **Tweaks → Reload** after editing a manifest.

`dw tweak install <folder>` (or **Tweaks → Install Tweak…**) puts the manifest in the first folder and the dylib at
its `dylib` path, declares it in the config and enables it for the apps you name, with one password prompt.
`dw new <Name>` starts a tweak folder with a manifest, a source file, `build.sh` and the SDK. See
[TWEAKS.md](../TWEAKS.md#installing-uninstalling-listing).

## Manifest

A property list with a dictionary at the top level. See [`Examples/ExampleTweak.workbench.plist`](../Examples/ExampleTweak.workbench.plist)
(every item type), or [`Examples/TitleBadge`](../Examples/TitleBadge) for a complete working tweak.

| Key | Required | Meaning |
| --- | --- | --- |
| `formatVersion` | yes | `1` |
| `identifier` | yes | Reverse-DNS ID, e.g. `com.you.mytweak`. Letters, digits, `.`, `-`. Also names the storage key. |
| `dylib` | yes | Absolute path of the dylib, matching its `dylib:` line in `dynjectd.conf`. For `dw tweak install`, a `*.dylib` directly in `/opt/dynject/lib/tweaks/` without `:` or spaces. |
| `name` | no | Display name. Defaults to the identifier. |
| `summary`, `version`, `author` | no | Shown in the header. |
| `takesEffect` | no | `live` (the tweak observes changes) or `relaunch` (default). Workbench uses it to tell the user what to do, and offers to relaunch the apps that have the tweak loaded. |
| `applyCommand` | no | Array: absolute executable path plus arguments. Run as the user, with no shell and a 10 s timeout, after each change. Only needed if the tweak must do extra work beyond the notification. |
| `sections` | yes | Array of `{ title?, footer?, items: [item] }`. May be empty when the manifest only declares `appleMenu` items or `bridge` capabilities. |
| `appleMenu` | no | Array of Apple-menu items, added to the Apple menu by MenuLoader. See [Apple menu items](#apple-menu-items-menuloader). |
| `appleMenuPlacement` | no | `shared` (default): the items are one section of the shared "Tweaks" entry. `submenu`: the tweak gets its own entry in the Apple menu. |
| `appleMenuTitle` | no | Title of the tweak's own entry, or of its section in the shared one. Default: `name`. |
| `appleMenuSymbol` | no | SF Symbol name for the tweak's own entry (`submenu` placement). |
| `bridge` | no | Array of capabilities DynjectBridge grants the tweak inside apps the config injects it into: `settings.set`, `notify`, `open:<scheme>`, `pasteboard.write`. Unknown entries and forbidden schemes (`file`, `javascript`, `x-apple*`, `shortcuts`, `tel`, `dynject-workbench`, ...) are errors and skipped; schemes other than `http`, `https` and `mailto` get a warning. See [bridge.md](bridge.md). |

### Items

| Key | Applies to | Meaning |
| --- | --- | --- |
| `type` | all | `switch`, `slider`, `number`, `color`, `choice`, `text`, `appList` |
| `key` | all | Setting name; unique within the manifest. |
| `title`, `footer` | all | Label and help text. |
| `default` | all | Default value. Must fit the type; Workbench publishes it so the tweak sees it too. |
| `perApp` | all | `true` lets the user override this setting per app. |
| `enabledIf` | all | Key of a `switch`; this item is disabled while that switch is off (per app, too). |
| `min`, `max`, `step` | slider, number | Range and step. A slider requires both `min` and `max`. |
| `integer` | slider, number | Store whole numbers. |
| `options` | choice | Array of `{ value, title }`. `value` may be a string, number or boolean. |
| `allowAuto` | color | Also allow the value `"auto"`. |
| `placeholder` | text | Placeholder text. |

Value types: `switch` → boolean; `slider`/`number` → number; `color` → `"#RRGGBB"`, `"#RRGGBBAA"` or `"auto"`;
`choice` → one option's value; `text` → string; `appList` → array of bundle IDs.

Invalid items are skipped and reported. The rest of the manifest still loads.

## Apple menu items (MenuLoader)

MenuLoader is the Apple-menu counterpart of PreferenceLoader. A tweak **declares** items in its manifest, and
one small global tweak, `Tweaks/MenuLoader`, adds them to the Apple menu of every app it is injected into.
No tweak writes menu code. MenuLoader itself is pure infrastructure, like PreferenceLoader: it has no items of
its own. Dynject's own controls (Respring…, Safe Mode…, Open Dynject Workbench) are a group Workbench publishes.

```xml
<key>appleMenu</key>
<array>
  <dict>
    <key>id</key><string>toggle</string>
    <key>title</key><string>Window Tweak</string>
    <key>action</key><string>notify:com.example.windowtweak.toggle</string>
    <key>symbol</key><string>macwindow</string>
    <key>checkedBy</key><string>enabled</string>
  </dict>
</array>
```

| Key | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Unique within the tweak. |
| `title` | yes | Menu item title. |
| `action` | yes | What choosing the item does; see below. |
| `symbol` | no | SF Symbol name for the item's icon (the Apple menu shows small icons). |
| `apps` | no | Array of bundle IDs. The item appears only inside these apps (that is, while one of them is frontmost). Absent = every app. |
| `checkedBy` | no | Key of a `switch` setting of this tweak. The item shows a checkmark while that setting is on, resolved like `DTPrefBool` (per-app override → value → default). Display only: toggling is the action's job. |
| `keyEquivalent` | no | One visible character: not a space, control character or function key (arrows, F-keys, Delete; AppKit's U+F700–U+F8FF and other private-use characters). Use a lowercase letter; see Shortcuts below. |
| `modifiers` | no | Array of `command`, `option`, `shift`, `control`. Only used with `keyEquivalent`. Absent = `command`. Must include `command`. |

Actions:

| Action | Effect |
| --- | --- |
| `notify:<name>` | Posts the Darwin notification `<name>` (allowed from sandboxed apps). Observe it in your tweak or a helper. |
| `url:<absolute URL>` | Opens the URL with NSWorkspace. Any scheme, e.g. `url:dynject-workbench://respring` (the **Dynject ▸ Respring…** item) or `url:dynject-workbench://safemode`. |
| `shortcut:<Shortcut name>` | Opens `shortcuts://run-shortcut?name=<percent-encoded name>`. |
| `app:<bundle ID>` | Launches or activates that app. |

Placement. The contributor (the tweak) chooses, with top-level manifest keys:

```xml
<key>appleMenuPlacement</key><string>submenu</string>   <!-- or shared (default) -->
<key>appleMenuTitle</key><string>Glass</string>          <!-- default: the tweak's name -->
<key>appleMenuSymbol</key><string>sparkles</string>      <!-- own entry's icon, optional -->
```

```
 App Store…
 ───────────────
 Dynject      ▸     Workbench's own group (can be hidden in Workbench)
 Glass        ▸     tweaks with appleMenuPlacement = submenu, by title
 Tweaks       ▸     the shared entry: one section per shared tweak, headed by its title
 ───────────────
 Recent Items ▸
```

- `submenu`: the tweak gets its own entry, "`appleMenuTitle` ▸" with `appleMenuSymbol`, below App Store…. Use it for a
  tweak whose items are its main interface.
- `shared` (default): its items are one section of the shared entry, which the user can rename (default "Tweaks")
  or flatten into sections of the Apple menu itself. With several tweaks in it, each section starts with a header
  showing `appleMenuTitle`; sections are separated either way.
- An entry or section appears only in apps where at least one of its items does (`apps`).
- A bad `appleMenuPlacement` is an error and `shared` applies; an empty `appleMenuTitle` or a non-string
  `appleMenuSymbol` is ignored with an error. The keys without `appleMenu` items get a warning.

Shortcuts. The Apple menu is part of every app's main menu, and AppKit checks it for key equivalents before
the key reaches the focused view. So:

- A shortcut needs `command`. One without it (`modifiers: []`, or only `option`, `shift` and/or `control`)
  would take that key from typing in every app MenuLoader is injected into: a plain letter, an arrow key, an
  Option character (how accented characters, and `@` on some layouts, are typed), or a Control key that text views
  and terminals use (⌃A, ⌃E, ⌃K…). Workbench rejects it with an
  error and drops the shortcut; the item is kept. MenuLoader drops such a shortcut too if it finds one in the list.
- AppKit reads an uppercase letter as Shift plus that letter (`"K"` is ⇧⌘K, not ⌘K). Workbench warns about an
  uppercase key and adds `shift` to its modifiers, so it shows what really works. For a Shift shortcut you may also
  write the lowercase letter plus `shift`; it is published as the uppercase letter with `shift`, the form AppKit
  matches (MenuLoader normalizes hand-written lists the same way).
- The app's own shortcuts win. In an app whose menus already use the same shortcut, AppKit keeps the app's and
  the Apple-menu item shows none. Workbench warns about shortcuts most apps use (⌘Q, ⌘W, ⌘H, ⌘M, ⌘, ⌘N, ⌘O, ⌘S,
  ⌘P, ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A, ⌘F, ⌘G, ⌃⌘F and the like) and those of the Apple menu itself (⌃⌘Q, ⇧⌘Q).
- Two items with the same shortcut (in an app where both appear): the first in published order keeps it, and
  Workbench publishes the later one without a shortcut and shows why on its tweak page.

Validation, reported like other manifest problems: an item without `id`, `title` or a valid `action` (unknown
scheme, empty value, a URL that isn't absolute, a malformed bundle ID), with a duplicate `id`, or with a bad `apps`
list is skipped. A bad `symbol`, `keyEquivalent` or `modifiers`, or a `checkedBy` that isn't a `switch` of this
manifest, is ignored and the item is kept (invalid `modifiers`, or modifiers without `command`, also
drop the `keyEquivalent`, so a shortcut never lands on the wrong keys).

### What Workbench publishes

Workbench combines the items of every loaded manifest, plus its own **Dynject** group, into one key in the global
preferences domain, and posts a Darwin notification after each change:

```
key   dynject.menuloader
value {
  formatVersion: 1,
  items: [ { id, title, action, symbol?, apps?, checkedBy?, checkedByDefault?, keyEquivalent?, modifiers?, tweakID, tweakName }, ... ],
  contributors: [ { tweakID, title, placement: "submenu" | "shared", symbol? }, ... ],
  placement: "submenu" | "section",     // style of the shared entry
  submenuTitle: "Tweaks"                // title of the shared entry
}
notification  dynject.menuloader.changed
```

- `contributors` has one entry per tweak with published items, in Apple-menu order: Workbench's own group
  (`local.dynject.workbench`) first, then the other `submenu` contributors by title, then the `shared` ones by
  title (ties: identifier). `items` follow the same order, in manifest order within a tweak.
- The **Dynject** group (`tweakID` `local.dynject.workbench`, `placement` `submenu`, symbol `puzzlepiece.extension`):
  **Respring…** (`url:dynject-workbench://respring`), **Safe Mode…** (`url:dynject-workbench://safemode`) and
  **Open Dynject Workbench** (`app:local.dynject.workbench`). Workbench's Apple-menu options can hide it. A manifest
  that uses that identifier is ignored.
- `formatVersion` stays 1: `contributors` is an addition. A MenuLoader build that predates it puts every item in
  the shared entry. MenuLoader treats an item whose `tweakID` has no `contributors` entry (a list from an older
  Workbench) as `shared`, titled with its `tweakName`; a `placement` other than `submenu` means `shared`.
- Only valid items are published. Tweaks the user switched off with **Show in Apple menu** are left out.
- Shortcuts are published normalized: `keyEquivalent` is a lowercase letter, or the uppercase letter when
  `modifiers` includes `shift`, and `modifiers` always includes `command` (absent = `command`). An item
  whose shortcut an earlier item already has, in an app where both can appear, is published without one.
- Items with `checkedBy` also carry `checkedByDefault`, the manifest default of that switch. MenuLoader uses it as
  the fallback while the tweak has no settings payload yet, so the checkmark matches what Workbench shows.
- When nothing contributes an item (every tweak and the Dynject group hidden), the key is removed. Treat a missing
  key as "no items".
- The key is rewritten, and the notification posted, only when its content changes: on launch, on **Reload**, and
  when the user changes a tweak's switch, the Dynject group switch, the shared style or the shared title.
- In the Apple menu, after the section that holds "App Store…": one entry per `submenu` contributor, then the
  shared entry: `placement: submenu` (default) is one submenu titled `submenuTitle`, `section` puts the shared
  tweaks' items directly into the Apple menu, a section per tweak. Then MenuLoader's separator before Recent Items.
  An app with no items for it gets nothing.
- Test builds of MenuLoader (`-DML_TEST`) read `dynject.menuloader.test` and listen for
  `dynject.menuloader.test.changed`. Workbench's fixture mode and UI smoke test write that test key into the fixture
  preferences file, never to the global domain.

Workbench reads only manifests. It doesn't know which apps MenuLoader is injected into; that is the Injection page's job.

## Storage and delivery (what the SDK reads)

Workbench writes a single key into the user's **global preferences domain**. That domain is readable from
inside sandboxed apps, which is where an injected tweak runs:

```
key   dynject.tweak.<identifier>
value {
  formatVersion: 1,
  values:   { <key>: <value>, ... },                  // settings the user changed
  perApp:   { <bundleID>: { <key>: <value> }, ... },  // per-app overrides
  defaults: { <key>: <default>, ... }                 // from the manifest
}
```

After every write, Workbench posts the Darwin notification `dynject.tweak.<identifier>.changed`.

Inside a given app, a value resolves in this order: `perApp[<the app's bundle ID>][key]`, then `values[key]`,
then `defaults[key]`, then the fallback the tweak passes. Bundle IDs are the real ones
(`[[NSBundle mainBundle] bundleIdentifier]`, e.g. `com.apple.finder`), *not* Dynject's XPC service names.

Keys Workbench doesn't recognise are left alone, so a tweak can rename settings across versions without losing data.
Removing a tweak's settings only requires deleting its one key (`dw tweak uninstall` keeps it).

## SDK

```objc
#import "DynjectTweak.h"
static NSString *const kID = @"com.you.mytweak";

if (DTPrefBool(kID, @"enabled", YES)) {
    CGFloat r = DTPrefDouble(kID, @"radius", 8);
    NSString *accent = DTPrefString(kID, @"accent", @"auto");   // "#RRGGBB", "#RRGGBBAA" or "auto"
    NSArray *excluded = DTPrefList(kID, @"exclude");
}

// takesEffect = live: re-read and redraw when the user changes something.
DTPrefObserve(kID, nil, ^{ /* re-apply */ });
```

`DTPrefValue` / `DTResolve` / `DTPayloadInDomain` give raw access. Each read synchronizes preferences first, so
a value read after the notification is current. Live updates in an app that already has a stale preferences cache
are best-effort; a relaunch always picks up the latest values.

## How Workbench behaves

- **Saving:** changes are written as you make them, about 0.3 s after you stop adjusting, then the
  notification is posted and `applyCommand` runs.
- **Revert Session:** the first change in a session snapshots the previous payload (also saved under
  `Backups/tweaks/`). **Revert Session** restores it.
- **Per-app overrides:** each app's detail pane has a "<Tweak> for <App>" panel. Ticking a setting there starts
  an override at the current value. The panel says when the dylib isn't injected into that app.
- **Restarting Dynject:** changing a tweak's settings never touches `dynjectd.conf` and never needs a restart.
  Which apps load the tweak is still decided by the Injection page.
- **Apple menu:** a tweak that declares `appleMenu` items gets an "Apple menu" section listing them, with a
  **Show in Apple menu** switch (on by default, kept in Workbench's own preferences) and says where the items go.
  The Apple-logo button under the tweak list shows or hides the **Dynject** group and sets the shared entry's style
  (submenu or section) and title.

## Not in version 1

The format leaves room for these later: suggested injection targets, settings presets (export/import), and image
settings. (Installing and uninstalling tweaks needs nothing in the format: `dw tweak install|uninstall` use the
`identifier` and `dylib` keys.) Safe mode after crashes
exists outside the format: see [safe-mode.md](safe-mode.md).
