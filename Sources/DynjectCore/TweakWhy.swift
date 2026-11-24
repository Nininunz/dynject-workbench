import Foundation

// `dw why <tweak> <app>`: every check between "the app launches" and "the tweak runs", in the order they happen,
// each with its outcome and what to do, and the first one that stops the tweak. The checks are pure (`Why.explain`
// on `WhyInputs`); `WhyInputs.live` gathers them from the real system, read-only.

// MARK: - DH_CTOR's marker

/// What a DH_CTOR compiled into a dylib says: `dynject.ctor:<tweak ID as written>|<bundle IDs as written>`.
public struct CtorMarker: Equatable, Sendable {
    public static let prefix = "dynject.ctor:"

    /// nil when DH_CTOR's tweak ID isn't a string literal.
    public var tweakID: String?
    /// The apps the tweak targets; empty: every app. nil when they aren't all string literals (a macro, a variable).
    public var bundleIDs: [String]?

    public init(tweakID: String?, bundleIDs: [String]?) {
        self.tweakID = tweakID
        self.bundleIDs = bundleIDs
    }

    /// Every marker in `data`, in file order, without duplicates (a universal dylib has one per slice).
    public static func markers(in data: Data) -> [CtorMarker] {
        let prefix = Data(Self.prefix.utf8)
        var out: [CtorMarker] = []
        var start = data.startIndex
        while let r = data.range(of: prefix, in: start..<data.endIndex) {
            start = r.upperBound
            guard let end = data[r.upperBound...].firstIndex(of: 0), end - r.upperBound <= 4096 else { continue }
            if let m = parse(String(decoding: data[r.upperBound..<end], as: UTF8.self)), !out.contains(m) { out.append(m) }
            start = end
        }
        return out
    }

    /// The text after the prefix: `"id"|"a", "b"`.
    public static func parse(_ text: String) -> CtorMarker? {
        guard let (idPart, rest) = literals(Substring(text), stopAt: "|"), let rest else { return nil }
        let id = idPart.flatMap { $0.count == 1 ? $0[0] : nil }
        guard let (bundles, _) = literals(rest.dropFirst(), stopAt: nil) else { return nil }
        return CtorMarker(tweakID: id, bundleIDs: bundles)
    }

    /// Comma-separated C string literals (adjacent ones concatenate) up to `stopAt` outside a literal. Returns the
    /// values (nil if anything but literals, commas and spaces is there) and the rest from `stopAt` on (nil if not
    /// found). nil overall for an unterminated literal.
    static func literals(_ s: Substring, stopAt: Character?) -> ([String]?, Substring?)? {
        var values: [String] = []
        var onlyLiterals = true
        var afterComma = true
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if let stopAt, c == stopAt { return (onlyLiterals ? values : nil, s[i...]) }
            if c == " " || c == "\t" { i = s.index(after: i); continue }
            if c == "," { afterComma = true; i = s.index(after: i); continue }
            guard c == "\"" else {
                onlyLiterals = false
                i = s.index(after: i)
                continue
            }
            var value = ""
            var j = s.index(after: i)
            var closed = false
            while j < s.endIndex {
                let d = s[j]
                if d == "\\" {
                    j = s.index(after: j)
                    guard j < s.endIndex else { break }
                    value.append(s[j])
                } else if d == "\"" {
                    closed = true
                    break
                } else {
                    value.append(d)
                }
                j = s.index(after: j)
            }
            guard closed else { return nil }
            if afterComma || values.isEmpty { values.append(value) } else { values[values.count - 1] += value }
            afterComma = false
            i = s.index(after: j)
        }
        return (onlyLiterals ? values : nil, stopAt == nil ? s[s.endIndex...] : nil)
    }
}

// MARK: - Report

public enum WhyStatus: String, Codable, Sendable {
    /// Lets it through.
    case pass
    /// Stops it.
    case fail
    /// May stop it, or should be looked at.
    case warning
    /// Couldn't be checked.
    case unknown
    /// Context, neither for nor against.
    case info

    public var symbol: String {
        switch self {
        case .pass: return "✓"
        case .fail: return "✗"
        case .warning: return "!"
        case .unknown: return "?"
        case .info: return "-"
        }
    }
}

public struct WhyStep: Codable, Equatable, Sendable {
    public var section: String
    /// A short, stable name, e.g. "process gate".
    public var check: String
    public var status: WhyStatus
    public var detail: String
    public var fix: String?

    public init(section: String, check: String, status: WhyStatus, detail: String, fix: String? = nil) {
        self.section = section
        self.check = check
        self.status = status
        self.detail = detail
        self.fix = fix
    }

    enum CodingKeys: String, CodingKey { case section, check, status, detail, fix }

    /// `fix` is always present (null when there is none).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(section, forKey: .section)
        try c.encode(check, forKey: .check)
        try c.encode(status, forKey: .status)
        try c.encode(detail, forKey: .detail)
        try c.encode(fix, forKey: .fix)
    }
}

public struct WhyReport: Sendable {
    public var tweak: String
    public var app: String
    public var steps: [WhyStep]
    /// Running with the current copy loaded (and nothing stopping it).
    public var loadedNow: Bool
    public var appName: String

    /// What stops it, in order.
    public var blockers: [WhyStep] { steps.filter { $0.status == .fail } }
    public var loads: Bool { blockers.isEmpty }
    /// 0 when nothing stops it, 1 otherwise.
    public var exitCode: Int32 { loads ? 0 : 1 }

    public var verdict: String {
        if let first = blockers.first {
            let more = blockers.count - 1
            return "it doesn't load: \(first.detail)" + (more > 0 ? " (and \(more) more ✗ above)" : "")
        }
        let unknown = steps.filter { $0.status == .unknown }.count
        let caveat = unknown > 0 ? "; \(unknown) check\(unknown == 1 ? "" : "s") couldn't be made (?)" : ""
        if loadedNow { return "it's loaded in the running \(appName)\(caveat)" }
        return "nothing stops it: it should load at \(appName)'s next launch\(caveat)"
    }

    public func text(header: String? = nil) -> String {
        var out: [String] = []
        if let header { out += [header, ""] }
        var sections: [String] = []
        for s in steps where !sections.contains(s.section) { sections.append(s.section) }
        for section in sections {
            out.append(section)
            for s in steps where s.section == section {
                out.append("  \(s.status.symbol) \(s.detail)")
                if s.status != .pass, s.status != .info, let fix = s.fix { out.append("      → \(fix)") }
            }
            out.append("")
        }
        out.append("→ \(verdict)")
        return out.joined(separator: "\n")
    }

    struct JSONShape: Encodable {
        var tweak: String
        var app: String
        var loads: Bool
        var verdict: String
        var steps: [WhyStep]
    }

    /// {tweak, app, loads, verdict, steps: [{section, check, status, detail, fix}]}.
    public func json() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(JSONShape(tweak: tweak, app: app, loads: loads, verdict: verdict, steps: steps))) ?? Data("{}".utf8)
    }
}

// MARK: - Inputs

/// One line from the tweak's unified log.
public struct WhyLogLine: Equatable, Sendable {
    public var date: Date?
    public var process: String
    public var message: String

    public init(date: Date?, process: String, message: String) {
        self.date = date
        self.process = process
        self.message = message
    }

    /// Lines of `log show --style compact`: "2026-11-20 18:57:06.249 Df Finder[41566:6ecea3] [sub:cat] message".
    public static func parse(_ output: String) -> [WhyLogLine] {
        let re = try! NSRegularExpression(
            pattern: #"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)(?:\.\d+)? +\S+ +(.+?)\[\d+:[0-9a-fA-F]+\] +(?:\[[^\]]*\] +)?(.*)$"#)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out: [WhyLogLine] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges == 4,
                  let d = Range(m.range(at: 1), in: s), let p = Range(m.range(at: 2), in: s),
                  let t = Range(m.range(at: 3), in: s) else { continue }
            out.append(WhyLogLine(date: f.date(from: String(s[d])), process: String(s[p]), message: String(s[t])))
        }
        return out
    }
}

/// The running copy of the app, if any.
public enum WhyRunning: Sendable {
    case notRunning
    case running(RespringCandidate)
}

/// Everything `Why.explain` looks at.
public struct WhyInputs: Sendable {
    /// For labels: the manifest's name, else the dylib's file name.
    public var tweakName: String
    /// From the manifest, else from the dylib's DH_CTOR marker; nil when neither says.
    public var tweakID: String?
    public var manifest: TweakManifest?
    /// As the config names it.
    public var dylibPath: String
    public var dylibFileExists: Bool
    /// nil when the file can't be read as Mach-O.
    public var dylibSlices: [MachOInfo.Slice]?
    public var ctorMarkers: [CtorMarker]
    /// nil when the file can't be read.
    public var safeModeSupport: SafeModeSupport?
    /// The manifest's compatibility issues on this Mac.
    public var compatibilityIssues: [CompatibilityIssue]

    public var app: InstalledApp
    /// The app executable's architectures; nil when it can't be read.
    public var appArchs: [String]?
    public var appleSilicon: Bool
    public var service: ServiceName

    public var config: EffectiveConfig
    public var daemon: DaemonStatus
    /// "dynject.safemode": tweak ID → bundle IDs.
    public var safeModeEntries: [String: [String]]
    /// Why Safe Mode turned things off (state.json).
    public var safeModeDisabled: [SafeModeDisabledEntry]
    public var running: WhyRunning
    /// The tweak's log lines about this app, oldest first; nil when not searched.
    public var log: [WhyLogLine]?
    public var logMinutes: Int

    public init(tweakName: String, tweakID: String?, manifest: TweakManifest?, dylibPath: String, dylibFileExists: Bool,
                dylibSlices: [MachOInfo.Slice]?, ctorMarkers: [CtorMarker], safeModeSupport: SafeModeSupport?,
                compatibilityIssues: [CompatibilityIssue], app: InstalledApp, appArchs: [String]?, appleSilicon: Bool,
                service: ServiceName, config: EffectiveConfig, daemon: DaemonStatus, safeModeEntries: [String: [String]],
                safeModeDisabled: [SafeModeDisabledEntry] = [], running: WhyRunning, log: [WhyLogLine]?, logMinutes: Int = 60) {
        self.tweakName = tweakName
        self.tweakID = tweakID
        self.manifest = manifest
        self.dylibPath = dylibPath
        self.dylibFileExists = dylibFileExists
        self.dylibSlices = dylibSlices
        self.ctorMarkers = ctorMarkers
        self.safeModeSupport = safeModeSupport
        self.compatibilityIssues = compatibilityIssues
        self.app = app
        self.appArchs = appArchs
        self.appleSilicon = appleSilicon
        self.service = service
        self.config = config
        self.daemon = daemon
        self.safeModeEntries = safeModeEntries
        self.safeModeDisabled = safeModeDisabled
        self.running = running
        self.log = log
        self.logMinutes = logMinutes
    }
}

// MARK: - Finding the tweak and the app

public enum WhyLookupError: Error, Equatable, CustomStringConvertible {
    case noTweak(String, known: [String])
    case ambiguousTweak(String, matches: [String])
    case noApp(String)
    case ambiguousApp(String, matches: [String])

    public var description: String {
        switch self {
        case let .noTweak(arg, known):
            return "no installed tweak matches \"\(arg)\"" + (known.isEmpty ? "" : "; installed: \(known.joined(separator: ", "))")
        case let .ambiguousTweak(arg, matches):
            return "\"\(arg)\" matches several tweaks: \(matches.joined(separator: ", ")); use the tweak ID"
        case let .noApp(arg):
            return "no app matches \"\(arg)\" in /Applications, ~/Applications, /System/Applications or /System/Library/CoreServices; give its bundle ID or the .app path"
        case let .ambiguousApp(arg, matches):
            return "\"\(arg)\" matches several apps: \(matches.joined(separator: ", ")); give the .app path"
        }
    }
}

public struct WhyTweakChoice: Sendable {
    public var manifest: TweakManifest?
    /// As the config names it.
    public var dylibPath: String
}

public enum WhyLookup {
    /// By tweak ID, then name, then dylib file name (with or without "lib" and ".dylib"), then dylib path; case
    /// doesn't matter. `configDylibs` adds dylibs the config declares without a manifest.
    public static func tweak(_ arg: String, manifests: [TweakManifest], configDylibs: [String]) -> Result<WhyTweakChoice, WhyLookupError> {
        let a = arg.lowercased()
        func file(_ path: String) -> String { (path as NSString).lastPathComponent.lowercased() }
        func fileMatches(_ path: String) -> Bool {
            let f = file(path)
            return f == a || f == "lib\(a).dylib" || f == "\(a).dylib" || f == "lib\(a)"
                || path.lowercased() == (arg as NSString).expandingTildeInPath.lowercased()
        }
        let manifested = Set(manifests.map(\.dylib))
        let bare = configDylibs.filter { !manifested.contains($0) }
        let tiers: [[WhyTweakChoice]] = [
            manifests.filter { $0.id.lowercased() == a }.map { WhyTweakChoice(manifest: $0, dylibPath: $0.dylib) },
            manifests.filter { $0.name.lowercased() == a }.map { WhyTweakChoice(manifest: $0, dylibPath: $0.dylib) },
            manifests.filter { fileMatches($0.dylib) }.map { WhyTweakChoice(manifest: $0, dylibPath: $0.dylib) }
                + bare.filter(fileMatches).map { WhyTweakChoice(manifest: nil, dylibPath: $0) },
        ]
        for tier in tiers where !tier.isEmpty {
            if tier.count == 1 { return .success(tier[0]) }
            return .failure(.ambiguousTweak(arg, matches: tier.map { $0.manifest?.id ?? $0.dylibPath }))
        }
        return .failure(.noTweak(arg, known: manifests.map(\.id).sorted() + bare.map { ($0 as NSString).lastPathComponent }))
    }

    /// By bundle ID, then display name or bundle file name ("Visual Studio Code" for Code), then executable name;
    /// case doesn't matter. A path to a .app is read
    /// with `readBundle`.
    public static func app(_ arg: String, apps: [InstalledApp],
                           readBundle: (String) -> InstalledApp? = AppDiscovery.read(bundleAt:)) -> Result<InstalledApp, WhyLookupError> {
        let expanded = (arg as NSString).expandingTildeInPath
        if expanded.hasSuffix(".app") || expanded.hasSuffix(".app/"), expanded.contains("/") {
            if let app = readBundle(expanded) { return .success(app) }
            return .failure(.noApp(arg))
        }
        let a = arg.lowercased()
        let name = a.hasSuffix(".app") ? String(a.dropLast(4)) : a
        let tiers = [
            apps.filter { $0.bundleID.lowercased() == a },
            apps.filter {
                $0.displayName.lowercased() == name
                    || ($0.bundlePath as NSString).lastPathComponent.lowercased() == name + ".app"
            },
            apps.filter { $0.executableName.lowercased() == a },
        ]
        for tier in tiers where !tier.isEmpty {
            if tier.count == 1 { return .success(tier[0]) }
            return .failure(.ambiguousApp(arg, matches: tier.map(\.bundlePath)))
        }
        return .failure(.noApp(arg))
    }
}

// MARK: - The checks

public enum Why {
    /// The architecture the app's process runs as. Apple's own apps run arm64e when they have it; others run arm64
    /// when they have it (a third-party arm64e slice is only used when there is no arm64 one); x86_64 apps run under
    /// Rosetta. nil when nothing fits.
    public static func processArch(appArchs: [String], bundleID: String, appleSilicon: Bool) -> String? {
        guard appleSilicon else { return appArchs.contains("x86_64") ? "x86_64" : nil }
        let apple = bundleID.lowercased().hasPrefix("com.apple.")
        if appArchs.contains("arm64e"), apple || !appArchs.contains("arm64") { return "arm64e" }
        if appArchs.contains("arm64") { return "arm64" }
        if appArchs.contains("x86_64") { return "x86_64" }
        return nil
    }

    static func clock(_ d: Date?) -> String { Doctor.clock(d) }

    /// Apps dynjectd never gets into, whatever the config says, and why (seen on macOS 27.2).
    public static let unreachable: [String: String] = [
        "com.apple.loginwindow": "dynjectd never sees loginwindow start: macOS starts its per-session copies "
            + "(com.apple.loginwindow.<UUID>) outside the xpcproxy launch dynjectd watches, and its log has no line "
            + "for them, so no tweak gets in",
    ]

    public static func explain(_ i: WhyInputs) -> WhyReport {
        var steps: [WhyStep] = []
        func add(_ section: String, _ check: String, _ status: WhyStatus, _ detail: String, fix: String? = nil) {
            steps.append(WhyStep(section: section, check: check, status: status, detail: detail, fix: fix))
        }
        let app = i.app
        let bundle = app.bundleID
        let dylibName = (i.dylibPath as NSString).lastPathComponent
        let enableFix = "dw enable \(i.dylibPath) \(bundle)"

        // dynjectd
        let engine = "dynjectd"
        if i.daemon.processes.isEmpty {
            add(engine, "running", .fail, "dynjectd isn't running, so nothing is injected", fix: Doctor.restartHint)
        } else if i.daemon.isDuplicated {
            add(engine, "running", .warning, "\(i.daemon.processes.count) dynjectd processes are running; only one should",
                fix: Doctor.restartHint)
        } else if !i.daemon.staleProcesses.isEmpty {
            add(engine, "running", .warning, "dynjectd started before dynjectd.conf last changed: it still decides with the old config",
                fix: Doctor.restartHint)
        } else {
            add(engine, "running", .pass, "running (pid \(i.daemon.processes[0].pid)), with the current config")
        }
        if let why = unreachable[bundle] { add(engine, "reaches it", .fail, why) }

        // dynjectd.conf, at launch
        let conf = "dynjectd.conf (at launch)"
        let declared = i.config.dylib(path: i.dylibPath)
        if let declared {
            add(conf, "declared", .pass, "declared on line \(declared.line + 1): \(declared.defaultAllow ? "allow" : "deny") by default")
        } else {
            add(conf, "declared", .fail, "\(dylibName) has no dylib: line in dynjectd.conf, so dynjectd never injects it",
                fix: "dw tweak install <its folder> (or add the line in Workbench → Raw Config)")
        }
        if !i.dylibFileExists {
            add(conf, "file", .fail, "the file is missing: \(i.dylibPath) (dynjectd skips missing files)",
                fix: "reinstall it: dw tweak install <its folder>")
        }
        let s = i.service
        let serviceNote: String
        switch s.source {
        case .observed: serviceNote = "service \(s.value), from dynjectd's log"
        case .launchdLabel: serviceNote = "service \(s.value), its launchd label"
        case .predicted: serviceNote = "service \(s.value), predicted (dynjectd's log shows the real one after a launch)"
        }
        let sg = PolicyEvaluator.serviceGate(s.value, config: i.config)
        if sg.passed {
            add(conf, "service gate", .pass, "service gate: \(sg.reason) (\(serviceNote))")
        } else {
            let fix: String?
            if sg.reason.hasPrefix("XPC service matches system-daemon") { fix = nil }
            else if sg.reason.contains("deny:") { fix = "remove or narrow that deny: rule (Workbench → Raw Config)" }
            else { fix = "add an allow: rule matching part of the service name (Workbench → Raw Config)" }
            add(conf, "service gate", .fail, "service gate: \(sg.reason) (\(serviceNote))", fix: fix)
        }
        let pg = PolicyEvaluator.processGate(name: app.executableName, path: app.executablePath, config: i.config)
        if pg.passed {
            add(conf, "process gate", .pass, "process gate: \(pg.reason)")
        } else {
            let fix: String
            if pg.reason.hasPrefix("skip_helpers") { fix = "turn skip_helpers off in Workbench → Raw Config, if you mean to inject helpers" }
            else if pg.reason.contains("deny:") { fix = "remove or narrow that deny: rule (Workbench → Raw Config); it stops every tweak here" }
            else { fix = "\(enableFix) (adds allow:\(app.executableName))" }
            add(conf, "process gate", .fail, "process gate: \(pg.reason)", fix: fix)
        }
        if declared != nil,
           let d = PolicyEvaluator.decisions(service: s.value, config: i.config, fileExists: { _ in true })
               .first(where: { $0.dylibPath == i.dylibPath }) {
            if d.allowed {
                add(conf, "dylib rule", .pass, "\(dylibName): \(d.reasonText)")
            } else {
                add(conf, "dylib rule", .fail, "\(dylibName): \(d.reasonText), so it isn't injected here", fix: enableFix)
            }
        }

        // dyld, at launch
        let dyld = "dyld (at launch)"
        if i.dylibFileExists {
            if let slices = i.dylibSlices, let appArchs = i.appArchs {
                let archs = slices.map(\.arch)
                if let arch = processArch(appArchs: appArchs, bundleID: bundle, appleSilicon: i.appleSilicon) {
                    let has = "the dylib has \(archs.joined(separator: " "))"
                    // dyld loads a dylib's arm64e slice into an arm64 process too, and prefers it.
                    let loadable = arch == "arm64" ? ["arm64e", "arm64"] : [arch]
                    if let slice = loadable.lazy.compactMap({ a in slices.first { $0.arch == a } }).first {
                        let which = slice.arch == arch ? "" : " (it loads the \(slice.arch) slice)"
                        add(dyld, "architecture", .pass, "\(app.displayName) runs as \(arch); \(has)\(which)")
                        if slice.arch != "x86_64", !slice.isSigned {
                            add(dyld, "signature", .fail, "its \(slice.arch) slice isn't code signed; Apple silicon won't run unsigned code",
                                fix: "sign it (codesign -s - <dylib>; the tweak's build.sh does) and reinstall")
                        }
                    } else {
                        add(dyld, "architecture", .fail, "\(app.displayName) runs as \(arch); \(has), so dyld can't load it",
                            fix: "build with -arch \(arch) too, as the tweak template does, and reinstall")
                    }
                } else {
                    add(dyld, "architecture", .unknown, "can't tell how \(app.displayName) runs (its executable has \(appArchs.joined(separator: " ")))")
                }
            } else {
                add(dyld, "architecture", .unknown, i.dylibSlices == nil ? "can't read the dylib's Mach-O header"
                    : "can't read \(app.displayName)'s executable")
            }
        }

        // DynjectHook, in the app
        let hook = "the tweak (in the app, before main)"
        let support = i.safeModeSupport
        var tweakID = i.tweakID
        if support == .unsupported {
            add(hook, "dynjecthook", .info, "not built on DynjectHook: no target list or Safe Mode to check; its own code decides whether it runs")
        } else if i.dylibFileExists {
            let marker = i.ctorMarkers.first { $0.tweakID != nil && $0.tweakID == tweakID }
                ?? (i.ctorMarkers.count == 1 && (tweakID == nil || i.ctorMarkers[0].tweakID == nil) ? i.ctorMarkers[0] : nil)
            if tweakID == nil { tweakID = marker?.tweakID }
            switch marker?.bundleIDs {
            case nil where marker == nil:
                let several = i.ctorMarkers.count > 1 ? " (it has DH_CTOR markers, none for \(tweakID ?? "its ID"))" : ""
                add(hook, "targets", .unknown, "can't tell which apps it targets: built before DynjectHook 0.1.2, which marks them\(several)",
                    fix: "rebuild and reinstall it; until then the log below shows what happened at the last launch")
            case nil:
                add(hook, "targets", .unknown, "its DH_CTOR names its apps with something other than string literals, so they can't be read")
            case let ids? where ids.isEmpty:
                add(hook, "targets", .pass, "targets every app (DH_CTOR lists no bundle IDs)")
            case let ids? where ids.contains(bundle):
                add(hook, "targets", .pass, ids.count == 1 ? "targets \(bundle)" : "targets \(bundle), one of \(ids.count) apps in its DH_CTOR")
            case let ids?:
                if let near = ids.first(where: { $0.lowercased() == bundle.lowercased() }) {
                    add(hook, "targets", .fail, "its DH_CTOR lists \"\(near)\" but the app's bundle ID is \"\(bundle)\"; DynjectHook compares them exactly, case included",
                        fix: "change it to \"\(bundle)\" in DH_CTOR, rebuild and reinstall")
                } else {
                    add(hook, "targets", .fail, "its DH_CTOR targets only \(ids.joined(separator: ", ")), not \(bundle)",
                        fix: "it isn't meant for this app; to change that, add \"\(bundle)\" to its DH_CTOR and rebuild")
                }
            }

            // Safe Mode
            if let id = tweakID {
                let own = i.safeModeEntries[id] ?? []
                let all = i.safeModeEntries[SafeModeNames.all] ?? []
                let why = i.safeModeDisabled.first { $0.tweakID == id && ($0.bundleID == bundle || $0.bundleID == SafeModeNames.all) }
                    .map { " (\($0.reason.rawValue), since \(clock($0.since)))" } ?? ""
                if own.contains(SafeModeNames.all) {
                    add(hook, "safe mode", .fail, "Safe Mode has it off in every app\(why)", fix: "dw safemode enable \(id) '*'")
                } else if own.contains(bundle) {
                    add(hook, "safe mode", .fail, "Safe Mode has it off in \(app.displayName)\(why)", fix: "dw safemode enable \(id) \(bundle)")
                } else if all.contains(SafeModeNames.all) || all.contains(bundle) {
                    let panic = all.contains(SafeModeNames.all)
                    if support == .perTweak {
                        add(hook, "safe mode", .info, panic ? "the panic switch is on, but this build's older DynjectHook ignores it"
                            : "Safe Mode has every tweak off in \(app.displayName), but this build's older DynjectHook ignores that")
                    } else if panic {
                        add(hook, "safe mode", .fail, "the panic switch is on: no DynjectHook tweak loads anywhere", fix: "dw safemode panic off")
                    } else {
                        add(hook, "safe mode", .fail, "Safe Mode has every tweak off in \(app.displayName)", fix: "dw safemode enable '*' \(bundle)")
                    }
                } else {
                    add(hook, "safe mode", .pass, "Safe Mode doesn't stop it here")
                }
            } else {
                add(hook, "safe mode", .unknown, "no tweak ID (no manifest, no DH_CTOR marker), so Safe Mode can't be checked")
            }
            add(hook, "shift", .info, "holding Shift while \(app.displayName) launches skips it; DynjectHook checks only then")
        }
        for issue in i.compatibilityIssues {
            switch issue.kind {
            case .systemTooOld: add(hook, "macos", .fail, issue.message, fix: issue.fix)
            case .untestedSystem: add(hook, "macos", .warning, issue.message, fix: issue.fix)
            case .unmetDependency: add(hook, "depends", .warning, issue.message, fix: issue.fix)
            default: break
            }
        }
        if let min = i.manifest?.minimumSystemVersion, !i.compatibilityIssues.contains(where: { $0.kind == .systemTooOld }) {
            add(hook, "macos", .pass, "needs macOS \(min) or later, which this Mac has")
        }

        // Now
        let now = "now"
        var loadedNow = false
        switch i.running {
        case .notRunning:
            add(now, "running", .info, "\(app.displayName) isn't running")
        case let .running(c):
            let pid = c.app.pid
            let mine = c.reasons.filter { $0.dylib == i.dylibPath }
            if c.loaded == nil {
                add(now, "running", .unknown, "\(app.displayName) is running (pid \(pid)), but lsof couldn't look inside it")
            } else if c.loaded!.contains(i.dylibPath) {
                if let r = mine.first(where: { $0.kind == .updated }) {
                    add(now, "running", .warning, "\(app.displayName) (pid \(pid)) runs an older copy: the file changed at \(clock(r.date)), after it launched",
                        fix: Doctor.respringFix(c, only: true) ?? "relaunch it")
                } else if let r = mine.first(where: { $0.kind == .unwanted }) {
                    add(now, "running", .warning, "\(app.displayName) (pid \(pid)) has it loaded, though the config no longer injects it: \(r.detail)",
                        fix: Doctor.respringFix(c, only: true) ?? "relaunch it")
                } else if let r = mine.first(where: { $0.kind == .safeModeOff || $0.kind == .safeModeOn }) {
                    add(now, "running", .warning, "\(app.displayName) (pid \(pid)) has it loaded. \(r.detail)", fix: Doctor.respringFix(c, only: true) ?? "relaunch it")
                } else {
                    add(now, "running", .pass, "\(app.displayName) (pid \(pid)) has it loaded")
                    loadedNow = true
                }
            } else if mine.contains(where: { $0.kind == .missing }) {
                if c.exclusion == .injectionBlocked {
                    add(now, "running", .fail, "\(app.displayName) (pid \(pid)) launched after the config took effect and still lacks it; something stops the injection (hardened runtime, library validation)",
                        fix: "check its code signature flags: codesign -dv \(app.bundlePath)")
                } else {
                    add(now, "running", .warning, "\(app.displayName) (pid \(pid)) launched without it, before it was enabled",
                        fix: Doctor.respringFix(c, only: true) ?? "relaunch it")
                }
            } else {
                add(now, "running", .info, "\(app.displayName) (pid \(pid)) runs without it")
            }
        }
        if let log = i.log {
            let relevant = log.filter { line in
                line.message.contains("not loading into") || line.message.contains("exception in tweak constructor")
                    || line.message.contains("requires macOS")
            }
            if let last = relevant.last {
                let msg = last.message.replacingOccurrences(of: "\((tweakID ?? "")): ", with: "")
                let bad = last.message.contains("exception")
                add(now, "log", bad ? .warning : .info, "last launch, \(clock(last.date)): \(msg)",
                    fix: bad ? "dw log \(tweakID ?? i.tweakName) \(i.logMinutes)" : nil)
            } else if let last = log.last {
                add(now, "log", .info, "it logged in \(last.process) at \(clock(last.date)), and didn't skip itself")
            } else {
                add(now, "log", .info, "nothing from it about \(app.displayName) in the last \(i.logMinutes) min")
            }
        }

        let tweakLabel = tweakID.map { "\(i.tweakName) (\($0))" } ?? i.tweakName
        return WhyReport(tweak: tweakLabel, app: "\(app.displayName) (\(bundle))", steps: steps,
                         loadedNow: loadedNow && !steps.contains { $0.status == .fail }, appName: app.displayName)
    }
}

// MARK: - The real system

public extension MachOInfo {
    /// The architectures of a Mach-O or universal file from its first bytes only (an app's executable can be large).
    static func architectures(ofFileAt path: String) -> [String]? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 4096), data.count >= 12 else { return nil }
        let b = [UInt8](data)
        func be32(_ o: Int) -> UInt32? {
            guard o + 4 <= b.count else { return nil }
            return UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
        }
        guard let magic = be32(0) else { return nil }
        if magic == 0xCAFE_BABE || magic == 0xCAFE_BABF {
            guard let n = be32(4), n > 0, n < 64 else { return nil }
            let stride = magic == 0xCAFE_BABF ? 32 : 20
            var out: [String] = []
            for k in 0..<Int(n) {
                guard let cpu = be32(8 + k * stride), let sub = be32(12 + k * stride) else { return nil }
                out.append(archName(cpu: cpu, subtype: sub))
            }
            return out
        }
        if magic == 0xCFFA_EDFE, let cpu = be32(4)?.byteSwapped, let sub = be32(8)?.byteSwapped {
            return [archName(cpu: cpu, subtype: sub)]
        }
        return nil
    }
}

public extension WhyInputs {
    /// Gathers everything from this Mac, read-only (it runs ps, launchctl, lsof and, with `searchLog`, log show).
    static func live(tweak tweakArg: String, app appArg: String, searchLog: Bool, logMinutes: Int = 60,
                     locations: TweakLocations = .live()) -> Result<WhyInputs, WhyLookupError> {
        let configText = FileManager.default.contents(atPath: locations.configPath).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let config = EffectiveConfig(document: ConfigDocument(text: configText))
        let manifests = TweakManifestLoader.load(directories: locations.manifestSearchDirectories).manifests
        let choice: WhyTweakChoice
        switch WhyLookup.tweak(tweakArg, manifests: manifests, configDylibs: config.dylibPaths) {
        case let .success(c): choice = c
        case let .failure(e): return .failure(e)
        }
        let app: InstalledApp
        switch WhyLookup.app(appArg, apps: AppDiscovery.scan(roots: AppDiscovery.defaultRoots)) {
        case let .success(a): app = a
        case let .failure(e): return .failure(e)
        }

        let file = locations.filePath(forDylib: choice.dylibPath)
        let exists = FileManager.default.fileExists(atPath: file)
        let data = exists ? try? Data(contentsOf: URL(fileURLWithPath: file), options: .mappedIfSafe) : nil
        let markers = data.map(CtorMarker.markers(in:)) ?? []
        let manifest = choice.manifest
        let tweakID = manifest?.id ?? (markers.count == 1 ? markers[0].tweakID : nil)

        let daemon = DaemonInspector.status(configPath: locations.configPath)
        let logText = DynjectLogParser.readTail(path: "/opt/dynject/log/dynjectd.log")
        let service = ServiceNameResolver.resolve(app, log: logText.map(DynjectLogParser.parse))
        let safeMode = SafeMode.live()
        let state = safeMode.stateStore.load()

        var issues: [CompatibilityIssue] = []
        if let manifest {
            issues = TweakCompatibility.issues(for: manifest, installed: manifests,
                                               environment: .live(locations: locations))
        }

        var running = WhyRunning.notRunning
        if let r = WorkspaceRunningApps(includeBackground: true).runningApps().first(where: { $0.bundleID == app.bundleID }) {
            let planner = RespringPlanner.live(configText: configText, configPath: locations.configPath, logText: logText,
                                               manifests: manifests, safeModeState: state, daemon: daemon)
            let loaded = planner.inspector.loadedDylibs(pids: [r.pid], candidates: planner.tweakDylibs)[r.pid]
            running = .running(planner.candidate(for: r, loaded: loaded))
        }

        var log: [WhyLogLine]?
        if searchLog, let id = tweakID {
            func q(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            let predicate = "subsystem == \"\(q(id))\" AND (process == \"\(q(app.executableName))\" OR eventMessage CONTAINS \"\(q(app.bundleID))\")"
            let out = try? ProcessRunner.run("/usr/bin/log", ["show", "--last", "\(logMinutes)m", "--style", "compact", "--info",
                                                              "--predicate", predicate])
            log = out.map { WhyLogLine.parse($0.stdout) } ?? []
        }

        var appleSilicon = false
        var size = MemoryLayout<Int32>.size
        var value: Int32 = 0
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 { appleSilicon = value == 1 }

        return .success(WhyInputs(
            tweakName: manifest?.name ?? (choice.dylibPath as NSString).lastPathComponent,
            tweakID: tweakID, manifest: manifest, dylibPath: choice.dylibPath, dylibFileExists: exists,
            dylibSlices: data.flatMap(MachOInfo.inspect)?.slices, ctorMarkers: markers,
            safeModeSupport: exists ? SafeModeSupportChecker.shared.support(dylibAt: file) : nil,
            compatibilityIssues: issues, app: app, appArchs: MachOInfo.architectures(ofFileAt: app.executablePath),
            appleSilicon: appleSilicon, service: service, config: config, daemon: daemon,
            safeModeEntries: safeMode.keys.entries(), safeModeDisabled: state.disabled, running: running,
            log: log, logMinutes: logMinutes))
    }
}
