// `dw safemode ...`: Safe Mode from the command line (docs/safe-mode.md). Nothing here needs admin rights or
// touches the Dynject config.
import DynjectCore
import Foundation
import os

let safeModeUsage = """
usage:
  dw safemode status
  dw safemode disable <tweakID> <bundleID|*>
  dw safemode enable  <tweakID> <bundleID|*>
  dw safemode panic on|off
  dw safemode clear
  dw safemode settings [threshold N] [window MINUTES] [notify on|off] [depth N] [max-age MINUTES]
  dw safemode watch [--once] [--no-notify]
  dw safemode agent install|uninstall|status [--binary PATH] [--no-notify]
  dw safemode help

options (any subcommand):
  --domain D        preferences domain holding "dynject.safemode" (default: the global domain)
  --state-dir D     Safe Mode state directory (default: ~/Library/Application Support/Dynject Workbench/SafeMode)
  --reports-dir D   crash reports (default: ~/Library/Logs/DiagnosticReports)
  --tweaks-dir D    tweak manifests (default: Workbench's Tweaks folder and /opt/dynject/lib/tweaks)
  --dylib-dir D     installed tweak dylibs (default: /opt/dynject/lib/tweaks)
  --launch-agents-dir D, --bin-dir D, --no-launchctl   (agent; for testing)
"""

struct SafeModeOptions {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    static let valued: Set<String> = ["--domain", "--state-dir", "--reports-dir", "--tweaks-dir", "--dylib-dir",
                                      "--launch-agents-dir", "--bin-dir", "--binary"]
    static let boolean: Set<String> = ["--once", "--no-notify", "--no-launchctl"]

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--help" || a == "-h" {
                positional.append("help")
                i += 1
            } else if Self.valued.contains(a) {
                guard i + 1 < args.count else { fail("\(a) needs a value") }
                values[a] = args[i + 1]
                i += 2
            } else if Self.boolean.contains(a) {
                flags.insert(a)
                i += 1
            } else if a.hasPrefix("--") {
                fail("unknown option \(a)\n\n\(safeModeUsage)", 2)
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    /// Absolute, so the LaunchAgent (which runs elsewhere) gets the same directories.
    func path(_ key: String) -> String? {
        values[key].map { v in
            var p = (v as NSString).expandingTildeInPath
            if !p.hasPrefix("/") { p = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(p) }
            return (p as NSString).standardizingPath
        }
    }

    /// Options that `watch` must keep when it runs from the LaunchAgent.
    var watchArguments: [String] {
        ["--domain", "--state-dir", "--reports-dir", "--tweaks-dir", "--dylib-dir"].flatMap { k in
            path(k).map { [k, k == "--domain" ? values[k]! : $0] } ?? []
        } + (flags.contains("--no-notify") ? ["--no-notify"] : [])
    }
}

func makeSafeMode(_ o: SafeModeOptions) -> SafeMode {
    let stateDir = o.path("--state-dir").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? SafeModeStateStore.defaultDirectory
    if let domain = o.values["--domain"] {
        return SafeMode.inDomain(domain, stateDirectory: stateDir)
    }
    return SafeMode(keys: SafeModeKeyStore(store: CFPreferencesTweakBackend(), names: .production),
                    stateStore: SafeModeStateStore(directory: stateDir))
}

func makeCatalog(_ o: SafeModeOptions) -> SafeModeCatalog {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Dynject Workbench", isDirectory: true)
    let dirs = o.path("--tweaks-dir").map { [$0] } ?? TweakManifestLoader.defaultDirectories(supportDirectory: support)
    let manifests = TweakManifestLoader.load(directories: dirs).manifests
    return SafeModeCatalog(manifests: manifests, dylibDirectory: o.path("--dylib-dir") ?? SafeModeCatalog.defaultDylibDirectory)
}

func makeAgent(_ o: SafeModeOptions) -> SafeModeAgent {
    let runner: LaunchctlRunner = o.flags.contains("--no-launchctl")
        ? RecordingLaunchctlRunner(respond: { args in
            print("(not run) launchctl \(args.joined(separator: " "))")
            return (args.first == "print" ? 113 : 0, "")
        })
        : SystemLaunchctlRunner()
    return SafeModeAgent(
        launchAgentsDirectory: o.path("--launch-agents-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? SafeModeAgent.defaultLaunchAgentsDirectory,
        binDirectory: o.path("--bin-dir").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? SafeModeAgent.defaultBinDirectory,
        runner: runner)
}

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func describeTarget(_ bundleID: String) -> String { bundleID == SafeModeNames.all ? "every app" : bundleID }

func safeModeCommand(_ args: [String]) {
    let o = SafeModeOptions(args)
    let p = o.positional
    let sm = makeSafeMode(o)
    do {
        switch (p.first, p.count) {
        case ("status", 1): printStatus(sm, o)
        case ("disable", 3):
            let catalog = makeCatalog(o)
            if SafeModeTweak.isUnmanifestedID(p[1]) {
                fail("\(p[1]) has no manifest, so it has no tweak ID that Safe Mode can name; disable it in the config instead (Workbench or `dw disable`)")
            }
            if p[1] == SafeModeNames.all {
                print("note: \"*\" stands for every DynjectHook tweak")
            } else if let t = catalog.tweak(p[1]) {
                if SafeModeSupportChecker.shared.supportsSafeMode(dylibAt: t.dylibPath) == false {
                    print("warning: \(t.name) isn't built on DynjectHook and ignores Safe Mode; it keeps loading until it is disabled in the config")
                }
            } else {
                print("note: no installed tweak has the ID \(p[1]); recording it anyway")
            }
            try sm.disable(tweakID: p[1], bundleID: p[2])
            print("disabled \(p[1]) in \(describeTarget(p[2])); relaunch the app to apply")
        case ("enable", 3):
            let still = try sm.enable(tweakID: p[1], bundleID: p[2])
            if still.isEmpty {
                print("re-enabled \(p[1]) in \(describeTarget(p[2])); relaunch the app to apply")
            } else {
                print("removed \(p[1])'s entry for \(describeTarget(p[2])), but it stays out because \(SafeModeStillOff.describe(still))")
                if still.contains(.allTweaksInApp) { print("  dw safemode enable '*' \(p[2])   re-enables every tweak there") }
                if still.contains(.panic) { print("  dw safemode panic off") }
            }
        case ("panic", 2) where p[1] == "on" || p[1] == "off":
            try sm.setPanic(p[1] == "on")
            print(p[1] == "on"
                  ? "panic on: DynjectHook tweaks stay out of every app launched from now on (tweaks that ignore Safe Mode still load)"
                  : "panic off")
            if p[1] == "on" {
                let old = makeCatalog(o).tweaks.filter { $0.hasManifest && SafeModeSupportChecker.shared.support(dylibAt: $0.dylibPath) == .perTweak }
                if !old.isEmpty {
                    print("note: built with an older DynjectHook, these ignore the panic switch and still load: "
                          + old.map(\.name).joined(separator: ", "))
                }
            }
        case ("clear", 1):
            try sm.clear()
            print("cleared: every tweak re-enabled, panic off; earlier crashes no longer count")
        case ("settings", _): try settingsCommand(sm, Array(p.dropFirst()))
        case ("watch", 1): watch(sm, o)
        case ("agent", 2): agentCommand(p[1], o)
        case ("help", 1):
            print(safeModeUsage)
        default:
            print(safeModeUsage)
            exit(p.isEmpty ? 0 : 2)
        }
    } catch {
        fail(error.localizedDescription)
    }
}

func printStatus(_ sm: SafeMode, _ o: SafeModeOptions) {
    let catalog = makeCatalog(o)
    let snap = sm.snapshot(catalog: catalog)
    print("panic switch: \(snap.panic ? "ON (every DynjectHook tweak is off everywhere)" : "off")")
    print("watcher agent: \(makeAgent(o).status().summary)")
    let s = snap.settings
    print("rules: disable at once on a crash in the tweak; else after \(s.threshold) tweak-loaded crashes within "
          + "\(Int(s.windowMinutes)) min; notifications \(s.notify ? "on" : "off")")
    print("")
    if snap.disabled.isEmpty {
        print("disabled: none")
    } else {
        print("disabled:")
        for d in snap.disabled {
            let name = d.tweakID == SafeModeNames.all ? "every DynjectHook tweak" : d.tweak?.name ?? d.tweakID
            var line = "  \(name) [\(d.tweakID)] in \(describeTarget(d.bundleID))"
            line += " — " + (d.reason?.rawValue ?? "set outside Workbench")
            if let since = d.since { line += ", since \(dateFormatter.string(from: since))" }
            print(line)
            if let r = d.reportPath { print("      report: \(r)") }
            if d.supportsSafeMode == false { print("      warning: this tweak ignores Safe Mode; disable it in the config") }
            let also = d.alsoOffBecause.filter { $0 != .panic }
            if !also.isEmpty { print("      also off here because \(SafeModeStillOff.describe(also))") }
        }
    }
    let unsupported = catalog.tweaks.filter { t in
        !t.hasManifest || SafeModeSupportChecker.shared.supportsSafeMode(dylibAt: t.dylibPath) == false
    }
    if !unsupported.isEmpty {
        print("")
        print("tweaks that ignore Safe Mode (only the config can stop them): " + unsupported.map(\.name).joined(separator: ", "))
    }
    let old = catalog.tweaks.filter { $0.hasManifest && SafeModeSupportChecker.shared.support(dylibAt: $0.dylibPath) == .perTweak }
    if !old.isEmpty {
        print("tweaks built with an older DynjectHook (per-app entries work, the panic switch doesn't): "
              + old.map(\.name).joined(separator: ", "))
    }
    print("")
    let recent = snap.recentCrashes.prefix(10)
    if recent.isEmpty {
        print("recent tweak-related crashes: none")
    } else {
        print("recent tweak-related crashes:")
        for c in recent {
            print("  \(dateFormatter.string(from: c.date))  \(c.appName ?? "?") (\(c.bundleID ?? "no bundle ID"))  \(c.tweakID)"
                  + (c.inTweak ? "  IN TWEAK" : ""))
            print("      \(c.frameSummary)")
            print("      \(c.reportPath)")
        }
    }
    print("")
    print("Hold Shift while an app launches to skip DynjectHook tweaks for that launch.")
}

func settingsCommand(_ sm: SafeMode, _ args: [String]) throws {
    guard args.count % 2 == 0 else { fail("settings take name/value pairs\n\n\(safeModeUsage)", 2) }
    if !args.isEmpty {
        try sm.updateSettings { s in
            for i in stride(from: 0, to: args.count, by: 2) {
                let (k, v) = (args[i], args[i + 1])
                switch k {
                case "threshold": guard let n = Int(v), n >= 1 else { fail("threshold must be a whole number ≥ 1") }; s.threshold = n
                case "window": guard let n = Double(v), n > 0 else { fail("window must be minutes > 0") }; s.windowMinutes = n
                case "notify": guard v == "on" || v == "off" else { fail("notify must be on or off") }; s.notify = v == "on"
                case "depth": guard let n = Int(v), n >= 1 else { fail("depth must be a whole number ≥ 1") }; s.inTweakDepth = n
                case "max-age": guard let n = Double(v), n > 0 else { fail("max-age must be minutes > 0") }; s.maxReportAgeMinutes = n
                default: fail("unknown setting \(k)")
                }
            }
        }
    }
    let s = sm.settings()
    print("threshold \(s.threshold)  window \(s.windowMinutes) min  notify \(s.notify ? "on" : "off")  depth \(s.inTweakDepth)  max-age \(s.maxReportAgeMinutes) min")
}

func watch(_ sm: SafeMode, _ o: SafeModeOptions) {
    let logger = Logger(subsystem: SafeModeAgent.logSubsystem, category: "watch")
    let log: (String) -> Void = { msg in
        logger.log("\(msg, privacy: .public)")
        print(msg)
        fflush(stdout)
    }
    let scanner = SafeModeScanner(reportsDirectory: o.path("--reports-dir") ?? SafeModeScanner.defaultReportsDirectory,
                                  safeMode: sm, catalog: { makeCatalog(o) },
                                  notifier: o.flags.contains("--no-notify") ? nil : OsascriptNotifier(), log: log)
    if o.flags.contains("--once") {
        let r = scanner.scan()
        print("examined \(r.examined.count) report(s): \(r.crashes.count) tweak-related crash record(s), "
              + "\(r.disabled.count) disabled, \(r.problems.count) problem(s)" + (r.pending > 0 ? ", \(r.pending) still being written" : ""))
        return
    }
    log("watching \(scanner.reportsDirectory)")
    let watcher = SafeModeWatcher(scanner: scanner)
    watcher.start()
    withExtendedLifetime(watcher) { dispatchMain() }
}

func agentCommand(_ action: String, _ o: SafeModeOptions) {
    let agent = makeAgent(o)
    do {
        switch action {
        case "install":
            let source = o.path("--binary") ?? Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
            let r = try agent.install(sourceBinary: source, extraArguments: o.watchArguments)
            print("installed \(r.binary)\nwrote \(r.plist)\nloaded \(SafeModeAgent.label): \(agent.status().summary)")
        case "uninstall":
            try agent.uninstall()
            print("removed \(SafeModeAgent.label)")
        case "status":
            let s = agent.status()
            print("\(SafeModeAgent.label): \(s.summary)")
            print("  plist \(agent.plistURL.path)\(s.plistInstalled ? "" : " (missing)")")
            print("  binary \(agent.binaryURL.path)\(s.binaryInstalled ? "" : " (missing)")")
            if s.plistInstalled && !s.plistMatches { print("  warning: the plist doesn't run this binary; reinstall") }
        default:
            fail("agent takes install, uninstall or status", 2)
        }
    } catch {
        fail(error.localizedDescription)
    }
}
