# SettingsLoader

The System Settings counterpart of iOS's PreferenceLoader. Every installed tweak whose manifest has settings gets
a native page in System Settings, under **Tweaks** at the bottom of the sidebar. The pages are drawn from the same
manifests as Workbench's tweak pages, with the same controls, and they save the same way. System Settings' own header
works on them: the title, and back and forward through its history, the way they work on Apple's panes. No tweak
writes settings UI. SettingsLoader is pure infrastructure: it has no settings of its own.

```
 Sidebar          Tweaks                             ‹ ›  MenuLoader
 …                ┌────────────────────────────┐          ┌────────────────────────────────┐
 Printers         │  🧩  Tweaks                 │          │ 🧩 MenuLoader                   │
                  │  Settings for the Dynject   │          │    Version 1.1.0 · …            │
 🧩 Tweaks        │  tweaks installed on this…  │          ├ Apple Menu ─────────────────────┤
                  ├─────────────────────────────┤   ──▶    │ Show tweak items …         [on] │
                  │ 🧩 Inspector              › │          │ Shared menu style  [segmented]  │
                  │ 🧩 MenuLoader             › │          └────────────────────────────────┘
                  └─────────────────────────────┘
```

## Install

From the repo root (macOS 27, tested on 27.2):

    Tweaks/SettingsLoader/build.sh
    dw tweak install Tweaks/SettingsLoader --for com.apple.systempreferences
    Tweaks/SettingsLoader/build.sh register
    dw respring com.apple.systempreferences

`register` copies `build/SettingsLoader.app` to `~/Library/Application Support/Dynject Workbench/SettingsLoader/` and
registers the Settings extension inside it (`pluginkit -a`, as you, no password). The app and the extension are
stubs that never run: the extension only gives System Settings a sidebar entry to show. To remove everything:

    dw tweak uninstall local.dynject.settingsloader
    Tweaks/SettingsLoader/build.sh unregister

## For tweak authors

Nothing to do. A manifest with settings (`sections`, see [docs/tweak-format.md](../../docs/tweak-format.md)) gets
a page. Changes are saved like Workbench saves them: the settings payload in the global preferences domain, the
`dynject.tweak.<id>.changed` notification, then the manifest's `applyCommand` if it has one. `DTPref*` and
`DTPrefObserve` read them as usual. Per-app overrides aren't shown; the page says when a tweak has some and leaves
them to Workbench.

## How it works

System Settings on macOS 27 builds its pages from Settings extensions (ExtensionKit) and shows each one in an
`_EXHostViewController`, which runs the extension in its own process. SettingsLoader is injected into System Settings
and:

- **Sidebar.** System Settings leaves third-party extensions out of its sidebar. SettingsLoader yields a copy of the
  sidebar's extensions snapshot with its own extension added, through the provider's own stream, and adds it again
  whenever a new snapshot drops it (checked every 3 seconds and whenever a page starts showing).
- **Page.** When the host controller is set to the Tweaks extension, SettingsLoader turns hosting off (the stub never
  starts) and puts its own SwiftUI page over the host's placeholder. System Settings keeps one host controller and
  sets it to each pane in turn; when it moves on, the page is taken out.
- **Navigation.** Each extension has a coordinator in System Settings. Apple's pages tell it about a push with
  `navigationStackDidChange:` and a `Settings.NavigationToken`; SettingsLoader builds the same tokens, so pushes
  go into the window's history and set the header's title. Back and forward reach the page as
  `setNavigationWithPath:` on the coordinator's `_extensionUIProxy`, where SettingsLoader installs its own object.
  When back or forward leads from another pane into one of these pages, the history manager's `_targetItem` says
  which page to show.

It relies on System Settings internals (Swift properties read with `Mirror`, the coordinator's Objective-C methods,
the snapshot's layout). The manifest's `requires` lists them, so `dw doctor --apis` says when a macOS update moves
them; when one is missing, SettingsLoader stays out of the way (no sidebar entry, or System Settings' own blank page) and logs what it could not find. `dw log local.dynject.settingsloader` shows its log.

## Limits

- Per-app overrides are left to Workbench.
- One level of pages: the Tweaks list, then a tweak's page.
- The dylib is about 8 MB: it carries Workbench's DynjectCore for three architectures.
- If the Tweaks extension isn't registered, there's no sidebar entry and the log says to run `build.sh register`.
