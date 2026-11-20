# Title Badge

A proof-of-concept tweak for the [Workbench tweak format](../../docs/tweak-format.md). It adds a small badge to
the titlebar of every titled window. It uses only public AppKit API (`NSTitlebarAccessoryViewController`),
with no method swizzling.

It uses every part of the SDK: a switch, text, choice, color (with Auto), slider and app list; per-app
overrides; and live updates via `DTPrefObserve`. It starts through DynjectHook's `DH_CTOR` (tweak ID
`local.dynject.titlebadge`, every app), so it honours Safe Mode: it does not load where `dynject.safemode` lists it
or `"*"` for the app, or while Shift is held at launch (see [Hooking](../../docs/hooking.md#entry-point-and-load-policy-dh_ctor)). It logs what it applied to the unified log:

```sh
/usr/bin/log show --last 5m --predicate 'subsystem == "local.dynject.titlebadge"' --style compact
```

## Build and test (no Dynject involved)

```sh
./build.sh        # build/libTitleBadge.dylib (x86_64, arm64, arm64e; ad-hoc signed; includes DynjectHook.m)
./build.sh test   # also runs a local test app with DYLD_INSERT_LIBRARIES
```

The test app writes the tweak's settings key the way Workbench does, then checks three things: the badge
appears at launch, a live change with a per-app override takes effect, and switching it off removes the badge.
It saves and restores any existing settings for this tweak.

## Install (live; needs administrator rights)

1. `dw tweak install Examples/TitleBadge --for com.apple.calculator` (or Workbench → Tweaks → Install Tweak…): one
   password prompt copies `build/libTitleBadge.dylib` to `/opt/dynject/lib/tweaks/`, adds
   `dylib:/opt/dynject/lib/tweaks/libTitleBadge.dylib:deny` and an override for that app to the config and restarts
   dynjectd; the manifest goes to `~/Library/Application Support/Dynject Workbench/Tweaks/`.
2. Relaunch the app (`dw respring`).
3. Change its settings under **Tweaks → Title Badge**, or per app in the app's detail pane. Changes apply live.
