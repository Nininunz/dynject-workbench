# Title Badge

A proof-of-concept tweak for the [Workbench tweak format](../../docs/tweak-format.md). It adds a small badge to
the titlebar of every titled window. It uses only public AppKit API (`NSTitlebarAccessoryViewController`),
with no method swizzling.

It uses every part of the SDK: a switch, text, choice, color (with Auto), slider and app list; per-app
overrides; and live updates via `DTPrefObserve`. It logs what it applied to the unified log:

```sh
/usr/bin/log show --last 5m --predicate 'subsystem == "local.dynject.titlebadge"' --style compact
```

## Build and test (no Dynject involved)

```sh
./build.sh        # build/libTitleBadge.dylib (x86_64, arm64, arm64e; ad-hoc signed)
./build.sh test   # also runs a local test app with DYLD_INSERT_LIBRARIES
```

The test app writes the tweak's settings key the way Workbench does, then checks three things: the badge
appears at launch, a live change with a per-app override takes effect, and switching it off removes the badge.
It saves and restores any existing settings for this tweak.

## Install (live; needs administrator rights)

1. Copy `build/libTitleBadge.dylib` to `/opt/dynject/lib/tweaks/`.
2. Copy `TitleBadge.workbench.plist` to `~/Library/Application Support/Dynject Workbench/Tweaks/`.
3. In Workbench → Raw Config, add `dylib:/opt/dynject/lib/tweaks/libTitleBadge.dylib:deny`. Then turn it on
   for an app on the Apps & Injection page → Save & Restart → relaunch that app.
4. Change its settings under **Tweaks → Title Badge**, or per app in the app's detail pane. Changes apply live.
