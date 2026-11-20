import AppKit
import DynjectCore
import Observation

// The Respring sheet's state (docs/respring.md). It plans with DynjectCore's RespringPlanner and relaunches with
// Respringer. Live mode reads the real running apps and relaunches them with WorkspaceAppController, but only when
// the user presses "Respring Selected". When the environment isolates respring (fixture mode, a smoke test,
// `-DWRespringFixture`), the running apps are made up (RespringFixtureWorld) and the controller is
// SimulatedAppController, so no real app is ever quit, opened or inspected.

/// `dynject-workbench://respring` (also `dynject-workbench:respring`). It only opens the sheet.
enum WorkbenchLink: Equatable {
    static let scheme = "dynject-workbench"

    case respring

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let target = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .split(separator: "/").first.map { String($0).lowercased() }
        switch target {
        case "respring": self = .respring
        default: return nil
        }
    }
}

/// What the planner reads, gathered on the main actor from WorkbenchModel.
struct RespringInputs {
    var configText: String
    var configPath: String
    var logPath: String
    var manifests: [TweakManifest]
    var dylibDirectory: String
    var safeModeStateDirectory: URL
    var daemon: DaemonStatus?
    /// Scanned apps (fixture mode resolves bundle and executable paths from them).
    var installedApps: [InstalledApp]
    /// Scanned apps the saved config injects something into (the default fixture's running apps).
    var injectedApps: [InstalledApp]
    var appsScanned: Bool
}

/// `-DWRespringFixture <file>`: the running apps of an isolated Respring sheet, as JSON.
///
///     {"apps": [{"bundleID": "com.apple.TextEdit", "launchedMinutesAgo": 90, "loaded": []},
///               {"bundleID": "com.example.stubborn", "name": "Stubborn", "bundlePath": "/Applications/Stubborn.app",
///                "loaded": ["/opt/dynject/lib/tweaks/libX.dylib"], "refusesToQuit": true},
///               {"bundleID": "local.dynject.workbench", "hostsCaller": true}],
///      "dylibModifiedMinutesAgo": {"/opt/dynject/lib/tweaks/libX.dylib": 10}}
struct RespringFixture: Codable, Equatable {
    struct App: Codable, Equatable {
        var bundleID: String
        var name: String?
        /// Default: the scanned app's, else Launch Services', else /Applications/<name>.app.
        var bundlePath: String?
        var pid: Int32?
        var launchedMinutesAgo: Double?
        /// Tweak dylibs the process has mapped.
        var loaded: [String]?
        var hidden: Bool?
        /// Pretend the sheet runs inside this app (as Workbench does in live mode).
        var hostsCaller: Bool?
        /// The simulated quit request is accepted but the app never quits (the timeout path).
        var refusesToQuit: Bool?
        /// The simulated reopen fails.
        var openFails: Bool?
        /// What the reopened process has mapped. Default: what the config gives it.
        var reopenLoads: [String]?
    }

    var apps: [App]
    var dylibModifiedMinutesAgo: [String: Double]?

    static func load(path: String) throws -> RespringFixture {
        try JSONDecoder().decode(RespringFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

/// The made-up running apps of an isolated Respring sheet. A simulated relaunch gives the app a new pid that has
/// what the relaunch loaded, so the next plan shows it up to date, as a real respring would.
final class RespringFixtureWorld: RunningAppSource, LoadedDylibInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var apps: [RunningApp]
    private var loaded: [Int32: Set<String>]
    private var nextPID: Int32 = 70_000
    let hostBundleIDs: Set<String>
    let refusesToQuit: Set<String>
    let openFails: Set<String>
    let reopenLoads: [String: Set<String>]
    let modified: [String: Date]

    init(apps: [RunningApp], loaded: [Int32: Set<String>], hostBundleIDs: Set<String> = [], refusesToQuit: Set<String> = [],
         openFails: Set<String> = [], reopenLoads: [String: Set<String>] = [:], modified: [String: Date] = [:]) {
        self.apps = apps
        self.loaded = loaded
        self.hostBundleIDs = hostBundleIDs
        self.refusesToQuit = refusesToQuit
        self.openFails = openFails
        self.reopenLoads = reopenLoads
        self.modified = modified
    }

    /// From a fixture file, or (nil) a default: up to five scanned apps the config injects into, plus Finder,
    /// a terminal and Workbench itself (as the host), all launched an hour ago with nothing loaded.
    static func make(fixture: RespringFixture?, inputs: RespringInputs, now: Date = Date()) -> RespringFixtureWorld {
        func resolve(_ bundleID: String, name: String?, bundlePath: String?) -> (name: String, bundle: String, exe: String) {
            if bundlePath == nil, let app = inputs.installedApps.first(where: { $0.bundleID == bundleID }) {
                return (name ?? app.displayName, app.bundlePath, app.executablePath)
            }
            var bundle = bundlePath
            if bundle == nil, RespringExclusions.workbenchBundleIDs.contains(bundleID) { bundle = Bundle.main.bundlePath }
            if bundle == nil { bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path }
            let display = name ?? bundle.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            let path = bundle ?? "/Applications/\(display).app"
            let exe = Bundle(path: path)?.executablePath ?? (path as NSString).appendingPathComponent("Contents/MacOS/\(display)")
            return (display, path, exe)
        }

        var specs = fixture?.apps ?? []
        if fixture == nil {
            var ids = Array(inputs.injectedApps.map(\.bundleID).prefix(5))
            if !ids.contains(RespringExclusions.finderBundleID), inputs.installedApps.contains(where: { $0.bundleID == RespringExclusions.finderBundleID }) {
                ids.append(RespringExclusions.finderBundleID)
            }
            if !ids.contains(where: RespringExclusions.isDeveloperTool),
               let tool = inputs.installedApps.first(where: { RespringExclusions.isDeveloperTool($0.bundleID) }) {
                ids.append(tool.bundleID)
            }
            specs = ids.map { RespringFixture.App(bundleID: $0) }
            specs.append(.init(bundleID: RespringExclusions.workbenchBundleIDs.sorted()[0], name: "Dynject Workbench", hostsCaller: true))
        }

        var apps: [RunningApp] = []
        var loaded: [Int32: Set<String>] = [:]
        var hosts: Set<String> = [], refuses: Set<String> = [], fails: Set<String> = [], reopen: [String: Set<String>] = [:]
        for (i, s) in specs.enumerated() {
            let r = resolve(s.bundleID, name: s.name, bundlePath: s.bundlePath)
            let pid = s.pid ?? Int32(51_000 + i)
            apps.append(RunningApp(pid: pid, bundleID: s.bundleID, name: r.name, bundlePath: RespringPaths.normalized(r.bundle),
                                   executablePath: r.exe, launchDate: now.addingTimeInterval(-60 * (s.launchedMinutesAgo ?? 60)),
                                   isHidden: s.hidden ?? false))
            loaded[pid] = Set(s.loaded ?? [])
            if s.hostsCaller == true { hosts.insert(s.bundleID) }
            if s.refusesToQuit == true { refuses.insert(s.bundleID) }
            if s.openFails == true { fails.insert(s.bundleID) }
            if let l = s.reopenLoads { reopen[s.bundleID] = Set(l) }
        }
        let modified = (fixture?.dylibModifiedMinutesAgo ?? [:]).mapValues { now.addingTimeInterval(-60 * $0) }
        return RespringFixtureWorld(apps: apps, loaded: loaded, hostBundleIDs: hosts, refusesToQuit: refuses,
                                    openFails: fails, reopenLoads: reopen, modified: modified)
    }

    func runningApps() -> [RunningApp] {
        lock.lock(); defer { lock.unlock() }
        return apps
    }

    func loadedDylibs(pids: [Int32], candidates: [String]) -> [Int32: Set<String>] {
        lock.lock(); defer { lock.unlock() }
        var out: [Int32: Set<String>] = [:]
        for p in pids { if let l = loaded[p] { out[p] = l.intersection(candidates) } }
        return out
    }

    func modificationDate(_ path: String) -> Date? { modified[path] }

    /// The host is whichever fixture app is marked `hostsCaller` (by bundle ID, so it stays the host after a
    /// simulated hand-off gives it a new pid).
    var exclusions: RespringExclusions {
        lock.lock(); defer { lock.unlock() }
        return RespringExclusions(hostPIDs: Set(apps.filter { hostBundleIDs.contains($0.bundleID) }.map(\.pid)))
    }

    /// A controller over the current apps that reopens each one with `reopenLoads`, else what the plan expects.
    func controller(for plan: RespringPlan) -> SimulatedAppController {
        lock.lock(); defer { lock.unlock() }
        let c = SimulatedAppController(apps: apps, nextPID: nextPID)
        c.refusesToQuit = refusesToQuit
        c.openFails = openFails
        for cand in plan.candidates {
            c.loadedAfterOpen[cand.app.bundleID] = reopenLoads[cand.app.bundleID] ?? Set(cand.expected)
        }
        return c
    }

    /// Applies a simulated run: relaunched apps get their new pid and what they loaded, an app handed off is
    /// "reopened" the same way, and an app that quit but didn't reopen is gone.
    func apply(_ results: [RespringResult], now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        for r in results {
            let old = r.candidate.app.pid
            guard let i = apps.firstIndex(where: { $0.pid == old }) else { continue }
            let id = r.candidate.app.bundleID
            func replace(with pid: Int32, loading set: Set<String>) {
                apps[i].pid = pid
                apps[i].launchDate = now
                loaded[old] = nil
                loaded[pid] = set
                nextPID = max(nextPID, pid + 1)
            }
            switch r.outcome {
            case .relaunched:
                guard let pid = r.newPID else { continue }
                var set = reopenLoads[id] ?? Set(r.candidate.expected)
                if let v = r.verification, v.inspected {
                    set = Set(r.candidate.expected).subtracting(v.missing).union(v.unexpected)
                }
                replace(with: pid, loading: set)
            case .handedOff:
                replace(with: nextPID, loading: reopenLoads[id] ?? Set(r.candidate.expected))
            case .openFailed:
                apps.remove(at: i)
                loaded[old] = nil
            default:
                continue
            }
        }
    }
}

/// Paces a simulated run so the sheet's progress is visible (fixture mode only).
final class PacedAppController: AppController {
    let base: SimulatedAppController
    let pace: TimeInterval

    init(_ base: SimulatedAppController, pace: TimeInterval) {
        self.base = base
        self.pace = pace
    }

    func terminate(_ app: RunningApp, method: RespringQuitMethod) -> Bool {
        Thread.sleep(forTimeInterval: pace)
        return base.terminate(app, method: method)
    }

    func isRunning(pid: Int32) -> Bool { base.isRunning(pid: pid) }
    func runningPIDs(bundleID: String) -> [Int32] { base.runningPIDs(bundleID: bundleID) }

    func open(bundleURL: URL, options: RespringOpenOptions) throws -> Int32 {
        Thread.sleep(forTimeInterval: pace)
        return try base.open(bundleURL: bundleURL, options: options)
    }

    func loadedDylibs(pid: Int32, candidates: [String]) -> Set<String>? { base.loadedDylibs(pid: pid, candidates: candidates) }

    func scheduleReopen(bundleURL: URL, afterExitOf pid: Int32, timeout: TimeInterval) throws {
        try base.scheduleReopen(bundleURL: bundleURL, afterExitOf: pid, timeout: timeout)
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

@MainActor @Observable
final class RespringModel {
    /// No real app is quit, opened or inspected (AppEnvironment.isolatesRespring).
    let simulated: Bool
    let fixturePath: String?
    @ObservationIgnored var inputs: (() -> RespringInputs)?
    /// Called after a run (WorkbenchModel rechecks loaded dylibs).
    @ObservationIgnored var onFinished: (() -> Void)?

    // MARK: Plan
    private(set) var plan: RespringPlan?
    private(set) var labels: [String: String] = [:]
    private(set) var tweakDylibs: [String] = []
    private(set) var configEffectiveSince: Date?
    private(set) var daemonNeedsRestart = false
    private(set) var isPlanning = false
    private(set) var plannedAt: Date?
    private(set) var planCount = 0
    private(set) var fixtureError: String?

    // MARK: Sheet
    var showSheet = false
    var showAllApps = false
    /// Checked rows, by pid.
    private(set) var selection: Set<Int32> = []
    /// The user changed a checkbox since the sheet opened (a refresh then keeps their choices).
    private(set) var selectionTouched = false
    var quitTimeout: Double = 15
    /// Times the sheet was asked for through a dynject-workbench:// link.
    private(set) var linkRequests = 0

    // MARK: Run
    private(set) var isRunning = false
    private(set) var stopRequested = false
    /// The apps of the current or last run, in relaunch order (empty: the sheet shows the list to choose from).
    private(set) var runList: [RespringCandidate] = []
    /// pid → what is happening to it now.
    private(set) var activity: [Int32: String] = [:]
    /// pid (the old one) → result.
    private(set) var results: [Int32: RespringResult] = [:]
    private(set) var runSummary: String?
    /// The simulated controller's calls in the last run (fixture mode; the smoke test checks them).
    private(set) var simulatedCalls: [SimulatedAppController.Call] = []

    @ObservationIgnored private var world: RespringFixtureWorld?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var cancelFlag = CancelFlag()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var fingerprintTimer: Timer?
    @ObservationIgnored private var fingerprint: [String: Date] = [:]
    @ObservationIgnored private var started = false
    /// Paces simulated runs so progress shows (0 in unit tests).
    @ObservationIgnored var simulatedPace: TimeInterval = 0.25

    init(env: AppEnvironment) {
        simulated = env.isolatesRespring
        fixturePath = env.respringFixturePath
    }

    // MARK: Refreshing

    /// Watches for what makes apps pending: app launches and quits (live mode), and changes to the config or the
    /// installed tweak dylibs made outside Workbench (dw install, dw config apply), checked every 15 s.
    func start() {
        guard !started else { return }
        started = true
        if !simulated {
            let nc = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleRefresh(after: 2) }
                })
            }
        }
        fingerprint = currentFingerprint()
        fingerprintTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = self.currentFingerprint()
                if now != self.fingerprint {
                    self.fingerprint = now
                    self.scheduleRefresh()
                }
            }
        }
    }

    /// The config's and each installed tweak dylib's modification date.
    private func currentFingerprint() -> [String: Date] {
        guard let i = inputs?() else { return [:] }
        let fm = FileManager.default
        var paths = [i.configPath]
        paths += ((try? fm.contentsOfDirectory(atPath: i.dylibDirectory)) ?? []).map { (i.dylibDirectory as NSString).appendingPathComponent($0) }
        var out: [String: Date] = [:]
        for p in paths { out[p] = RespringPlanner.fileModificationDate(p) ?? .distantPast }
        return out
    }

    /// Debounced refresh (several triggers often fire together).
    func scheduleRefresh(after delay: TimeInterval = 0.5) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Plans again off the main thread. While a run is in progress it waits until the run ends.
    func refresh() {
        refreshTask?.cancel()
        guard !isRunning else { needsRefresh = true; return }
        guard let inputs = inputs?() else { return }
        if simulated, world == nil {
            // Fixture apps resolve their paths from the scanned apps.
            guard inputs.appsScanned else { needsRefresh = true; return }
            do {
                let fixture = try fixturePath.map(RespringFixture.load(path:))
                world = RespringFixtureWorld.make(fixture: fixture, inputs: inputs)
                fixtureError = nil
            } catch {
                fixtureError = "Can't read the respring fixture \(fixturePath ?? ""): \(error.localizedDescription)"
                world = RespringFixtureWorld(apps: [], loaded: [:])
            }
        }
        needsRefresh = false
        isPlanning = true
        let world = self.world
        Task.detached(priority: .userInitiated) {
            let planner = Self.makePlanner(inputs: inputs, world: world)
            let plan = planner.plan()
            let labels = planner.tweakLabels, dylibs = planner.tweakDylibs, since = planner.configEffectiveSince
            await MainActor.run { self.apply(plan, labels: labels, dylibs: dylibs, since: since, daemon: inputs.daemon) }
        }
    }

    /// Reads only. With a fixture world, nothing real is looked at except the config, log, manifests and Safe Mode
    /// state the inputs name.
    nonisolated static func makePlanner(inputs: RespringInputs, world: RespringFixtureWorld?) -> RespringPlanner {
        let state = SafeModeStateStore(directory: inputs.safeModeStateDirectory).load()
        let logText = DynjectLogParser.readTail(path: inputs.logPath)
        guard let world else {
            return RespringPlanner.live(configText: inputs.configText, configPath: inputs.configPath, logText: logText,
                                        manifests: inputs.manifests, dylibDirectory: inputs.dylibDirectory,
                                        safeModeState: state, daemon: inputs.daemon)
        }
        var planner = RespringPlanner.live(configText: inputs.configText, configPath: inputs.configPath, logText: logText,
                                           manifests: inputs.manifests, dylibDirectory: inputs.dylibDirectory,
                                           safeModeState: state, daemon: inputs.daemon,
                                           runningApps: world, inspector: world, exclusions: world.exclusions)
        planner.fileExists = { _ in true }
        planner.modificationDate = world.modificationDate
        return planner
    }

    private func apply(_ plan: RespringPlan, labels: [String: String], dylibs: [String], since: Date?, daemon: DaemonStatus?) {
        self.plan = plan
        self.labels = labels
        tweakDylibs = dylibs
        configEffectiveSince = since
        daemonNeedsRestart = daemon?.needsRestart ?? false
        plannedAt = Date()
        planCount += 1
        isPlanning = false
        let pids = Set(plan.candidates.map(\.id))
        if selectionTouched {
            selection.formIntersection(pids)
        } else {
            selection = Set(plan.defaultSelection.map(\.id))
        }
        if needsRefresh { scheduleRefresh() }
    }

    // MARK: Sheet

    /// Opens the sheet. Never relaunches anything by itself.
    func present(fromLink: Bool = false) {
        if fromLink { linkRequests += 1 }
        if !isRunning {
            if runList.isEmpty { selectionTouched = false }
            refresh()
        }
        showSheet = true
    }

    func close() {
        guard !isRunning else { return }
        showSheet = false
        if !runList.isEmpty { backToList() }
    }

    /// After a run: the list again, with a fresh plan.
    func backToList() {
        guard !isRunning else { return }
        runList = []
        results = [:]
        activity = [:]
        runSummary = nil
        selectionTouched = false
        refresh()
    }

    var pendingCount: Int { plan?.pending.count ?? 0 }

    /// Rows the sheet lists: pending apps and anything checked, or every running app.
    var visibleCandidates: [RespringCandidate] {
        guard let plan else { return [] }
        return showAllApps ? plan.candidates : plan.candidates.filter { $0.isPending || selection.contains($0.id) }
    }

    var selectedCandidates: [RespringCandidate] {
        (plan?.candidates ?? []).filter { selection.contains($0.id) && canSelect($0) }
    }

    func canSelect(_ c: RespringCandidate) -> Bool { c.exclusion?.canBeSelected ?? true }

    func isSelected(_ c: RespringCandidate) -> Bool { selection.contains(c.id) }

    func setSelected(_ on: Bool, _ c: RespringCandidate) {
        guard canSelect(c), !isRunning else { return }
        selectionTouched = true
        if on { selection.insert(c.id) } else { selection.remove(c.id) }
    }

    func selectDefaults() {
        selection = Set(plan?.defaultSelection.map(\.id) ?? [])
        selectionTouched = true
    }

    /// The checkbox's note for an app left out by default (nil: nothing to say).
    func note(for c: RespringCandidate) -> String? {
        let checked = isSelected(c)
        if c.isWorkbench && c.hostsCaller {
            return checked ? "Workbench quits last; a helper process reopens it after it exits."
                           : "This is Workbench. If checked, it quits last and a helper process reopens it."
        }
        if c.hostsCaller {
            return checked ? "Workbench runs inside this app: it quits last, and a helper process reopens it."
                           : "Unchecked: Workbench runs inside this app, so relaunching it would end Workbench too."
        }
        if c.isWorkbench {
            return checked ? "Another Workbench; relaunched after the other apps." : "Unchecked: \(RespringExclusion.workbench.note)."
        }
        guard let ex = c.exclusion else { return nil }
        if !ex.canBeSelected { return "\(ex.note.prefix(1).uppercased())\(ex.note.dropFirst())." }
        return checked ? "Checked even though: \(ex.note)." : "Unchecked: \(ex.note)."
    }

    // MARK: Running

    /// Relaunches the checked apps, one at a time, off the main thread. Only the "Respring Selected" button calls it.
    func run() {
        guard !isRunning, let plan else { return }
        let apps = selectedCandidates
        guard !apps.isEmpty else { return }
        runList = Respringer.ordered(apps)
        results = [:]
        activity = [:]
        runSummary = nil
        simulatedCalls = []
        stopRequested = false
        isRunning = true
        let flag = CancelFlag()
        cancelFlag = flag

        let controller: AppController
        let simulatedController: SimulatedAppController?
        let clock: RespringClock
        if simulated {
            let c = (world ?? RespringFixtureWorld(apps: [], loaded: [:])).controller(for: plan)
            simulatedController = c
            controller = simulatedPace > 0 ? PacedAppController(c, pace: simulatedPace) : c
            clock = .manual()
        } else {
            simulatedController = nil
            controller = WorkspaceAppController()
            clock = .system
        }
        let engine = Respringer(controller: controller, clock: clock,
                                settings: .init(quitTimeout: quitTimeout, tweakDylibs: tweakDylibs))
        Task.detached(priority: .userInitiated) {
            let results = engine.run(apps, progress: { p in
                DispatchQueue.main.async { MainActor.assumeIsolated { self.progress(p) } }
            }, isCancelled: { flag.isSet })
            await MainActor.run { self.finish(results, calls: simulatedController?.calls) }
        }
    }

    /// Lets the current app finish, then stops.
    func stop() {
        guard isRunning else { return }
        stopRequested = true
        cancelFlag.set()
    }

    private func progress(_ p: RespringProgress) {
        let pid = p.candidate.id
        switch p.phase {
        case .quitting: activity[pid] = "Quitting…"
        case let .waitingToQuit(elapsed): activity[pid] = "Waiting for it to quit (\(Int(elapsed)) s of \(Int(quitTimeout)))…"
        case .opening: activity[pid] = "Opening in the background…"
        case .verifying: activity[pid] = "Checking its tweaks…"
        case let .finished(r):
            activity[pid] = nil
            results[pid] = r
        }
    }

    private func finish(_ list: [RespringResult], calls: [SimulatedAppController.Call]?) {
        for r in list { results[r.id] = r }
        activity = [:]
        isRunning = false
        simulatedCalls = calls ?? []
        world?.apply(list)
        let ok = list.filter(\.succeeded).count
        let skipped = list.filter {
            switch $0.outcome {
            case .didNotQuit, .quitRefused, .notRunning, .cancelled: return true
            default: return false
            }
        }.count
        var s = "\(ok) of \(list.count) relaunched as expected"
        if skipped > 0 { s += "; \(skipped) skipped" }
        let failed = list.count - ok - skipped
        if failed > 0 { s += "; \(failed) need\(failed == 1 ? "s" : "") a look" }
        runSummary = s + (simulated ? " (simulated)" : "") + "."
        onFinished?()
        refresh()
    }

    func result(for c: RespringCandidate) -> RespringResult? { results[c.id] }

    func summary(_ r: RespringResult) -> String { r.summary(labels: labels) }
}
