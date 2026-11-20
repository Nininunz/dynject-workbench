import Foundation

// MARK: - App discovery

public enum AppDiscovery {
    public static var defaultRoots: [String] {
        [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications",
            "/System/Library/CoreServices",
        ]
    }

    /// Finds .app bundles in `roots`, descending into plain folders (e.g. Utilities) up to `depth`.
    public static func scan(roots: [String], depth: Int = 2) -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        let fm = FileManager.default

        func visit(_ dir: String, _ remaining: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = (dir as NSString).appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    let resolved = (path as NSString).resolvingSymlinksInPath
                    guard seen.insert(resolved).inserted, let app = read(bundleAt: path) else { continue }
                    apps.append(app)
                } else if remaining > 1 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                        visit(path, remaining - 1)
                    }
                }
            }
        }

        for root in roots { visit(root, depth) }
        return apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func read(bundleAt path: String) -> InstalledApp? {
        let infoPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: infoPath),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty,
              let exe = info["CFBundleExecutable"] as? String, !exe.isEmpty
        else { return nil }
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = (info["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (info["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? fileName
        return InstalledApp(
            displayName: name,
            bundleID: bundleID,
            executableName: exe,
            executablePath: (path as NSString).appendingPathComponent("Contents/MacOS/\(exe)"),
            bundlePath: path
        )
    }
}

// MARK: - Process helpers

public enum ProcessRunner {
    public struct Output {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        // Drain both pipes concurrently so large output cannot deadlock.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        errData = err.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return Output(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }
}

// MARK: - Loaded images (confirmed injection)

public enum LoadedImageInspector {
    /// Parses `lsof -nP -Fn -p ...` output into pid → mapped file paths.
    public static func parseLsof(_ output: String) -> [Int32: Set<String>] {
        var result: [Int32: Set<String>] = [:]
        var pid: Int32?
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value); if let pid { result[pid, default: []] = result[pid] ?? [] }
            case "n": if let pid { result[pid, default: []].insert(value) }
            default: break
            }
        }
        return result
    }

    /// Which of `dylibs` are mapped into each pid. Only works for processes this user may inspect;
    /// pids that lsof could not read are absent from the result.
    public static func inspect(pids: [Int32], dylibs: [String]) -> [Int32: Set<String>] {
        guard !pids.isEmpty, !dylibs.isEmpty else { return [:] }
        // lsof reports resolved paths; map both forms back to the configured path.
        var wanted: [String: String] = [:]
        for d in dylibs {
            wanted[(d as NSString).resolvingSymlinksInPath] = d
            wanted[d] = d
        }
        guard let out = try? ProcessRunner.run("/usr/sbin/lsof",
                                               ["-nP", "-Fn", "-p", pids.map(String.init).joined(separator: ",")])
        else { return [:] }
        // lsof exits 1 if any pid vanished; output for the rest is still valid.
        return parseLsof(out.stdout).mapValues { files in Set(files.compactMap { wanted[$0] }) }
    }
}

// MARK: - Daemon status

public struct DaemonProcess: Equatable, Sendable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var parentPID: Int32
    public var started: Date?
    public var startedText: String
    public var command: String
}

public struct LaunchdJobInfo: Equatable, Sendable {
    public var label: String
    public var loaded: Bool
    public var state: String?
    public var runs: Int?
    public var lastExitCode: String?
    public var program: String?
    public var arguments: [String]
}

public struct DaemonStatus: Equatable, Sendable {
    public var processes: [DaemonProcess]
    public var job: LaunchdJobInfo?
    public var configModified: Date?

    public var isDuplicated: Bool { processes.count > 1 }

    /// Daemons started before the config was last written (they run an older config). ps gives start times to the
    /// second, so a daemon started in the same second as the write (the restart right after a save) counts as current.
    public var staleProcesses: [DaemonProcess] {
        guard let configModified else { return [] }
        return processes.filter { ($0.started ?? .distantPast).addingTimeInterval(1) <= configModified }
    }

    public var needsRestart: Bool { !staleProcesses.isEmpty || isDuplicated }
}

public enum DaemonInspector {
    public static let label = "com.dynject.dynjectd"
    public static let daemonName = "dynjectd"

    public static func status(configPath: String) -> DaemonStatus {
        // pgrep -x matches the kernel's process name, exactly as the restart helper does.
        let pids = (try? ProcessRunner.run("/usr/bin/pgrep", ["-x", daemonName]))?.stdout
            .split(separator: "\n").compactMap { Int32($0) } ?? []
        var processes: [DaemonProcess] = []
        if !pids.isEmpty {
            let ps = (try? ProcessRunner.run("/bin/ps", ["-ww", "-o", "pid=,ppid=,lstart=,args=", "-p",
                                                         pids.map(String.init).joined(separator: ",")]))?.stdout ?? ""
            processes = parsePS(ps, pids: Set(pids))
        }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: configPath)[.modificationDate]) as? Date
        return DaemonStatus(processes: processes, job: launchdJob(), configModified: mtime)
    }

    static let lstartFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    /// Parses `ps -o pid=,ppid=,lstart=,args=` (lstart is always 5 tokens), keeping only `pids`.
    /// Note: the `comm` column is truncated to its width on macOS, so it is not used.
    public static func parsePS(_ text: String, pids: Set<Int32>) -> [DaemonProcess] {
        text.split(separator: "\n").compactMap { line in
            let t = line.split(separator: " ", omittingEmptySubsequences: true)
            guard t.count >= 8, let pid = Int32(t[0]), pids.contains(pid), let ppid = Int32(t[1]) else { return nil }
            let lstart = t[2...6].joined(separator: " ")
            return DaemonProcess(pid: pid, parentPID: ppid, started: lstartFormatter.date(from: lstart),
                                 startedText: lstart, command: t[7...].joined(separator: " "))
        }
    }

    public static func launchdJob() -> LaunchdJobInfo? {
        guard let out = try? ProcessRunner.run("/bin/launchctl", ["print", "system/\(label)"]) else { return nil }
        if out.status != 0 { return LaunchdJobInfo(label: label, loaded: false, state: nil, runs: nil, lastExitCode: nil, program: nil, arguments: []) }
        return parseLaunchctlPrint(out.stdout)
    }

    public static func parseLaunchctlPrint(_ text: String) -> LaunchdJobInfo {
        var info = LaunchdJobInfo(label: label, loaded: true, state: nil, runs: nil, lastExitCode: nil, program: nil, arguments: [])
        var inArgs = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inArgs {
                if line == "}" { inArgs = false } else { info.arguments.append(line) }
                continue
            }
            if line == "arguments = {" { inArgs = true; continue }
            guard raw.hasPrefix("\t"), !raw.hasPrefix("\t\t"), let eq = line.range(of: " = ") else { continue }
            let key = String(line[..<eq.lowerBound]), value = String(line[eq.upperBound...])
            switch key {
            case "state": info.state = value
            case "runs": info.runs = Int(value)
            case "last exit code": info.lastExitCode = value
            case "program": info.program = value
            default: break
            }
        }
        return info
    }
}
