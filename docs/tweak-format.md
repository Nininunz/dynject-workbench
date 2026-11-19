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

## Manifest

A property list with a dictionary at the top level. See [`Examples/ExampleTweak.workbench.plist`](../Examples/ExampleTweak.workbench.plist)
(every item type), or [`Examples/TitleBadge`](../Examples/TitleBadge) for a complete working tweak.

| Key | Required | Meaning |
| --- | --- | --- |
| `formatVersion` | yes | `1` |
| `identifier` | yes | Reverse-DNS ID, e.g. `com.you.mytweak`. Letters, digits, `.`, `-`. Also names the storage key. |
| `dylib` | yes | Absolute path of the dylib, matching its `dylib:` line in `dynjectd.conf`. |
| `name` | no | Display name. Defaults to the identifier. |
| `summary`, `version`, `author` | no | Shown in the header. |
| `takesEffect` | no | `live` (the tweak observes changes) or `relaunch` (default). Workbench uses it to tell the user what to do, and offers to relaunch the apps that have the tweak loaded. |
| `applyCommand` | no | Array: absolute executable path plus arguments. Run as the user, with no shell and a 10 s timeout, after each change. Only needed if the tweak must do extra work beyond the notification. |
| `sections` | yes | Array of `{ title?, footer?, items: [item] }`. |

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
Uninstalling a tweak only requires deleting its one key.

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

## Not in version 1

The format leaves room for these later: suggested injection targets, tweak install/uninstall (dylib + manifest
into `/opt/dynject/lib/tweaks/`), safe mode after repeated crashes, settings presets (export/import), and image settings.
