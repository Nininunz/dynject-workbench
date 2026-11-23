import Foundation

// Naming where a tweak crashed: the function, its source line, and the hook that was running.
//
// - Builds made with -g leave a dSYM next to the dylib (clang runs dsymutil when it compiles and links in one step).
//   `TweakSymbolStore.keep` copies it at install time into ~/Library/Application Support/Dynject Workbench/Symbols,
//   one bundle per build, with a link per architecture's UUID. The crash reporter can't find it next to the installed
//   dylib, so reports usually carry the function name (from the symbol table) but no line; `CrashSymbolicator` asks
//   `atos` for the line with the stored dSYM whose UUID the report names.
// - A crash report names the replacement function a tweak crashed in (`-[NPScreenHook _notchFrame]`), not the method
//   it replaces. DynjectHook logs a "dynject.hooks:map" line for every hook it makes (TweakSDK/DynjectHook.m,
//   DHLogHookMap); `CrashSymbolicator` reads them back from the crashed process's log and matches them to the start
//   of each function on the stack.

// MARK: - Keeping symbols

public struct TweakSymbolStore: Sendable {
    public var directory: URL

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dynject Workbench/Symbols", isDirectory: true)
    }

    /// Builds kept per dylib file name; older ones are removed.
    public static let buildsKept = 10

    public init(directory: URL = TweakSymbolStore.defaultDirectory) { self.directory = directory }

    public enum KeepResult: Equatable, Sendable {
        /// Kept (or already there): the build's UUIDs.
        case kept([String])
        /// No `<dylib>.dSYM` next to it: built without -g.
        case noDSYM
        /// A dSYM is there but from another build (stale).
        case mismatch
        case failed(String)
    }

    /// Copies the dSYM of the dylib at `dylibPath` (`<dylibPath>.dSYM`) into the store.
    @discardableResult
    public func keep(dylibAt dylibPath: String) -> KeepResult {
        let fm = FileManager.default
        let dsym = dylibPath + ".dSYM"
        let name = (dylibPath as NSString).lastPathComponent
        guard fm.fileExists(atPath: dsym) else { return .noDSYM }
        guard let dylib = fm.contents(atPath: dylibPath).flatMap(MachOInfo.inspect) else { return .failed("can't read \(dylibPath)") }
        let wanted = Set(dylib.uuids.values)
        guard !wanted.isEmpty else { return .failed("\(name) has no LC_UUID") }
        let dwarf = (dsym as NSString).appendingPathComponent("Contents/Resources/DWARF/\(name)")
        guard let have = fm.contents(atPath: dwarf).flatMap(MachOInfo.inspect), Set(have.uuids.values) == wanted else {
            return .mismatch
        }
        let uuids = wanted.sorted()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let bundle = directory.appendingPathComponent("\(name)-\(uuids[0].prefix(8)).dSYM")
            if !fm.fileExists(atPath: bundle.path) {
                let partial = directory.appendingPathComponent(".\(bundle.lastPathComponent).\(getpid())")
                try? fm.removeItem(at: partial)
                try fm.copyItem(atPath: dsym, toPath: partial.path)
                try fm.moveItem(at: partial, to: bundle)
            }
            for uuid in uuids {
                let link = directory.appendingPathComponent("\(uuid).dSYM")
                try? fm.removeItem(at: link)
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: bundle.lastPathComponent)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
        prune(name: name)
        return .kept(uuids)
    }

    /// The stored dSYM bundle for a build, by any of its UUIDs.
    public func dsym(uuid: String) -> String? {
        let link = directory.appendingPathComponent("\(uuid.uppercased()).dSYM").path
        let target = (link as NSString).resolvingSymlinksInPath
        return FileManager.default.fileExists(atPath: target) ? target : nil
    }

    /// Keeps the newest `buildsKept` bundles of one dylib, and drops links that lead nowhere.
    func prune(name: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: []) else { return }
        let mine = entries.filter { $0.lastPathComponent.hasPrefix(name + "-") && $0.pathExtension == "dSYM" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        for old in mine.dropFirst(Self.buildsKept) { try? fm.removeItem(at: old) }
        for e in entries where (try? fm.destinationOfSymbolicLink(atPath: e.path)) != nil {
            if !fm.fileExists(atPath: (e.path as NSString).resolvingSymlinksInPath) { try? fm.removeItem(at: e) }
        }
    }
}

// MARK: - Hook map

/// One "dynject.hooks:map" line: the replacement at `offset` in `image` stands for `target`.
public struct CrashHookMapEntry: Equatable, Sendable {
    public var image: String
    public var offset: UInt64
    /// "-[NSScreen _notchFrame]", "+[Foo bar]" or "import getenv".
    public var target: String

    public init(image: String, offset: UInt64, target: String) {
        self.image = image
        self.offset = offset
        self.target = target
    }

    public static let marker = "dynject.hooks:map "

    /// Parses a log message; nil for other lines.
    public static func parse(_ message: String) -> CrashHookMapEntry? {
        guard let r = message.range(of: marker) else { return nil }
        let parts = message[r.upperBound...].split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[1].hasPrefix("0x"), let offset = UInt64(parts[1].dropFirst(2), radix: 16) else { return nil }
        return .init(image: parts[0], offset: offset, target: parts[2])
    }
}

// MARK: - Symbolicating

/// Adds source lines and hook targets to a report's frames in tweak images. Injected into `CrashAttributor` so
/// tests can do without atos and the log.
public protocol CrashSymbolicating: Sendable {
    /// Source file and line for frames of `imageIndex` that lack them, keyed by image offset.
    func lines(_ report: CrashReport, imageIndex: Int, offsets: [UInt64]) -> [UInt64: (file: String, line: Int)]
    /// The hook map lines the crashed process logged.
    func hookMap(_ report: CrashReport) -> [CrashHookMapEntry]
}

public struct CrashSymbolicator: CrashSymbolicating {
    public var store: TweakSymbolStore
    /// How long after launch the hook map is looked for: nearly every hook is made at launch, and reading a long-lived
    /// process's whole log would be slow.
    public var hookWindow: TimeInterval = 10 * 60

    public init(store: TweakSymbolStore = TweakSymbolStore()) { self.store = store }

    public func lines(_ report: CrashReport, imageIndex: Int, offsets: [UInt64]) -> [UInt64: (file: String, line: Int)] {
        guard let image = report.image(at: imageIndex), let uuid = image.uuid, let dsym = store.dsym(uuid: uuid),
              let name = image.fileName, !offsets.isEmpty else { return [:] }
        let dwarf = (dsym as NSString).appendingPathComponent("Contents/Resources/DWARF/\(name)")
        // Offsets from a load address of 0: a dylib's __TEXT starts at 0, so addresses are image offsets.
        var args = ["-o", dwarf, "-l", "0x0"]
        if let arch = image.arch { args += ["-arch", arch] }
        args += offsets.map { String(format: "0x%llx", $0) }
        guard let out = try? ProcessRunner.run("/usr/bin/atos", args), out.status == 0 else { return [:] }
        var result: [UInt64: (String, Int)] = [:]
        for (offset, line) in zip(offsets, out.stdout.split(separator: "\n", omittingEmptySubsequences: false)) {
            if let loc = Self.sourceLocation(String(line)) { result[offset] = loc }
        }
        return result
    }

    /// "-[Foo bar] (in libX.dylib) (Foo.m:42)" → ("Foo.m", 42).
    static func sourceLocation(_ atosLine: String) -> (String, Int)? {
        guard atosLine.hasSuffix(")"), let open = atosLine.range(of: " (", options: .backwards) else { return nil }
        let inner = atosLine[open.upperBound..<atosLine.index(before: atosLine.endIndex)]
        guard let colon = inner.lastIndex(of: ":"), let line = Int(inner[inner.index(after: colon)...]),
              !inner.hasPrefix("in ") else { return nil }
        return (String(inner[..<colon]), line)
    }

    public func hookMap(_ report: CrashReport) -> [CrashHookMapEntry] {
        guard let pid = report.pid, let launch = report.launchDate else { return [] }
        let end = min(report.date ?? launch.addingTimeInterval(hookWindow), launch.addingTimeInterval(hookWindow))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let predicate = "processID == \(pid) AND subsystem == \"dynject.hooks\" AND category == \"map\""
        guard let out = try? ProcessRunner.run("/usr/bin/log", ["show", "--style", "compact",
                                                                "--start", f.string(from: launch.addingTimeInterval(-1)),
                                                                "--end", f.string(from: end.addingTimeInterval(2)),
                                                                "--predicate", predicate]) else { return [] }
        return out.stdout.split(separator: "\n").compactMap { CrashHookMapEntry.parse(String($0)) }
    }
}
