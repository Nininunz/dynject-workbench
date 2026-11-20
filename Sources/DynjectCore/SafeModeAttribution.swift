import Foundation

// MARK: - Which tweaks exist

/// An installed tweak as Safe Mode sees it: a manifest's identifier and dylib, or an unmanifested dylib in the
/// tweaks directory (tweakID "dylib:<file name>").
public struct SafeModeTweak: Hashable, Sendable, Identifiable {
    public var id: String { tweakID }
    public var tweakID: String
    public var name: String
    /// Installed dylib path (the manifest's "dylib", or the file in the tweaks directory).
    public var dylibPath: String
    public var hasManifest: Bool

    public init(tweakID: String, name: String, dylibPath: String, hasManifest: Bool) {
        self.tweakID = tweakID
        self.name = name
        self.dylibPath = dylibPath
        self.hasManifest = hasManifest
    }

    public static let unmanifestedPrefix = "dylib:"

    public static func unmanifestedID(fileName: String) -> String { unmanifestedPrefix + fileName }

    public static func isUnmanifestedID(_ id: String) -> Bool { id.hasPrefix(unmanifestedPrefix) }

    /// Only tweaks with a manifest have a tweak ID that DynjectHook's DHShouldLoad can be told about.
    public var canUseSafeModeKey: Bool { hasManifest }

    public var fileName: String { (dylibPath as NSString).lastPathComponent }
}

/// The tweaks Safe Mode can attribute crashes to.
public struct SafeModeCatalog: Sendable {
    public static let defaultDylibDirectory = "/opt/dynject/lib/tweaks"

    public var tweaks: [SafeModeTweak]
    public var dylibDirectory: String

    /// Builds the catalog from loaded manifests plus every `.dylib` in `dylibDirectory` that no manifest names.
    /// When several manifests name the same dylib, those whose identifier is compiled into it (as a C string,
    /// e.g. DH_CTOR's tweak ID) win; if none is, all of them are kept.
    public init(manifests: [TweakManifest], dylibDirectory: String = SafeModeCatalog.defaultDylibDirectory,
                listDirectory: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
                readFile: (String) -> Data? = { FileManager.default.contents(atPath: $0) }) {
        self.dylibDirectory = dylibDirectory
        var tweaks: [SafeModeTweak] = []
        let byDylib = Dictionary(grouping: manifests, by: \.dylib)
        for dylib in byDylib.keys.sorted() {
            var group = byDylib[dylib]!
            if group.count > 1, let data = readFile(dylib) {
                let named = group.filter { data.range(of: Data(($0.id + "\0").utf8)) != nil }
                if !named.isEmpty { group = named }
            }
            tweaks += group.map { SafeModeTweak(tweakID: $0.id, name: $0.name, dylibPath: $0.dylib, hasManifest: true) }
        }
        let claimedNames = Set(manifests.map { ($0.dylib as NSString).lastPathComponent })
        let claimedPaths = Set(manifests.map(\.dylib))
        for file in listDirectory(dylibDirectory).sorted() where file.hasSuffix(".dylib") {
            let path = (dylibDirectory as NSString).appendingPathComponent(file)
            guard !claimedPaths.contains(path), !claimedNames.contains(file) else { continue }
            tweaks.append(SafeModeTweak(tweakID: SafeModeTweak.unmanifestedID(fileName: file), name: file,
                                        dylibPath: path, hasManifest: false))
        }
        self.tweaks = tweaks
    }

    public init(tweaks: [SafeModeTweak], dylibDirectory: String = SafeModeCatalog.defaultDylibDirectory) {
        self.tweaks = tweaks
        self.dylibDirectory = dylibDirectory
    }

    public func tweak(_ id: String) -> SafeModeTweak? { tweaks.first { $0.tweakID == id } }

    /// The tweaks a crashed process's image is. Matching is by full path when the report kept it, and by file
    /// name when the reporter anonymised it ("/Users/USER/*/libX.dylib") or omitted it.
    public func tweaks(matching image: CrashReport.Image) -> [SafeModeTweak] {
        guard let fileName = image.fileName else { return [] }
        let named = tweaks.filter { $0.fileName == fileName }
        guard !named.isEmpty, let path = image.path, !image.isAnonymised else { return named }
        // Only same-named candidates need the (file-system touching) canonical comparison.
        let p = Self.canonical(path)
        return named.filter { Self.canonical($0.dylibPath) == p }
    }

    /// Resolves symlinks and the /private prefix so "/tmp/x" and "/private/tmp/x" compare equal.
    static func canonical(_ path: String) -> String {
        var p = (path as NSString).resolvingSymlinksInPath
        if p.hasPrefix("/private/") { p = String(p.dropFirst("/private".count)) }
        return p
    }
}

// MARK: - Does a tweak honour "dynject.safemode"?

/// How much of Safe Mode a tweak's dylib honours.
public enum SafeModeSupport: Int, Comparable, Sendable, CaseIterable {
    /// Not built on DynjectHook: it ignores the key and only the Dynject config can stop it.
    case unsupported
    /// An older DynjectHook: honours its own entry ({tweakID: [bundleID | "*"]}) but not the "*" entry, so the
    /// panic switch and "every tweak in this app" don't stop it.
    case perTweak
    /// The current DynjectHook: honours its own entry and the "*" entry (panic switch).
    case perTweakAndPanic

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// Whether the tweak honours its own entry in the key.
    public var honoursKey: Bool { self >= .perTweak }
    /// Whether the tweak honours the "*" entry (the panic switch, or every tweak in one app).
    public var honoursPanic: Bool { self >= .perTweakAndPanic }
}

/// A tweak supports Safe Mode when DynjectHook is compiled into its dylib: DHShouldLoad reads the
/// "dynject.safemode" key through a CFSTR literal, so the dylib holds that byte string as a C string of its own
/// (NUL before and after; a tweak ID such as "x.dynject.safemode.y" doesn't count). DynjectHook builds that also
/// honour the "*" entry (panic switch) carry a second marker, "dynject.safemode:all-tweaks"; older builds
/// honour only their own entry. Other tweaks (Brutalium, and TitleBadge builds from before its DH_CTOR conversion) ignore the key and can only be
/// stopped through the Dynject config.
public final class SafeModeSupportChecker: @unchecked Sendable {
    public static let marker = Data(("\0" + SafeModeNames.productionKey + "\0").utf8)
    /// DynjectHook's capability string for the "*" entry (DHSafeModeCapabilities in DynjectHook.m).
    public static let panicMarker = Data(("\0" + SafeModeNames.productionKey + ":all-tweaks\0").utf8)

    private struct Stamp: Equatable { var size: UInt64; var mtime: Date }
    private var cache: [String: (Stamp, SafeModeSupport)] = [:]
    private let lock = NSLock()

    public init() {}

    public static func dataSupport(_ data: Data) -> SafeModeSupport {
        guard data.range(of: marker) != nil else { return .unsupported }
        return data.range(of: panicMarker) != nil ? .perTweakAndPanic : .perTweak
    }

    public static func dataSupportsSafeMode(_ data: Data) -> Bool { dataSupport(data).honoursKey }

    /// nil when the file can't be read. Results are cached per path, size and modification date.
    public func support(dylibAt path: String) -> SafeModeSupport? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        let stamp = Stamp(size: size, mtime: mtime)
        lock.lock()
        if let (s, v) = cache[path], s == stamp { lock.unlock(); return v }
        lock.unlock()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        let v = Self.dataSupport(data)
        lock.lock()
        cache[path] = (stamp, v)
        lock.unlock()
        return v
    }

    /// Whether the tweak honours its own entry in the key (any DynjectHook build). nil when unreadable.
    public func supportsSafeMode(dylibAt path: String) -> Bool? { support(dylibAt: path)?.honoursKey }

    /// Whether the tweak also honours the "*" entry (the panic switch). nil when unreadable.
    public func honoursPanic(dylibAt path: String) -> Bool? { support(dylibAt: path)?.honoursPanic }

    public static let shared = SafeModeSupportChecker()
}

// MARK: - Attribution

/// Which tweaks were loaded in a crashed process, and which of them the crash happened in.
public struct CrashAttribution: Sendable, Equatable {
    public struct LoadedTweak: Sendable, Equatable {
        public var tweak: SafeModeTweak
        /// Index into the report's `usedImages`.
        public var imageIndex: Int
        /// A frame of this tweak is among the faulting thread's top frames or the exception backtrace's.
        public var inTweak: Bool
        /// The first such frame, e.g. "libX.dylib: -[Foo bar] + 0x1c0".
        public var frame: String?
    }

    public var loaded: [LoadedTweak]
    /// e.g. "EXC_BAD_ACCESS (SIGSEGV) in libX.dylib: -[Foo bar] + 0x1c0". For crashes outside tweaks, the
    /// first meaningful frame of the faulting thread (or of the exception backtrace).
    public var frameSummary: String

    public var tweakIDs: [String] { loaded.map(\.tweak.tweakID) }
    public var culprits: [SafeModeTweak] { loaded.filter(\.inTweak).map(\.tweak) }
    public var isTweakRelated: Bool { !loaded.isEmpty }
}

public enum CrashAttributor {
    /// Frames that every crash or exception passes through. They are skipped (only while they lead the stack)
    /// before counting the top frames, so an abort() inside libsystem doesn't push the real caller out.
    public static let machineryImages: Set<String> = [
        "libsystem_kernel.dylib", "libsystem_pthread.dylib", "libsystem_c.dylib", "libsystem_platform.dylib",
        "libsystem_malloc.dylib", "libc++abi.dylib", "libobjc.A.dylib", "libdyld.dylib", "libsystem_trace.dylib",
    ]
    public static let machinerySymbols: Set<String> = [
        "__exceptionPreprocess", "objc_exception_throw", "objc_exception_rethrow", "_objc_terminate()",
    ]

    /// Default number of frames (after leading machinery) in which a tweak frame counts as "in the tweak".
    public static let defaultDepth = 6

    public static func attribute(_ report: CrashReport, catalog: SafeModeCatalog,
                                 depth: Int = defaultDepth) -> CrashAttribution {
        var loaded: [CrashAttribution.LoadedTweak] = []
        var seen = Set<String>()
        for (i, image) in report.images.enumerated() {
            // The app's own executable is never a tweak, whatever its name.
            if let p = image.path, let main = report.processPath,
               p == main || (!image.isAnonymised && SafeModeCatalog.canonical(p) == SafeModeCatalog.canonical(main)) { continue }
            for tweak in catalog.tweaks(matching: image) where seen.insert(tweak.tweakID).inserted {
                loaded.append(.init(tweak: tweak, imageIndex: i, inTweak: false, frame: nil))
            }
        }
        let tweakImages = Set(loaded.map(\.imageIndex))
        let faulting = top(report.faultingFrames, report: report, depth: depth)
        let thrown = top(report.lastExceptionBacktrace, report: report, depth: depth)
        // The exception backtrace says where an Objective-C exception was thrown; look there first.
        let candidates = thrown + faulting
        for idx in loaded.indices {
            let i = loaded[idx].imageIndex
            if let f = candidates.first(where: { $0.imageIndex == i }) {
                loaded[idx].inTweak = true
                loaded[idx].frame = describe(f, report: report)
            }
        }
        let tweakFrame = candidates.first { $0.imageIndex.map(tweakImages.contains) ?? false }
        let where_ = (tweakFrame ?? candidates.first).map { describe($0, report: report) }
        let summary = [report.exceptionDescription, where_.map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")
        return CrashAttribution(loaded: loaded, frameSummary: summary.isEmpty ? "crash" : summary)
    }

    /// The first `depth` frames after leading crash/exception machinery.
    static func top(_ frames: [CrashReport.Frame], report: CrashReport, depth: Int) -> [CrashReport.Frame] {
        let rest = frames.drop { f in
            if let s = f.symbol, machinerySymbols.contains(s) { return true }
            guard let name = report.image(at: f.imageIndex)?.fileName else { return false }
            return machineryImages.contains(name)
        }
        return Array(rest.prefix(max(depth, 0)))
    }

    public static func describe(_ f: CrashReport.Frame, report: CrashReport) -> String {
        let image = report.image(at: f.imageIndex)?.fileName ?? "???"
        let offset = f.imageOffset.map { String(format: "0x%llx", $0) }
        switch (f.symbol, offset) {
        case let (s?, _): return "\(image): \(s)"
        case let (nil, o?): return "\(image) + \(o)"
        default: return image
        }
    }
}
