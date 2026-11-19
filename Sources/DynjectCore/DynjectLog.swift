import Foundation

/// Facts extracted from dynjectd.log. The log carries only HH:MM:SS timestamps (no date),
/// so times are shown verbatim and never compared with file dates.
public struct DynjectLogSnapshot: Equatable, Sendable {
    public struct DaemonStart: Equatable, Sendable {
        public var time: String
        public var pid: Int32?
        /// e.g. "/opt/.../libX.dylib (deny-all, 1 override(s))"
        public var dylibSummaries: [String]
    }

    public struct ServiceEvent: Equatable, Sendable {
        public var time: String
        public var service: String
        public var executable: String?
        /// "MATCH (1 dylib(s) injected)" or "SKIP (reason)"
        public var outcome: String
        public var isMatch: Bool
    }

    public var starts: [DaemonStart] = []
    public var events: [ServiceEvent] = []
    public var missingDylibWarnings: [String] = []

    public init() {}

    /// Most recent event for each app bundle ID (application.* services) or executable.
    public func lastEvent(bundleID: String, executable: String, service: String) -> ServiceEvent? {
        events.last { event in
            if let b = Self.bundleID(fromService: event.service) { return b == bundleID }
            if event.service == service { return true }
            return event.executable == executable
        }
    }

    public func lastMatch(bundleID: String, executable: String, service: String) -> ServiceEvent? {
        events.last { event in
            guard event.isMatch else { return false }
            if let b = Self.bundleID(fromService: event.service) { return b == bundleID }
            return event.service == service || event.executable == executable
        }
    }

    /// Observed non-LaunchServices service names keyed by executable (e.g. Finder → com.apple.Finder).
    public var observedLaunchdServices: [String: String] {
        var map: [String: String] = [:]
        for e in events where !e.service.hasPrefix("application.") {
            if let exe = e.executable { map[exe] = e.service }
        }
        return map
    }

    /// Bundle IDs seen as "application.<id>.<n>.<n>[.<uuid>]".
    public var observedApplicationBundleIDs: Set<String> {
        Set(events.compactMap { Self.bundleID(fromService: $0.service) })
    }

    /// "application.com.apple.TextEdit.1152921500311909930.1152921500311909935" → "com.apple.TextEdit"
    public static func bundleID(fromService service: String) -> String? {
        guard service.hasPrefix("application.") else { return nil }
        var parts = service.dropFirst("application.".count).split(separator: ".", omittingEmptySubsequences: false)
        while let last = parts.last, parts.count > 1, isInstanceComponent(last) {
            parts.removeLast()
        }
        let id = parts.joined(separator: ".")
        return id.isEmpty ? nil : id
    }

    private static func isInstanceComponent(_ s: Substring) -> Bool {
        if !s.isEmpty, s.allSatisfy(\.isNumber) { return true }
        // UUID: 8-4-4-4-12 hex
        let groups = s.split(separator: "-")
        return groups.count == 5 && groups.map(\.count) == [8, 4, 4, 4, 12]
            && s.allSatisfy { $0 == "-" || $0.isHexDigit }
    }
}

public enum DynjectLogParser {
    // [dynjectd 02:05:12] dynjectd: com.apple.Finder(Finder) MATCH (1 dylib(s) injected)
    private static let linePattern = try! NSRegularExpression(
        pattern: #"^\[(\S+) (\d{2}:\d{2}:\d{2})\] (\S+): (.*)$"#)
    private static let matchPattern = try! NSRegularExpression(
        pattern: #"^(\S+?)\(([^()]*)\) (MATCH \(.*\))$"#)
    private static let skipPattern = try! NSRegularExpression(pattern: #"^(\S+) (SKIP \((.*)\))$"#)
    private static let pidPattern = try! NSRegularExpression(pattern: #"running \(pid=(\d+)\)"#)

    public static func parse(_ text: String) -> DynjectLogSnapshot {
        var snap = DynjectLogSnapshot()
        var pendingStart: DynjectLogSnapshot.DaemonStart?

        func flush() {
            if let s = pendingStart { snap.starts.append(s) }
            pendingStart = nil
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let m = linePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let timeR = Range(m.range(at: 2), in: line),
                  let msgR = Range(m.range(at: 4), in: line) else { continue }
            let time = String(line[timeR])
            let message = String(line[msgR])
            let ns = NSRange(message.startIndex..., in: message)

            if message == "starting" {
                flush()
                pendingStart = .init(time: time, pid: nil, dylibSummaries: [])
            } else if message.hasPrefix("dylib["), let close = message.firstIndex(of: "]") {
                let summary = message[message.index(after: close)...].trimmingCharacters(in: .whitespaces)
                pendingStart?.dylibSummaries.append(summary)
            } else if message.hasPrefix("done dynjectd running"),
                      let pm = pidPattern.firstMatch(in: message, range: ns),
                      let r = Range(pm.range(at: 1), in: message) {
                if pendingStart != nil {
                    pendingStart?.pid = Int32(message[r])
                    flush()
                } else if var last = snap.starts.popLast() {
                    last.pid = Int32(message[r])
                    snap.starts.append(last)
                }
            } else if message.hasPrefix("SKIP dylib[") {
                snap.missingDylibWarnings.append(message)
            } else if let mm = matchPattern.firstMatch(in: message, range: ns),
                      let s = Range(mm.range(at: 1), in: message),
                      let e = Range(mm.range(at: 2), in: message),
                      let o = Range(mm.range(at: 3), in: message) {
                snap.events.append(.init(time: time, service: String(message[s]),
                                         executable: String(message[e]), outcome: String(message[o]), isMatch: true))
            } else if let sm = skipPattern.firstMatch(in: message, range: ns),
                      let s = Range(sm.range(at: 1), in: message),
                      let o = Range(sm.range(at: 2), in: message) {
                var service = String(message[s])
                var exe: String?
                // "<service>(<exe>)" never appears with SKIP today, but tolerate it.
                if let open = service.firstIndex(of: "("), service.hasSuffix(")") {
                    exe = String(service[service.index(after: open)..<service.index(before: service.endIndex)])
                    service = String(service[..<open])
                }
                snap.events.append(.init(time: time, service: service, executable: exe,
                                         outcome: String(message[o]), isMatch: false))
            }
        }
        flush()
        return snap
    }

    /// Reads at most the last `maxBytes` of the log.
    public static func readTail(path: String, maxBytes: Int = 1_000_000) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return text
    }
}

public enum ServiceNameResolver {
    /// launchd labels that appear as the XPC service name instead of "application.<id>".
    /// Keyed by lowercase bundle ID.
    public static let knownLaunchdLabels: [String: String] = [
        "com.apple.finder": "com.apple.Finder",
        "com.apple.dock": "com.apple.Dock.agent",
    ]

    public static func resolve(_ app: InstalledApp, log: DynjectLogSnapshot?) -> ServiceName {
        if let log {
            if log.observedApplicationBundleIDs.contains(app.bundleID),
               let e = log.events.last(where: { DynjectLogSnapshot.bundleID(fromService: $0.service) == app.bundleID }) {
                return ServiceName(e.service, source: .observed)
            }
            if knownLaunchdLabels[app.bundleID.lowercased()] != nil || app.bundlePath.hasPrefix("/System/Library/CoreServices/"),
               let s = log.observedLaunchdServices[app.executableName] {
                return ServiceName(s, source: .observed)
            }
        }
        if let label = knownLaunchdLabels[app.bundleID.lowercased()] {
            return ServiceName(label, source: .launchdLabel)
        }
        return ServiceName("application.\(app.bundleID).0.0", source: .predicted)
    }
}
