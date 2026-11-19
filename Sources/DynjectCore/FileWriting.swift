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

public struct ProtectedFileWriter: Sendable {
    public var backups: BackupStore
    public var executor: PrivilegedExecutor

    public init(backups: BackupStore, executor: PrivilegedExecutor) {
        self.backups = backups
        self.executor = executor
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
