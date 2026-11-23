import Foundation

/// The parts of a macOS crash report (`.ips`) that Safe Mode needs.
///
/// An `.ips` file is two JSON documents: the first line is a small header (`bug_type`, `incident_id`,
/// `app_name`, `bundleID`, `timestamp`, ...), the rest is the body (`procName`, `bundleInfo`, `captureTime`,
/// `exception`, `faultingThread`, `threads`, `lastExceptionBacktrace`, `usedImages`, ...). Every field is
/// optional here: unknown fields are ignored and missing ones become nil, so newer report versions still parse.
public struct CrashReport: Sendable, Equatable {
    public struct Image: Sendable, Equatable {
        /// As recorded. Paths under /Users are anonymised ("/Users/USER/*/libX.dylib"); /opt paths are intact.
        public var path: String?
        public var name: String?
        public var base: UInt64?
        public var size: UInt64?
        /// The build's LC_UUID, upper case ("20248097-0E2D-…"); a dSYM with the same UUID symbolicates it.
        public var uuid: String?
        /// The slice that was loaded: "arm64e", "arm64", "x86_64".
        public var arch: String?

        public init(path: String?, name: String?, base: UInt64? = nil, size: UInt64? = nil, uuid: String? = nil,
                    arch: String? = nil) {
            self.path = path
            self.name = name
            self.base = base
            self.size = size
            self.uuid = uuid
            self.arch = arch
        }

        /// The image's file name: `name`, or the last path component of `path`.
        public var fileName: String? {
            if let name, !name.isEmpty { return name }
            guard let path, !path.isEmpty else { return nil }
            return (path as NSString).lastPathComponent
        }

        /// True when the crash reporter replaced part of the path ("/Users/USER/*/..."), so only the file
        /// name can be trusted.
        public var isAnonymised: Bool {
            guard let path else { return true }
            return path.contains("*") || path.hasPrefix("/Users/USER/") || path.hasPrefix("/private/var/USER/")
        }
    }

    public struct Frame: Sendable, Equatable {
        public var imageIndex: Int?
        public var imageOffset: UInt64?
        public var symbol: String?
        /// How far into `symbol` the frame is: the function starts at imageOffset - symbolLocation.
        public var symbolLocation: UInt64?
        /// Set when the reporter (or CrashSymbolicator) found the build's debug symbols.
        public var sourceFile: String?
        public var sourceLine: Int?
        /// A function inlined into the next frame's: it shares that frame's address.
        public var isInline: Bool

        public init(imageIndex: Int?, imageOffset: UInt64? = nil, symbol: String? = nil, symbolLocation: UInt64? = nil,
                    sourceFile: String? = nil, sourceLine: Int? = nil, isInline: Bool = false) {
            self.imageIndex = imageIndex
            self.imageOffset = imageOffset
            self.symbol = symbol
            self.symbolLocation = symbolLocation
            self.sourceFile = sourceFile
            self.sourceLine = sourceLine
            self.isInline = isInline
        }

        /// Where the frame's function starts in its image, when the report says (not for inlined functions).
        public var functionOffset: UInt64? {
            guard !isInline, let o = imageOffset, let l = symbolLocation, l <= o else { return nil }
            return o - l
        }
    }

    /// Path of the report file this was read from.
    public var path: String
    public var bugType: String?
    /// Set on simulated crashes (ExcUserFault_* reports): the process did not die.
    public var isSimulated: Bool
    public var incidentID: String?
    public var appName: String?
    public var processName: String?
    public var processPath: String?
    public var pid: Int32?
    /// When the process started (`procLaunch`).
    public var launchDate: Date?
    public var bundleID: String?
    /// `captureTime` from the body, else `timestamp` from the header.
    public var date: Date?
    public var exceptionType: String?
    public var signal: String?
    public var exceptionSubtype: String?
    public var faultingThread: Int?
    /// Frames of the faulting thread, innermost first. Empty when the body has none.
    public var faultingFrames: [Frame]
    /// Where an uncaught Objective-C exception was thrown, innermost first. Empty for other crashes.
    public var lastExceptionBacktrace: [Frame]
    public var images: [Image]
    /// False when only the header could be read (the body is missing or not JSON).
    public var hasBody: Bool

    public static let crashBugType = "309"

    /// A real crash (bug type 309, not simulated). Hangs, spins, resource reports, etc. are not crashes.
    public var isCrash: Bool { bugType == Self.crashBugType && !isSimulated }
    public var displayName: String { appName ?? processName ?? (path as NSString).lastPathComponent }

    public func image(at index: Int?) -> Image? {
        guard let index, index >= 0, index < images.count else { return nil }
        return images[index]
    }

    /// e.g. "EXC_BAD_ACCESS (SIGSEGV)".
    public var exceptionDescription: String? {
        switch (exceptionType, signal) {
        case let (t?, s?): return "\(t) (\(s))"
        case let (t?, nil): return t
        case let (nil, s?): return s
        default: return nil
        }
    }
}

public enum CrashReportError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(p): return "Could not read \(p)."
        case let .malformed(m): return m
        }
    }
}

public enum CrashReportParser {
    /// Parses the header and, when `headerOnly` is false and the body is JSON, the body.
    /// Throws only when not even the header is a JSON object.
    public static func parse(data: Data, path: String, headerOnly: Bool = false) throws -> CrashReport {
        let newline = data.firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
        let headerData = data[data.startIndex..<newline]
        guard let header = (try? JSONSerialization.jsonObject(with: headerData)) as? [String: Any] else {
            throw CrashReportError.malformed("\((path as NSString).lastPathComponent): the first line is not a JSON object.")
        }
        var report = CrashReport(
            path: path,
            bugType: string(header["bug_type"]),
            isSimulated: bool(header["is_simulated"]),
            incidentID: string(header["incident_id"]),
            appName: string(header["app_name"]) ?? string(header["name"]),
            processName: nil, processPath: nil, pid: nil, launchDate: nil,
            bundleID: nonEmpty(header["bundleID"] as? String),
            date: string(header["timestamp"]).flatMap(parseDate),
            exceptionType: nil, signal: nil, exceptionSubtype: nil, faultingThread: nil,
            faultingFrames: [], lastExceptionBacktrace: [], images: [], hasBody: false)
        guard !headerOnly else { return report }

        let bodyData = newline < data.endIndex ? data[data.index(after: newline)...] : Data()
        guard let body = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else { return report }
        report.hasBody = true
        report.processName = string(body["procName"])
        report.processPath = string(body["procPath"])
        report.pid = int(body["pid"]).map(Int32.init(truncatingIfNeeded:))
        report.launchDate = string(body["procLaunch"]).flatMap(parseDate)
        if let info = body["bundleInfo"] as? [String: Any], let id = nonEmpty(info["CFBundleIdentifier"] as? String) {
            report.bundleID = id
        }
        if report.bugType == nil { report.bugType = string(body["bug_type"]) }
        if report.incidentID == nil { report.incidentID = string(body["incident"]) }
        if let d = string(body["captureTime"]).flatMap(parseDate) { report.date = d }
        if let exc = body["exception"] as? [String: Any] {
            report.exceptionType = string(exc["type"])
            report.signal = string(exc["signal"])
            report.exceptionSubtype = string(exc["subtype"])
        }
        report.images = ((body["usedImages"] as? [Any]) ?? []).map { raw in
            let d = raw as? [String: Any] ?? [:]
            return .init(path: nonEmpty(d["path"] as? String), name: nonEmpty(d["name"] as? String),
                         base: uint64(d["base"]), size: uint64(d["size"]),
                         uuid: nonEmpty(d["uuid"] as? String)?.uppercased(), arch: nonEmpty(d["arch"] as? String))
        }
        let threads = (body["threads"] as? [Any]) ?? []
        var faulting = int(body["faultingThread"])
        if faulting == nil {
            faulting = threads.firstIndex { ($0 as? [String: Any]).map { bool($0["triggered"]) } ?? false }
        }
        report.faultingThread = faulting
        if let f = faulting, f >= 0, f < threads.count, let thread = threads[f] as? [String: Any] {
            report.faultingFrames = frames(thread["frames"])
        }
        report.lastExceptionBacktrace = frames(body["lastExceptionBacktrace"])
        return report
    }

    public static func parse(fileAt path: String, headerOnly: Bool = false) throws -> CrashReport {
        guard let data = FileManager.default.contents(atPath: path) else { throw CrashReportError.unreadable(path) }
        return try parse(data: data, path: path, headerOnly: headerOnly)
    }

    static func frames(_ raw: Any?) -> [CrashReport.Frame] {
        ((raw as? [Any]) ?? []).compactMap { f in
            guard let d = f as? [String: Any] else { return nil }
            return .init(imageIndex: int(d["imageIndex"]), imageOffset: uint64(d["imageOffset"]),
                         symbol: nonEmpty(d["symbol"] as? String), symbolLocation: uint64(d["symbolLocation"]),
                         sourceFile: nonEmpty(d["sourceFile"] as? String), sourceLine: int(d["sourceLine"]),
                         isInline: bool(d["inline"]))
        }
    }

    // MARK: Lenient value conversion

    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return nonEmpty(s) }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    static func bool(_ v: Any?) -> Bool {
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return s == "1" || s.lowercased() == "true" }
        return false
    }

    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func uint64(_ v: Any?) -> UInt64? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        if n.doubleValue < 0 { return nil }
        return n.uint64Value
    }

    /// "2026-11-19 06:32:44.9746 -0600" (captureTime) or "2026-11-19 06:32:45.00 -0600" (header timestamp).
    public static func parseDate(_ s: String) -> Date? {
        let parts = s.split(separator: " ")
        guard parts.count == 3 else { return nil }
        let time = parts[1]
        var whole = Substring(time), fraction = 0.0
        if let dot = time.firstIndex(of: ".") {
            whole = time[..<dot]
            fraction = Double("0" + time[dot...]) ?? 0
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.date(from: "\(parts[0]) \(whole) \(parts[2])").map { $0.addingTimeInterval(fraction) }
    }
}
