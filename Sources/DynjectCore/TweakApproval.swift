import CryptoKit
import Foundation

// Install approval (docs/install-approval.md): `dylib-sha256:<path>:<hex>` lines that approve the exact bytes of a
// dylib. An approval-aware dynjectd checks them (logging in audit mode, skipping in enforce mode); the stock one
// ignores the key. Installs write the approval in the same privileged step as the file; `dw tweak approve` writes it
// for dylibs already installed.

public enum DylibDigest {
    /// Lower-case hex SHA-256, as `shasum -a 256` prints it.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The digest of the file at `path`, or nil when it can't be read.
    public static func sha256Hex(ofFileAt path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return sha256Hex(data)
    }
}

public extension ConfigEditor {
    /// The document with exactly one `dylib-sha256` line for `path`, right after its `dylib:` line (at the end when
    /// the config doesn't declare it). Unchanged when that line is already there.
    static func setApproval(_ path: String, sha256: String, in original: ConfigDocument) -> ConfigDocument {
        let hex = sha256.lowercased()
        let wanted = "dylib-sha256:\(path):\(hex)"
        let kinds = original.kinds
        let existing = kinds.indices.filter { if case let .approval(p, _) = kinds[$0] { return p == path } else { return false } }
        if existing.count == 1, original.lines[existing[0]].text == wanted { return original }
        var doc = original
        for i in existing.reversed() { doc.removeLine(at: i) }
        let declared = doc.kinds.firstIndex { if case let .dylib(p, _) = $0 { return p == path } else { return false } }
        doc.insertLine(wanted, at: declared.map { $0 + 1 } ?? doc.lines.count)
        return doc
    }
}

/// What an approval-aware dynjectd says about approvals in its log ("approval: audit; 2 of 6 dylib(s) ..."), from
/// its latest start. nil: the running daemon doesn't check approvals (stock), or the log doesn't say.
public enum DaemonApprovalMode: String, Sendable {
    case audit, enforce

    public static func latest(in logText: String) -> DaemonApprovalMode? {
        var mode: DaemonApprovalMode?
        for line in logText.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasSuffix("dynjectd: starting") { mode = nil }
            guard let r = line.range(of: "dynjectd: approval: ") else { continue }
            let rest = line[r.upperBound...]
            if rest.hasPrefix("enforce") { mode = .enforce } else if rest.hasPrefix("audit") { mode = .audit }
        }
        return mode
    }
}

/// `dw tweak approve`: approval lines for dylibs that are already installed, written in one privileged step.
public struct TweakApprovalPlan: Sendable {
    public struct Entry: Equatable, Sendable {
        public var path: String
        public var sha256: String
        /// The approval the config had for it (nil: none).
        public var previous: String?
        public var changes: Bool { previous != sha256 }
    }

    public var locations: TweakLocations
    public var entries: [Entry]
    /// Dylibs asked for that couldn't be approved, with why.
    public var skipped: [(path: String, why: String)]
    public var configOriginal: Data
    /// nil: every approval is already in place.
    public var configNew: String?
    public var configLines: [LineDiff.Op]

    public var changesNothing: Bool { configNew == nil }

    /// `dylibs`: config paths to approve; nil for every dylib the config declares.
    public static func plan(dylibs: [String]?, locations: TweakLocations) throws -> TweakApprovalPlan {
        guard let data = FileManager.default.contents(atPath: locations.configPath) else {
            throw TweakInstallError.refused("Can't read \(locations.configPath).")
        }
        let original = ConfigDocument(text: String(decoding: data, as: UTF8.self))
        let config = EffectiveConfig(document: original)
        var doc = original
        var entries: [Entry] = []
        var skipped: [(path: String, why: String)] = []
        for path in dylibs ?? config.dylibPaths {
            guard config.dylib(path: path) != nil else {
                skipped.append((path, "the config doesn't declare it"))
                continue
            }
            let file = locations.filePath(forDylib: path)
            var st = stat()
            guard lstat(file, &st) == 0 else { skipped.append((path, "no file at \(file)")); continue }
            guard (st.st_mode & S_IFMT) == S_IFREG else {
                skipped.append((path, "\(file) is not a regular file (dynjectd refuses symbolic links)"))
                continue
            }
            guard let hex = DylibDigest.sha256Hex(ofFileAt: file) else { skipped.append((path, "can't read \(file)")); continue }
            entries.append(Entry(path: path, sha256: hex, previous: config.approvals[path]))
            doc = ConfigEditor.setApproval(path, sha256: hex, in: doc)
        }
        let new = doc.text == original.text ? nil : doc.text
        return TweakApprovalPlan(locations: locations, entries: entries, skipped: skipped, configOriginal: data,
                                 configNew: new, configLines: new.map { LineDiff.diff(original.text, $0) } ?? [])
    }

    /// One line per dylib, for `dw`.
    public var summaryLines: [String] {
        entries.map { e in
            let name = (e.path as NSString).lastPathComponent
            let short = String(e.sha256.prefix(16))
            switch e.previous {
            case nil: return "\(name): approve sha256 \(short)…"
            case e.sha256?: return "\(name): already approved (\(short)…)"
            case let old?: return "\(name): replace approval \(old.prefix(16))… with \(short)… (the file changed since it was approved)"
            }
        } + skipped.map { "\(($0.path as NSString).lastPathComponent): skipped, \($0.why)" }
    }

    /// Writes the config (one administrator prompt at most) and restarts dynjectd so it reads the approvals.
    public func execute(writer: ProtectedFileWriter, restarter: DaemonRestarter) throws -> BatchOutcome? {
        guard let configNew else { return nil }
        let change = ProtectedChange.write(Data(configNew.utf8), to: locations.configPath, expectedCurrent: configOriginal,
                                           category: "config")
        return try writer.apply([change], restartWith: restarter)
    }
}
