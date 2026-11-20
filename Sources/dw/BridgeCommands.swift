// `dw bridge ...`: the DynjectBridge broker and its LaunchAgent (docs/bridge.md). Nothing here needs admin rights.
import DynjectCore
import Foundation
import os

let bridgeUsage = """
usage:
  dw bridge status
  dw bridge log [N]                     the last N decisions (default 20)
  dw bridge ping <tweakID>              send a ping as dw (an unsigned tool: expect a denial)
  dw bridge agent install|uninstall|status [--binary PATH]
  dw bridge serve                       run the broker (the LaunchAgent does this)
  dw bridge help

serve options (testing):
  --test                accept ad-hoc signed callers. needs --service, --token-key, --version-key and
                        --notification that differ from the real ones, and --config, --tweaks-dir,
                        --settings-file and --log-file
  --service NAME        mach service (default local.dynject.bridge)
  --token-key K, --version-key K, --notification N
  --config PATH         dynjectd.conf to check injection against (default /opt/dynject/etc/dynjectd.conf)
  --tweaks-dir D        manifests (repeatable; default Workbench's Tweaks folder and /opt/dynject/lib/tweaks)
  --app-roots D         where callers must be installed (repeatable; default /Applications, /System/Applications,
                        ~/Applications, /System/Library/CoreServices)
  --settings-file F     write settings.set payloads to this plist instead of the global domain
  --log-file F          decision log (default ~/Library/Application Support/Dynject Workbench/Bridge/log.json)
  --tweak-burst N, --tweak-rate R, --process-burst N, --process-rate R   rate limits (20, 5/s, 60, 20/s)
agent options (testing): --launch-agents-dir D, --bin-dir D, --no-launchctl (required with either directory)
"""

struct BridgeOptions {
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    static let valued: Set<String> = ["--service", "--token-key", "--version-key", "--notification", "--config", "--tweaks-dir",
                                      "--settings-file", "--log-file", "--tweak-burst", "--tweak-rate", "--process-burst",
                                      "--process-rate", "--binary", "--launch-agents-dir", "--bin-dir", "--app-roots"]
    static let boolean: Set<String> = ["--test", "--no-launchctl"]

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--help" || a == "-h" {
                positional.append("help")
                i += 1
            } else if Self.valued.contains(a) {
                guard i + 1 < args.count else { fail("\(a) needs a value") }
                values[a, default: []].append(args[i + 1])
                i += 2
            } else if Self.boolean.contains(a) {
                flags.insert(a)
                i += 1
            } else if a.hasPrefix("--") {
                fail("unknown option \(a)\n\n\(bridgeUsage)", 2)
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func value(_ k: String) -> String? { values[k]?.last }

    func path(_ k: String) -> String? { value(k).map(absolute) }

    func absolute(_ v: String) -> String {
        var p = (v as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(p) }
        return (p as NSString).standardizingPath
    }

    var names: BridgeNames {
        let p = BridgeNames.production
        return BridgeNames(service: value("--service") ?? p.service, tokenKey: value("--token-key") ?? p.tokenKey,
                           versionKey: value("--version-key") ?? p.versionKey, notification: value("--notification") ?? p.notification)
    }

    var logURL: URL { path("--log-file").map { URL(fileURLWithPath: $0) } ?? BridgeDecisionLog.defaultFileURL }
}

func bridgeCommand(_ args: [String]) {
    let o = BridgeOptions(args)
    let p = o.positional
    switch (p.first, p.count) {
    case ("serve", 1): bridgeServe(o)
    case ("status", 1): bridgeStatus(o)
    case ("log", 1): bridgeLog(o, count: 20)
    case ("log", 2): bridgeLog(o, count: Int(p[1]) ?? 20)
    case ("ping", 2): bridgePing(o, tweak: p[1])
    case ("agent", 2): bridgeAgentCommand(p[1], o)
    case ("help", _):
        print(bridgeUsage)
    default:
        print(bridgeUsage)
        exit(p.isEmpty ? 0 : 2)
    }
}

func makeBridgeAgent(_ o: BridgeOptions) -> BridgeAgent {
    let runner: LaunchctlRunner = o.flags.contains("--no-launchctl")
        ? RecordingLaunchctlRunner(respond: { args in
            print("(not run) launchctl \(args.joined(separator: " "))")
            return (args.first == "print" ? 113 : 0, "")
        })
        : SystemLaunchctlRunner()
    return BridgeAgent(
        launchAgentsDirectory: o.path("--launch-agents-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? UserLaunchAgent.defaultLaunchAgentsDirectory,
        binDirectory: o.path("--bin-dir").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? UserLaunchAgent.defaultBinDirectory,
        runner: runner)
}

func bridgeAgentCommand(_ action: String, _ o: BridgeOptions) {
    if let problem = BridgeAgent.testingOptionsProblem(directoriesOverridden: o.value("--launch-agents-dir") != nil || o.value("--bin-dir") != nil,
                                                       simulatedLaunchctl: o.flags.contains("--no-launchctl")) {
        fail(problem, 2)
    }
    let agent = makeBridgeAgent(o)
    do {
        switch action {
        case "install":
            let source = o.path("--binary") ?? Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
            let r = try agent.install(sourceBinary: source)
            print("installed \(r.binary)\nwrote \(r.plist)\nloaded \(agent.label): \(agent.status().summary)")
        case "uninstall":
            try agent.uninstall()
            if !o.flags.contains("--no-launchctl") {
                // The token names a service that no longer exists; tweaks then report "not installed" at once.
                try CFPreferencesBridgeTokenStore(names: .production).clear()
            }
            print("removed \(agent.label)")
        case "status":
            let s = agent.status()
            print("\(agent.label): \(s.summary)")
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

func bridgeStatus(_ o: BridgeOptions) {
    let names = o.names
    print("agent: \(makeBridgeAgent(o).status().summary)")
    let token = CFPreferencesBridgeTokenStore(names: names).token()
    print("token: \(token.map { "published in \(names.tokenKey) (\($0.count) characters)" } ?? "not published")")
    let entries = BridgeDecisionLog.load(o.logURL)
    let denied = entries.filter { !$0.allowed }.count
    print("log: \(entries.count) decision(s), \(denied) denied, in \(o.logURL.path)")
}

func bridgeLog(_ o: BridgeOptions, count: Int) {
    let entries = BridgeDecisionLog.load(o.logURL).suffix(max(1, count))
    if entries.isEmpty { print("no decisions in \(o.logURL.path)"); return }
    for e in entries.map(BridgeLogText.clean) {
        var line = "\(dateFormatter.string(from: e.date))  \(e.allowed ? "allowed" : "DENIED ")  \(e.app) (pid \(e.pid))  \(e.tweak)  \(e.action)"
        if !e.allowed { line += "  \(e.reason)" + (e.detail.map { ": \($0)" } ?? "") }
        if e.count > 1 { line += "  (×\(e.count))" }
        print(line)
    }
}

func bridgePing(_ o: BridgeOptions, tweak: String) {
    guard let r = BridgeXPCClient.send(["v": BridgeProtocol.version, "tweak": tweak, "action": "ping"], service: o.names.service) else {
        fail("no reply from \(o.names.service) (is the agent running? dw bridge status)")
    }
    print(r)
}

func bridgeServe(_ o: BridgeOptions) {
    let logger = Logger(subsystem: BridgeProtocol.logSubsystem, category: "serve")
    let say: (String) -> Void = { msg in
        logger.log("\(msg, privacy: .public)")
        print(msg)
        fflush(stdout)
    }
    let names = o.names
    let test = o.flags.contains("--test")
    if test {
        guard names.isDisjointFromProduction else {
            fail("--test needs --service, --token-key, --version-key and --notification that differ from the real ones")
        }
        for k in ["--config", "--tweaks-dir", "--settings-file", "--log-file"] where o.value(k) == nil {
            fail("--test needs \(k), so nothing real is read or written")
        }
    }
    var settings = BridgeService.Settings()
    settings.allowAdHocCallers = test
    if let v = o.value("--tweak-burst").flatMap(Int.init) { settings.tweakBurst = v }
    if let v = o.value("--tweak-rate").flatMap(Double.init) { settings.tweakPerSecond = v }
    if let v = o.value("--process-burst").flatMap(Int.init) { settings.processBurst = v }
    if let v = o.value("--process-rate").flatMap(Double.init) { settings.processPerSecond = v }

    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Dynject Workbench", isDirectory: true)
    let tweakDirs = o.values["--tweaks-dir"].map { $0.map(o.absolute) } ?? TweakManifestLoader.defaultDirectories(supportDirectory: support)
    let config = o.path("--config") ?? configPath
    let backend: TweakPrefsBackend = o.path("--settings-file").map { PostingFileTweakBackend(path: $0) } ?? CFPreferencesTweakBackend()
    let log = BridgeDecisionLog(fileURL: o.logURL)
    let appRoots = o.values["--app-roots"].map { $0.map(o.absolute) } ?? AppDiscovery.defaultRoots
    let service = BridgeService(settings: settings, sources: .live(configPath: config, tweakDirectories: tweakDirs, appRoots: appRoots),
                                effects: SystemBridgeEffects(settingsBackend: backend), log: log)

    // The log is saved at most once a second, and on SIGTERM (launchctl bootout, kickstart -k).
    var saveScheduled = false
    func saveLog() {
        do { try log.save() } catch { say("could not save \(o.logURL.path): \(error.localizedDescription)") }
    }
    service.onDecision = { _ in
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            saveScheduled = false
            saveLog()
        }
    }
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler {
        if log.isDirty { saveLog() }
        say("stopping (SIGTERM)")
        exit(0)
    }
    term.resume()

    let listener = BridgeXPCListener(serviceName: names.service, queue: .main) { payload, peer, identify in
        service.handle(payload: payload, peer: peer, identify: identify)
    }
    listener.start()

    // Publish after listening, so a tweak that reacts to the notification finds the service answering.
    if let token = BridgeSPI.issueMachExtension(service: names.service) {
        do {
            try CFPreferencesBridgeTokenStore(names: names).publish(token: token)
            say("published the token for \(names.service) in \(names.tokenKey), posted \(names.notification)")
        } catch {
            say("could not publish the token: \(error.localizedDescription)")
        }
    } else {
        say("sandbox_extension_issue_mach failed (errno \(errno)); sandboxed tweaks can't reach \(names.service)")
    }
    say("serving \(names.service)\(test ? " in test mode (ad-hoc callers accepted)" : ""); config \(config); manifests in \(tweakDirs.joined(separator: ", "))")
    withExtendedLifetime((listener, term)) { dispatchMain() }
}
