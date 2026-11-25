import Foundation

// Versions: a tweak's own (semantic), the macOS it runs on, and the DynjectHook SDK compiled into its dylib.

// MARK: - Semantic versions

/// MAJOR.MINOR.PATCH with an optional -prerelease (semver 2.0 precedence; no +build metadata). Manifests'
/// `version` and `depends` (">= 1.2.0") use it.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Dot-separated prerelease identifiers ("beta.2" -> ["beta", "2"]). Empty for a release.
    public var prerelease: [String]

    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// nil unless `string` is exactly MAJOR.MINOR.PATCH[-PRERELEASE]: numbers without leading zeros, prerelease
    /// identifiers of [0-9A-Za-z-], numeric ones without leading zeros.
    public init?(_ string: String) {
        let parts = string.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3 else { return nil }
        var numbers: [Int] = []
        for c in core {
            guard Self.isNumeric(c), let n = Int(c) else { return nil }
            numbers.append(n)
        }
        var pre: [String] = []
        if parts.count == 2 {
            let ids = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            for id in ids {
                guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
                if id.allSatisfy(\.isNumber), !Self.isNumeric(id) { return nil }
                pre.append(String(id))
            }
        }
        self.init(numbers[0], numbers[1], numbers[2], prerelease: pre)
    }

    /// Digits only, no leading zero (except "0" itself).
    static func isNumeric(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } && (s == "0" || s.first != "0")
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: Self, b: Self) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // A prerelease sorts before its release.
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true    // numeric identifiers sort before alphanumeric ones
            case (nil, .some): return false
            case (nil, nil): return x < y      // ASCII order
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

// MARK: - macOS versions

/// A macOS version as manifests write it: "27", "27.0" or "27.2.1". Missing components count as 0 when
/// comparing, so "27" == "27.0" == "27.0.0".
public struct SystemVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// 1 to 3 components, as written.
    public var components: [Int]

    public init(_ components: [Int]) { self.components = components }

    public init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 6, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            out.append(n)
        }
        components = out
    }

    public init(_ v: OperatingSystemVersion) { components = [v.majorVersion, v.minorVersion, v.patchVersion] }

    /// The macOS this process runs on.
    public static var current: SystemVersion { SystemVersion(ProcessInfo.processInfo.operatingSystemVersion) }

    var padded: [Int] { components + Array(repeating: 0, count: max(0, 3 - components.count)) }

    /// The first `count` components (padded), e.g. 27.2.1 truncated to 2 is 27.2.
    func truncated(to count: Int) -> SystemVersion { SystemVersion(Array(padded.prefix(count))) }

    /// "27.2.1", "27.2" (a trailing .0 patch is dropped), "27".
    public var description: String {
        var c = components
        if c.count == 3, c[2] == 0 { c.removeLast() }
        return c.map(String.init).joined(separator: ".")
    }

    public static func == (a: Self, b: Self) -> Bool { a.padded == b.padded }
    public func hash(into h: inout Hasher) { h.combine(padded) }
    public static func < (a: Self, b: Self) -> Bool { a.padded.lexicographicallyPrecedes(b.padded) }
}

/// `testedSystemVersions`: "27.0 - 27.2" or one version ("27.2"). The upper end counts at the precision it is
/// written with, so "27.0 - 27.2" includes 27.2.1 and a single "27.2" means any 27.2.x.
public struct SystemVersionRange: Hashable, Sendable, CustomStringConvertible {
    public var lower: SystemVersion
    public var upper: SystemVersion

    public init(lower: SystemVersion, upper: SystemVersion) {
        self.lower = lower
        self.upper = upper
    }

    /// nil if malformed or the lower end is above the upper end.
    public init?(_ string: String) {
        let ends = string.split(separator: "-", omittingEmptySubsequences: false)
        switch ends.count {
        case 1:
            guard let v = SystemVersion(String(ends[0])) else { return nil }
            self.init(lower: v, upper: v)
        case 2:
            guard let l = SystemVersion(String(ends[0])), let u = SystemVersion(String(ends[1])), l <= u else { return nil }
            self.init(lower: l, upper: u)
        default:
            return nil
        }
    }

    public func contains(_ v: SystemVersion) -> Bool {
        v >= lower && v.truncated(to: upper.components.count) <= upper
    }

    public var description: String { lower == upper && lower.components == upper.components ? "\(lower)" : "\(lower) – \(upper)" }
}

// MARK: - The SDK a dylib was built with

/// Which DynjectHook (SDK) a tweak's dylib was built with: DynjectHook.m embeds "dynject.sdk:<DH_SDK_VERSION>" as a
/// C string of its own (DHSDKVersionMarker), and DH_SDK_VERSION is `WorkbenchInfo.sdkVersion` (a test checks). Builds
/// from before the marker, and tweaks not built on DynjectHook, have none.
public final class SDKVersionChecker: @unchecked Sendable {
    public static let markerPrefix = "dynject.sdk:"

    private struct Stamp: Equatable { var size: UInt64; var mtime: Date }
    private var cache: [String: (Stamp, String?)] = [:]
    private let lock = NSLock()

    public init() {}

    public static let shared = SDKVersionChecker()

    /// The SDK version in `data`, or nil without a marker. With several (two DynjectHook copies linked into one
    /// dylib), the oldest one.
    public static func version(in data: Data) -> String? {
        let prefix = Data(("\0" + markerPrefix).utf8)
        var found: [String] = []
        var start = data.startIndex
        while let r = data.range(of: prefix, in: start..<data.endIndex) {
            let from = r.upperBound
            guard let end = data[from...].firstIndex(of: 0), end - from <= 64 else { start = r.upperBound; continue }
            let s = String(decoding: data[from..<end], as: UTF8.self)
            if !s.isEmpty { found.append(s) }
            start = end
        }
        return found.min { a, b in
            switch (SemanticVersion(a), SemanticVersion(b)) {
            case let (x?, y?): return x < y
            default: return a < b
            }
        }
    }

    /// The SDK version of the dylib at `path`; nil without a marker or when the file can't be read. Cached per
    /// path, size and modification date.
    public func version(dylibAt path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let stamp = Stamp(size: size, mtime: mtime)
        lock.lock()
        if let (s, v) = cache[path], s == stamp { lock.unlock(); return v }
        lock.unlock()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        let v = Self.version(in: data)
        lock.lock()
        cache[path] = (stamp, v)
        lock.unlock()
        return v
    }
}
