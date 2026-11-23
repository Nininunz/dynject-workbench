import Foundation

// Safe Mode: per-app, automatic disabling of tweaks that crash apps. See docs/safe-mode.md.
//
//   key   "dynject.safemode" in the user's global preferences domain
//   value { tweakID: [bundleID | "*"], "*": ["*"] (panic: every DynjectHook tweak, everywhere) }
//   Darwin notification "dynject.safemode.changed" after every change.
//
// DynjectHook's DHShouldLoad reads the key at load time. Everything the key can't hold (why, since when, which
// crash report, re-enable times, processed reports, settings) lives in SafeMode/state.json.

// MARK: - Names

public struct SafeModeNames: Sendable, Equatable {
    public static let productionKey = "dynject.safemode"
    /// The key, notification and preferences domain tests use instead of the real ones.
    public static let testDomain = "local.dynject.safemode.test"
    /// The tweak and bundle-ID wildcard.
    public static let all = "*"

    public var key: String
    public var notification: String

    public static let production = SafeModeNames(key: productionKey, notification: "dynject.safemode.changed")

    /// For a preferences domain other than the global one (tests): same key, notification "<domain>.changed".
    public static func forDomain(_ domain: String) -> SafeModeNames {
        SafeModeNames(key: productionKey, notification: "\(domain).changed")
    }

    public init(key: String, notification: String) {
        self.key = key
        self.notification = notification
    }
}

// MARK: - The preferences key

/// Read-modify-write access to "dynject.safemode". Entries it doesn't touch (other tweaks, values of unexpected
/// types) are preserved; every change posts the change notification; an empty dictionary removes the key.
public final class SafeModeKeyStore {
    public let store: GlobalPrefsStore
    public let names: SafeModeNames

    public init(store: GlobalPrefsStore, names: SafeModeNames) {
        self.store = store
        self.names = names
    }

    public func rawValue() -> [String: Any] { store.dictionary(forKey: names.key) ?? [:] }

    /// tweakID → bundle IDs, keeping only string values inside arrays (what DynjectHook honours).
    public func entries() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (k, v) in rawValue() {
            guard let a = v as? [Any] else { continue }
            let ids = a.compactMap { $0 as? String }
            if !ids.isEmpty { out[k] = ids }
        }
        return out
    }

    public var isPanicOn: Bool { entries()[SafeModeNames.all]?.contains(SafeModeNames.all) ?? false }

    /// Whether the key lists `bundleID` (or "*") for `tweakID`. The panic switch is not included.
    public func isListed(tweakID: String, bundleID: String) -> Bool {
        guard let ids = entries()[tweakID] else { return false }
        return ids.contains(SafeModeNames.all) || ids.contains(bundleID)
    }

    /// Whether a DynjectHook tweak stays out of `bundleID`: its own entry or the "*" entry (every tweak) lists
    /// the app or "*". DHShouldLoad applies the same test.
    public func isSuppressed(tweakID: String, bundleID: String) -> Bool {
        isListed(tweakID: tweakID, bundleID: bundleID) || isListed(tweakID: SafeModeNames.all, bundleID: bundleID)
    }

    /// Adds `bundleID` to the tweak's list. Returns false when it was already covered.
    @discardableResult
    public func add(tweakID: String, bundleID: String) throws -> Bool {
        try modify { raw in
            var list = (raw[tweakID] as? [Any]) ?? []
            let strings = list.compactMap { $0 as? String }
            // A tweak listed for "*" is off everywhere already. The "*" entry is different: its own "*" is the
            // panic switch, and apps listed beside it should survive turning panic off.
            let collapses = tweakID != SafeModeNames.all
            if collapses && strings.contains(SafeModeNames.all) { return }
            if bundleID == SafeModeNames.all && collapses {
                // Off everywhere replaces the per-app entries, so no per-app row survives that Re-enable can't
                // actually re-enable. (state.json keeps their history.)
                raw[tweakID] = [SafeModeNames.all]
                return
            }
            if strings.contains(bundleID) { return }
            list.append(bundleID)
            raw[tweakID] = list
        }
    }

    /// Removes `bundleID` from the tweak's list; "*" removes the tweak's whole entry (re-enabled everywhere),
    /// unless `wildcardRemovesEntry` is false, which removes only the "*" element.
    @discardableResult
    public func remove(tweakID: String, bundleID: String, wildcardRemovesEntry: Bool = true) throws -> Bool {
        try modify { raw in
            guard let list = raw[tweakID] as? [Any] else { return }
            if bundleID == SafeModeNames.all && wildcardRemovesEntry { raw[tweakID] = nil; return }
            let kept = list.filter { ($0 as? String) != bundleID }
            raw[tweakID] = kept.isEmpty ? nil : kept
        }
    }

    /// Adds or removes "*" in the "*" entry. Apps listed there on their own (every tweak off in one app) stay.
    @discardableResult
    public func setPanic(_ on: Bool) throws -> Bool {
        on ? try add(tweakID: SafeModeNames.all, bundleID: SafeModeNames.all)
            : try remove(tweakID: SafeModeNames.all, bundleID: SafeModeNames.all, wildcardRemovesEntry: false)
    }

    /// Removes the key entirely.
    @discardableResult
    public func removeAll() throws -> Bool { try modify { $0 = [:] } }

    /// Applies `body` to the current value; writes and notifies only if something changed.
    @discardableResult
    public func modify(_ body: (inout [String: Any]) -> Void) throws -> Bool {
        let old = store.dictionary(forKey: names.key)
        var raw = old ?? [:]
        body(&raw)
        let new: [String: Any]? = raw.isEmpty ? nil : raw
        switch (old, new) {
        case (nil, nil): return false
        case let (o?, n?) where NSDictionary(dictionary: o).isEqual(to: n): return false
        default: break
        }
        try store.setDictionary(new, forKey: names.key)
        store.postNotification(names.notification)
        return true
    }
}

// MARK: - State (state.json)

public enum SafeModeReason: String, Codable, Sendable, CaseIterable {
    case crashInTweak = "crash in tweak"
    case repeatedCrashes = "repeated crashes"
    case manual
    case panic
}

public struct SafeModeSettings: Codable, Equatable, Sendable {
    /// Tweak-loaded crashes of one app within `windowMinutes` that disable a tweak there.
    public var threshold: Int = 2
    public var windowMinutes: Double = 10
    /// Post a notification when the watcher disables something.
    public var notify: Bool = true
    /// How many frames (after crash machinery such as abort() or objc_exception_throw) are searched for a
    /// tweak frame when deciding whether a crash happened inside a tweak.
    public var inTweakDepth: Int = CrashAttributor.defaultDepth
    /// Reports of crashes older than this are recorded but never disable anything (e.g. a backlog the first
    /// time the watcher runs).
    public var maxReportAgeMinutes: Double = 60

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SafeModeSettings()
        threshold = max(1, (try? c.decodeIfPresent(Int.self, forKey: .threshold)) ?? d.threshold)
        windowMinutes = (try? c.decodeIfPresent(Double.self, forKey: .windowMinutes)).flatMap { $0 > 0 ? $0 : nil } ?? d.windowMinutes
        notify = (try? c.decodeIfPresent(Bool.self, forKey: .notify)) ?? d.notify
        inTweakDepth = max(1, (try? c.decodeIfPresent(Int.self, forKey: .inTweakDepth)) ?? d.inTweakDepth)
        maxReportAgeMinutes = (try? c.decodeIfPresent(Double.self, forKey: .maxReportAgeMinutes)).flatMap { $0 > 0 ? $0 : nil }
            ?? d.maxReportAgeMinutes
    }
}

/// A crash report the watcher has looked at, so restarts don't process it again.
public struct SafeModeProcessedReport: Codable, Equatable, Sendable {
    public var size: Int64
    /// Modification time, seconds since 1970 (kept numeric so sub-second precision survives).
    public var mtime: Double
    public var incidentID: String?

    public init(size: Int64, mtime: Double, incidentID: String?) {
        self.size = size
        self.mtime = mtime
        self.incidentID = incidentID
    }

    public func matches(size: Int64, mtime: Double) -> Bool { self.size == size && abs(self.mtime - mtime) < 0.001 }
}

/// One tweak loaded in one crashed process.
public struct SafeModeCrash: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(reportPath)|\(tweakID)" }
    public var tweakID: String
    /// nil when the report has no usable bundle identifier (such crashes never disable anything).
    public var bundleID: String?
    public var appName: String?
    public var date: Date
    public var reportPath: String
    /// The crash happened in this tweak's code.
    public var inTweak: Bool
    public var frameSummary: String
    public var incidentID: String?
    /// The tweaks the crash happened in (any loaded tweak with a frame in view). When it names other tweaks, the
    /// crash is theirs and never counts as a "repeated crash" against this one. nil in records from older versions.
    public var culpritIDs: [String]?

    public init(tweakID: String, bundleID: String?, appName: String?, date: Date, reportPath: String, inTweak: Bool,
                frameSummary: String, incidentID: String?, culpritIDs: [String]? = nil) {
        self.tweakID = tweakID
        self.bundleID = bundleID
        self.appName = appName
        self.date = date
        self.reportPath = reportPath
        self.inTweak = inTweak
        self.frameSummary = frameSummary
        self.incidentID = incidentID
        self.culpritIDs = culpritIDs
    }

    /// Whether this crash counts toward `tweakID`'s repeated-crash threshold: no tweak was found at fault, or
    /// this one was.
    public func counts(against tweakID: String) -> Bool {
        guard let c = culpritIDs, !c.isEmpty else { return true }
        return c.contains(tweakID)
    }
}

/// Why and since when a (tweak, app) pair is in the key.
public struct SafeModeDisabledEntry: Codable, Equatable, Sendable {
    public var tweakID: String
    public var bundleID: String
    public var since: Date
    public var reason: SafeModeReason
    public var reportPath: String?
    public var frameSummary: String?

    public init(tweakID: String, bundleID: String, since: Date, reason: SafeModeReason, reportPath: String? = nil,
                frameSummary: String? = nil) {
        self.tweakID = tweakID
        self.bundleID = bundleID
        self.since = since
        self.reason = reason
        self.reportPath = reportPath
        self.frameSummary = frameSummary
    }
}

public struct SafeModeReenable: Codable, Equatable, Sendable {
    /// "*" for every tweak (after `clear`).
    public var tweakID: String
    /// "*" for every app.
    public var bundleID: String
    public var date: Date
}

public struct SafeModeState: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    public static let maxRecentCrashes = 200

    public var formatVersion = SafeModeState.formatVersion
    public var settings = SafeModeSettings()
    /// Report file name → what it was when processed.
    public var processedReports: [String: SafeModeProcessedReport] = [:]
    /// Oldest first.
    public var recentCrashes: [SafeModeCrash] = []
    public var disabled: [SafeModeDisabledEntry] = []
    public var reenabled: [SafeModeReenable] = []
    /// When the panic switch was turned on through Safe Mode (nil: off, or turned on with `defaults`).
    public var panicSince: Date?

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerate missing, mistyped and individually broken fields so a damaged file still loads.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = (try? c.decodeIfPresent(Int.self, forKey: .formatVersion)) ?? Self.formatVersion
        settings = (try? c.decodeIfPresent(SafeModeSettings.self, forKey: .settings)) ?? SafeModeSettings()
        processedReports = ((try? c.decodeIfPresent([String: Lossy<SafeModeProcessedReport>].self, forKey: .processedReports)) ?? [:])
            .compactMapValues(\.value)
        recentCrashes = ((try? c.decodeIfPresent([Lossy<SafeModeCrash>].self, forKey: .recentCrashes)) ?? []).compactMap(\.value)
        disabled = ((try? c.decodeIfPresent([Lossy<SafeModeDisabledEntry>].self, forKey: .disabled)) ?? []).compactMap(\.value)
        reenabled = ((try? c.decodeIfPresent([Lossy<SafeModeReenable>].self, forKey: .reenabled)) ?? []).compactMap(\.value)
        panicSince = try? c.decodeIfPresent(Date.self, forKey: .panicSince)
    }

    /// The latest re-enable that covers (tweak, app): exact, the tweak in every app, or everything.
    public func reenabledAt(tweakID: String, bundleID: String) -> Date? {
        reenabled.filter {
            ($0.tweakID == tweakID || $0.tweakID == SafeModeNames.all)
                && ($0.bundleID == bundleID || $0.bundleID == SafeModeNames.all)
        }.map(\.date).max()
    }

    public mutating func recordReenable(tweakID: String, bundleID: String, at date: Date) {
        reenabled.removeAll { $0.tweakID == tweakID && $0.bundleID == bundleID }
        reenabled.append(.init(tweakID: tweakID, bundleID: bundleID, date: date))
    }

    public func hasSeen(incidentID: String) -> Bool {
        processedReports.values.contains { $0.incidentID == incidentID } || recentCrashes.contains { $0.incidentID == incidentID }
    }

    public func disabledEntry(tweakID: String, bundleID: String) -> SafeModeDisabledEntry? {
        disabled.last { $0.tweakID == tweakID && $0.bundleID == bundleID }
    }

    public mutating func setDisabled(_ entry: SafeModeDisabledEntry) {
        disabled.removeAll { $0.tweakID == entry.tweakID && $0.bundleID == entry.bundleID }
        disabled.append(entry)
    }

    mutating func trimCrashes() {
        recentCrashes.sort { $0.date < $1.date }
        if recentCrashes.count > Self.maxRecentCrashes { recentCrashes.removeFirst(recentCrashes.count - Self.maxRecentCrashes) }
    }
}

/// Decodes to nil instead of failing the surrounding collection.
struct Lossy<T: Decodable>: Decodable {
    var value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

public enum SafeModeStateError: Error, LocalizedError {
    case lock(String)
    public var errorDescription: String? {
        switch self { case let .lock(m): return m }
    }
}

/// state.json with atomic writes. `update` holds an exclusive lock (flock on state.lock) across
/// read-modify-write, so the watcher and Workbench never lose each other's changes.
public final class SafeModeStateStore {
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("state.json") }
    var lockURL: URL { directory.appendingPathComponent("state.lock") }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dynject Workbench/SafeMode", isDirectory: true)
    }

    public init(directory: URL = SafeModeStateStore.defaultDirectory) { self.directory = directory }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(isoFormatter(fractional: true).string(from: date))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            if let n = try? c.decode(Double.self) { return Date(timeIntervalSince1970: n) }
            let s = try c.decode(String.self)
            if let d = isoFormatter(fractional: true).date(from: s) ?? isoFormatter(fractional: false).date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO 8601 date: \(s)")
        }
        return d
    }()

    static func isoFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f
    }

    /// The current state; defaults when the file is missing or unreadable.
    public func load() -> SafeModeState {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let state = try? Self.decoder.decode(SafeModeState.self, from: data) else { return SafeModeState() }
        return state
    }

    @discardableResult
    public func update<T>(_ body: (inout SafeModeState) throws -> T) throws -> T {
        try updateCommitting { state, _ in try body(&state) }
    }

    /// `update`, plus `commit`, which writes the state as it is so far while the lock is still held. The scanner
    /// commits right after each key write, so a pass that is stopped later (SIGTERM, a crash) can't leave the key
    /// changed with state.json knowing nothing about it.
    @discardableResult
    public func updateCommitting<T>(_ body: (inout SafeModeState, _ commit: (SafeModeState) throws -> Void) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw SafeModeStateError.lock("Could not open \(lockURL.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw SafeModeStateError.lock("Could not lock \(lockURL.path).") }
        defer { flock(fd, LOCK_UN) }

        let existing = FileManager.default.contents(atPath: fileURL.path)
        var state = existing.flatMap { try? Self.decoder.decode(SafeModeState.self, from: $0) } ?? SafeModeState()
        if let existing, (try? Self.decoder.decode(SafeModeState.self, from: existing)) == nil {
            // Keep an unreadable file for inspection instead of silently overwriting it.
            try? existing.write(to: directory.appendingPathComponent("state.json.unreadable"), options: .atomic)
        }
        var written = existing == nil ? nil : state
        let result = try body(&state) { snapshot in
            guard snapshot != written else { return }
            try AtomicFile.write(try Self.encoder.encode(snapshot), to: fileURL.path)
            written = snapshot
        }
        if state != written {
            try AtomicFile.write(try Self.encoder.encode(state), to: fileURL.path)
        }
        return result
    }
}

// MARK: - Rules

/// What the watcher should do about one tweak in one app.
public struct SafeModeDecision: Equatable, Sendable {
    public var tweak: SafeModeTweak
    public var bundleID: String
    public var appName: String?
    public var reason: SafeModeReason
    public var reportPath: String
    public var frameSummary: String
    /// The crashes that led to it (one for `.crashInTweak`).
    public var crashCount: Int
}

public enum SafeModeEvaluation: Equatable, Sendable {
    case notACrash
    case duplicate
    /// A Dynject process (dynjectd) crashed; Safe Mode never acts on Dynject itself.
    case dynject
    case noTweaks
    case recorded(crashes: [SafeModeCrash], decisions: [SafeModeDecision])

    public var crashes: [SafeModeCrash] { if case let .recorded(c, _) = self { return c } else { return [] } }
    public var decisions: [SafeModeDecision] { if case let .recorded(_, d) = self { return d } else { return [] } }
}

public enum SafeModeRules {
    /// Records the crash for every tweak loaded in the process and decides which (tweak, app) pairs to disable:
    ///  - immediately when the crash happened inside the tweak;
    ///  - otherwise when the app had `threshold` tweak-loaded crashes within `windowMinutes`.
    /// Crashes before the pair's last re-enable never count, and neither do crashes another tweak was found at
    /// fault for (a bystander that merely shared the process); crashes older than `maxReportAgeMinutes` (relative
    /// to `now`) are recorded but decide nothing; non-crash reports and repeated incident IDs are ignored.
    /// `isInert` says a tweak was loaded but not running in that app when it crashed (Safe Mode kept it out at
    /// that time); such tweaks are neither recorded nor disabled again, unless the crash happened in their code,
    /// which proves they ran. Tweaks without a manifest are recorded, never disabled.
    public static func evaluate(_ report: CrashReport, attribution: CrashAttribution, state: inout SafeModeState,
                                now: Date, fallbackDate: Date? = nil,
                                isInert: (SafeModeTweak, String) -> Bool = { _, _ in false }) -> SafeModeEvaluation {
        guard report.isCrash else { return .notACrash }
        if let id = report.incidentID, state.hasSeen(incidentID: id) { return .duplicate }
        if let p = report.processPath, p.hasPrefix("/opt/dynject/") { return .dynject }
        let date = report.date ?? fallbackDate ?? now
        let settings = state.settings
        let window = settings.windowMinutes * 60
        let fresh = date >= now.addingTimeInterval(-settings.maxReportAgeMinutes * 60)

        var crashes: [SafeModeCrash] = []
        var decisions: [SafeModeDecision] = []
        let culprits = attribution.culprits.map(\.tweakID)
        for loaded in attribution.loaded {
            let tweak = loaded.tweak
            if !loaded.inTweak, let b = report.bundleID, isInert(tweak, b) { continue }
            let crash = SafeModeCrash(tweakID: tweak.tweakID, bundleID: report.bundleID, appName: report.displayName,
                                      date: date, reportPath: report.path, inTweak: loaded.inTweak,
                                      frameSummary: loaded.frame.map { "\(report.exceptionDescription.map { "\($0) " } ?? "")in \($0)" }
                                          ?? attribution.frameSummary,
                                      incidentID: report.incidentID, culpritIDs: culprits)
            crashes.append(crash)
            state.recentCrashes.append(crash)
            guard let bundleID = report.bundleID, fresh, tweak.canUseSafeModeKey else { continue }
            let reenabled = state.reenabledAt(tweakID: tweak.tweakID, bundleID: bundleID) ?? .distantPast
            guard date > reenabled else { continue }
            if loaded.inTweak {
                decisions.append(.init(tweak: tweak, bundleID: bundleID, appName: report.displayName, reason: .crashInTweak,
                                       reportPath: report.path, frameSummary: crash.frameSummary, crashCount: 1))
                continue
            }
            let counted = state.recentCrashes.filter {
                $0.tweakID == tweak.tweakID && $0.bundleID == bundleID && $0.date > reenabled
                    && $0.date <= date && $0.date >= date.addingTimeInterval(-window) && $0.counts(against: tweak.tweakID)
            }
            if counted.count >= settings.threshold {
                decisions.append(.init(tweak: tweak, bundleID: bundleID, appName: report.displayName, reason: .repeatedCrashes,
                                       reportPath: report.path, frameSummary: crash.frameSummary, crashCount: counted.count))
            }
        }
        state.trimCrashes()
        return crashes.isEmpty ? .noTweaks : .recorded(crashes: crashes, decisions: decisions)
    }

    /// Whether the key kept `tweakID` out of `bundleID` when the app crashed at `date`, for a tweak with
    /// `support`: an entry that covers the pair and was added no later than `date`. Entries' start times come from
    /// state.json (`disabled[].since`, `panicSince`); an entry it knows nothing about (added with `defaults`) is
    /// taken to be older than the crash. Old DynjectHook builds (`.perTweak`) ignore the "*" entry.
    public static func wasSuppressed(tweakID: String, bundleID: String, at date: Date, entries: [String: [String]],
                                     state: SafeModeState, support: SafeModeSupport) -> Bool {
        func began(_ t: String, _ b: String) -> Date { state.disabledEntry(tweakID: t, bundleID: b)?.since ?? .distantPast }
        let all = SafeModeNames.all
        if support.honoursKey, tweakID != all, let ids = entries[tweakID] {
            for b in [bundleID, all] where ids.contains(b) && began(tweakID, b) <= date { return true }
        }
        if support.honoursPanic, let ids = entries[all] {
            if bundleID != all, ids.contains(bundleID), began(all, bundleID) <= date { return true }
            if ids.contains(all), (state.panicSince ?? .distantPast) <= date { return true }
        }
        return false
    }
}

// MARK: - Facade

/// One (tweak, app) pair in the key, with whatever state.json knows about it.
public struct SafeModeDisabledItem: Equatable, Sendable, Identifiable {
    public var id: String { "\(tweakID)|\(bundleID)" }
    /// A tweak ID, or "*": every DynjectHook tweak in `bundleID`.
    public var tweakID: String
    /// A bundle ID or "*" (every app).
    public var bundleID: String
    /// nil when the entry was added outside Workbench and the watcher (e.g. with `defaults`).
    public var since: Date?
    public var reason: SafeModeReason?
    public var reportPath: String?
    public var frameSummary: String?
    /// nil when no installed tweak has this ID.
    public var tweak: SafeModeTweak?
    /// nil when unknown (no tweak, or its dylib can't be read).
    public var support: SafeModeSupport?
    /// What else keeps the tweak out of the app (an "every app" entry, every tweak off in that app, panic).
    public var alsoOffBecause: [SafeModeStillOff] = []

    /// false: the tweak ignores the key; only the Dynject config can stop it. nil when unknown.
    public var supportsSafeMode: Bool? { support?.honoursKey }
}

/// Why a tweak stays out of an app after its own entry for that app is gone.
public enum SafeModeStillOff: String, Equatable, Sendable {
    /// The tweak's entry lists "*" (every app).
    case everyApp = "it is disabled in every app"
    /// The "*" entry lists the app (every DynjectHook tweak off there).
    case allTweaksInApp = "every tweak is disabled in this app"
    /// The panic switch is on.
    case panic = "the panic switch is on"

    public static func describe(_ reasons: [SafeModeStillOff]) -> String {
        reasons.map(\.rawValue).joined(separator: " and ")
    }
}

public enum SafeModeError: Error, LocalizedError, Equatable {
    /// Re-enabling one app for a tweak that is listed for "*": nothing would change.
    case disabledEverywhere(tweakID: String, bundleID: String)

    public var errorDescription: String? {
        switch self {
        case let .disabledEverywhere(t, b):
            return "\(t) is disabled in every app, so re-enabling it in \(b) alone changes nothing. Re-enable it everywhere (bundle ID \"*\"), then disable it in the apps where it should stay off."
        }
    }
}

public struct SafeModeSnapshot: Equatable, Sendable {
    public var panic: Bool
    public var settings: SafeModeSettings
    public var disabled: [SafeModeDisabledItem]
    /// Newest first.
    public var recentCrashes: [SafeModeCrash]
}

/// The API Workbench and `dw` use: the key plus state.json, kept consistent.
public final class SafeMode {
    public let keys: SafeModeKeyStore
    public let stateStore: SafeModeStateStore

    public init(keys: SafeModeKeyStore, stateStore: SafeModeStateStore) {
        self.keys = keys
        self.stateStore = stateStore
    }

    /// The real key in the global domain and the real state directory.
    public static func live() -> SafeMode {
        SafeMode(keys: SafeModeKeyStore(store: CFPreferencesTweakBackend(), names: .production),
                 stateStore: SafeModeStateStore())
    }

    /// A preferences domain other than the global one (tests: SafeModeNames.testDomain).
    public static func inDomain(_ domain: String, stateDirectory: URL) -> SafeMode {
        SafeMode(keys: SafeModeKeyStore(store: CFPreferencesTweakBackend(domain: domain as CFString), names: .forDomain(domain)),
                 stateStore: SafeModeStateStore(directory: stateDirectory))
    }

    public var isPanicOn: Bool { keys.isPanicOn }

    public func settings() -> SafeModeSettings { stateStore.load().settings }

    public func updateSettings(_ body: (inout SafeModeSettings) -> Void) throws {
        try stateStore.update { body(&$0.settings) }
    }

    /// Disables `tweakID` in `bundleID` ("*": every app) by hand.
    public func disable(tweakID: String, bundleID: String, reason: SafeModeReason = .manual, reportPath: String? = nil,
                        now: Date = Date()) throws {
        try stateStore.update { state in
            try keys.add(tweakID: tweakID, bundleID: bundleID)
            state.setDisabled(.init(tweakID: tweakID, bundleID: bundleID, since: now, reason: reason, reportPath: reportPath))
        }
    }

    /// Re-enables `tweakID` in `bundleID` ("*": every app it is disabled in). Crashes before `now` no longer
    /// count for that pair. Returns what still keeps the tweak out of that app, if anything (empty: it loads at
    /// the app's next launch). Throws `SafeModeError.disabledEverywhere`, changing nothing, when the tweak is
    /// listed for "*" and `bundleID` names one app.
    @discardableResult
    public func enable(tweakID: String, bundleID: String, now: Date = Date()) throws -> [SafeModeStillOff] {
        try stateStore.update { state in
            let removed = try keys.remove(tweakID: tweakID, bundleID: bundleID)
            let still = stillOff(tweakID: tweakID, bundleID: bundleID)
            if !removed && still.contains(.everyApp) {
                throw SafeModeError.disabledEverywhere(tweakID: tweakID, bundleID: bundleID)
            }
            state.disabled.removeAll { $0.tweakID == tweakID && (bundleID == SafeModeNames.all || $0.bundleID == bundleID) }
            state.recordReenable(tweakID: tweakID, bundleID: bundleID, at: now)
            return still
        }
    }

    /// What keeps `tweakID` out of `bundleID` apart from its own entry for that app.
    public func stillOff(tweakID: String, bundleID: String) -> [SafeModeStillOff] {
        Self.stillOff(tweakID: tweakID, bundleID: bundleID, entries: keys.entries())
    }

    static func stillOff(tweakID: String, bundleID: String, entries: [String: [String]]) -> [SafeModeStillOff] {
        let all = SafeModeNames.all
        var r: [SafeModeStillOff] = []
        if tweakID != all, bundleID != all, entries[tweakID]?.contains(all) == true { r.append(.everyApp) }
        if tweakID != all, bundleID != all, entries[all]?.contains(bundleID) == true { r.append(.allTweaksInApp) }
        if entries[all]?.contains(all) == true { r.append(.panic) }
        return r
    }

    /// The panic switch: "*" = ["*"], which every DynjectHook tweak honours in every app. Written under the state
    /// lock like every other change to the key, so it never races the watcher's read-modify-write.
    public func setPanic(_ on: Bool, now: Date = Date()) throws {
        try stateStore.update { state in
            let was = keys.isPanicOn
            try keys.setPanic(on)
            if on {
                if !was { state.panicSince = now }
            } else {
                state.panicSince = nil
            }
        }
    }

    /// Re-enables everything and turns panic off; earlier crashes never count again.
    public func clear(now: Date = Date()) throws {
        try stateStore.update { state in
            try keys.removeAll()
            state.disabled = []
            state.panicSince = nil
            state.recordReenable(tweakID: SafeModeNames.all, bundleID: SafeModeNames.all, at: now)
        }
    }

    /// Brings state.json in line with entries removed from the key outside Safe Mode (`defaults delete`, a hand
    /// edit): their records go, and each counts as a re-enable as of when it was disabled, so the crashes that led
    /// to it never count again. Call inside `stateStore.update`.
    public func reconcile(_ state: inout SafeModeState) {
        let all = SafeModeNames.all
        let entries = keys.entries()
        func listed(_ e: SafeModeDisabledEntry) -> Bool {
            guard let ids = entries[e.tweakID] else { return false }
            return ids.contains(e.bundleID) || (e.tweakID != all && ids.contains(all))
        }
        for e in state.disabled where !listed(e) {
            let exact = state.reenabled.last { $0.tweakID == e.tweakID && $0.bundleID == e.bundleID }?.date
            if (exact ?? .distantPast) < e.since { state.recordReenable(tweakID: e.tweakID, bundleID: e.bundleID, at: e.since) }
        }
        state.disabled.removeAll { !listed($0) }
        if state.panicSince != nil, entries[all]?.contains(all) != true { state.panicSince = nil }
    }

    /// Everything the Safe Mode panel shows. `catalog` resolves tweak IDs; `support` checks dylibs.
    public func snapshot(catalog: SafeModeCatalog? = nil, support: SafeModeSupportChecker? = .shared) -> SafeModeSnapshot {
        let state = stateStore.load()
        var items: [SafeModeDisabledItem] = []
        let entries = keys.entries()
        for (tweakID, ids) in entries.sorted(by: { $0.key < $1.key }) {
            let tweak = catalog?.tweak(tweakID)
            let level = tweak.flatMap { t in support?.support(dylibAt: t.dylibPath) }
            // ("*", "*") is the panic switch, reported as `panic`; ("*", app) is every tweak off in one app.
            for b in ids where !(tweakID == SafeModeNames.all && b == SafeModeNames.all) {
                let meta = state.disabledEntry(tweakID: tweakID, bundleID: b)
                items.append(.init(tweakID: tweakID, bundleID: b, since: meta?.since, reason: meta?.reason,
                                   reportPath: meta?.reportPath, frameSummary: meta?.frameSummary, tweak: tweak,
                                   support: level, alsoOffBecause: Self.stillOff(tweakID: tweakID, bundleID: b, entries: entries)))
            }
        }
        return SafeModeSnapshot(panic: entries[SafeModeNames.all]?.contains(SafeModeNames.all) ?? false, settings: state.settings, disabled: items,
                                recentCrashes: state.recentCrashes.reversed())
    }
}

// MARK: - User notifications

public protocol SafeModeNotifier: AnyObject {
    func post(title: String, message: String)
}

/// `osascript -e 'display notification ...'`: works from a LaunchAgent without an app bundle.
public final class OsascriptNotifier: SafeModeNotifier {
    public init() {}

    public static func script(title: String, message: String) -> String {
        func q(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "display notification \(q(message)) with title \(q(title))"
    }

    public func post(title: String, message: String) {
        _ = try? ProcessRunner.run("/usr/bin/osascript", ["-e", Self.script(title: title, message: message)])
    }
}

public final class RecordingNotifier: SafeModeNotifier {
    public private(set) var posted: [(title: String, message: String)] = []
    public init() {}
    public func post(title: String, message: String) { posted.append((title, message)) }
}

// MARK: - Scanning the reports directory

public struct SafeModeScanResult: Sendable {
    /// Reports read in this scan (new or changed).
    public var examined: [String] = []
    public var crashes: [SafeModeCrash] = []
    /// Pairs newly written to the key.
    public var disabled: [SafeModeDecision] = []
    /// Unreadable or malformed reports, failed writes.
    public var problems: [String] = []
    /// Reports too new to read safely (still being written); scan again shortly.
    public var pending: Int = 0
    /// Reports whose key write failed; they are evaluated again on a later pass (while still fresh).
    public var retrying: Int = 0
}

/// Processes new crash reports: attribution, rules, key writes, state, notifications. One `scan()` call does
/// one pass; SafeModeWatcher calls it when the directory changes and periodically.
public final class SafeModeScanner {
    public let reportsDirectory: String
    public let safeMode: SafeMode
    let catalog: () -> SafeModeCatalog
    let support: SafeModeSupportChecker
    let notifier: SafeModeNotifier?
    /// Source lines and hook names for crashes in tweaks (CrashSymbolicator); nil leaves frames as the report has them.
    public var symbolicator: CrashSymbolicating?
    let now: () -> Date
    let log: (String) -> Void
    /// Files modified more recently than this are left for a later scan (the reporter may still be writing).
    public var settleTime: TimeInterval = 2
    /// A report whose body isn't JSON yet is retried until it is this old, then recorded as malformed.
    public var malformedGrace: TimeInterval = 60

    public static var defaultReportsDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/DiagnosticReports")
    }

    public init(reportsDirectory: String = SafeModeScanner.defaultReportsDirectory, safeMode: SafeMode,
                catalog: @escaping () -> SafeModeCatalog, support: SafeModeSupportChecker = .shared,
                notifier: SafeModeNotifier? = nil, now: @escaping () -> Date = Date.init,
                log: @escaping (String) -> Void = { _ in }) {
        self.reportsDirectory = reportsDirectory
        self.safeMode = safeMode
        self.catalog = catalog
        self.support = support
        self.notifier = notifier
        self.now = now
        self.log = log
    }

    struct Candidate { var name: String; var path: String; var size: Int64; var mtime: Date }

    func listReports() -> [Candidate]? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: reportsDirectory) else { return nil }
        return names.filter { $0.hasSuffix(".ips") }.compactMap { name in
            let path = (reportsDirectory as NSString).appendingPathComponent(name)
            guard let a = try? fm.attributesOfItem(atPath: path), (a[.type] as? FileAttributeType) == .typeRegular,
                  let size = (a[.size] as? NSNumber)?.int64Value, let mtime = a[.modificationDate] as? Date else { return nil }
            return Candidate(name: name, path: path, size: size, mtime: mtime)
        }.sorted { ($0.mtime, $0.name) < ($1.mtime, $1.name) }
    }

    @discardableResult
    public func scan() -> SafeModeScanResult {
        var result = SafeModeScanResult()
        guard let reports = listReports() else {
            result.problems.append("Can't read \(reportsDirectory).")
            return result
        }
        let now = now()
        var catalog: SafeModeCatalog?
        do {
            try safeMode.stateStore.updateCommitting { state, commit in
                safeMode.reconcile(&state)
                let present = Set(reports.map(\.name))
                state.processedReports = state.processedReports.filter { present.contains($0.key) }
                for r in reports {
                    let mtime = r.mtime.timeIntervalSince1970
                    if let p = state.processedReports[r.name], p.matches(size: r.size, mtime: mtime) { continue }
                    switch process(r, state: &state, now: now, catalog: &catalog, result: &result) {
                    case .later:
                        result.pending += 1
                    case .retry:
                        result.retrying += 1
                    case let .done(incident, wroteKey):
                        result.examined.append(r.name)
                        state.processedReports[r.name] = .init(size: r.size, mtime: mtime, incidentID: incident)
                        // The key now lists something state.json doesn't explain yet: save at once rather than
                        // after the rest of the pass, so being stopped mid-pass can't lose why.
                        if wroteKey { try commit(state) }
                    }
                }
            }
        } catch {
            result.problems.append("Could not update Safe Mode state: \(error.localizedDescription)")
        }
        for p in result.problems { log("problem: \(p)") }
        if let notifier, !result.disabled.isEmpty, safeMode.settings().notify {
            for d in result.disabled { notifier.post(title: Self.notificationTitle(d), message: Self.notificationMessage(d, support: support)) }
        }
        return result
    }

    enum Outcome { case later, retry, done(incidentID: String?, wroteKey: Bool) }

    func process(_ r: Candidate, state: inout SafeModeState, now: Date, catalog: inout SafeModeCatalog?,
                 result: inout SafeModeScanResult) -> Outcome {
        // A modification time in the future (the clock was moved back, files restored with their dates) counts as
        // settled: waiting for it would never end.
        let age = now.timeIntervalSince(r.mtime)
        let young = { (limit: TimeInterval) in age >= 0 && age < limit }
        if young(settleTime) { return .later }
        let report: CrashReport
        do {
            // Header first: most reports aren't crashes, and their bodies needn't be parsed.
            let header = try CrashReportParser.parse(fileAt: r.path, headerOnly: true)
            guard header.isCrash else { return .done(incidentID: header.incidentID, wroteKey: false) }
            report = try CrashReportParser.parse(fileAt: r.path)
            guard report.hasBody else { throw CrashReportError.malformed("\(r.name): the report body is not JSON.") }
        } catch {
            if young(malformedGrace) { return .later }
            result.problems.append(error.localizedDescription)
            return .done(incidentID: nil, wroteKey: false)
        }
        if catalog == nil { catalog = self.catalog() }
        let attribution = CrashAttributor.attribute(report, catalog: catalog!, depth: state.settings.inTweakDepth,
                                                    symbolicator: symbolicator)
        let keys = safeMode.keys, support = support
        let entries = keys.entries()
        let crashDate = report.date ?? r.mtime
        let before = state
        let evaluation = SafeModeRules.evaluate(report, attribution: attribution, state: &state, now: now,
                                                fallbackDate: r.mtime) { tweak, bundleID in
            // Loaded but not running when the app crashed: the key already kept it out at that time.
            guard tweak.hasManifest, let level = support.support(dylibAt: tweak.dylibPath) else { return false }
            return SafeModeRules.wasSuppressed(tweakID: tweak.tweakID, bundleID: bundleID, at: crashDate,
                                               entries: entries, state: before, support: level)
        }
        var written: [SafeModeDecision] = []
        var failed = false
        for d in evaluation.decisions {
            do {
                if try keys.add(tweakID: d.tweak.tweakID, bundleID: d.bundleID) {
                    written.append(d)
                } else if keys.entries()[d.tweak.tweakID]?.contains(d.bundleID) == true,
                          state.disabledEntry(tweakID: d.tweak.tweakID, bundleID: d.bundleID) == nil {
                    // Listed, but state.json doesn't know why: an earlier pass wrote the key and was stopped
                    // before saving. Record it (and notify) now.
                    written.append(d)
                }
            } catch {
                failed = true
                result.problems.append("Could not disable \(d.tweak.tweakID) in \(d.bundleID): \(error.localizedDescription)")
            }
        }
        if failed {
            // Evaluate the report again on a later pass (a crash in the tweak must still disable it): forget its
            // crash records, which would otherwise make it a duplicate, but keep what did reach the key.
            state = before
        }
        for d in written {
            state.setDisabled(.init(tweakID: d.tweak.tweakID, bundleID: d.bundleID, since: now, reason: d.reason,
                                    reportPath: d.reportPath, frameSummary: d.frameSummary))
            result.disabled.append(d)
            log("disabled \(d.tweak.tweakID) in \(d.bundleID): \(d.reason.rawValue) [\(r.name)]")
        }
        if failed { return .retry }
        result.crashes += evaluation.crashes
        for c in evaluation.crashes {
            log("crash: \(c.appName ?? "?") (\(c.bundleID ?? "no bundle ID")) with \(c.tweakID) loaded"
                + (c.inTweak ? ", in the tweak" : "") + ": \(c.frameSummary) [\(r.name)]")
        }
        return .done(incidentID: report.incidentID, wroteKey: !written.isEmpty)
    }

    public static func notificationTitle(_ d: SafeModeDecision) -> String {
        "Safe Mode: \(d.tweak.name) disabled in \(d.appName ?? d.bundleID)"
    }

    public static func notificationMessage(_ d: SafeModeDecision, support: SafeModeSupportChecker) -> String {
        let why = d.reason == .crashInTweak ? "It crashed the app (\(d.frameSummary))."
            : "The app crashed \(d.crashCount) times with it loaded."
        if support.supportsSafeMode(dylibAt: d.tweak.dylibPath) == false {
            return "\(why) This tweak ignores Safe Mode: disable it in the config from Dynject Workbench > Safe Mode."
        }
        return "\(why) Relaunch the app. Re-enable it in Dynject Workbench > Safe Mode."
    }
}

// MARK: - Watching

/// Runs `scanner.scan()` when the reports directory changes (DispatchSource on the directory), after new
/// reports settle, and every `rescanInterval` seconds.
public final class SafeModeWatcher {
    public let scanner: SafeModeScanner
    public let queue: DispatchQueue
    public var rescanInterval: TimeInterval
    public var debounce: TimeInterval
    public var onScan: ((SafeModeScanResult) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var scheduled = false

    public init(scanner: SafeModeScanner, rescanInterval: TimeInterval = 60, debounce: TimeInterval = 1,
                queue: DispatchQueue = DispatchQueue(label: "local.dynject.safemode.watcher")) {
        self.scanner = scanner
        self.rescanInterval = rescanInterval
        self.debounce = debounce
        self.queue = queue
    }

    public func start() {
        queue.async { [self] in
            openSource()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + rescanInterval, repeating: rescanInterval)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                if self.source == nil { self.openSource() }
                self.runScan()
            }
            t.resume()
            timer = t
            runScan()
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            source?.cancel()
            source = nil
        }
    }

    private func openSource() {
        let fd = open(scanner.reportsDirectory, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
        s.setEventHandler { [weak self, weak s] in
            guard let self, let s else { return }
            if !s.data.intersection([.delete, .rename]).isEmpty {
                // The directory itself went away or moved: reopen on the next timer tick.
                s.cancel()
                self.source = nil
                return
            }
            self.schedule(after: self.debounce)
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    private func schedule(after delay: TimeInterval) {
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.runScan()
        }
    }

    private func runScan() {
        let r = scanner.scan()
        onScan?(r)
        if r.pending > 0 { schedule(after: max(scanner.settleTime, 1) + 0.5) }
    }
}
