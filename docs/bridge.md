bridge
======

DynjectBridge lets a tweak in a sandboxed app ask for a few things the sandbox forbids:
write its own settings, post its own notifications, open declared kinds of links, put
text on the clipboard. the macos analogue of rocketbootstrap, minus the "any service"
part: there is exactly one service and it does exactly these things.

code: `Sources/DynjectCore/Bridge.swift` (rules, actions, rate limits, log; pure),
`BridgeSystem.swift` (xpc listener, code identity, token, effects, agent),
`Sources/dw/BridgeCommands.swift` (`dw bridge`), `TweakSDK/include/DynjectBridge.h` +
`TweakSDK/DynjectBridge.m` (the sdk), `Sources/DynjectWorkbench/BridgeModel.swift` and
`Views/BridgeView.swift` (the page).


how it works
------------

    tweak in Notes (sandboxed)                      dw bridge serve (LaunchAgent, you, unsandboxed)
      DBRequest(id, action, args)                     on start: sandbox_extension_issue_mach(
        read dynject.bridge.token (global prefs) <──────  "com.apple.app-sandbox.mach", "local.dynject.bridge")
        sandbox_extension_consume(token), once          write dynject.bridge.token + .version, post
        xpc to local.dynject.bridge ──────────────────>  dynject.bridge.changed
                                                        per request: audit token -> code identity,
                                                        live config + manifest -> allow/deny, act, log
        reply {ok, error?, message?, result?} <────────

- the agent: `~/Library/LaunchAgents/local.dynject.bridge.plist`, RunAtLoad, KeepAlive,
  MachServices `{local.dynject.bridge: true}`, ProcessType Adaptive, running a copy of dw at
  `~/Library/Application Support/Dynject Workbench/bin/dw-bridge` (its own copy, so removing
  the safe mode watcher doesn't take it away). no admin rights. `dw bridge agent
  install|uninstall|status` or workbench -> bridge.
- the token: a sandbox extension for the mach lookup of that one service name. a sandboxed
  app can't look the service up until it consumes one. it's generic (any process), it's
  not secret, and the spike showed it keeps working across broker restarts. the broker
  republishes it on every start anyway. uninstall removes the keys.
- the wire: one xpc dictionary, the request as a binary plist under `plist`:
  `{v: 1, tweak: <id>, action: <name>, args: {...}}`. the reply has the same shape:
  `{ok: bool, error?: code, message?: text, result?: plist}`. 1 MB cap both ways.
- the broker runs everything on its main queue. the config file is re-parsed when it
  changes (size, mtime, inode); the Tweaks folders are re-read on each request.


security model
--------------

what the broker trusts: the kernel and Security.framework about who's on the other end,
and the user's own files (config, manifests). nothing the caller says about itself.

the caller is the **app**, not the tweak. the broker gets the app's audit token; every
dylib loaded in that app (yours, other tweaks, the app's own code, anything it loads
later) has the same identity. the `tweak` field is self-asserted: any code in an app the
config injects tweak X into can send requests as X. so:

- a capability is granted to (app, tweak) pairs the user already set up: the tweak is
  installed and the config injects it there. a random sandboxed app the user didn't
  inject anything into gets nothing.
- inside such an app, assume everything that's there can use every capability of every
  tweak injected there. that is why the capabilities are narrow, why each only touches
  that tweak's own namespace, and why there is no "run a command", no file writes and no
  open of file urls.
- an app that wasn't sandboxed could do all of this itself. the bridge adds nothing for it.

### authorization

checked in this order for every request; the first failure decides.

| # | rule | denial |
|---|------|--------|
| 1 | per process (pid + pid version): burst 60, 20/s. first, before the size check or any parsing | `rate-limited` |
| 2 | payload ≤ 1 MB. the transport checks the length before copying anything | `too-large` |
| 3 | `{v: 1, tweak: id-shaped string, action: string ≤ 64, args: dict or absent}` | `bad-request`, `unsupported-version` |
| 4 | the audit token yields a code object with a signing identifier | `unidentified-caller` |
| 5 | `SecTaskCopySigningIdentifier` agrees with the code signature | `identity-mismatch` |
| 6 | `SecCodeCheckValidity` passes, and the code is one of: Apple's (`anchor apple`); Developer ID with a team id (`anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "<team>"`); Mac App Store (`anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]`); ad hoc only with `--test`. an Apple Development certificate is none of these | `untrusted-caller` |
| 7 | identifiers starting `com.apple.` (any case) and the ones dynjectd knows by launchd label (finder, dock) must be Apple's | `untrusted-caller` |
| 8 | not Apple's: hardened runtime (CS_RUNTIME 0x10000), and none of `com.apple.security.cs.allow-dyld-environment-variables`, `.cs.disable-library-validation`, `com.apple.security.get-task-allow` | `untrusted-caller` |
| 9 | launched as an app: parent is launchd (pid 1) and it is its own responsible process | `untrusted-caller` |
| 10 | the executable is `X.app/Contents/MacOS/<CFBundleExecutable>` of a bundle whose `CFBundleIdentifier` is the signing identifier | `identity-mismatch` |
| 11 | a manifest in the Tweaks folders has that `identifier` | `unknown-tweak` |
| 12 | the config can be read | `config-unavailable` |
| 13 | the caller's bundle is the installed app with that bundle id found by AppDiscovery in the app folders (/Applications, /System/Applications, ~/Applications, /System/Library/CoreServices; rescanned every 30 s) | `not-injected` |
| 14 | the live config injects the manifest's `dylib` into that app: dynjectd's three filters for it (service name as Workbench predicts it, `application.<bundle id>.0.0` or finder/dock's launchd label; executable name and path; the dylib's policy and overrides), and the dylib file exists | `not-injected` |
| 15 | if an override decided rule 14, its pattern names exactly this app: the bundle id, `application.<bundle id>.`, or the launchd label (the forms Workbench writes). dynjectd matches patterns as substrings, so `com.apple.Notes` also covers `com.evil.com.apple.Notes`; the bridge doesn't honour that. a dylib allowed by default (no override) passes | `not-injected` |
| 16 | the action exists | `unknown-action` |
| 17 | the manifest's `bridge` declares the action's capability | `capability-missing` |
| 18 | the action's own argument checks (below) | `bad-arguments` (`capability-missing` for an undeclared `open:` scheme) |
| 19 | per (process, tweak): burst 20, 5/s | `rate-limited` |
| 20 | the action itself worked | `failed` |

`--test` waives rules 8 and 9 for ad-hoc callers only (the e2e host is started from a
shell with `DYLD_INSERT_LIBRARIES`), never for anyone else.

what the caller is told: `unknown-tweak` and `not-injected` both come back as
`not-injected`, "<tweak> isn't available in this app", without dylib names, so an app can't
probe what's installed. the log keeps the real reason and detail.

identity is looked up once per connection and again whenever a message arrives with a
different audit token (libxpc keeps the last message's; the pid version in it changes on
exec). the code signature is not re-validated for every request in between. the parent
and responsible pid are read before the audit-token lookup: if that lookup then succeeds,
the same process (pid versions never repeat) was alive throughout.

launch context, measured on this mac (2026-11-20): every app launched normally had ppid 1
and was its own responsible process; apps started by other apps (a helper app inside
ChatGPT, Ollama's updater) had their launcher as parent. a child a shell started and then
orphaned is reparented to launchd (ppid 1, and its parent unique id becomes launchd's too),
but stays attributed to the terminal, which is why the responsible pid is checked as well.
the responsible pid comes from the private `responsibility_get_pid_responsible_for_pid`;
without it only the ppid is checked.

### capabilities and actions

manifest key `bridge`, an array of strings. `TweakManifestParser` validates it; bad entries
are skipped with an error, duplicates warned about.

    <key>bridge</key>
    <array>
      <string>settings.set</string>
      <string>notify</string>
      <string>open:https</string>
      <string>pasteboard.write</string>
    </array>

| action | needs | args | checks |
|---|---|---|---|
| `ping` | nothing | none | returns `{protocol, broker, brokerPID, app, capabilities}` |
| `settings.set` | `settings.set` | `key`, `value`, `app?` | `key` is an item of this manifest; `value` fits its type, within `min`/`max`, whole and within ±2^53 for `integer`, finite after step rounding, text ≤ 64 KB, app list ≤ 1000 bundle-id-shaped entries of ≤ 255 bytes (step rounding and color case are normalized, not refused). the tweak's whole payload must stay ≤ 256 KB. `app`: only the caller's own bundle id, only for `perApp` items. writes `dynject.tweak.<id>` like workbench (TweakSettings) and posts `dynject.tweak.<id>.changed`. returns `{key, value}` |
| `notify` | `notify` | `name` | `name` is the tweak id or starts with `<id>.`; `[A-Za-z0-9._-]`, ≤ 200 bytes; never in the infrastructure namespaces `com.apple.`, `dynject.`, `local.dynject.menuloader*`, `local.dynject.bridge*`, `local.dynject.safemode*`, `local.dynject.workbench*`, whatever the id (example tweaks like `local.dynject.titlebadge` keep their own); never inside another installed tweak's id when that id is longer (`com.you.glass` can't post `com.you.glass.pro.*` while `com.you.glass.pro` is installed) |
| `open` | `open:<scheme>` | `url` | absolute url ≤ 4 KB whose lowercased scheme is declared; http(s) need a host. never, declared or not (the manifest parser refuses them too): local and script schemes (`file`, `javascript`, `vbscript`, `data`, `blob`, `about`, `applescript`, `help`, `x-man-page`), network file systems and remote shells (`afp`, `smb`, `nfs`, `cifs`, `ftp`, `ftps`, `sftp`, `vnc`, `rdp`, `ssh`, `telnet`), handlers that act on the url (`shortcuts`, `workflow`, `vscode`, `vscode-insiders`, `cursor`, `windsurf`, `zed`, `idea`, `jetbrains`, `terminal`, `iterm2`, `warp`, `x-github-client`, `github-mac`, `github-windows`, `sourcetree`, `facetime`, `facetime-audio`, `facetime-group`, `tel`, `telprompt`, `sms`, `imessage`, `callto`, `skype`, `webcal`, `zoommtg`, `zoomus`, `msteams`, `slack`, `discord`, `itms`, `itms-apps`, `itms-services`, `macappstore`, `macappstores`), `dynject-workbench`, and the families `x-apple*` and `ms-*`. only `http`, `https` and `mailto` count as low risk: any other declared scheme gets a manifest warning and a warning in the install review. opened with NSWorkspace |
| `pasteboard.write` | `pasteboard.write` | `string` | ≤ 512 KB. replaces the general pasteboard's contents |

error codes are the strings in the table above; the sdk puts them in `DBErrorReasonKey`.


the sdk
-------

`TweakSDK/include/DynjectBridge.h` and `TweakSDK/DynjectBridge.m`, compiled into the
tweak like DynjectHook: `-fobjc-arc`, every symbol hidden, no objective-c classes, never
throws. C functions with blocks:

    BOOL DBIsAvailable(void);       // the token is published. reads one key, no ipc.
    void DBRequest(const char *tweakID, const char *action, NSDictionary *args,
                   dispatch_queue_t queue, void (^reply)(NSDictionary *result, NSError *error));
    void DBSetSetting(const char *tweakID, NSString *key, id value, NSString *app,
                      void (^done)(NSError *error));

- returns at once; the reply runs exactly once on `queue` (NULL: main): broker answer,
  5 s timeout, or an immediate error for bad arguments (not a plist dict, > 1 MB) or a
  missing token.
- first request: read the token, `sandbox_extension_consume` it (looked up with dlsym),
  connect. only a token for exactly this service is consumed: eight `;`-separated
  fields, the seventh `com.apple.app-sandbox.mach`, the eighth the service name. anything
  else in the key counts as no token (logged once), and `DBIsAvailable` says NO.
- later requests reuse the connection. `dynject.bridge.changed` (anyone can post it) only
  marks the token for re-reading: the next request re-reads it and moves to a new
  connection only if it changed and is valid; the old connection is cancelled 6 s later,
  after its requests got an answer or timed out. the notification never fails a request.
  an invalidated connection is rebuilt next time.
- a request in flight when the broker dies fails with `DBErrorConnection`; resend. launchd
  restarts the broker (KeepAlive) and libxpc reconnects the same connection.
- test builds: `-DDB_SERVICE_NAME='"..."' -DDB_TOKEN_KEY='"..."' -DDB_CHANGED_NOTIFICATION='"..."'`.


failure modes
-------------

- not installed: no token, `DBErrorNotInstalled` at once. installed but not running: the
  lookup works (launchd holds the port), the request waits for launchd to start it, or
  times out after 5 s if it can't.
- broker crash or `kickstart -k`: requests in flight at that moment fail
  (`DBErrorConnection`), the next one works. its rate-limit buckets start over. the log loses at most the last
  second (it's saved at most once a second, and on SIGTERM).
- config unreadable or manifest gone: every request for it is denied, nothing is cached
  past a change.
- workbench open on the tweak's settings page: it re-reads the key on
  `dynject.tweak.<id>.changed`, unless it has an unsaved change of its own, which then
  wins.
- the broker's log: `~/Library/Application Support/Dynject Workbench/Bridge/log.json`,
  the last 200 decisions of trusted callers (time, pid, app, tweak, action, allowed,
  reason, detail). a denial folds into a denial among the last 20 entries with the same
  caller (pid and app) and reason, whatever its tweak, action or detail: it moves to the
  end with the latest values and a count, so one app can't push the rest out. control,
  format and bidi characters (ESC, BEL, CR, LF, U+202A–202E, U+2066–2069, ...) are stored
  as `\u{XXXX}`, and escaped again when `dw bridge log` or workbench shows the file.
  denials before the caller is a trusted app (process rate limit, too-large, bad-request,
  unidentified, untrusted, identity-mismatch) only go to os_log, at most 5 a second (burst
  20) with a count of the ones skipped: subsystem `local.dynject.bridge`,
  `log stream --predicate 'subsystem == "local.dynject.bridge"'`.


private spi
-----------

the mechanism stands on functions with no public header:
`sandbox_extension_issue_mach` / `sandbox_extension_consume` (libsystem_sandbox),
`xpc_connection_get_audit_token` (libxpc) and, for the launch check,
`responsibility_get_pid_responsible_for_pid`. both are exported and used by apple's own
software (webkit does the same thing with the same calls), but apple can change or close
them in any update. all of them are looked up with dlsym: if one disappears the broker
logs it and keeps serving (unsandboxed callers only), the sdk returns errors, nothing
crashes. without `xpc_connection_get_audit_token` the broker identifies nobody and
denies everything; without the responsibility lookup only the ppid is checked.

the class string `com.apple.app-sandbox.mach` and the "generic token works for every
app, survives restarts" behaviour were found by experiment on macos 27 (the spike), not
documented anywhere.


workbench
---------

sidebar -> bridge: agent status, install / uninstall, whether the token is published,
which tweaks declare what, the last 100 decisions. each tweak page lists its
capabilities and its last few decisions; install tweak's review sheet lists the
capabilities before you agree, with a warning for any `open:` scheme other than http,
https and mailto. isolated launches (fixture mode, smoke test, other
manifests or reports) use a preview label and names under the isolation root,
simulated launchctl and an in-memory token; see HACKING.md.


dw
--

    dw bridge status                      agent, token, log summary
    dw bridge log [N]                     last N decisions
    dw bridge ping <tweakID>              a ping from dw itself (denied: not an app)
    dw bridge agent install|uninstall|status [--binary PATH]
                                          --launch-agents-dir / --bin-dir only with --no-launchctl
                                          (which also leaves the token keys alone)
    dw bridge serve [--test ...]          what the agent runs; dw bridge help for options

`--test` accepts ad-hoc signed callers. it refuses to start unless the service, token
key, version key and notification all differ from the real ones and `--config`,
`--tweaks-dir`, `--settings-file` and `--log-file` are given, so a test broker can't
read or write anything real. `--app-roots` (repeatable) sets where callers must be
installed.


testing
-------

unit tests (`Tests/DynjectCoreTests/BridgeTests.swift`): manifest parsing, the
authorization table with fake identities, config, installed apps and manifests, every
action's argument checks, rate limits with a fake clock, the log ring and its file, the
agent plist, and `BridgeReviewTests`, a regression test per finding of the security
review (fake finder, substring patterns, copies outside the app folders, launch context
and hardening, huge integers, log escaping and folding, identical replies, payload caps,
notify namespaces, agent options). one of them checks the three requirements statically
against apps on the machine (Calculator, the first App Store app, the first Developer ID
app; read from disk, nothing launched).
`Tests/DynjectHookTests/DBTBridgeSDKTests.m`: the sdk's refusals before any ipc.
`Tests/DynjectWorkbenchTests`: the page's isolation.

### end-to-end test

    ./scripts/bridge-e2e.sh       (~40 s; KEEP=1 keeps .build/bridge-e2e/run)

builds, under `.build/bridge-e2e/`: dw, a test tweak (`scripts/bridge-e2e/TestTweak.m` +
the sdk with test names), a sandboxed ad-hoc host app `local.bridge-e2e.host`, a second
sandboxed app `local.bridge-e2e.stranger`, and an unsandboxed probe tool. it writes a
fake config that injects the tweak into the host only, a Tweaks folder with the test
tweak (settings.set, notify, open:https) and a second tweak injected nowhere, and a
temporary LaunchAgent plist running `dw bridge serve --test` with service
`local.bridge-e2e.service`, keys `local.bridge-e2e.token|version`, settings to a plist
file, its own log, and `.build/bridge-e2e/apps` as the only app folder. it bootstraps that, runs the host with `DYLD_INSERT_LIBRARIES`,
restarts the broker under it, and always boots it out, deletes the test keys and the run
folder. never touched: `local.dynject.bridge`, ~/Library/LaunchAgents, `dynject.*` keys,
/opt/dynject, the live config, other apps (the script checks the real token key, agent
plist, log and config are unchanged).

results, 2026-11-20, macos 27.2, apple silicon: 39 passed, 0 failed.

    sdk builds clean                          x86_64 arm64 arm64e, 0 warnings, 0 exported symbols
    sdk ignores a token for another service   DBIsAvailable NO, requests "not installed"
    broker publishes the token                163 characters, version 1
    host is sandboxed                         sandbox_check(self) = 1
    lookup denied before the token            sandbox_check(mach-lookup) = 1
    DBIsAvailable                             yes
    DBRequest returns at once (main thread)   0.06 ms
    ping ok                                   app local.bridge-e2e.host, capabilities listed
    lookup allowed after the token            sandbox_check(mach-lookup) = 0
    settings.set declared key                 ok, .changed delivered to the host
    settings.set own per-app override         ok
    settings.set undeclared / out of range    bad-arguments / bad-arguments
    settings.set another app's override       bad-arguments
    notify own prefix                         ok, delivered to the host
    notify other prefix / look-alike prefix   bad-arguments / bad-arguments
    open file: / javascript:                  bad-arguments / bad-arguments
    open undeclared scheme (mailto)           capability-missing
    pasteboard.write undeclared               capability-missing
    tweak without a manifest                  not-injected (log: unknown-tweak)
    tweak not injected into the host          not-injected
    unknown action ("run")                    unknown-action
    sdk: non-dict args / > 1 MB               refused locally
    forged dynject.bridge.changed mid-flight  10 of 10 requests ok
    rate limit (30 at once)                   20 ok, 10 rate-limited
    broker restart (kickstart -k)             reconnected at the first ping, no errors
    settings.set after restart                ok
    settings file                             enabled=false, host override=true, size=7, no bogus key
    sandboxed app the config doesn't list     not-injected
    unsandboxed tool outside any app          identity-mismatch (os_log only)
    decision log persisted                    37 allowed, 7 denied entries; no identity-mismatch in it
    temporary agent booted out, nothing real touched
