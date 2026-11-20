import Foundation

/// Runs launchctl. Injectable so tests (and fixture modes) never load a real job.
public protocol LaunchctlRunner: AnyObject {
    func run(_ arguments: [String]) -> (status: Int32, output: String)
}

public final class SystemLaunchctlRunner: LaunchctlRunner {
    public init() {}
    public func run(_ arguments: [String]) -> (status: Int32, output: String) {
        guard let out = try? ProcessRunner.run("/bin/launchctl", arguments) else { return (-1, "could not run launchctl") }
        return (out.status, out.stdout + out.stderr)
    }
}

/// Records calls and answers from a script; the default answer is (0, "").
public final class RecordingLaunchctlRunner: LaunchctlRunner {
    public private(set) var calls: [[String]] = []
    public var respond: ([String]) -> (status: Int32, output: String)
    public init(respond: @escaping ([String]) -> (status: Int32, output: String) = { _ in (0, "") }) { self.respond = respond }
    public func run(_ arguments: [String]) -> (status: Int32, output: String) {
        calls.append(arguments)
        return respond(arguments)
    }
}

public struct LaunchAgentStatus: Equatable, Sendable {
    public var plistInstalled: Bool
    public var binaryInstalled: Bool
    /// launchd knows the job (bootstrapped in the user's GUI domain).
    public var loaded: Bool
    public var running: Bool
    public var pid: Int32?
    public var lastExitCode: String?
    /// The installed plist runs the installed binary with the agent's subcommand.
    public var plistMatches: Bool

    public var summary: String {
        if !plistInstalled { return "not installed" }
        if !loaded { return "installed, not loaded" }
        if running { return "running" + (pid.map { " (pid \($0))" } ?? "") }
        return "loaded, not running" + (lastExitCode.map { " (last exit \($0))" } ?? "")
    }
}

public typealias SafeModeAgentStatus = LaunchAgentStatus

/// A per-user LaunchAgent that runs a copy of `dw` with a subcommand: RunAtLoad + KeepAlive, a plist in
/// ~/Library/LaunchAgents, the binary in Workbench's bin folder. No administrator rights are involved.
/// SafeModeAgent and BridgeAgent are the two.
public class UserLaunchAgent {
    public let label: String
    /// Arguments after the binary, e.g. ["safemode", "watch"].
    public let command: [String]
    /// File name of the copied dw in the bin directory. Each agent has its own, so removing one never
    /// pulls the binary out from under the other.
    public let binaryName: String
    /// Extra top-level plist keys (MachServices, ProcessType).
    public let extraPlistKeys: [String: Any]
    public let launchAgentsDirectory: URL
    public let binDirectory: URL
    public let runner: LaunchctlRunner
    public let uid: uid_t

    public var plistURL: URL { launchAgentsDirectory.appendingPathComponent("\(label).plist") }
    public var binaryURL: URL { binDirectory.appendingPathComponent(binaryName) }
    public var serviceTarget: String { "gui/\(uid)/\(label)" }
    public var domainTarget: String { "gui/\(uid)" }

    public static var defaultLaunchAgentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    public static var defaultBinDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dynject Workbench/bin", isDirectory: true)
    }

    public init(label: String, command: [String], binaryName: String = "dw", extraPlistKeys: [String: Any] = [:],
                launchAgentsDirectory: URL, binDirectory: URL, runner: LaunchctlRunner, uid: uid_t = getuid()) {
        self.label = label
        self.command = command
        self.binaryName = binaryName
        self.extraPlistKeys = extraPlistKeys
        self.launchAgentsDirectory = launchAgentsDirectory
        self.binDirectory = binDirectory
        self.runner = runner
        self.uid = uid
    }

    public func programArguments(extra: [String] = []) -> [String] { [binaryURL.path] + command + extra }

    /// The LaunchAgent property list: RunAtLoad + KeepAlive, background priority unless the extra keys say
    /// otherwise, no output files (the agents log through os_log).
    public func plist(extraArguments: [String] = []) -> [String: Any] {
        var p: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments(extra: extraArguments),
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "ThrottleInterval": 30,
            "LimitLoadToSessionType": "Aqua",
        ]
        for (k, v) in extraPlistKeys { p[k] = v }
        return p
    }

    public func plistData(extraArguments: [String] = []) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: plist(extraArguments: extraArguments), format: .xml, options: 0)
    }

    public struct InstallReport: Equatable, Sendable {
        public var binary: String
        public var plist: String
        public var launchctl: [String]
    }

    public enum AgentError: Error, LocalizedError, Equatable {
        case missingBinary(String)
        case launchctl(String)
        public var errorDescription: String? {
            switch self {
            case let .missingBinary(p): return "No dw binary at \(p)."
            case let .launchctl(m): return "launchctl failed: \(m)"
            }
        }
    }

    /// Copies `sourceBinary` (a dw executable) to the bin directory, writes the plist and (re)loads the job.
    @discardableResult
    public func install(sourceBinary: String, extraArguments: [String] = []) throws -> InstallReport {
        let fm = FileManager.default
        guard let bin = fm.contents(atPath: sourceBinary) else { throw AgentError.missingBinary(sourceBinary) }
        try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        if (fm.contents(atPath: binaryURL.path)) != bin {
            try AtomicFile.write(bin, to: binaryURL.path)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        }
        try AtomicFile.write(try plistData(extraArguments: extraArguments), to: plistURL.path)
        var log: [String] = []
        // Replace a loaded copy so the new binary and arguments take effect. Not loaded is fine.
        let out = runner.run(["bootout", serviceTarget])
        log.append("bootout \(serviceTarget): \(out.status)")
        let boot = runner.run(["bootstrap", domainTarget, plistURL.path])
        log.append("bootstrap \(domainTarget): \(boot.status)")
        guard boot.status == 0 else { throw AgentError.launchctl(boot.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return InstallReport(binary: binaryURL.path, plist: plistURL.path, launchctl: log)
    }

    /// Unloads the job and removes the plist and the copied binary.
    public func uninstall() throws {
        _ = runner.run(["bootout", serviceTarget])
        let fm = FileManager.default
        if fm.fileExists(atPath: plistURL.path) { try fm.removeItem(at: plistURL) }
        if fm.fileExists(atPath: binaryURL.path) { try fm.removeItem(at: binaryURL) }
    }

    public func status() -> LaunchAgentStatus {
        let fm = FileManager.default
        var s = LaunchAgentStatus(plistInstalled: fm.fileExists(atPath: plistURL.path),
                                  binaryInstalled: fm.isExecutableFile(atPath: binaryURL.path),
                                  loaded: false, running: false, pid: nil, lastExitCode: nil, plistMatches: false)
        if let data = fm.contents(atPath: plistURL.path),
           let p = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
           let args = p["ProgramArguments"] as? [String] {
            let expected = programArguments()
            s.plistMatches = Array(args.prefix(expected.count)) == expected
        }
        let out = runner.run(["print", serviceTarget])
        guard out.status == 0 else { return s }
        s.loaded = true
        let info = Self.parsePrint(out.output)
        s.running = info.state == "running"
        s.pid = info.pid
        s.lastExitCode = info.lastExitCode
        return s
    }

    /// The top-level `state`, `pid` and `last exit code` of `launchctl print`.
    public static func parsePrint(_ text: String) -> (state: String?, pid: Int32?, lastExitCode: String?) {
        var state: String?, pid: Int32?, exit: String?
        for raw in text.split(separator: "\n") {
            guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t") else { continue }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let eq = line.range(of: " = ") else { continue }
            let key = line[..<eq.lowerBound], value = String(line[eq.upperBound...])
            switch key {
            case "state": state = value
            case "pid": pid = Int32(value)
            case "last exit code": exit = value
            default: break
            }
        }
        return (state, pid, exit)
    }
}

/// The LaunchAgent that runs `dw safemode watch`.
public final class SafeModeAgent: UserLaunchAgent {
    public static let label = "local.dynject.safemode"
    /// os_log subsystem of the watcher.
    public static let logSubsystem = "local.dynject.safemode"

    public init(launchAgentsDirectory: URL = UserLaunchAgent.defaultLaunchAgentsDirectory,
                binDirectory: URL = UserLaunchAgent.defaultBinDirectory,
                runner: LaunchctlRunner = SystemLaunchctlRunner(), uid: uid_t = getuid()) {
        super.init(label: Self.label, command: ["safemode", "watch"], launchAgentsDirectory: launchAgentsDirectory,
                   binDirectory: binDirectory, runner: runner, uid: uid)
    }
}
