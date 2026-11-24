import Foundation
import Security

// `dw doctor`: a read-only health check of the engine, the config, installed tweaks, the agents, the Apple-menu
// list, running apps and Safe Mode. Every input comes through `DoctorContext`, so tests run it on temporary folders
// and fakes. Nothing here writes, asks for a password or launches an app (it runs csrutil, pgrep, ps, launchctl
// print and lsof). `dw doctor --apis`: `Doctor.apis`, the private-API canary (TweakRequirements.swift).

// MARK: - Report

public enum DoctorStatus: String, Codable, Sendable {
    case ok, warning, problem

    public var symbol: String {
        switch self {
        case .ok: return "✓"
        case .warning: return "!"
        case .problem: return "✗"
        }
    }
}

public struct DoctorCheck: Codable, Equatable, Sendable {
    public var section: String
    /// A short, stable name for the check, e.g. "dynjectd running".
    public var check: String
    public var status: DoctorStatus
    /// The line shown after the symbol.
    public var detail: String
    /// One line saying what to do (warnings and problems).
    public var fix: String?

    public init(section: String, check: String, status: DoctorStatus, detail: String, fix: String? = nil) {
        self.section = section
        self.check = check
        self.status = status
        self.detail = detail
        self.fix = fix
    }

    enum CodingKeys: String, CodingKey { case section, check, status, detail, fix }

    /// `fix` is always present (null when there is none), so every object has the same keys.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(section, forKey: .section)
        try c.encode(check, forKey: .check)
        try c.encode(status, forKey: .status)
        try c.encode(detail, forKey: .detail)
        try c.encode(fix, forKey: .fix)
    }
}

public struct DoctorReport: Sendable {
    public var checks: [DoctorCheck]

    public init(checks: [DoctorCheck] = []) { self.checks = checks }

    public var problems: Int { checks.filter { $0.status == .problem }.count }
    public var warnings: Int { checks.filter { $0.status == .warning }.count }
    /// 0 without problems (warnings allowed), 1 otherwise.
    public var exitCode: Int32 { problems > 0 ? 1 : 0 }

    public var summary: String {
        func n(_ k: Int, _ word: String) -> String { "\(k) \(word)\(k == 1 ? "" : "s")" }
        return problems + warnings == 0 ? "all good" : "\(n(problems, "problem")), \(n(warnings, "warning"))"
    }

    /// Sections in order of appearance, one line per check, fixes indented under warnings and problems.
    /// `quiet`: only warnings and problems (and their sections); nothing at all when there are none.
    public func text(quiet: Bool = false, header: String? = nil) -> String {
        let shown = quiet ? checks.filter { $0.status != .ok } : checks
        var out: [String] = []
        if let header, !(quiet && shown.isEmpty) { out += [header, ""] }
        var sections: [String] = []
        for c in shown where !sections.contains(c.section) { sections.append(c.section) }
        for s in sections {
            out.append(s)
            for c in shown where c.section == s {
                out.append("  \(c.status.symbol) \(c.detail)")
                if c.status != .ok, let fix = c.fix { out.append("      → \(fix)") }
            }
            out.append("")
        }
        if !(quiet && shown.isEmpty) { out.append(summary) }
        return out.joined(separator: "\n")
    }

    /// A JSON array of {section, check, status, detail, fix}.
    public func json() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(checks)) ?? Data("[]".utf8)
    }
}

/// Collects the checks of one section.
struct DoctorSection {
    let name: String
    var checks: [DoctorCheck] = []

    init(_ name: String) { self.name = name }

    mutating func ok(_ check: String, _ detail: String) {
        checks.append(.init(section: name, check: check, status: .ok, detail: detail))
    }

    mutating func warn(_ check: String, _ detail: String, fix: String? = nil) {
        checks.append(.init(section: name, check: check, status: .warning, detail: detail, fix: fix))
    }

    mutating func problem(_ check: String, _ detail: String, fix: String? = nil) {
        checks.append(.init(section: name, check: check, status: .problem, detail: detail, fix: fix))
    }
}

// MARK: - Inputs

/// Everything `Doctor.run` reads. `live()` is the real system; tests point the paths at temporary folders and
/// replace the closures and agents with fakes.
public struct DoctorContext {
    public var now = Date()
    public var engineRoot = "/opt/dynject"
    public var launchDaemonPlist = "/Library/LaunchDaemons/\(DaemonInspector.label).plist"
    /// Config, tweaks folder and manifest folders.
    public var locations: TweakLocations
    /// How far back dynjectd's log is searched for ERROR lines.
    public var logWindow: TimeInterval = 60 * 60
    /// How far back crashes count.
    public var crashWindow: TimeInterval = 24 * 60 * 60
    public var daemonStatus: () -> DaemonStatus
    /// `csrutil status` output, nil if it couldn't run.
    public var sipStatus: () -> String?
    /// nil when the file's code signature is valid, else why not.
    public var codeSignatureProblem: (String) -> String?
    public var safeModeAgent: UserLaunchAgent
    public var bridgeAgent: UserLaunchAgent
    public var bridgeToken: () -> String?
    public var bridgeService = BridgeNames.production.service
    public var menuStore: GlobalPrefsStore
    public var menuNames = MenuLoaderNames.production
    public var menuSettings: () -> MenuLoaderSettings
    public var safeMode: SafeMode
    /// The respring plan for the config text, manifests and daemon; nil to skip the apps section.
    public var respringPlan: ((String, [TweakManifest], DaemonStatus) -> RespringPlan)?
    /// Where Dynject Workbench.app may be installed, in order.
    public var workbenchApps: [String]
    /// The dw running the checks (compared with the agents' copies when no app is installed).
    public var thisDw: String?
    public var version = WorkbenchInfo.version
    /// The macOS that minimumSystemVersion and testedSystemVersions are checked against.
    public var systemVersion = SystemVersion.current
    /// DynjectHook's DHHookFunction log lines (`log show --style compact`) since the given date; nil to skip.
    public var inlineHookLog: ((Date) -> String?)? = nil

    public init(locations: TweakLocations, daemonStatus: @escaping () -> DaemonStatus, sipStatus: @escaping () -> String?,
                codeSignatureProblem: @escaping (String) -> String?, safeModeAgent: UserLaunchAgent, bridgeAgent: UserLaunchAgent,
                bridgeToken: @escaping () -> String?, menuStore: GlobalPrefsStore, menuSettings: @escaping () -> MenuLoaderSettings,
                safeMode: SafeMode, respringPlan: ((String, [TweakManifest], DaemonStatus) -> RespringPlan)?,
                workbenchApps: [String], thisDw: String?) {
        self.locations = locations
        self.daemonStatus = daemonStatus
        self.sipStatus = sipStatus
        self.codeSignatureProblem = codeSignatureProblem
        self.safeModeAgent = safeModeAgent
        self.bridgeAgent = bridgeAgent
        self.bridgeToken = bridgeToken
        self.menuStore = menuStore
        self.menuSettings = menuSettings
        self.safeMode = safeMode
        self.respringPlan = respringPlan
        self.workbenchApps = workbenchApps
        self.thisDw = thisDw
    }

    public var configPath: String { locations.configPath }
    public var logPath: String { engineRoot + "/log/dynjectd.log" }
    public var errorLogPath: String { engineRoot + "/log/dynjectd.error.log" }

    public static let workbenchAppName = "Dynject Workbench.app"

    /// The real system, read-only.
    public static func live() -> DoctorContext {
        let configPath = TweakLocations.liveConfigPath
        return DoctorContext(
            locations: .live(),
            daemonStatus: { DaemonInspector.status(configPath: configPath) },
            sipStatus: { (try? ProcessRunner.run("/usr/bin/csrutil", ["status"]))?.stdout },
            codeSignatureProblem: CodeSignatureCheck.problem(path:),
            safeModeAgent: SafeModeAgent(), bridgeAgent: BridgeAgent(),
            bridgeToken: { CFPreferencesBridgeTokenStore(names: .production).token() },
            menuStore: CFPreferencesTweakBackend(),
            menuSettings: { MenuLoaderSettings.savedByWorkbench() },
            safeMode: .live(),
            respringPlan: { text, manifests, daemon in
                RespringPlanner.live(configText: text, configPath: configPath,
                                     logText: DynjectLogParser.readTail(path: "/opt/dynject/log/dynjectd.log"),
                                     manifests: manifests, safeModeState: SafeModeStateStore().load(), daemon: daemon).plan()
            },
            workbenchApps: [NSHomeDirectory() + "/Applications/" + workbenchAppName, "/Applications/" + workbenchAppName],
            thisDw: Bundle.main.executableURL?.resolvingSymlinksInPath().path)
        .with(inlineHookLog: { since in
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            // DynjectHook logs under the category "hook": filtering on it keeps a day's search to seconds.
            return (try? ProcessRunner.run("/usr/bin/log", ["show", "--start", f.string(from: since), "--style", "compact",
                                                            "--predicate", #"category == "hook" AND eventMessage BEGINSWITH "DHHookFunction""#]))?.stdout
        })
    }

    func with(inlineHookLog: @escaping (Date) -> String?) -> DoctorContext {
        var c = self
        c.inlineHookLog = inlineHookLog
        return c
    }
}

// MARK: - Helpers (pure, tested on their own)

/// `csrutil status`, and whether the engine can run with it: it needs filesystem protections and debugging
/// restrictions off (`csrutil enable --without fs --without debug`).
public struct SIPStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable { case enabled, disabled, custom, unknown }
    public var state: State
    /// Protection name → enabled, from the "Configuration:" lines of a custom configuration.
    public var protections: [String: Bool]

    public static let filesystem = "Filesystem Protections"
    public static let debugging = "Debugging Restrictions"

    public static func parse(_ output: String) -> SIPStatus {
        var state = State.unknown
        var protections: [String: Bool] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("System Integrity Protection status:") {
                let v = line.dropFirst("System Integrity Protection status:".count).trimmingCharacters(in: .whitespaces).lowercased()
                if v.contains("custom configuration") { state = .custom }
                else if v.hasPrefix("enabled") { state = .enabled }
                else if v.hasPrefix("disabled") { state = .disabled }
            } else if let colon = line.lastIndex(of: ":") {
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
                if value == "enabled" || value == "disabled" {
                    protections[String(line[..<colon])] = value == "enabled"
                }
            }
        }
        return SIPStatus(state: state, protections: protections)
    }

    /// What the engine needs that is still on (empty: it can run).
    public var blockingEngine: [String] {
        switch state {
        case .disabled: return []
        case .enabled: return [Self.filesystem, Self.debugging]
        case .custom, .unknown: return [Self.filesystem, Self.debugging].filter { protections[$0] != false }
        }
    }

    /// Protections off beyond the two the engine needs.
    public var alsoOff: [String] {
        protections.filter { !$0.value && ![Self.filesystem, Self.debugging].contains($0.key) }.keys.sorted()
    }
}

/// dynjectd's log stamps lines with a time of day only. Dates are reconstructed backwards from the file's
/// modification date (its last line), stepping back a day whenever the time of day goes forward.
public enum DynjectLogClock {
    private static let stamp = try! NSRegularExpression(pattern: #"^\[\S+ (\d{2}):(\d{2}):(\d{2})\] "#)

    /// Lines stamped at or after `since`, oldest first, with their dates.
    public static func lines(in text: String, modified: Date, since: Date,
                             calendar: Calendar = .current) -> [(date: Date, line: String)] {
        var out: [(Date, String)] = []
        var day = calendar.startOfDay(for: modified)
        var next = modified.addingTimeInterval(1)
        for raw in text.split(whereSeparator: \.isNewline).reversed() {
            let line = String(raw)
            guard let m = stamp.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            func n(_ i: Int) -> Int { Int((line as NSString).substring(with: m.range(at: i))) ?? 0 }
            let seconds = TimeInterval(n(1) * 3600 + n(2) * 60 + n(3))
            var date = day.addingTimeInterval(seconds)
            if date > next {
                day = calendar.date(byAdding: .day, value: -1, to: day) ?? day.addingTimeInterval(-86400)
                date = day.addingTimeInterval(seconds)
            }
            if date < since { break }
            out.append((date, line))
            next = date
        }
        return out.reversed()
    }

    /// The ERROR lines among `lines(in:modified:since:)`.
    public static func errors(in text: String, modified: Date, since: Date,
                              calendar: Calendar = .current) -> [(date: Date, line: String)] {
        lines(in: text, modified: modified, since: since, calendar: calendar).filter { $0.line.contains("ERROR") }
    }
}

/// The bridge token names the mach service it opens: `<hash>;…;com.apple.app-sandbox.mach;<service>`.
public enum BridgeTokenCheck {
    public static let extensionClass = "com.apple.app-sandbox.mach"

    /// nil when `token` is a mach-lookup extension for `service`, else what is wrong.
    public static func problem(token: String, service: String) -> String? {
        let parts = token.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[parts.count - 2] == extensionClass else {
            return "the token isn't a mach-lookup sandbox extension"
        }
        let named = parts[parts.count - 1]
        return named == service ? nil : "the token opens \(named), not \(service)"
    }
}

/// An agent's copy of dw against the dw it should be (the installed app's).
public enum AgentBinaryCheck {
    public enum Result: Equatable, Sendable { case same, differs, unknown }

    public static func compare(installed: String, reference: String) -> Result {
        guard let a = try? Data(contentsOf: URL(fileURLWithPath: installed), options: .mappedIfSafe),
              let b = try? Data(contentsOf: URL(fileURLWithPath: reference), options: .mappedIfSafe) else { return .unknown }
        return sha256Hex(a) == sha256Hex(b) ? .same : .differs
    }
}

/// Static code signature validation of a file (every architecture), without running codesign.
public enum CodeSignatureCheck {
    public static func problem(path: String) -> String? {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
        guard status == errSecSuccess, let code else { return message(status) }
        var error: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &error)
        guard status != errSecSuccess else { return nil }
        if let e = error?.takeRetainedValue() { return CFErrorCopyDescription(e) as String? ?? message(status) }
        return message(status)
    }

    static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}

// MARK: - The checks

public enum Doctor {
    /// Seen in `fix` lines.
    static let restartHint = "restart dynject: workbench -> daemon -> restart dynject (stops every dynjectd, starts one)"
    static let amfidHint = "workbench -> daemon -> restart dynject (starts the idle amfid first); by hand: "
        + "sudo launchctl kickstart system/com.apple.MobileFileIntegrity, then sudo launchctl kickstart system/\(DaemonInspector.label)"
    static let sipHint = "from recovery: csrutil enable --without fs --without debug"
    static let configHint = "fix it in workbench -> raw config, or dw config apply <file>"
    static let watcherHint = "reinstall the watcher: dw safemode agent install (or workbench -> safe mode)"
    static let bridgeHint = "reinstall the broker: dw bridge agent install (or workbench -> bridge)"

    /// "macOS 27.2.1 (26B131)".
    public static var macOSDescription: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &buf, &size, nil, 0)
        let build = String(cString: buf)
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" + (build.isEmpty ? "" : " (\(build))")
    }

    public static func run(_ c: DoctorContext) -> DoctorReport {
        let daemon = c.daemonStatus()
        let configText = FileManager.default.contents(atPath: c.configPath).map { String(decoding: $0, as: UTF8.self) }
        let (manifests, _) = TweakManifestLoader.load(directories: c.locations.manifestSearchDirectories)
        var checks = engine(c, daemon: daemon)
        checks += config(c, text: configText, manifests: manifests)
        checks += tweaks(c)
        checks += inlineHooks(c, tweakIDs: Set(manifests.map(\.id)))
        checks += agents(c, manifests: manifests)
        checks += appleMenu(c, manifests: manifests)
        if let plan = c.respringPlan, let configText { checks += apps(plan(configText, manifests, daemon)) }
        checks += safeMode(c, manifests: manifests)
        checks += workbench(c)
        return DoctorReport(checks: checks)
    }

    static func clock(_ d: Date?) -> String {
        guard let d else { return "?" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "MMM d HH:mm"
        return f.string(from: d)
    }

    static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    // MARK: engine

    static func engine(_ c: DoctorContext, daemon: DaemonStatus) -> [DoctorCheck] {
        var s = DoctorSection("engine")
        let fm = FileManager.default
        let bins = ["dynjectd", "dynject_loader"].map { "\(c.engineRoot)/bin/\($0)" }
        let missing = bins.filter { !fm.isExecutableFile(atPath: $0) }
        if missing.isEmpty {
            s.ok("engine binaries", "dynjectd and dynject_loader in \(c.engineRoot)/bin")
        }
        for m in missing {
            s.problem("engine binaries", "\(m) missing", fix: "install the dynject engine (https://github.com/ut0mt8/dynject); workbench never installs it")
        }
        if fm.fileExists(atPath: c.launchDaemonPlist) {
            s.ok("launchdaemon", "launchdaemon \(name(c.launchDaemonPlist)) present")
        } else {
            s.warn("launchdaemon", "no \(c.launchDaemonPlist): dynjectd won't start at boot",
                   fix: "install the engine's launchdaemon plist (see its README)")
        }

        let logText = DynjectLogParser.readTail(path: c.logPath, maxBytes: 200_000)
        let lastStartFailedOnAmfid = logText.map { text in
            text.split(whereSeparator: \.isNewline).last { $0.contains("dynject_loader:") }?.contains("amfid not found") ?? false
        } ?? false
        switch daemon.processes.count {
        case 0:
            s.problem("dynjectd running", "dynjectd isn't running: nothing is injected"
                      + (lastStartFailedOnAmfid ? " (the last start failed: amfid not found; launchd stops the idle amfid)" : ""),
                      fix: amfidHint)
        case 1:
            let p = daemon.processes[0]
            if daemon.staleProcesses.isEmpty {
                s.ok("dynjectd running", "dynjectd running (pid \(p.pid), since \(clock(p.started)))")
            } else {
                s.warn("dynjectd running", "dynjectd (pid \(p.pid)) started \(clock(p.started)), before the config was written "
                       + "(\(clock(daemon.configModified))): apps get the old set", fix: restartHint)
            }
        default:
            s.warn("dynjectd running", "\(daemon.processes.count) dynjectd running (pids \(daemon.processes.map { String($0.pid) }.joined(separator: ", "))): "
                   + "each injects with the config it started with", fix: restartHint)
        }

        if let logText {
            let modified = (try? fm.attributesOfItem(atPath: c.logPath)[.modificationDate]) as? Date ?? c.now
            let since = c.now.addingTimeInterval(-c.logWindow)
            let errors = DynjectLogClock.errors(in: logText, modified: modified, since: since)
            let minutes = Int(c.logWindow / 60)
            if let last = errors.last {
                let amfid = last.line.contains("amfid not found")
                s.warn("log errors", "\(errors.count) ERROR line(s) in dynjectd.log in the last \(minutes) min; last at \(clock(last.date)): "
                       + last.line.trimmingCharacters(in: .whitespaces),
                       fix: amfid ? amfidHint : "read \(c.logPath) around that time")
            } else {
                s.ok("log errors", "dynjectd.log readable, no ERROR in the last \(minutes) min")
            }
        } else {
            s.warn("log errors", "can't read \(c.logPath)", fix: "the engine writes it as root, mode 644; check it exists and is readable")
        }
        if let attrs = try? fm.attributesOfItem(atPath: c.errorLogPath), let size = (attrs[.size] as? NSNumber)?.intValue, size > 0,
           let m = attrs[.modificationDate] as? Date, m > c.now.addingTimeInterval(-c.logWindow) {
            let last = DynjectLogParser.readTail(path: c.errorLogPath, maxBytes: 4096)?
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            s.warn("error log", "dynjectd.error.log written at \(clock(m)): \(last)", fix: "read \(c.errorLogPath)")
        }

        if let out = c.sipStatus() {
            let sip = SIPStatus.parse(out)
            let blocking = sip.blockingEngine
            switch (sip.state, blocking.isEmpty) {
            case (.disabled, _):
                s.warn("sip", "SIP fully disabled: the engine works, but only needs filesystem + debugging off", fix: sipHint)
            case (.enabled, _):
                s.problem("sip", "SIP fully enabled: the engine can't patch amfid, so nothing is injected", fix: sipHint)
            case (_, true):
                let extra = sip.alsoOff
                s.ok("sip", "SIP custom: filesystem + debugging off, as the engine needs"
                     + (extra.isEmpty ? "" : "; also off: " + extra.joined(separator: ", ").lowercased()))
            case (_, false):
                s.problem("sip", "SIP: \(blocking.joined(separator: " and ").lowercased()) still on; the engine needs both off", fix: sipHint)
            }
        } else {
            s.warn("sip", "couldn't run csrutil status", fix: nil)
        }
        return s.checks
    }

    // MARK: config

    static func config(_ c: DoctorContext, text: String?, manifests: [TweakManifest]) -> [DoctorCheck] {
        var s = DoctorSection("config")
        guard let text else {
            s.problem("config readable", "can't read \(c.configPath)",
                      fix: "restore it from ~/Library/Application Support/Dynject Workbench/Backups/ or reinstall the engine")
            return s.checks
        }
        let doc = ConfigDocument(text: text)
        let config = EffectiveConfig(document: doc)
        s.ok("config readable", "\(c.configPath): \(config.dylibPaths.count) dylib(s), \(config.allowRules.count) allow, "
             + "\(config.denyRules.count) deny rule(s)")
        // Missing files are the dylib checks' job below.
        let diagnostics = ConfigValidator.diagnose(doc, fileExists: { _ in true }).filter { $0.severity != .info }
        for d in diagnostics {
            let where_ = d.line.map { "line \($0 + 1): " } ?? ""
            if d.severity == .error { s.problem("config validator", where_ + d.message, fix: configHint) }
            else { s.warn("config validator", where_ + d.message, fix: configHint) }
        }
        if diagnostics.isEmpty { s.ok("config validator", "no validator findings") }

        let fm = FileManager.default
        for path in config.dylibPaths {
            let file = c.locations.filePath(forDylib: path)
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file), options: .mappedIfSafe) else {
                s.problem("dylib", "\(path): \(fm.fileExists(atPath: file) ? "unreadable" : "missing"); dynjectd skips it",
                          fix: "reinstall it (dw tweak install <folder>) or remove its dylib: line")
                continue
            }
            let check = MachOInfo.check(data, name: name(path))
            for e in check.errors { s.problem("dylib", e, fix: "rebuild it with its build.sh and reinstall") }
            for w in check.warnings { s.warn("dylib", w, fix: "rebuild it with its build.sh and reinstall") }
            let signature = check.errors.isEmpty ? c.codeSignatureProblem(file) : nil
            if let signature {
                s.problem("dylib", "\(name(path)): code signature invalid: \(signature)",
                          fix: "re-sign it (its build.sh signs ad-hoc) and reinstall; dyld refuses to load it")
            }
            if check.errors.isEmpty && check.warnings.isEmpty && signature == nil {
                s.ok("dylib", "\(name(path)): \(check.archs.joined(separator: ", ")), signature valid")
            }
        }
        let named = Set(manifests.map(\.dylib))
        for path in config.dylibPaths where !named.contains(path) {
            s.warn("manifest", "\(path) has no manifest: no settings page, no Safe Mode tweak id",
                   fix: "fine for third-party dylibs; tweak authors: ship a *.workbench.plist (docs/tweak-format.md)")
        }
        for m in manifests where config.dylib(path: m.dylib) == nil {
            s.warn("manifest", "\(m.name) (\(m.id)): the config doesn't declare \(m.dylib), so it loads nowhere",
                   fix: "install it with dw tweak install <folder>, or remove \(m.sourcePath)")
        }
        return s.checks
    }

    // MARK: tweaks

    static func tweaks(_ c: DoctorContext) -> [DoctorCheck] {
        var s = DoctorSection("tweaks")
        let (list, issues, _) = TweakInstaller.list(locations: c.locations)
        // A manifest without settings is fine here: it gives the tweak an id for Safe Mode and declares requirements.
        // A non-semantic version is listed per tweak below, with the version to use.
        for i in issues where i.message != "No usable settings items."
            && !(i.message.hasPrefix("version ") && i.message.contains("is not a semantic version")) {
            let detail = "\(name(i.file)): \(i.message)"
            let fix = "fix the manifest (docs/tweak-format.md), then reload in workbench"
            if i.severity == .error { s.problem("manifest", detail, fix: fix) } else { s.warn("manifest", detail, fix: fix) }
        }
        if list.isEmpty { s.ok("installed", "no tweak manifests in \(c.locations.manifestSearchDirectories.joined(separator: " or "))") }
        let locations = c.locations
        let env = TweakCompatibility.Environment(
            systemVersion: c.systemVersion, sdkVersion: c.version,
            components: BuiltInComponent.installedStatus(launchAgentsDirectory: c.safeModeAgent.launchAgentsDirectory),
            dylib: { DylibBuildInfo.read(dylibAt: locations.filePath(forDylib: $0.dylib)) })
        let installed = list.map(\.manifest)
        for t in list {
            let label = "\(t.manifest.name) (\(t.manifest.id))"
            guard t.fileExists else {
                s.problem("installed", "\(label): dylib missing at \(t.dylibFilePath)",
                          fix: "reinstall it (dw tweak install <folder>) or remove it (dw tweak uninstall \(t.manifest.id))")
                continue
            }
            switch t.safeMode {
            case .unsupported?:
                s.warn("safe mode support", "\(label): not built on DynjectHook, Safe Mode can't stop it",
                       fix: "only the config can turn it off (workbench switches, dw disable); authors: use DH_CTOR (docs/hooking.md)")
            case .perTweak?:
                s.warn("safe mode support", "\(label): built with an older DynjectHook, ignores the panic switch",
                       fix: "rebuild it against the current TweakSDK and reinstall")
            default:
                s.ok("installed", "\(label): \(t.policy)")
            }
            for i in TweakCompatibility.issues(for: t.manifest, installed: installed, environment: env) {
                // An older DynjectHook without the panic switch was reported above; its missing SDK marker says the same.
                if i.kind == .missingSDKMarker, t.safeMode == .perTweak { continue }
                let detail = "\(label): \(i.message)"
                if i.severity == .error { s.problem(i.kind.doctorCheck, detail, fix: i.fix) }
                else { s.warn(i.kind.doctorCheck, detail, fix: i.fix) }
            }
        }
        return s.checks
    }

    // MARK: inline hooks

    /// What the installed tweaks' DHHookFunction calls logged in the last `crashWindow` (DynjectHook logs under the
    /// tweak's ID as subsystem; other copies, like test hosts', are left out): hooks that went in, and the ones that
    /// didn't. "may not run code it made" is about the Mac (the process can't map code it changed); the others are
    /// about the function or the tweak.
    static func inlineHooks(_ c: DoctorContext, tweakIDs: Set<String>) -> [DoctorCheck] {
        guard let read = c.inlineHookLog else { return [] }
        var s = DoctorSection("inline hooks")
        let hours = Int(c.crashWindow / 3600)
        guard let text = read(c.now.addingTimeInterval(-c.crashWindow)) else {
            s.warn("log", "couldn't read the unified log to see DHHookFunction's results")
            return s.checks
        }
        var hooked: [String: Int] = [:]
        var cantRunCode: [String: Int] = [:]
        var other: [String] = []
        // compact: "<date> <time> <type> <process>[<pid>:<tid>] [<subsystem>:hook] <message>"; the process name may
        // have spaces ("System Settings").
        let pattern = try! NSRegularExpression(pattern: #"^\S+ \S+ \S+ (.+?)\[\d+:[0-9a-fx]+\] \[([^:\]]+):hook\] (DHHookFunction.*)$"#)
        for line in text.split(separator: "\n").map(String.init) {
            let ns = line as NSString
            guard let m = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let process = ns.substring(with: m.range(at: 1)), subsystem = ns.substring(with: m.range(at: 2))
            let message = ns.substring(with: m.range(at: 3))
            guard tweakIDs.contains(subsystem) else { continue }
            if message.hasSuffix(": hooking") || message.contains(": hooking (") { hooked[process, default: 0] += 1 }
            else if message.contains("may not run code it made") { cantRunCode[process, default: 0] += 1 }
            else if message.contains("not hooked") || message.contains("is NULL") {
                let entry = "\(subsystem) in \(process): \(message)"
                if !other.contains(entry) { other.append(entry) }
            }
        }
        func list(_ counts: [String: Int]) -> String {
            counts.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")
        }
        if !cantRunCode.isEmpty {
            s.problem("can patch code", "DHHookFunction couldn't hook in \(list(cantRunCode)) in the last \(hours) h: "
                      + "those processes may not run code they changed, which inline hooks need",
                      fix: "keep SIP's debugging restrictions off and dynject's loader running (it patches amfid): dw doctor's engine "
                           + "checks; tweaks fall back to method or import hooks there")
        }
        if !hooked.isEmpty {
            s.ok("hooked", "\(hooked.values.reduce(0, +)) function hook(s) in the last \(hours) h: \(list(hooked))")
        }
        for o in other.prefix(10) {
            s.warn("refused", o, fix: "that function can't be hooked inline (docs/hooking.md, \"Hooking any function\"); hook a caller or use DHHookImport")
        }
        if other.count > 10 { s.warn("refused", "… \(other.count - 10) more") }
        if hooked.isEmpty && cantRunCode.isEmpty && other.isEmpty {
            s.ok("hooked", "no installed tweak used DHHookFunction in the last \(hours) h")
        }
        return s.checks
    }

    // MARK: agents

    static func agents(_ c: DoctorContext, manifests: [TweakManifest]) -> [DoctorCheck] {
        var s = DoctorSection("agents")
        let fm = FileManager.default
        let app = c.workbenchApps.first { fm.fileExists(atPath: $0) }
        let reference = app.map { $0 + "/Contents/MacOS/dw" }.flatMap { fm.fileExists(atPath: $0) ? $0 : nil } ?? c.thisDw
        let referenceLabel = app != nil ? "the dw in \(DoctorContext.workbenchAppName)" : "this dw"
        let bridgeUsers = manifests.filter { !$0.bridge.isEmpty }.map(\.name)

        @discardableResult
        func agent(_ a: UserLaunchAgent, _ what: String, fix: String, needed: Bool, neededNote: String) -> LaunchAgentStatus {
            let st = a.status()
            guard st.plistInstalled else {
                if needed { s.warn(what, "\(what) not installed: \(neededNote)", fix: fix) }
                else { s.ok(what, "\(what) not installed (\(neededNote))") }
                return st
            }
            if !st.binaryInstalled {
                s.problem(what, "\(what): \(a.binaryURL.path) missing", fix: fix)
            } else if !st.loaded {
                s.warn(what, "\(what) installed, not loaded", fix: fix)
            } else if !st.running {
                s.warn(what, "\(what) loaded, not running" + (st.lastExitCode.map { " (last exit \($0))" } ?? ""), fix: fix)
            } else {
                s.ok(what, "\(what) running" + (st.pid.map { " (pid \($0))" } ?? ""))
            }
            if !st.plistMatches { s.warn(what, "\(what): \(name(a.plistURL.path)) doesn't run \(a.binaryURL.path)", fix: fix) }
            if st.binaryInstalled, let reference {
                switch AgentBinaryCheck.compare(installed: a.binaryURL.path, reference: reference) {
                case .differs:
                    s.warn(what, "\(what): \(a.binaryURL.path) differs from \(referenceLabel) (stale copy)", fix: fix)
                case .same: break
                case .unknown: s.warn(what, "\(what): couldn't compare \(a.binaryURL.path) with \(reference)", fix: nil)
                }
            }
            return st
        }
        agent(c.safeModeAgent, "safe mode watcher", fix: watcherHint, needed: true,
              neededNote: "crashing tweaks aren't switched off")
        let bridge = agent(c.bridgeAgent, "bridge broker", fix: bridgeHint, needed: !bridgeUsers.isEmpty,
              neededNote: bridgeUsers.isEmpty ? "no tweak declares bridge capabilities"
                  : "\(bridgeUsers.joined(separator: ", ")) declare bridge capabilities")
        if bridge.plistInstalled && bridge.running {
            if let token = c.bridgeToken() {
                if let p = BridgeTokenCheck.problem(token: token, service: c.bridgeService) {
                    s.problem("bridge token", "bridge token: \(p)", fix: bridgeHint)
                } else {
                    s.ok("bridge token", "bridge token published for \(c.bridgeService)")
                }
            } else {
                s.problem("bridge token", "bridge broker running but no token published: sandboxed tweaks can't reach it", fix: bridgeHint)
            }
        }
        return s.checks
    }

    // MARK: apple menu

    static func appleMenu(_ c: DoctorContext, manifests: [TweakManifest]) -> [DoctorCheck] {
        var s = DoctorSection("apple menu")
        let settings = c.menuSettings()
        let expected = MenuLoaderPublisher.payload(for: manifests, settings: settings)
        let published = MenuLoaderPublisher(store: c.menuStore, names: c.menuNames).currentPayload()
        if MenuLoaderPublisher.isSame(published, expected) {
            let items = (expected?["items"] as? [Any])?.count ?? 0
            let groups = (expected?["contributors"] as? [Any])?.count ?? 0
            s.ok("published list", "\(c.menuNames.key) matches the installed manifests (\(items) item(s) in \(groups) group(s))")
        } else {
            s.warn("published list", published == nil ? "\(c.menuNames.key) isn't published: no tweak items in apple menus"
                       : "\(c.menuNames.key) differs from what the installed manifests and workbench's options publish",
                   fix: "dw menu publish (or reload in workbench)")
        }
        return s.checks
    }

    // MARK: apps

    static func apps(_ plan: RespringPlan) -> [DoctorCheck] {
        var s = DoctorSection("apps")
        let pending = plan.pending
        if pending.isEmpty { s.ok("up to date", "\(plan.candidates.count) running app(s), none out of date") }
        for p in pending {
            let label = "\(p.app.name) (\(p.app.bundleID))"
            var detail = "\(label): \(p.reasonSummary)"
            if let e = p.exclusion { detail += "; \(e.note)" }
            s.warn("out of date", detail, fix: respringFix(p))
        }
        let blind = plan.notInspected
        if !blind.isEmpty {
            s.warn("not inspected", "couldn't inspect with lsof: " + blind.map(\.app.name).joined(separator: ", "), fix: nil)
        }
        return s.checks
    }

    /// How to relaunch an out-of-date app; nil for system processes that are never relaunched.
    /// `only`: relaunch just this app (dw why) rather than every out-of-date one (doctor).
    static func respringFix(_ p: RespringCandidate, only: Bool = false) -> String? {
        switch p.exclusion {
        case nil: return only ? "dw respring --only \(p.app.bundleID)" : "dw respring"
        case .protectedSystem?: return nil
        case .injectionBlocked?: return "check its hardened runtime / library validation; a relaunch won't fix it"
        case .hostsThisProcess?: return "quit and reopen it yourself"
        case .developerTool?: return "relaunch it yourself, or dw respring --include \(p.app.bundleID)"
        case .finder?, .workbench?: return "dw respring --include \(p.app.bundleID)"
        }
    }

    // MARK: safe mode

    static func safeMode(_ c: DoctorContext, manifests: [TweakManifest]) -> [DoctorCheck] {
        var s = DoctorSection("safe mode")
        let catalog = SafeModeCatalog(manifests: manifests, dylibDirectory: c.locations.dylibFileDirectory)
        let snap = c.safeMode.snapshot(catalog: catalog)
        if snap.panic {
            s.warn("panic", "panic switch on: no DynjectHook tweak loads in apps launched now", fix: "dw safemode panic off")
        }
        for d in snap.disabled {
            let who = d.tweakID == SafeModeNames.all ? "every DynjectHook tweak" : d.tweak?.name ?? d.tweakID
            let where_ = d.bundleID == SafeModeNames.all ? "every app" : d.bundleID
            let why = d.reason?.rawValue ?? "set outside workbench"
            func q(_ v: String) -> String { v == SafeModeNames.all ? "'*'" : v }
            s.warn("disabled", "\(who) off in \(where_): \(why)" + (d.since.map { ", since \(clock($0))" } ?? ""),
                   fix: "dw safemode enable \(q(d.tweakID)) \(q(d.bundleID))")
        }
        let cutoff = c.now.addingTimeInterval(-c.crashWindow)
        // The watcher keeps one record per (report, loaded tweak); doctor shows one line per crash, naming the tweak
        // it happened in apart from the ones that were only loaded.
        var recent: [[SafeModeCrash]] = []
        for crash in snap.recentCrashes where crash.date >= cutoff {
            if let i = recent.firstIndex(where: { $0[0].reportPath == crash.reportPath }) { recent[i].append(crash) }
            else { recent.append([crash]) }
        }
        func names(_ ids: [String]) -> String {
            ids.map { catalog.tweak($0)?.name ?? $0 }.sorted().joined(separator: ", ")
        }
        for records in recent.prefix(5) {
            let first = records[0]
            let culprits = records.filter(\.inTweak).map(\.tweakID)
            let bystanders = records.map(\.tweakID).filter { !culprits.contains($0) }
            var what = culprits.isEmpty ? "crashed with \(names(bystanders)) loaded"
                                        : "crashed in \(names(culprits))" + (bystanders.isEmpty ? "" : " (also loaded: \(names(bystanders)))")
            what += ": \(first.frameSummary)"
            let reportExists = FileManager.default.fileExists(atPath: first.reportPath)
            s.warn("crash", "\(clock(first.date)) \(first.appName ?? first.bundleID ?? "?") \(what)",
                   fix: reportExists ? "read the report: \(first.reportPath)" : "its report has been deleted; dw safemode status lists the record")
        }
        if recent.count > 5 {
            s.warn("crash", "\(recent.count - 5) more tweak-related crash(es) in the last \(Int(c.crashWindow / 3600)) h", fix: "dw safemode status")
        }
        if !snap.panic && snap.disabled.isEmpty && recent.isEmpty {
            s.ok("safe mode", "nothing disabled, panic off, no tweak-related crashes in \(Int(c.crashWindow / 3600)) h")
        }
        return s.checks
    }

    // MARK: workbench

    static func workbench(_ c: DoctorContext) -> [DoctorCheck] {
        var s = DoctorSection("workbench")
        let fm = FileManager.default
        guard let app = c.workbenchApps.first(where: { fm.fileExists(atPath: $0) }) else {
            s.warn("app", "\(DoctorContext.workbenchAppName) isn't in \(c.workbenchApps.map { ($0 as NSString).deletingLastPathComponent }.joined(separator: " or "))",
                   fix: "build and install it: ./scripts/bootstrap.sh")
            return s.checks
        }
        let info = fm.contents(atPath: app + "/Contents/Info.plist")
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let version = info?["CFBundleShortVersionString"] as? String
        if version == c.version {
            s.ok("app", "\(app) \(c.version), same as this dw")
        } else {
            s.warn("app", "\(app) is \(version ?? "unknown"), this dw is \(c.version)",
                   fix: "rebuild and reinstall: ./scripts/bootstrap.sh, then reinstall the agents")
        }
        return s.checks
    }

    // MARK: - apis

    /// `dw doctor --apis`: each manifest's `requires` (plus what its declared features imply) and Workbench's own
    /// needs, checked in this process. Missing required APIs are problems, missing optional ones warnings.
    public static func apis(manifests: [TweakManifest], evaluator: TweakRequirementEvaluator = TweakRequirementEvaluator(),
                            bridgeInUse: Bool, system: String = macOSDescription) -> DoctorReport {
        var s = DoctorSection("apis")
        s.ok("macOS", system)
        func judge(_ who: String, _ reqs: [TweakRequirement], missingIsProblem: Bool, consequence: String, fix: String) {
            let results = evaluator.evaluate(reqs)
            let required = results.filter { !$0.requirement.optional }.flatMap(\.missing)
            let optional = results.filter { $0.requirement.optional }.flatMap(\.missing)
            if !required.isEmpty {
                let detail = "\(who): missing \(required.joined(separator: ", ")): \(consequence)"
                if missingIsProblem { s.problem(who, detail, fix: fix) } else { s.warn(who, detail, fix: fix) }
            }
            if !optional.isEmpty {
                s.warn(who, "\(who): optional \(optional.joined(separator: ", ")) missing; a feature is off", fix: nil)
            }
            if required.isEmpty && optional.isEmpty {
                s.ok(who, "\(who): all present: " + reqs.map(\.summary).joined(separator: ", "))
            }
        }
        for m in manifests {
            let who = "\(m.name) (\(m.id))"
            let reqs = m.effectiveRequirements
            if m.requires == nil && reqs.isEmpty {
                s.warn(who, "\(who): declares no requirements, nothing to check",
                       fix: "tweak authors: declare requires in the manifest (docs/tweak-format.md#requirements)")
            } else if reqs.isEmpty {
                s.ok(who, "\(who): needs nothing private")
            } else {
                judge(who, reqs, missingIsProblem: true, consequence: "this tweak will probably misbehave on this macOS",
                      fix: "look for an update; meanwhile turn it off in the config (workbench switches, dw disable)")
            }
        }
        judge("workbench bridge broker", TweakRequirement.bridgeBroker, missingIsProblem: bridgeInUse,
              consequence: "sandboxed tweaks can't reach the broker, or it identifies no caller",
              fix: "docs/bridge.md#private-spi; look for a workbench update")
        return DoctorReport(checks: s.checks)
    }
}

extension CompatibilityIssue.Kind {
    /// The check name `dw doctor` lists it under.
    var doctorCheck: String {
        switch self {
        case .systemTooOld, .untestedSystem: return "macos"
        case .nonSemanticVersion: return "version"
        case .oldSDK, .missingSDKMarker: return "sdk"
        case .unmetDependency: return "depends"
        }
    }
}
