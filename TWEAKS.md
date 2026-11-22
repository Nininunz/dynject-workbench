writing tweaks
==============

for people writing tweaks. you know objective-c and you know what a dylib is.
references: docs/hooking.md, docs/tweak-format.md, docs/safe-mode.md, docs/respring.md,
docs/bridge.md.
working examples: Examples/TitleBadge (settings, no swizzling), Examples/OLEDFinder (hook
classes on appkit views, one app, no settings) and Tweaks/MenuLoader (hooks a private appkit
class, listens for notifications). Tweaks/Inspector looks inside an app while you write one.


the loop
--------

    dw new WindowTitles --app com.apple.TextEdit     # folder with source, manifest, build.sh, sdk/
    cd WindowTitles && ./build.sh                    # build/libWindowTitles.dylib
    ./build.sh test                                  # its test host: checks it in a local app, nothing installed
    dw tweak install . --for com.apple.TextEdit      # one password prompt
    dw respring                                      # or workbench -> respring...
    dw log local.windowtitles 10                     # last 10 minutes of its log

or let `dw dev` do the loop: from the tweak folder, `dw dev` (add `--for <bundleID>` the
first time) builds, runs the test host, installs, relaunches the app and shows the log,
then does it again every time you save. a failed build or test installs nothing. by hand:
change code, `./build.sh test`, `dw tweak install .` again, `dw respring`. a rebuild only
replaces the dylib (old one backed up) and doesn't restart dynjectd. add `--dry-run`
to install/uninstall to see the plan first.

`dw new <Name> [--id <reverse.dns.id>] [--app <bundleID>] [--dir <path>] [--sdk <dir>]`.
the id defaults to `local.<name>`; pass `--id com.you.name` for anything you share.
dw finds the sdk in the app bundle (`Contents/Resources/TweakSDK`, put there by
`scripts/build-app.sh`), or, run from `.build`, in this repo's `TweakSDK/`.


anatomy of a tweak folder
-------------------------

what `dw new` gives you:

    WindowTitles/
      WindowTitles.m                  DH_CTOR with the --app bundle filter, a hook class on
                                      -[NSWindow setTitle:] using DH_ORIG, an Enabled setting
                                      bound to a hook group via DTPrefBool + DTPrefObserve, os_log
      WindowTitles.workbench.plist    manifest: id, install path, version 0.1.0, settings
      build.sh                        universal (x86_64 arm64 arm64e), ad-hoc or SIGN_IDENTITY,
                                      fails if anything is exported. `./build.sh test` also builds a
                                      test copy (-DTWEAK_TEST: tweak id <id>.test, so it never
                                      touches your settings, and the host's bundle id added to
                                      DH_CTOR) and runs testhost/ with it injected
      testhost/TestHost.m             the test host: an accessory app whose steps set the title,
                                      switch the setting off live and back on per app, and check
                                      the result. change the steps when you change the tweak
      README.md
      sdk/                            copies of DynjectHook.h, DynjectHook.m, DynjectTweak.h
      build/                          output, gitignored

the folder builds on its own. `dw tweak install` wants the manifest plus the built
dylib, either in `build/` or next to the manifest (or name it with `--dylib`).


manifest essentials
-------------------

`<anything>.workbench.plist`, full format in docs/tweak-format.md. the keys that matter:

    formatVersion   1
    identifier      com.you.tweak. names the settings key and the safe mode entry.
    dylib           /opt/dynject/lib/tweaks/libYourTweak.dylib. must be a *.dylib directly
                    in /opt/dynject/lib/tweaks, no ':' or spaces, for dw tweak install.
    name, summary, author
    version         semver: 1.2.0, 2.0.0-beta.1. see below.
    minimumSystemVersion   "27.0". installs refuse below it.
    testedSystemVersions   "27.0 - 27.2" or "27.2". installs warn outside it.
    depends         other tweaks ("com.you.lib >= 1.1.0"), "bridge", "safemode".
    takesEffect     live (you observe changes) or relaunch (default)
    sections        settings ui. may be empty if you only add apple-menu items.
    appleMenu       apple-menu items, see below.
    bridge          what the bridge may do for it, see below.
    requires        private classes, methods, functions it needs, see below.

workbench validates manifests with the same parser as dw and MenuLoader. errors
refuse an install; bad items are skipped and reported.

declare what you need from macos in `requires`, so `dw doctor --apis` can tell your
users when a macos update breaks your tweak, before they go hunting:

    <key>requires</key>
    <array>
      <dict>
        <key>class</key><string>_NSAppleMenu</string>
        <key>image</key><string>AppKit</string>
        <key>methods</key><array><string>-_addAppleMenuItems</string></array>
      </dict>
      <dict>   <!-- a class in an app's executable: can't be loaded, so look for its name -->
        <key>string</key><string>TBrowserWindow</string>
        <key>image</key><string>/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder</string>
      </dict>
      <dict>
        <key>symbol</key><string>sandbox_extension_consume</string>
        <key>image</key><string>libsystem_sandbox</string>
        <key>optional</key><true/>   <!-- missing turns a feature off, nothing breaks -->
      </dict>
    </array>

list what you hook or look up by name, not public api. `<array/>` says "nothing private".
the bridge's own spi is checked for you when you declare `bridge`. try it before you
install: `dw doctor --apis --tweaks-dir .`. format: docs/tweak-format.md#requirements.


versions, macos and dependencies
--------------------------------

`version` is semver, `MAJOR.MINOR.PATCH[-prerelease]`. anything else is a warning, and
then install can't tell an upgrade from a downgrade. bump it every release you hand to
someone: patch for fixes, minor for anything a user would notice, major when settings
keys or behaviour change incompatibly. install compares it with what's installed and
says so in the plan's first line:

    Installed 1.1.0 → new 1.2.0 (upgrade)
    Installed 1.2.0 → new 1.2.0 (rebuilt: same version, different dylib)
    Installed 1.2.0 → new 1.1.0 (downgrade)        refused without --allow-downgrade

so a rebuild during development doesn't need a bump; going back does need a flag.

macos limits:

    <key>minimumSystemVersion</key><string>27.0</string>
    <key>testedSystemVersions</key><string>27.0 - 27.2</string>

and the same minimum at load time, because a sandboxed tweak can't read its manifest and
a copied dylib never went through install:

    DH_CTOR("com.you.tweak", "com.apple.finder") {
        DH_REQUIRE_SYSTEM("27.0");    // returns from the body, logs, hooks nothing
        ...
    }

declare the real minimum: the first macos that has every class and method you touch,
not just the one you happen to run. don't cap the maximum. there is no
`maximumSystemVersion` on purpose: most tweaks keep working on the next release, and a
cap turns every update into a forced re-release. say what you tested in
`testedSystemVersions` (a warning outside it, never a refusal), and fail quietly at
runtime when a class or selector is gone (`DHClass` returns NULL, hooks on missing
methods log and return NULL).

dependencies:

    <key>depends</key>
    <array>
      <string>local.dynject.menuloader &gt;= 1.1.0</string>   <!-- another tweak, optional minimum -->
      <string>bridge</string>                                  <!-- the bridge agent -->
      <string>safemode</string>                                <!-- the safe mode watcher -->
    </array>

declaring `bridge` capabilities implies `bridge`. install refuses while a dependency
is missing (`--force` overrides) and prints the fix: `dw tweak install <its folder>`,
`dw bridge agent install`, `dw safemode agent install`. uninstall refuses to remove a
tweak something else depends on (`--force`). `dw tweak list` and the tweak page show
each dependency with ✓ or ✗, and which DynjectHook (`DH_SDK_VERSION`) the dylib was
built with: rebuild when workbench says it's older.


hooking with DynjectHook
------------------------

two files compiled into your dylib: `TweakSDK/include/DynjectHook.h` and
`TweakSDK/DynjectHook.m`, built with `-fobjc-arc`. think slimmed-down logos/substrate
with zkswizzle-style hook classes. objective-c methods only. full guide:
docs/hooking.md. read the abi section before you ship anything.

hook classes. never instantiated; their methods are installed on the target, so
`self` is the target at runtime. prefix the class name, the objc namespace is flat.

    @interface WT_NSWindowHook : NSObject @end
    @implementation WT_NSWindowHook
    - (void)setTitle:(NSString *)title {
        if (DHGroupIsEnabled(gMain)) title = [title stringByAppendingString:@" [wt]"];
        DH_ORIG(void (*)(id, SEL, NSString *), title);
    }
    @end

    DHHookClass([WT_NSWindowHook class], DHClass("NSWindow"), gMain);

no `super`, no ivars, no `-dealloc` in a hook class. one target per hook class.

single methods with a C function:

    static DHHook *gHook;
    static void MyLayout(id self, SEL _cmd) { DH_CALL_ORIG(gHook, void (*)(id, SEL), self, _cmd); }
    gHook = DHHookMessage(DHClass("CSGlassView"), @selector(layout), (IMP)MyLayout, NULL);

use `DHHookMessageEx(cls, sel, imp, group, &gHook)` for anything hooked after launch
(from `DHWhenClassLoads`, an observer): it writes the handle before the hook is live.
class methods: pass `object_getClass(cls)`.

groups give you a live Enabled switch:

    gMain = DHGroupCreate("main");
    DHGroupSetEnabled(gMain, DTPrefBool(kID, @"enabled", YES));   // before installing hooks
    DTPrefObserve(kID, nil, ^{ DHGroupSetEnabled(gMain, DTPrefBool(kID, @"enabled", YES)); });

a disabled hook may stay installed under someone else's, so every hook body must pass
straight through to the original when its group is off.

entry point. one per tweak:

    DH_CTOR("com.you.tweak", "com.apple.TextEdit", "com.apple.calculator") { ... }
    DH_CTOR("com.you.tweak") { ... }                     // every app it's injected into

it sets the log subsystem to your id, applies the bundle filter, checks safe mode and
the shift key, then runs the body inside @try. runs before the app's main: install
hooks there, defer ui work to the main queue. the bundle filter only narrows; the
config still decides which apps load the dylib at all.

abi rules, short version:
- call the original through its exact, non-variadic function type, `id` and `SEL`
  included. a variadic cast compiles and then reads garbage on arm64.
- struct returns, float args and BOOL returns all have to be typed right.
- alloc/new/copy/mutableCopy/init in a hook class need `ns_returns_retained`
  (and `ns_consumed` self for init). in a C replacement use the plain type.
  docs/hooking.md#arc-ownership-methods-that-return-a-retained-object.
- all DynjectHook symbols are hidden, so several tweaks can include it in one app.
  build your own code with `-fvisibility=hidden` too; `build.sh` fails on exports.

swift: only `@objc` methods reached through `objc_msgSend`. no C or swift function
hooks yet (see TODO.md).


settings
--------

`#import "DynjectTweak.h"`, header only.

    BOOL on       = DTPrefBool(kID, @"enabled", YES);
    double r      = DTPrefDouble(kID, @"radius", 8);
    NSString *c   = DTPrefString(kID, @"accent", @"auto");   // "#RRGGBB", "#RRGGBBAA", "auto"
    NSArray *apps = DTPrefList(kID, @"exclude");
    DTPrefObserve(kID, nil, ^{ /* re-read, re-apply; main queue */ });

`DTPrefValue`, `DTResolve`, `DTPayloadInDomain` for raw access. resolution order:
per-app override for this bundle id, then value, then manifest default, then your
fallback. bundle ids are the real ones, not dynject's xpc service names.

storage is one key, `dynject.tweak.<id>`, in the global preferences domain, which is
readable from inside sandboxed apps. workbench writes it and posts
`dynject.tweak.<id>.changed`. your tweak only reads. `dw tweak uninstall` leaves the
key; delete it yourself if you want it gone.


the bridge (sandboxed apps)
---------------------------

inside a sandboxed app (calculator, notes, textedit...) your tweak can read its settings
but can't write them, can't post most notifications and can't open other apps' links.
the bridge does those for it: a background agent running as you, `dw bridge serve`
(workbench -> bridge -> install bridge, or `dw bridge agent install`). think
rocketbootstrap with a fixed menu.

declare what you need in the manifest. nothing else is ever allowed:

    <key>bridge</key>
    <array>
      <string>settings.set</string>       <!-- this tweak's own settings, declared keys only -->
      <string>notify</string>             <!-- darwin notifications named <id> or <id>.* -->
      <string>open:https</string>         <!-- open https links; one entry per scheme. http, https,
                                               mailto are low risk; others get a warning at install;
                                               file:, shortcuts:, tel:, x-apple*, ... are refused -->
      <string>pasteboard.write</string>   <!-- put text on the clipboard -->
    </array>

compile `TweakSDK/DynjectBridge.m` in next to DynjectHook.m (same flags; copy
`DynjectBridge.h` into your `sdk/` too) and:

    #import "DynjectBridge.h"
    static const char *kID = "com.you.glass";

    // the apple-menu toggle from below, now persisted from inside calculator:
    static int token;
    notify_register_dispatch("com.you.glass.toggle", &token, dispatch_get_main_queue(), ^(int t) {
        BOOL on = !DTPrefBool(@(kID), @"enabled", YES);
        DHGroupSetEnabled(gMain, on);
        DBSetSetting(kID, @"enabled", @(on), nil, ^(NSError *error) {
            if (error) DHLog(@"bridge: %@", error.localizedDescription);   // not installed, denied, timeout
        });
    });

    // anything else: one request, one reply block on the queue you pass (NULL: main).
    DBRequest(kID, "open", @{@"url": @"https://example.com/help"}, NULL, ^(NSDictionary *r, NSError *e) { ... });

it never blocks and never throws: no bridge, a denial or a 5 s timeout all come back as
an NSError (`DBErrorReasonKey` has the broker's reason, e.g. `not-injected`,
`capability-missing`, `bad-arguments`, `rate-limited`).

it only works inside apps the config injects your tweak into (installed in the app
folders, with an override that names the app exactly), and the broker can't tell
your code from any other code in that app: anything loaded there can ask in your name.
so declare only what you use. `settings.set` with `app` sets a per-app override, only
for the app you're in and only for `perApp` items. rate limit: 20 at once, 5 a second
per app and tweak. `dw bridge log` shows what was allowed and denied, and why.
details and the security model: docs/bridge.md.


apple menu items (MenuLoader)
-----------------------------

declare items in the manifest; MenuLoader (injected separately, it's a tweak too) adds
them to the apple menu. you write no menu code.

    <key>appleMenuPlacement</key><string>submenu</string>   <!-- or shared, the default -->
    <key>appleMenuTitle</key><string>Glass</string>
    <key>appleMenu</key>
    <array>
      <dict>
        <key>id</key><string>toggle</string>
        <key>title</key><string>Glass Calculator</string>
        <key>action</key><string>notify:com.you.glass.toggle</string>
        <key>checkedBy</key><string>enabled</string>
        <key>apps</key><array><string>com.apple.calculator</string></array>
        <key>keyEquivalent</key><string>g</string>
        <key>modifiers</key><array><string>option</string><string>command</string></array>
      </dict>
    </array>

placement: `submenu` gets your own "Title ▸" entry under app store...; `shared` puts
your items in a section of the shared "Tweaks" entry.

actions:

    notify:<name>     notify_post(name). works from sandboxed apps.
    url:<url>         NSWorkspace openURL. any scheme.
    shortcut:<name>   runs a shortcuts.app shortcut.
    app:<bundleID>    launches or activates that app.

shortcuts must include command. without it the apple menu would eat that key in every
app (⌃A, ⌃E, option characters). workbench and MenuLoader both drop such shortcuts.
the app's own shortcuts win over yours.

`checkedBy` only draws the checkmark. toggling is your job: listen for the notification
and do something. a sandboxed host can't write the global preferences, so the tweak
can't flip its own setting from inside most apps by itself; act on the notification
directly, or ask the bridge (`settings.set`, above).

    #include <notify.h>
    static int token;
    notify_register_dispatch("com.you.glass.toggle", &token, dispatch_get_main_queue(), ^(int t) {
        GlassToggle();   // your code. runs in every app that has the tweak loaded.
    });

details: Tweaks/MenuLoader/README.md, docs/tweak-format.md#apple-menu-items-menuloader.


safe mode
---------

use `DH_CTOR` and you get it for free:

- the watcher (`dw safemode watch`, LaunchAgent `local.dynject.safemode`) reads crash
  reports and lists your tweak under `dynject.safemode` for the app it crashed: at once
  if the crash is in your code, after 2 tweak-loaded crashes in 10 minutes otherwise.
  `DH_CTOR` skips it at the next launch.
- holding shift at launch skips every DynjectHook tweak for that launch
  (`DH_DISABLE_SHIFT_BYPASS` in the environment turns that off).
- panic switch `"*": ["*"]`: no DynjectHook tweak loads anywhere.

the dylib is still injected; it just doesn't set itself up. tweaks that don't use
DynjectHook ignore all of this and only the config can stop them. a tweak built with
an older DynjectHook ignores the panic switch until rebuilt.

    dw safemode status
    dw safemode disable <tweakID> <bundleID|*>
    dw safemode enable  <tweakID> <bundleID|*>
    dw safemode panic on|off
    dw safemode clear

change the key with dw or workbench, not `defaults`: `defaults write -g` with a dict
replaces every entry. full rules: docs/safe-mode.md.


installing, uninstalling, listing
---------------------------------

    dw tweak install <folder|manifest> [--for <bundleID>]... [--dylib <path>]
                     [--allow-downgrade] [--force] [--dry-run]
    dw tweak uninstall <tweakID|manifest> [--keep-file] [--keep-rules] [--force] [--dry-run]
    dw tweak list

install validates the manifest (errors refuse) and the dylib (a mach-o dylib with an
arm64e slice; warns if x86_64 or arm64 is missing or a slice is unsigned), prints the
plan and asks for your password once. in that one helper call it copies the dylib into
place (hash-checked, previous file backed up), writes the config with the dylib
declared (`deny` by default) and enabled for each `--for` app, and restarts dynjectd.
the config edit is the same minimal edit workbench's switches make and is refused if it
would change any other app. nothing is written if a check fails. then the manifest is
copied to `~/Library/Application Support/Dynject Workbench/Tweaks/` (no password).
if only the dylib changed, dynjectd isn't restarted. `--for` repeats or takes a
comma-separated list. it refuses a downgrade (`--allow-downgrade`), a mac below the
manifest's `minimumSystemVersion` and unmet `depends` (`--force`); see versions,
macos and dependencies above.

uninstall removes the tweak's `dylib:` and `dylib-override:` lines and deletes its
dylib (only a regular `*.dylib` directly in `/opt/dynject/lib/tweaks`, never through a
symlink, backed up first), restart included, one prompt; then its manifest and safe
mode entries. settings stay. an `allow:<App>` line that only let its apps through (install
adds one for an app outside the applications folders) goes too, unless `--keep-rules`. one
that other tweaks still reach that app through stays, and the plan names them; one that
changes nothing is yours and left alone. it refuses
to remove the config's last dylib, because dynjectd won't start without one ("no
dylibs configured"); turn that tweak off per app instead.

uninstall also refuses while another installed tweak `depends` on it (`--force`).

list shows each installed manifest's version, dylib, whether the file exists, its config
policy, its safe mode support, the DynjectHook it was built with, its macos range and
its dependencies (✓/✗).

more apps later: workbench's apps & injection page, or
`dw enable /opt/dynject/lib/tweaks/libX.dylib <bundleID>` (and `dw disable`).


debugging
---------

- `dw log <subsystem> [minutes]` (default 5), or live:
  `log stream --level default --predicate 'subsystem == "com.you.tweak"'`.
  DynjectHook logs under your id with category `hook`.
- is it loaded? `lsof -p <pid> | grep dylib`. workbench's app detail pane shows
  configured / log MATCH / loaded; only loaded means it's in the process.
- not injected at all? the config decides: the detail pane shows each of dynjectd's
  three filters for that app. docs/workbench.md#how-dynject-decides.
- crash reports: `~/Library/Logs/DiagnosticReports/*.ips`. `dw safemode status` lists
  recent tweak-related ones and what got disabled.
- `dw respring --dry-run` says which running apps are out of date and why
  (missing, unwanted, updated, safe mode changed).
- what's in there? Tweaks/Inspector: enable it for the app (`dw tweak install
  Tweaks/Inspector --for <bundleID>`, respring), hold ⌃⌥⌘ and point at a view, L for
  layers, click. class, image, hierarchy, properties, methods with readable signatures,
  ivars, a runtime class search, and copy hook for a DynjectHook skeleton with exact types.
- a tweak doesn't load in one app: `dw why <tweak> <app>` names the check that stops it.
- two tweaks fighting over a method: `dw hooks <app>` lists what each tweak in the running
  app hooked, which hook is on top, and the methods more than one tweak hooks. `--scan`
  also finds hooks made without DynjectHook.
- test without dynject: `DYLD_INSERT_LIBRARIES` into a test app you built. a `dw new`
  tweak has one already (`./build.sh test`, `testhost/`). `Examples/TitleBadge/build.sh test`, `Examples/OLEDFinder/build.sh test` (screenshots and
  pixel checks), `Tweaks/MenuLoader/testhost/run.sh` and `Tweaks/Inspector/build.sh test` do this.

- testing in the real app from a script (pointer, keys, screenshots, logs): tools/live/README.md.


other dw commands
-----------------

    dw install <built.dylib>                     copy into /opt/dynject/lib/tweaks (prompt, hash-checked)
    dw enable  <installed.dylib> <bundleID>      declare if needed, enable for one app, restart
    dw disable <installed.dylib> <bundleID>
    dw relaunch <bundleID>
    dw respring [--dry-run] [--all] [--include ID]... [--exclude ID]... [--only ID] [--timeout S]
    dw config apply <new.conf> [--yes]           diff + validation; writes and restarts only with --yes
    dw --version

respring leaves out the terminal or editor running it, other terminals and editors,
workbench and finder unless you `--include` them; `--all` takes everything, finder
included. docs/respring.md.


conventions
-----------

several tweaks end up in the same app, written by people who never talked to each
other. these keep them out of each other's way.

names
- tweak id: reverse-dns you own. `com.yourname.tweakname`, or `local.yourname.tweakname`
  if you have no domain. `local.dynject.*` is reserved for the tweaks in this repo.
  `dw new` defaults to `local.<name>`; pass `--id` to set yours.
- derive everything else from the id: os_log subsystem = the id, darwin notifications
  `<id>.something`, the settings key is `dynject.tweak.<id>` (automatic).
- dylib: `lib<Name>.dylib`. it has to be unique in `/opt/dynject/lib/tweaks`.
- manifest: `<Name>.workbench.plist`, next to the source.

objective-c
- prefix every class you define, hook classes included. two tweaks with a `GlassHook`
  class collide and one of them silently loses.
- categories on system classes: prefix the method names too (`xyz_frame`, not `frame`),
  or you replace someone else's.
- no `+load`. start in `DH_CTOR`.

behaviour
- give `DH_CTOR` a bundle filter unless you really mean every app.
- an `enabled` switch bound to a `DHGroup`, so off means off without a relaunch.
- nothing slow at load: no network, no disk scans, no synchronous ax queries in the
  constructor. defer to the main queue.
- don't write the global preferences from inside the app (sandboxed apps can't anyway);
  signal something outside instead, or use the bridge's `settings.set`.
- log through os_log with your subsystem, quietly. no `NSLog` spam.

menus
- `appleMenuPlacement: shared` unless you have several items worth their own entry.
- shortcuts only when they earn it, always with ⌘, and not one an app already uses.
- `url:` actions: http(s) or your own scheme. never `file://`.


gotchas
-------

- private apis change between macos releases. MenuLoader leans on `_NSAppleMenu`; check
  your tweak on every update and fail quietly when a class or method is missing. declare
  them in `requires` and `dw doctor --apis` does the checking for your users, and move
  `testedSystemVersions` up once you've tried a new release.
- sandboxed hosts can read global prefs but can't write them. post a notification
  instead, or go through the bridge.
- inject only where you mean to. a `dylib:...:allow` default means every app, helpers
  that pass the filters included. use deny plus per-app overrides, and a `DH_CTOR`
  bundle filter on top.
- substring matching: `allow:Finder` also matches "Path Finder".
- arm64e: apple's own apps are arm64e, so the dylib needs an arm64e slice. build all
  three slices; `build.sh` does.
- injection happens only at launch. nothing changes in a running app until respring.
- a crash during a shift launch still counts toward "repeated crashes" for whatever
  was loaded. if a shift launch crashes, it isn't your tweak.
