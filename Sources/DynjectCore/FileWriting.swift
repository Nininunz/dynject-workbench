import CryptoKit
import Foundation

public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public enum WriteError: Error, LocalizedError, Equatable {
    case changedOnDisk(String)
    case cancelled
    case helperFailed(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case let .changedOnDisk(p): return "\(p) changed on disk after it was loaded. Reload it, then reapply your edits."
        case .cancelled: return "Administrator authorization was cancelled. Nothing was written."
        case let .helperFailed(m): return m
        case let .io(m): return m
        }
    }
}

// MARK: - Atomic write (unprivileged)

public enum AtomicFile {
    /// True when we can create a sibling temp file and replace `path` without privileges.
    public static func canWriteDirectly(_ path: String) -> Bool {
        let fm = FileManager.default
        let resolved = (path as NSString).resolvingSymlinksInPath
        let dir = (resolved as NSString).deletingLastPathComponent
        guard fm.isWritableFile(atPath: dir) else { return false }
        return !fm.fileExists(atPath: resolved) || fm.isWritableFile(atPath: resolved)
    }

    /// Write to a temp file in the same directory, fsync, keep the old permissions, then rename(2).
    public static func write(_ data: Data, to path: String) throws {
        let resolved = (path as NSString).resolvingSymlinksInPath
        let dir = (resolved as NSString).deletingLastPathComponent
        let name = (resolved as NSString).lastPathComponent
        let tmp = (dir as NSString).appendingPathComponent(".\(name).dw-\(UUID().uuidString)")
        let fm = FileManager.default
        let perms = (try? fm.attributesOfItem(atPath: resolved)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644

        guard fm.createFile(atPath: tmp, contents: nil, attributes: [.posixPermissions: perms]) else {
            throw WriteError.io("Could not create a temporary file in \(dir).")
        }
        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tmp))
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(tmp, resolved) == 0 else {
                throw WriteError.io("rename failed: \(String(cString: strerror(errno)))")
            }
        } catch {
            try? fm.removeItem(atPath: tmp)
            throw error
        }
        guard fm.contents(atPath: resolved) == data else {
            throw WriteError.io("Verification after writing \(resolved) failed.")
        }
    }
}

// MARK: - Backups

public struct BackupStore: Sendable {
    public var root: URL

    public init(root: URL) { self.root = root }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dynject Workbench/Backups", isDirectory: true)
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    /// Copies `data` (the current on-disk bytes of `originalPath`) into the backup folder.
    @discardableResult
    public func backup(_ data: Data, originalPath: String, category: String) throws -> URL {
        let dir = root.appendingPathComponent(category, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let flat = originalPath.split(separator: "/").joined(separator: "_")
        let url = dir.appendingPathComponent("\(Self.stamp.string(from: Date()))--\(flat)")
        try data.write(to: url, options: .withoutOverwriting)
        guard (try? Data(contentsOf: url)) == data else { throw WriteError.io("Backup verification failed: \(url.path)") }
        return url
    }

    public func list(category: String) -> [URL] {
        let dir = root.appendingPathComponent(category, isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

// MARK: - Privileged execution

public protocol PrivilegedExecutor: Sendable {
    /// Runs `HelperScript` with `arguments` as root. Returns stdout.
    func run(_ arguments: [String], prompt: String) throws -> String
}

public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Uses `osascript … do shell script … with administrator privileges`. The command and prompt
/// travel as osascript argv, so no AppleScript string escaping is involved.
public struct OsascriptExecutor: PrivilegedExecutor {
    public init() {}

    public static func command(for arguments: [String]) -> String {
        (["/bin/sh", "-c", HelperScript.source, "dw-helper"] + arguments).map(shellQuote).joined(separator: " ")
    }

    public func run(_ arguments: [String], prompt: String) throws -> String {
        let out = try ProcessRunner.run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges without altering line endings",
            "-e", "end run",
            Self.command(for: arguments), prompt,
        ])
        if out.status == 0 { return out.stdout }
        if out.stderr.contains("(-128)") { throw WriteError.cancelled }
        throw WriteError.helperFailed(HelperOutput.errorMessage(out.stderr))
    }
}

/// Runs the helper script as the current user. Used by tests (with stubbed commands) and never
/// for live writes.
public struct LocalShellExecutor: PrivilegedExecutor {
    public var environment: [String: String]

    public init(environment: [String: String]) { self.environment = environment }

    public func run(_ arguments: [String], prompt: String) throws -> String {
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        let out = try ProcessRunner.run("/bin/sh", ["-c", HelperScript.source, "dw-helper"] + arguments, environment: env)
        if out.status == 0 { return out.stdout }
        throw WriteError.helperFailed(HelperOutput.errorMessage(out.stderr))
    }
}

public enum HelperOutput {
    public static func errorMessage(_ stderr: String) -> String {
        if let r = stderr.range(of: "DW-ERROR ") {
            var msg = String(stderr[r.upperBound...])
            if let nl = msg.firstIndex(of: "\n") { msg = String(msg[..<nl]) }
            // osascript appends " (N)" with the exit status.
            if let paren = msg.range(of: #" \(\d+\)$"#, options: .regularExpression) { msg.removeSubrange(paren) }
            return msg
        }
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "The privileged helper failed." : trimmed
    }

    /// PIDs from "DW running-after 123 456".
    public static func pids(after output: String, tag: String) -> [Int32] {
        for line in output.split(separator: "\n") where line.hasPrefix("DW \(tag) ") {
            return line.dropFirst("DW \(tag) ".count).split(separator: " ").compactMap { Int32($0) }
        }
        return []
    }
}

// MARK: - Restart

public struct RestartReport: Equatable, Sendable {
    public var simulated: Bool
    public var before: [Int32]
    public var after: [Int32]
    public var transcript: String
}

public protocol DaemonRestarter: Sendable {
    var isLive: Bool { get }
    func restart() throws -> RestartReport
}

public struct PrivilegedRestarter: DaemonRestarter {
    public var executor: PrivilegedExecutor
    public var isLive: Bool { true }

    public init(executor: PrivilegedExecutor) { self.executor = executor }

    public func restart() throws -> RestartReport {
        let out = try executor.run(["restart"], prompt: "Dynject Workbench needs to restart dynjectd so it reads the new configuration.")
        return Self.report(from: out)
    }

    public static func report(from out: String) -> RestartReport {
        RestartReport(simulated: false,
                      before: HelperOutput.pids(after: out, tag: "running-before"),
                      after: HelperOutput.pids(after: out, tag: "running-after"),
                      transcript: out)
    }
}

/// Fixture mode: never touches launchd or processes.
public final class SimulatedRestarter: DaemonRestarter, @unchecked Sendable {
    public private(set) var count = 0
    public var isLive: Bool { false }
    public init() {}

    public func restart() throws -> RestartReport {
        count += 1
        return RestartReport(simulated: true, before: [], after: [],
                             transcript: "DW simulated restart #\(count) (fixture mode: launchd and dynjectd untouched)\n")
    }
}

// MARK: - Protected writer

public struct WriteOutcome: Equatable, Sendable {
    public var path: String
    public var backup: URL?
    public var usedAdministratorRights: Bool
    public var restart: RestartReport?
}

/// One file change in a `ProtectedFileWriter.apply` transaction.
public enum ProtectedChange: Sendable, Equatable {
    /// Write `data` to `path`. `expectedCurrent` is what the caller last saw there (nil: no file); the write is
    /// refused if the file differs.
    case write(Data, to: String, expectedCurrent: Data?, category: String)
    /// Delete `path`, a regular `*.dylib` file directly in the writer's `removableDirectory`, if it still holds
    /// `expectedCurrent`. The current bytes are backed up first.
    case remove(String, expectedCurrent: Data, category: String)

    public var path: String {
        switch self {
        case let .write(_, path, _, _), let .remove(path, _, _): return path
        }
    }
}

public struct BatchOutcome: Equatable, Sendable {
    /// path → backup of the bytes it held before (only for files that existed).
    public var backups: [String: URL]
    public var usedAdministratorRights: Bool
    public var restart: RestartReport?
    /// The helper's transcript ("" when the files were written directly).
    public var transcript: String
}

public struct ProtectedFileWriter: Sendable {
    public var backups: BackupStore
    public var executor: PrivilegedExecutor
    /// The only folder `.remove` changes may delete from (the helper script enforces /opt/dynject/lib/tweaks on
    /// its own). Tests and fixture mode point it at a temporary folder.
    public var removableDirectory: String

    public init(backups: BackupStore, executor: PrivilegedExecutor,
                removableDirectory: String = TweakLocations.liveTweaksDirectory) {
        self.backups = backups
        self.executor = executor
        self.removableDirectory = removableDirectory
    }

    /// Checks that `path` is a regular `*.dylib` file directly inside `directory` (no symlinks, no hidden files,
    /// no other folder, and the folder itself is not reached through a symlink). Returns why not, or nil.
    public static func removalProblem(_ path: String, directory: String) -> String? {
        // Not standardizingPath: it turns /private/var into /var, which realpath below would then reject.
        var dir = directory
        while dir.count > 1 && dir.hasSuffix("/") { dir.removeLast() }
        guard path.hasPrefix(dir + "/"), path.hasSuffix(".dylib") else {
            return "only *.dylib files in \(dir) can be removed"
        }
        let name = String(path.dropFirst(dir.count + 1))
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), !name.contains("\n") else {
            return "\(path) is not a plain file name directly in \(dir)"
        }
        guard let real = realpath(dir, nil) else { return "\(dir) is missing" }
        defer { free(real) }
        guard String(cString: real) == dir else { return "\(dir) resolves to \(String(cString: real)); not removing anything" }
        var st = stat()
        guard lstat(path, &st) == 0 else { return "\(path) does not exist" }
        if (st.st_mode & S_IFMT) == S_IFLNK { return "refusing to remove a symbolic link: \(path)" }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return "\(path) is not a regular file" }
        return nil
    }

    /// Applies several changes as one transaction, with at most one administrator prompt: every file is checked
    /// against what the caller expects and backed up first, then the changes are made, directly when every path
    /// is writable, otherwise all of them through one helper invocation, with the restart folded in when
    /// `restartWith` is live. Nothing is written if any check fails.
    public func apply(_ changes: [ProtectedChange], restartWith restarter: DaemonRestarter? = nil) throws -> BatchOutcome {
        precondition(!changes.isEmpty || restarter != nil, "nothing to do")
        let fm = FileManager.default
        for change in changes {
            let current = fm.contents(atPath: change.path)
            switch change {
            case let .write(_, path, expected, _):
                if current != expected { throw WriteError.changedOnDisk(path) }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { throw WriteError.io("\(path) is a folder.") }
            case let .remove(path, expected, _):
                if let problem = Self.removalProblem(path, directory: removableDirectory) { throw WriteError.io("Refusing to remove: \(problem).") }
                if current != expected { throw WriteError.changedOnDisk(path) }
            }
        }
        var backupURLs: [String: URL] = [:]
        for change in changes {
            let category: String
            switch change { case let .write(_, _, _, c), let .remove(_, _, c): category = c }
            if let current = fm.contents(atPath: change.path) {
                backupURLs[change.path] = try backups.backup(current, originalPath: change.path, category: category)
            }
        }

        let direct = changes.allSatisfy { change in
            switch change {
            case let .write(_, path, _, _): return AtomicFile.canWriteDirectly(path)
            case let .remove(path, _, _): return fm.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
            }
        }
        if direct {
            for change in changes {
                switch change {
                case let .write(data, path, _, _): try AtomicFile.write(data, to: path)
                case let .remove(path, _, _):
                    do { try fm.removeItem(atPath: path) } catch { throw WriteError.io("Could not remove \(path): \(error.localizedDescription)") }
                }
            }
            let report = try restarter?.restart()
            return BatchOutcome(backups: backupURLs, usedAdministratorRights: false, restart: report, transcript: "")
        }

        var staged: [URL] = []
        defer { staged.forEach { try? fm.removeItem(at: $0) } }
        var args: [String] = []
        for change in changes {
            switch change {
            case let .write(data, path, expected, _):
                let url = fm.temporaryDirectory.appendingPathComponent("dw-staged-\(UUID().uuidString)")
                guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    throw WriteError.io("Could not stage the new file.")
                }
                staged.append(url)
                args += ["install", path, url.path, sha256Hex(data), expected.map(sha256Hex) ?? "-"]
            case let .remove(path, expected, _):
                args += ["remove", path, sha256Hex(expected)]
            }
        }
        let folded = restarter?.isLive == true
        if folded { args.append("restart") }
        let names = changes.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
        let prompt = "Dynject Workbench needs to change \(names)" + (folded ? " and restart dynjectd." : ".")
        let out = try executor.run(args, prompt: prompt)
        var report: RestartReport?
        if folded {
            report = PrivilegedRestarter.report(from: out)
        } else if let restarter {
            report = try restarter.restart()
        }
        return BatchOutcome(backups: backupURLs, usedAdministratorRights: true, restart: report, transcript: out)
    }

    /// Backs up the current file, then writes `data` atomically: directly if we can, otherwise via the
    /// privileged helper. `expectedCurrent` guards against clobbering a concurrent edit.
    /// If `restartWith` is live and administrator rights are needed anyway, the restart is folded
    /// into the same authorization prompt.
    public func write(_ data: Data, to path: String, expectedCurrent: Data?, category: String,
                      restartWith restarter: DaemonRestarter? = nil) throws -> WriteOutcome {
        let current = FileManager.default.contents(atPath: path)
        if let expectedCurrent, current != expectedCurrent { throw WriteError.changedOnDisk(path) }
        let backupURL = try current.map { try backups.backup($0, originalPath: path, category: category) }

        if AtomicFile.canWriteDirectly(path) {
            try AtomicFile.write(data, to: path)
            let report = try restarter?.restart()
            return WriteOutcome(path: path, backup: backupURL, usedAdministratorRights: false, restart: report)
        }

        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("dw-staged-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: staged.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw WriteError.io("Could not stage the new file.")
        }
        defer { try? FileManager.default.removeItem(at: staged) }

        let folded = restarter?.isLive == true
        var args = ["install", path, staged.path, sha256Hex(data), current.map(sha256Hex) ?? "-"]
        if folded { args.append("restart") }
        let prompt = folded
            ? "Dynject Workbench needs to write \(path) and restart dynjectd."
            : "Dynject Workbench needs to write \(path)."
        let out = try executor.run(args, prompt: prompt)
        var report: RestartReport?
        if folded {
            report = PrivilegedRestarter.report(from: out)
        } else if let restarter {
            report = try restarter.restart()
        }
        return WriteOutcome(path: path, backup: backupURL, usedAdministratorRights: true, restart: report)
    }
}
