import Foundation

// Respring, part 2: the relaunch engine (docs/respring.md). It quits each selected app politely, waits, reopens it
// in the background and checks with lsof that the new process has the expected tweaks. Everything that touches
// processes goes through `AppController`, so tests and Workbench's fixture modes use a fake that never touches a
// real app.

/// How to ask an app to quit.
public enum RespringQuitMethod: String, Sendable {
    /// NSRunningApplication.terminate (the app may refuse, e.g. to show a save dialog).
    case terminate
    /// The "quit" Apple Event; Finder ignores terminate.
    case appleEventQuit
    /// SIGTERM, as `killall` sends: for macOS's UI agents, which launchd starts again.
    case signal
    /// Force quit (SIGKILL): only with `Settings.forceQuit`, for an app still running after the polite quit timed out.
    case forceTerminate
}

public struct RespringOpenOptions: Hashable, Sendable {
    /// false: don't steal focus.
    public var activates = false
    /// Reopen hidden if it was hidden.
    public var hides = false
    /// Extra environment for the new process. Only the offline test sets this (DYLD_INSERT_LIBRARIES for test
    /// apps); a real respring relies on dynjectd.
    public var environment: [String: String]?

    public init(activates: Bool = false, hides: Bool = false, environment: [String: String]? = nil) {
        self.activates = activates
        self.hides = hides
        self.environment = environment
    }
}

public enum RespringControlError: Error, LocalizedError, Equatable {
    case openFailed(String)

    public var errorDescription: String? {
        switch self { case let .openFailed(m): return m }
    }
}

/// Everything the engine does to processes.
public protocol AppController: AnyObject {
    /// Asks the app to quit. false when the request couldn't be sent.
    func terminate(_ app: RunningApp, method: RespringQuitMethod) -> Bool
    func isRunning(pid: Int32) -> Bool
    /// Running instances of the bundle ID right now.
    func runningPIDs(bundleID: String) -> [Int32]
    /// Opens the app and returns the new process's pid.
    func open(bundleURL: URL, options: RespringOpenOptions) throws -> Int32
    /// Which of `candidates` the pid has mapped; nil when it can't be inspected.
    func loadedDylibs(pid: Int32, candidates: [String]) -> Set<String>?
    /// For the app running the engine (or hosting it): a detached process that reopens the app once `pid` has
    /// exited, giving up after `timeout` seconds if it never does.
    func scheduleReopen(bundleURL: URL, afterExitOf pid: Int32, timeout: TimeInterval) throws
}

public struct RespringClock: @unchecked Sendable {
    public var now: () -> Date
    public var sleep: (TimeInterval) -> Void

    public init(now: @escaping () -> Date, sleep: @escaping (TimeInterval) -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let system = RespringClock(now: Date.init, sleep: { Thread.sleep(forTimeInterval: $0) })

    /// A clock whose sleep only advances its own time (tests, fixture mode).
    public static func manual(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> RespringClock {
        let box = ManualTime(start)
        return RespringClock(now: { box.read() }, sleep: { box.advance($0) })
    }

    private final class ManualTime: @unchecked Sendable {
        private var t: Date
        private let lock = NSLock()
        init(_ t: Date) { self.t = t }
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return t }
        func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
    }
}

// MARK: - Results

public struct RespringVerification: Hashable, Sendable {
    /// Expected dylibs the new process doesn't have.
    public var missing: [String]
    /// Tweak dylibs it has but shouldn't.
    public var unexpected: [String]
    /// false: lsof couldn't read the new process.
    public var inspected: Bool

    public var ok: Bool { inspected && missing.isEmpty && unexpected.isEmpty }
}

public struct RespringResult: Identifiable, Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// Dry run.
        case wouldRelaunch
        /// Dry run, for an app that hosts the caller.
        case wouldHandOff
        /// Quit, reopened, and checked (see `verification`).
        case relaunched
        /// The app hosts the caller: a detached process reopens it after it quits.
        case handedOff
        /// It had already quit before its turn.
        case notRunning
        /// The quit request couldn't be sent.
        case quitRefused
        /// Still running after the timeout (unsaved changes, a dialog): left alone.
        case didNotQuit(timeout: TimeInterval)
        /// Quit, but couldn't be reopened.
        case openFailed(String)
        /// Reopened, but it quit again by the end of the run, and again after a second reopen.
        case exitedAfterOpen
        /// Stopped before its turn.
        case cancelled
    }

    public var id: Int32 { candidate.app.pid }
    public var candidate: RespringCandidate
    public var outcome: Outcome
    public var newPID: Int32?
    public var verification: RespringVerification?
    /// It ignored the polite quit and was force-quit after the timeout (`Settings.forceQuit`).
    public var forced = false
    /// The first reopened process had quit by the end of the run, so it was opened once more.
    public var reopenedAgain = false

    public init(candidate: RespringCandidate, outcome: Outcome, newPID: Int32? = nil, verification: RespringVerification? = nil,
                forced: Bool = false) {
        self.candidate = candidate
        self.outcome = outcome
        self.newPID = newPID
        self.verification = verification
        self.forced = forced
    }

    /// Relaunched with the expected tweaks (or handed off / dry run).
    public var succeeded: Bool {
        switch outcome {
        case .relaunched: return verification?.ok ?? false
        case .wouldRelaunch, .wouldHandOff, .handedOff: return true
        default: return false
        }
    }

    public func label(_ dylib: String, labels: [String: String] = [:]) -> String {
        labels[dylib] ?? candidate.reasons.first { $0.dylib == dylib }?.tweak ?? (dylib as NSString).lastPathComponent
    }

    /// "relaunched (pid 123), verified" / "skipped: still running after 15 s (unsaved changes or a dialog?)"
    public func summary(labels: [String: String] = [:]) -> String {
        var prefix = forced ? "force-quit after the timeout; " : ""
        if reopenedAgain { prefix += "quit again right after reopening, opened once more; " }
        return prefix + outcomeSummary(labels: labels)
    }

    private func outcomeSummary(labels: [String: String]) -> String {
        switch outcome {
        case .wouldRelaunch: return "would relaunch"
        case .wouldHandOff: return "would quit and hand the reopen to a detached process"
        case .handedOff: return "quitting; a detached process reopens it"
        case .notRunning: return "skipped: no longer running"
        case .quitRefused: return "skipped: the quit request couldn't be sent"
        case let .didNotQuit(t): return "skipped: still running after \(Int(t.rounded())) s (unsaved changes or a dialog?)"
        case let .openFailed(m): return "quit, but reopening failed: \(m)"
        case .exitedAfterOpen: return "reopened, but it quit again (twice); open it yourself to see why"
        case .cancelled: return "cancelled"
        case .relaunched:
            let pid = newPID.map { "pid \($0)" } ?? "new pid"
            guard let v = verification else { return "relaunched (\(pid))" }
            if !v.inspected { return "relaunched (\(pid)); couldn't inspect the new process" }
            if v.ok { return "relaunched (\(pid)), verified" }
            var parts: [String] = []
            if !v.missing.isEmpty { parts.append("still missing " + v.missing.map { label($0, labels: labels) }.joined(separator: ", ")) }
            if !v.unexpected.isEmpty { parts.append("still has " + v.unexpected.map { label($0, labels: labels) }.joined(separator: ", ")) }
            return "relaunched (\(pid)) but \(parts.joined(separator: "; "))"
        }
    }
}

/// Progress for the UI.
public struct RespringProgress: Sendable {
    public enum Phase: Sendable {
        case quitting
        case waitingToQuit(elapsed: TimeInterval)
        /// It ignored the quit until the timeout; force-quitting it (`Settings.forceQuit`).
        case forceQuitting
        case opening
        /// A system agent quit; launchd is to start it again.
        case waitingForLaunchd
        case verifying
        /// At the end of the run: the reopened process has quit, so it is opened once more.
        case reopeningAfterExit
        case finished(RespringResult)
    }

    public var candidate: RespringCandidate
    /// 0-based position in the run.
    public var index: Int
    public var total: Int
    public var phase: Phase
}

// MARK: - Engine

public final class Respringer {
    public struct Settings: Sendable {
        /// How long an app gets to quit before it is skipped.
        public var quitTimeout: TimeInterval = 15
        public var pollInterval: TimeInterval = 0.2
        /// How long to wait for the new process to show its tweaks in lsof.
        public var verifyTimeout: TimeInterval = 5
        /// How long launchd gets to start a system agent again after it quit.
        public var restartTimeout: TimeInterval = 10
        /// Passed to every open (offline test only).
        public var environment: [String: String]?
        /// More tweak dylibs to look for when verifying (so an unwanted one that came back is noticed).
        public var tweakDylibs: [String] = []
        /// Force quit an app still running after `quitTimeout` instead of skipping it (its unsaved changes are lost).
        public var forceQuit = false
        /// How long a force-quit app gets to go away.
        public var forceTimeout: TimeInterval = 5
        /// At the end of the run, how long the last reopened app has had to settle before every reopened app is
        /// checked once more (some quit right after starting; that one is opened again).
        public var settleTime: TimeInterval = 2

        public init(quitTimeout: TimeInterval = 15, pollInterval: TimeInterval = 0.2, verifyTimeout: TimeInterval = 5,
                    environment: [String: String]? = nil, tweakDylibs: [String] = [], forceQuit: Bool = false,
                    settleTime: TimeInterval = 2) {
            self.quitTimeout = quitTimeout
            self.pollInterval = pollInterval
            self.verifyTimeout = verifyTimeout
            self.environment = environment
            self.tweakDylibs = tweakDylibs
            self.forceQuit = forceQuit
            self.settleTime = settleTime
        }
    }

    public let controller: AppController
    public let clock: RespringClock
    public var settings: Settings

    public init(controller: AppController, clock: RespringClock = .system, settings: Settings = Settings()) {
        self.controller = controller
        self.clock = clock
        self.settings = settings
    }

    static func byName(_ a: RespringCandidate, _ b: RespringCandidate) -> Bool {
        let c = a.app.name.localizedCaseInsensitiveCompare(b.app.name)
        return c == .orderedSame ? a.app.pid < b.app.pid : c == .orderedAscending
    }

    /// Relaunch order: other apps by name, then Workbench, then whatever hosts the caller (its relaunch ends the
    /// caller, so nothing can follow it).
    public static func ordered(_ apps: [RespringCandidate]) -> [RespringCandidate] {
        func rank(_ c: RespringCandidate) -> Int { c.hostsCaller ? 2 : c.isWorkbench ? 1 : 0 }
        return apps.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : byName($0, $1) }
    }

    /// Relaunches `apps` one at a time (in `ordered` order). Blocking: call it off the main thread in an app.
    /// `dryRun` reports what would happen without calling the controller at all.
    public func run(_ apps: [RespringCandidate], dryRun: Bool = false,
                    progress: ((RespringProgress) -> Void)? = nil,
                    isCancelled: () -> Bool = { false }) -> [RespringResult] {
        let list = Self.ordered(apps)
        var results: [RespringResult] = []
        for (i, c) in list.enumerated() {
            func report(_ phase: RespringProgress.Phase) {
                progress?(RespringProgress(candidate: c, index: i, total: list.count, phase: phase))
            }
            let result: RespringResult
            if dryRun {
                result = RespringResult(candidate: c, outcome: c.hostsCaller ? .wouldHandOff : .wouldRelaunch)
            } else if isCancelled() {
                result = RespringResult(candidate: c, outcome: .cancelled)
            } else {
                result = relaunch(c, report: report)
            }
            report(.finished(result))
            results.append(result)
            if result.outcome == .handedOff { break }
        }
        if !dryRun { recheck(&results, total: list.count, progress: progress) }
        return results
    }

    /// Reopened apps that have quit again since (ChatGPT has, right after its reopen): each is opened once more and
    /// checked after another settle; one that quits again is reported, not retried.
    func recheck(_ results: inout [RespringResult], total: Int, progress: ((RespringProgress) -> Void)?) {
        func opened(_ r: RespringResult) -> Bool { r.outcome == .relaunched && !r.candidate.app.isSystemAgent && r.newPID != nil }
        guard results.contains(where: opened) else { return }
        clock.sleep(settings.settleTime)
        var again: [Int] = []
        for (i, r) in results.enumerated() where opened(r) {
            guard let pid = r.newPID, !controller.isRunning(pid: pid) else { continue }
            let c = r.candidate
            if let other = controller.runningPIDs(bundleID: c.app.bundleID).first(where: { $0 != pid && $0 != c.app.pid }) {
                // Something else (the app itself, launchd) started it again: check that one.
                results[i].newPID = other
                results[i].verification = verify(c, pid: other)
                continue
            }
            progress?(RespringProgress(candidate: c, index: i, total: total, phase: .reopeningAfterExit))
            let url = URL(fileURLWithPath: c.app.bundlePath, isDirectory: true)
            results[i].reopenedAgain = true
            do {
                let p = try controller.open(bundleURL: url, options: RespringOpenOptions(
                    activates: false, hides: c.app.isHidden, environment: settings.environment))
                results[i].newPID = p
                results[i].verification = verify(c, pid: p)
                again.append(i)
            } catch {
                results[i].outcome = .openFailed(error.localizedDescription)
                progress?(RespringProgress(candidate: c, index: i, total: total, phase: .finished(results[i])))
            }
        }
        guard !again.isEmpty else { return }
        clock.sleep(settings.settleTime)
        for i in again {
            if let p = results[i].newPID, !controller.isRunning(pid: p) { results[i].outcome = .exitedAfterOpen }
            progress?(RespringProgress(candidate: results[i].candidate, index: i, total: total, phase: .finished(results[i])))
        }
    }

    func relaunch(_ c: RespringCandidate, report: (RespringProgress.Phase) -> Void) -> RespringResult {
        let app = c.app
        let url = URL(fileURLWithPath: app.bundlePath, isDirectory: true)
        guard controller.isRunning(pid: app.pid) else { return RespringResult(candidate: c, outcome: .notRunning) }
        let method: RespringQuitMethod = app.isSystemAgent ? .signal
            : app.bundleID.caseInsensitiveCompare(RespringExclusions.finderBundleID) == .orderedSame ? .appleEventQuit : .terminate

        if c.hostsCaller {
            do {
                try controller.scheduleReopen(bundleURL: url, afterExitOf: app.pid, timeout: settings.quitTimeout)
            } catch {
                return RespringResult(candidate: c, outcome: .openFailed(error.localizedDescription))
            }
            report(.quitting)
            return RespringResult(candidate: c, outcome: controller.terminate(app, method: method) ? .handedOff : .quitRefused)
        }

        let before = Set(controller.runningPIDs(bundleID: app.bundleID))
        report(.quitting)
        guard controller.terminate(app, method: method) else { return RespringResult(candidate: c, outcome: .quitRefused) }
        let start = clock.now()
        var forced = false
        while controller.isRunning(pid: app.pid) {
            let elapsed = clock.now().timeIntervalSince(start)
            if elapsed >= settings.quitTimeout && settings.forceQuit && !forced {
                report(.forceQuitting)
                forced = true
                _ = controller.terminate(app, method: .forceTerminate)
                continue
            }
            if elapsed >= settings.quitTimeout + (forced ? settings.forceTimeout : 0) {
                return RespringResult(candidate: c, outcome: .didNotQuit(timeout: settings.quitTimeout), forced: forced)
            }
            report(.waitingToQuit(elapsed: elapsed))
            clock.sleep(settings.pollInterval)
        }

        // launchd may already have restarted it (Finder); use that instance instead of opening a second one.
        func restarted() -> Int32? {
            controller.runningPIDs(bundleID: app.bundleID).first(where: { !before.contains($0) && $0 != app.pid })
        }
        let newPID: Int32
        if app.isSystemAgent {
            // Only launchd starts these: opening the bundle would make a second copy outside launchd.
            let waited = clock.now()
            var found = restarted()
            if found == nil { report(.waitingForLaunchd) }
            while found == nil && clock.now().timeIntervalSince(waited) < settings.restartTimeout {
                clock.sleep(settings.pollInterval)
                found = restarted()
            }
            guard let found else {
                let label = ServiceNameResolver.knownLaunchdLabels[app.bundleID.lowercased()] ?? "<its launchd label>"
                return RespringResult(candidate: c, outcome: .openFailed(
                    "launchd didn't start it again within \(Int(settings.restartTimeout)) s: `launchctl kickstart gui/\(getuid())/\(label)`, or log out and back in"))
            }
            newPID = found
        } else if let adopted = restarted() {
            newPID = adopted
        } else {
            report(.opening)
            do {
                newPID = try controller.open(bundleURL: url, options: RespringOpenOptions(
                    activates: false, hides: app.isHidden, environment: settings.environment))
            } catch {
                return RespringResult(candidate: c, outcome: .openFailed(error.localizedDescription))
            }
        }

        report(.verifying)
        return RespringResult(candidate: c, outcome: .relaunched, newPID: newPID, verification: verify(c, pid: newPID),
                              forced: forced)
    }

    /// Polls lsof until the new process has the expected tweaks and none it shouldn't, or `verifyTimeout` passes.
    func verify(_ c: RespringCandidate, pid: Int32) -> RespringVerification {
        var seen = Set<String>()
        let candidates = (c.expected + (c.loaded ?? []).sorted() + c.reasons.map(\.dylib) + settings.tweakDylibs)
            .filter { seen.insert($0).inserted }
        let start = clock.now()
        while true {
            var v = RespringVerification(missing: [], unexpected: [], inspected: false)
            if let loaded = controller.loadedDylibs(pid: pid, candidates: candidates) {
                v = RespringVerification(missing: c.expected.filter { !loaded.contains($0) },
                                         unexpected: loaded.filter { !c.expected.contains($0) }.sorted(),
                                         inspected: true)
            }
            if v.ok || clock.now().timeIntervalSince(start) >= settings.verifyTimeout { return v }
            clock.sleep(settings.pollInterval)
        }
    }
}

// MARK: - Simulation

/// A controller that only pretends: for tests and for Workbench's fixture and smoke-test modes. It never looks at
/// or signals a real process. Apps quit at once unless listed in `refusesToQuit`; reopened apps get `newPIDs` in
/// turn and report `loadedAfterOpen` (default: whatever `expectedAfterOpen` says, else nothing).
public final class SimulatedAppController: AppController {
    public enum Call: Hashable, Sendable {
        case terminate(Int32, RespringQuitMethod)
        case open(String, RespringOpenOptions)
        case scheduleReopen(String, Int32)
    }

    public private(set) var calls: [Call] = []
    public var running: Set<Int32>
    public var pidsByBundleID: [String: [Int32]]
    public var refusesToQuit: Set<String> = []
    /// bundle ID → how many of its next opens start a process that has quit again by the time anyone checks.
    public var exitsAfterOpen: [String: Int] = [:]
    public var quitRequestFails: Set<String> = []
    public var openFails: Set<String> = []
    /// bundle ID → dylibs the reopened process reports (nil: not inspectable).
    public var loadedAfterOpen: [String: Set<String>?] = [:]
    /// Called when an app quits; lets a test restart it "by launchd" (Finder).
    public var onQuit: ((RunningApp) -> Int32?)?
    private var nextPID: Int32
    private var bundleIDByPath: [String: String] = [:]
    private var loadedByPID: [Int32: Set<String>?] = [:]
    private let lock = NSLock()

    public init(apps: [RunningApp], nextPID: Int32 = 90_000) {
        running = Set(apps.map(\.pid))
        pidsByBundleID = Dictionary(grouping: apps, by: \.bundleID).mapValues { $0.map(\.pid) }
        for a in apps { bundleIDByPath[a.bundlePath] = a.bundleID }
        self.nextPID = nextPID
    }

    /// The plan's apps, each reopening with its expected tweaks (so verification passes).
    public convenience init(plan: RespringPlan, nextPID: Int32 = 90_000) {
        self.init(apps: plan.candidates.map(\.app), nextPID: nextPID)
        for c in plan.candidates { loadedAfterOpen[c.app.bundleID] = Set(c.expected) }
    }

    private func record(_ c: Call) { lock.lock(); calls.append(c); lock.unlock() }

    public func terminate(_ app: RunningApp, method: RespringQuitMethod) -> Bool {
        record(.terminate(app.pid, method))
        if quitRequestFails.contains(app.bundleID) { return false }
        if refusesToQuit.contains(app.bundleID) && method != .forceTerminate { return true }
        running.remove(app.pid)
        pidsByBundleID[app.bundleID]?.removeAll { $0 == app.pid }
        if let p = onQuit?(app) {
            running.insert(p)
            pidsByBundleID[app.bundleID, default: []].append(p)
            loadedByPID[p] = loadedAfterOpen[app.bundleID] ?? []
        }
        return true
    }

    public func isRunning(pid: Int32) -> Bool { running.contains(pid) }

    public func runningPIDs(bundleID: String) -> [Int32] { pidsByBundleID[bundleID] ?? [] }

    public func open(bundleURL: URL, options: RespringOpenOptions) throws -> Int32 {
        let path = RespringPaths.normalized(bundleURL.path)
        record(.open(path, options))
        let id = bundleIDByPath[path] ?? path
        if openFails.contains(id) { throw RespringControlError.openFailed("simulated failure") }
        let pid = nextPID
        nextPID += 1
        loadedByPID[pid] = loadedAfterOpen[id] ?? []
        if let n = exitsAfterOpen[id], n > 0 {
            exitsAfterOpen[id] = n - 1
            return pid
        }
        running.insert(pid)
        pidsByBundleID[id, default: []].append(pid)
        return pid
    }

    public func loadedDylibs(pid: Int32, candidates: [String]) -> Set<String>? {
        guard let entry = loadedByPID[pid] else { return nil }
        return entry.map { $0.intersection(candidates) }
    }

    public func scheduleReopen(bundleURL: URL, afterExitOf pid: Int32, timeout: TimeInterval) throws {
        record(.scheduleReopen(RespringPaths.normalized(bundleURL.path), pid))
    }
}
