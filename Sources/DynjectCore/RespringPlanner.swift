import Foundation

// Respring, part 1: which running apps need a relaunch to match the config (docs/respring.md).
//
// dynjectd sets DYLD_INSERT_LIBRARIES only when a process starts, so a running app keeps the tweaks it launched with.
// The planner compares, for every running regular app, what the config gives it now with what lsof shows it has
// loaded. Everything it reads comes in through injectable sources, so it is tested without touching real apps.

// MARK: - Inputs

/// A running regular (Dock-icon) app, as NSWorkspace reports it.
public struct RunningApp: Hashable, Sendable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var bundleID: String
    public var name: String
    /// The .app bundle, without a trailing slash.
    public var bundlePath: String
    public var executablePath: String
    public var launchDate: Date?
    public var isHidden: Bool

    public init(pid: Int32, bundleID: String, name: String, bundlePath: String, executablePath: String,
                launchDate: Date?, isHidden: Bool = false) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = RespringPaths.normalized(bundlePath)
        self.executablePath = executablePath
        self.launchDate = launchDate
        self.isHidden = isHidden
    }

    /// The app as the policy evaluator sees it (dynjectd matches on the executable that was started).
    public var installedApp: InstalledApp {
        InstalledApp(displayName: name, bundleID: bundleID,
                     executableName: (executablePath as NSString).lastPathComponent,
                     executablePath: executablePath, bundlePath: bundlePath)
    }
}

/// Running regular apps (NSWorkspace `runningApplications` with activation policy `.regular`).
public protocol RunningAppSource {
    func runningApps() -> [RunningApp]
}

/// Which of `candidates` each pid has mapped. A pid that couldn't be inspected is absent from the result.
public protocol LoadedDylibInspecting {
    func loadedDylibs(pids: [Int32], candidates: [String]) -> [Int32: Set<String>]
}

/// The process tree, for finding the app that hosts the current process.
public protocol ProcessAncestry {
    func parentPID(of pid: Int32) -> Int32?
    func executablePath(of pid: Int32) -> String?
}

/// A change in Safe Mode that applies at an app's next launch. The dylib stays injected either way (DynjectHook
/// decides in its constructor), so lsof can't see it; only the time of the change tells whether a running app
/// predates it.
public struct RespringSafeModeEvent: Hashable, Sendable {
    /// A tweak ID, or "*" for every DynjectHook tweak.
    public var tweakID: String
    /// A bundle ID, or "*" for every app.
    public var bundleID: String
    public var date: Date
    /// true: the tweak was turned off; false: re-enabled.
    public var turnedOff: Bool

    public init(tweakID: String, bundleID: String, date: Date, turnedOff: Bool) {
        self.tweakID = tweakID
        self.bundleID = bundleID
        self.date = date
        self.turnedOff = turnedOff
    }

    /// The dated changes state.json records: disable entries, re-enables and the panic switch's start. Turning the
    /// panic switch off is not dated, so it is not included.
    public static func from(state: SafeModeState) -> [RespringSafeModeEvent] {
        var events = state.disabled.map { RespringSafeModeEvent(tweakID: $0.tweakID, bundleID: $0.bundleID, date: $0.since, turnedOff: true) }
        events += state.reenabled.map { RespringSafeModeEvent(tweakID: $0.tweakID, bundleID: $0.bundleID, date: $0.date, turnedOff: false) }
        if let p = state.panicSince {
            events.append(RespringSafeModeEvent(tweakID: SafeModeNames.all, bundleID: SafeModeNames.all, date: p, turnedOff: true))
        }
        return events
    }

    func applies(tweakID t: String, bundleID b: String) -> Bool {
        (tweakID == t || tweakID == SafeModeNames.all) && (bundleID == b || bundleID == SafeModeNames.all)
    }
}

// MARK: - Output

/// Why a running app differs from what a relaunch would give it.
public struct RespringReason: Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The config gives it this dylib, but it isn't loaded.
        case missing
        /// Loaded, but the config no longer gives it (or the file is gone).
        case unwanted
        /// Loaded, and the file on disk changed after the app launched.
        case updated
        /// Loaded, and Safe Mode turned it off for this app after the app launched.
        case safeModeOff
        /// Loaded, and Safe Mode re-enabled it after the app launched.
        case safeModeOn
    }

    public var kind: Kind
    public var dylib: String
    /// The tweak ID from its manifest, else the dylib's file name.
    public var tweak: String
    /// updated: the file's modification date; Safe Mode: when it changed.
    public var date: Date?

    public init(_ kind: Kind, dylib: String, tweak: String, date: Date? = nil) {
        self.kind = kind
        self.dylib = dylib
        self.tweak = tweak
        self.date = date
    }

    /// "missing local.dynject.menuloader"
    public var summary: String {
        switch kind {
        case .missing: return "missing \(tweak)"
        case .unwanted: return "unwanted \(tweak)"
        case .updated: return "updated \(tweak)"
        case .safeModeOff: return "Safe Mode off: \(tweak)"
        case .safeModeOn: return "Safe Mode on again: \(tweak)"
        }
    }

    /// One line of explanation for the UI.
    public var detail: String {
        switch kind {
        case .missing: return "The config injects \(tweak) here, but the app launched without it."
        case .unwanted: return "\(tweak) is loaded, but the config no longer injects it here."
        case .updated: return "\(tweak) was replaced on disk after the app launched; it still runs the old copy."
        case .safeModeOff: return "Safe Mode turned \(tweak) off here after the app launched; it is still running."
        case .safeModeOn: return "Safe Mode re-enabled \(tweak) here after the app launched; it starts at the next launch."
        }
    }
}

/// Why an app is left out unless it is selected explicitly.
public enum RespringExclusion: String, Hashable, Sendable {
    /// Never relaunched (quitting loginwindow logs out); can't be included.
    case protectedSystem
    /// The process doing the respring runs inside this app (e.g. the terminal or editor running `dw`).
    case hostsThisProcess
    /// Dynject Workbench itself; relaunched last when selected.
    case workbench
    /// A terminal or code editor: quitting it would end sessions and builds.
    case developerTool
    /// Finder quits only through an Apple Event; relaunched with --all or when selected.
    case finder
    /// It launched after the current config took effect and still lacks a dylib, so something other than timing
    /// keeps it out (hardened runtime, library validation); a relaunch won't help.
    case injectionBlocked

    public var note: String {
        switch self {
        case .protectedSystem: return "never relaunched (system process)"
        case .hostsThisProcess: return "runs this process; relaunching it would end it"
        case .workbench: return "Dynject Workbench itself; relaunched last when selected"
        case .developerTool: return "terminal or editor; relaunch it yourself or select it explicitly"
        case .finder: return "Finder is relaunched only with --all or when selected"
        case .injectionBlocked: return "launched after the config took effect and still lacks it; a relaunch likely won't help"
        }
    }

    public var canBeSelected: Bool { self != .protectedSystem }
}

public struct RespringCandidate: Identifiable, Hashable, Sendable {
    public var id: Int32 { app.pid }
    public var app: RunningApp
    /// The XPC service name used for the policy (see ServiceNameResolver).
    public var service: String
    /// Tweak dylibs a launch now would inject, in config order.
    public var expected: [String]
    /// Tweak dylibs mapped right now; nil when lsof couldn't read the process.
    public var loaded: Set<String>?
    public var reasons: [RespringReason]
    /// Why it isn't selected by default (also set on apps that aren't pending; it matters for --all).
    public var exclusion: RespringExclusion?
    /// Relaunching it ends the process doing the respring, so it is handed off to a detached reopener and done last.
    public var hostsCaller: Bool

    public init(app: RunningApp, service: String, expected: [String], loaded: Set<String>?, reasons: [RespringReason],
                exclusion: RespringExclusion?, hostsCaller: Bool = false) {
        self.app = app
        self.service = service
        self.expected = expected
        self.loaded = loaded
        self.reasons = reasons
        self.exclusion = exclusion
        self.hostsCaller = hostsCaller
    }

    public var isPending: Bool { !reasons.isEmpty }
    public var isInspected: Bool { loaded != nil }
    /// Dynject touches it either way: it should have a tweak, or has one.
    public var isInvolved: Bool { !expected.isEmpty || !(loaded ?? []).isEmpty }
    /// Checked in the Respring sheet when it opens.
    public var selectedByDefault: Bool { isPending && exclusion == nil }
    public var isWorkbench: Bool { RespringExclusions.workbenchBundleIDs.contains(app.bundleID) }
    /// "missing local.dynject.menuloader, updated local.dynject.titlebadge"
    public var reasonSummary: String { reasons.map(\.summary).joined(separator: ", ") }
}

public struct RespringOptions: Equatable, Sendable {
    /// Every running regular app (minus exclusions), Finder included.
    public var all: Bool
    /// Bundle IDs to relaunch even when excluded by default or not pending.
    public var include: Set<String>
    /// Bundle IDs never to relaunch.
    public var exclude: Set<String>
    /// When set, only these bundle IDs are considered (each as if named with --include), pending or not.
    public var only: Set<String>?

    public init(all: Bool = false, include: Set<String> = [], exclude: Set<String> = [], only: Set<String>? = nil) {
        self.all = all
        self.include = include
        self.exclude = exclude
        self.only = only
    }
}

public struct RespringSelection: Sendable {
    public struct Skipped: Hashable, Sendable {
        public var candidate: RespringCandidate
        public var why: String
    }

    /// In relaunch order (see `Respringer.ordered`).
    public var apps: [RespringCandidate]
    /// Pending (or, with --all, running) apps left out, with the reason.
    public var skipped: [Skipped]
    /// --include bundle IDs that aren't running.
    public var notRunning: [String]
}

public struct RespringPlan: Sendable {
    public var date: Date
    /// Every running regular app, sorted by name.
    public var candidates: [RespringCandidate]

    public init(date: Date, candidates: [RespringCandidate]) {
        self.date = date
        self.candidates = candidates
    }

    public var pending: [RespringCandidate] { candidates.filter(\.isPending) }
    /// The pending apps the sheet checks by default (pending and not excluded).
    public var defaultSelection: [RespringCandidate] { candidates.filter(\.selectedByDefault) }
    public var notInspected: [RespringCandidate] { candidates.filter { !$0.isInspected } }

    public func candidate(bundleID: String) -> RespringCandidate? { candidates.first { $0.app.bundleID == bundleID } }

    /// What `dw respring` relaunches for these options.
    public func selection(_ options: RespringOptions) -> RespringSelection {
        var chosen: [RespringCandidate] = []
        var skipped: [RespringSelection.Skipped] = []
        let named = options.only ?? options.include
        for c in candidates {
            let id = c.app.bundleID
            if let only = options.only, !only.contains(id) { continue }
            let explicit = named.contains(id)
            guard explicit || options.all || c.isPending else { continue }
            if c.exclusion == .protectedSystem {
                if explicit || c.isPending { skipped.append(.init(candidate: c, why: RespringExclusion.protectedSystem.note)) }
                continue
            }
            if options.exclude.contains(id) {
                skipped.append(.init(candidate: c, why: "excluded with --exclude"))
                continue
            }
            if let ex = c.exclusion, !explicit {
                // --all brings in Finder and apps a relaunch probably won't fix; hosts, Workbench and developer
                // tools still need to be named.
                let allCovers = options.all && (ex == .finder || ex == .injectionBlocked)
                if !allCovers {
                    skipped.append(.init(candidate: c, why: ex.note))
                    continue
                }
            }
            chosen.append(c)
        }
        let running = Set(candidates.map(\.app.bundleID))
        return RespringSelection(apps: Respringer.ordered(chosen), skipped: skipped,
                                 notRunning: named.subtracting(running).sorted())
    }
}

// MARK: - Exclusions

public struct RespringExclusions: Sendable {
    public static let finderBundleID = "com.apple.finder"
    public static let workbenchBundleIDs: Set<String> = ["local.dynject.workbench"]
    /// Quitting these ends the login session or isn't possible.
    public static let protectedBundleIDs: Set<String> = ["com.apple.loginwindow"]

    /// Terminals and editors.
    public static let developerToolBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.apple.dt.Xcode", "com.google.android.studio",
        "com.panic.Nova", "com.barebones.bbedit",
    ]
    /// Bundle ID prefixes of terminals and editors (Warp, JetBrains IDEs, Zed, Sublime Text).
    public static let developerToolPrefixes = ["dev.warp.", "com.jetbrains.", "dev.zed.", "com.sublimetext."]

    public static func isDeveloperTool(_ bundleID: String) -> Bool {
        developerToolBundleIDs.contains(bundleID) || developerToolPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// The process doing the respring and its ancestors.
    public var hostPIDs: Set<Int32>
    /// The outermost .app bundle of each ancestor's executable.
    public var hostBundlePaths: Set<String>

    public init(hostPIDs: Set<Int32> = [], hostBundlePaths: Set<String> = []) {
        self.hostPIDs = hostPIDs
        self.hostBundlePaths = Set(hostBundlePaths.map(RespringPaths.normalized))
    }

    /// Walks the parent chain from `pid` (normally getpid()) up to launchd. A terminal's shell, an editor's
    /// integrated terminal (whose parent is a helper inside the editor's bundle) and an app running the engine
    /// in-process all lead back to their app.
    public static func host(of pid: Int32, ancestry: ProcessAncestry) -> RespringExclusions {
        var pids: Set<Int32> = []
        var paths: Set<String> = []
        var current: Int32? = pid
        while let p = current, p > 1, pids.insert(p).inserted, pids.count < 64 {
            if let exe = ancestry.executablePath(of: p), let app = RespringPaths.outermostAppBundle(in: exe) {
                paths.insert(app)
            }
            current = ancestry.parentPID(of: p)
        }
        return RespringExclusions(hostPIDs: pids, hostBundlePaths: paths)
    }

    public func hosts(_ app: RunningApp) -> Bool {
        hostPIDs.contains(app.pid) || hostBundlePaths.contains(app.bundlePath)
    }

    public func exclusion(for app: RunningApp) -> RespringExclusion? {
        if Self.protectedBundleIDs.contains(app.bundleID) { return .protectedSystem }
        if hosts(app) { return .hostsThisProcess }
        if Self.workbenchBundleIDs.contains(app.bundleID) { return .workbench }
        if Self.isDeveloperTool(app.bundleID) { return .developerTool }
        if app.bundleID.caseInsensitiveCompare(Self.finderBundleID) == .orderedSame { return .finder }
        return nil
    }
}

public enum RespringPaths {
    /// "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
    /// → "/Applications/Visual Studio Code.app"
    public static func outermostAppBundle(in path: String) -> String? {
        guard let r = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil)
        else { return nil }
        return normalized(String(path[..<r.upperBound]))
    }

    /// Drops a trailing slash so NSRunningApplication's bundle URLs and plain paths compare equal.
    public static func normalized(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

// MARK: - Planner

public struct RespringPlanner {
    public var config: EffectiveConfig
    public var runningApps: RunningAppSource
    public var inspector: LoadedDylibInspecting
    /// The XPC service name dynjectd would see for the app (ServiceNameResolver with the log).
    public var serviceName: (InstalledApp) -> String
    public var fileExists: (String) -> Bool
    public var modificationDate: (String) -> Date?
    public var now: () -> Date
    /// dylib path → tweak ID (from manifests), for labels. Others show their file name.
    public var tweakLabels: [String: String]
    /// More tweak dylibs to look for in lsof besides the config's (e.g. every file in the tweaks directory), so a
    /// dylib removed from the config still shows up as unwanted.
    public var extraTweakDylibs: [String]
    /// When the current config took effect (later of its modification and dynjectd's start). Apps launched after
    /// it that still lack a dylib are marked `injectionBlocked`.
    public var configEffectiveSince: Date?
    /// dylib path → tweak ID, for tweaks that honour Safe Mode (DynjectHook).
    public var safeModeTweaks: [String: String]
    public var safeModeEvents: [RespringSafeModeEvent]
    public var exclusions: RespringExclusions

    public init(config: EffectiveConfig, runningApps: RunningAppSource, inspector: LoadedDylibInspecting,
                serviceName: @escaping (InstalledApp) -> String = { ServiceNameResolver.resolve($0, log: nil).value },
                fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                modificationDate: @escaping (String) -> Date? = RespringPlanner.fileModificationDate,
                now: @escaping () -> Date = Date.init,
                tweakLabels: [String: String] = [:], extraTweakDylibs: [String] = [],
                configEffectiveSince: Date? = nil,
                safeModeTweaks: [String: String] = [:], safeModeEvents: [RespringSafeModeEvent] = [],
                exclusions: RespringExclusions = RespringExclusions()) {
        self.config = config
        self.runningApps = runningApps
        self.inspector = inspector
        self.serviceName = serviceName
        self.fileExists = fileExists
        self.modificationDate = modificationDate
        self.now = now
        self.tweakLabels = tweakLabels
        self.extraTweakDylibs = extraTweakDylibs
        self.configEffectiveSince = configEffectiveSince
        self.safeModeTweaks = safeModeTweaks
        self.safeModeEvents = safeModeEvents
        self.exclusions = exclusions
    }

    /// When the file last changed: the later of its modification time and its inode change time. A copy that keeps
    /// the source's dates (FileManager.copyItem, `cp -p`, `ditto`, a Finder drag) has an old mtime (and birth time)
    /// but a ctime of when it was written, and ctime can't be set from user space.
    public static func fileModificationDate(_ path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        func date(_ t: timespec) -> Date { Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9) }
        return max(date(st.st_mtimespec), date(st.st_ctimespec))
    }

    public func label(_ dylib: String) -> String { tweakLabels[dylib] ?? (dylib as NSString).lastPathComponent }

    /// Every dylib lsof is asked about.
    public var tweakDylibs: [String] {
        var seen = Set<String>()
        return (config.dylibPaths + extraTweakDylibs + safeModeTweaks.keys.sorted()).filter { seen.insert($0).inserted }
    }

    public func plan() -> RespringPlan {
        let apps = runningApps.runningApps()
        let loadedByPID = inspector.loadedDylibs(pids: apps.map(\.pid), candidates: tweakDylibs)
        let candidates = apps.map { candidate(for: $0, loaded: loadedByPID[$0.pid]) }.sorted(by: Respringer.byName)
        return RespringPlan(date: now(), candidates: candidates)
    }

    public func candidate(for app: RunningApp, loaded: Set<String>?) -> RespringCandidate {
        let installed = app.installedApp
        let service = serviceName(installed)
        let evaluation = PolicyEvaluator.evaluate(app: installed, service: service, config: config, fileExists: fileExists)
        let expected = evaluation.injectedDylibs
        var reasons: [RespringReason] = []
        if let loaded {
            for d in expected where !loaded.contains(d) {
                reasons.append(.init(.missing, dylib: d, tweak: label(d)))
            }
            for d in loaded.sorted() where !expected.contains(d) {
                reasons.append(.init(.unwanted, dylib: d, tweak: label(d)))
            }
            if let launched = app.launchDate {
                for d in expected where loaded.contains(d) {
                    if let m = modificationDate(d), m > launched {
                        reasons.append(.init(.updated, dylib: d, tweak: label(d), date: m))
                    }
                    if let tweakID = safeModeTweaks[d],
                       let e = safeModeEvents.filter({ $0.date > launched && $0.applies(tweakID: tweakID, bundleID: app.bundleID) })
                           .max(by: { $0.date < $1.date }) {
                        reasons.append(.init(e.turnedOff ? .safeModeOff : .safeModeOn, dylib: d, tweak: label(d), date: e.date))
                    }
                }
            }
        }
        var exclusion = exclusions.exclusion(for: app)
        if exclusion == nil, isBlocked(app, reasons: reasons) { exclusion = .injectionBlocked }
        return RespringCandidate(app: app, service: service, expected: expected, loaded: loaded, reasons: reasons,
                                 exclusion: exclusion, hostsCaller: exclusions.hosts(app))
    }

    /// Only missing dylibs, and the app launched after both the config took effect and each file was written.
    private func isBlocked(_ app: RunningApp, reasons: [RespringReason]) -> Bool {
        guard !reasons.isEmpty, reasons.allSatisfy({ $0.kind == .missing }),
              let launched = app.launchDate, let since = configEffectiveSince, launched > since else { return false }
        return reasons.allSatisfy { r in modificationDate(r.dylib).map { $0 < launched } ?? false }
    }
}
