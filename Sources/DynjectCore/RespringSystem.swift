import AppKit
import Darwin
import Foundation

// Respring, part 3: the real sources and controller. Only `WorkspaceAppController` changes anything (it quits and
// opens apps); everything else reads. Workbench's fixture and smoke-test modes must use SimulatedAppController.

/// NSWorkspace's running apps with a bundle: those with a Dock icon (activation policy `.regular`) and menu bar apps
/// (`.accessory`) of their own, not macOS's (see `isListed`).
public struct WorkspaceRunningApps: RunningAppSource {
    /// Also macOS's apps without a Dock icon (ControlCenter, MenuBarAgent, Spotlight…) and helper apps inside other
    /// apps: `dw why` wants them; respring leaves them alone (launchd starts most of them, and their owner the rest).
    public var includeBackground: Bool
    /// Also macOS's UI agents respring can relaunch (`RespringSystemAgents`): `dw respring --system`.
    public var includeSystemAgents: Bool

    public init(includeBackground: Bool = false, includeSystemAgents: Bool = false) {
        self.includeBackground = includeBackground
        self.includeSystemAgents = includeSystemAgents
    }

    /// Which running apps are listed. A menu bar app (`.accessory`) is, unless it's part of macOS (in /System) or a
    /// helper inside another app's bundle (".app/…/X.app"): those only with `includeBackground`.
    public static func isListed(regular: Bool, accessory: Bool, bundlePath: String, includeBackground: Bool) -> Bool {
        if regular { return true }
        guard accessory else { return false }
        if includeBackground { return true }
        let path = RespringPaths.normalized(bundlePath)
        let nested = (path as NSString).deletingLastPathComponent.contains(".app/")
            || (path as NSString).deletingLastPathComponent.hasSuffix(".app")
        return !path.hasPrefix("/System/") && !nested
    }

    public func runningApps() -> [RunningApp] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            guard !$0.isTerminated, let id = $0.bundleIdentifier, let url = $0.bundleURL else { return false }
            if includeSystemAgents && RespringSystemAgents.contains(id) { return true }
            return Self.isListed(regular: $0.activationPolicy == .regular, accessory: $0.activationPolicy == .accessory,
                                 bundlePath: url.resolvingSymlinksInPath().path, includeBackground: includeBackground)
        }
        // launchDate is nil for some apps (launched before the session's LaunchServices knew them); ask ps.
        let missing = apps.filter { $0.launchDate == nil }.map(\.processIdentifier)
        let started = Self.startDates(pids: missing)
        return apps.map { r in
            let bundle = r.bundleURL!.resolvingSymlinksInPath().path
            return RunningApp(pid: r.processIdentifier, bundleID: r.bundleIdentifier!,
                              name: r.localizedName ?? (bundle as NSString).lastPathComponent,
                              bundlePath: bundle,
                              executablePath: r.executableURL?.resolvingSymlinksInPath().path ?? bundle,
                              launchDate: r.launchDate ?? started[r.processIdentifier],
                              isHidden: r.isHidden, isSystemAgent: RespringSystemAgents.contains(r.bundleIdentifier!))
        }
    }

    /// `ps -o pid=,lstart=`: second precision.
    public static func startDates(pids: [Int32]) -> [Int32: Date] {
        guard !pids.isEmpty,
              let out = try? ProcessRunner.run("/bin/ps", ["-o", "pid=,lstart=", "-p", pids.map(String.init).joined(separator: ",")])
        else { return [:] }
        var result: [Int32: Date] = [:]
        for line in out.stdout.split(separator: "\n") {
            let t = line.split(separator: " ", omittingEmptySubsequences: true)
            guard t.count >= 6, let pid = Int32(t[0]),
                  let d = DaemonInspector.lstartFormatter.date(from: t[1...5].joined(separator: " ")) else { continue }
            result[pid] = d
        }
        return result
    }
}

/// lsof, through LoadedImageInspector.
public struct LsofDylibInspector: LoadedDylibInspecting {
    public init() {}

    public func loadedDylibs(pids: [Int32], candidates: [String]) -> [Int32: Set<String>] {
        guard !pids.isEmpty else { return [:] }
        // With no candidates lsof still tells which pids are readable; ask about an impossible path.
        let result = LoadedImageInspector.inspect(pids: pids, dylibs: candidates.isEmpty ? ["/nonexistent/.dynject"] : candidates)
        return result.mapValues { $0.filter { candidates.contains($0) } }
    }
}

/// sysctl(KERN_PROC_PID) and proc_pidpath.
public struct SystemProcessAncestry: ProcessAncestry {
    public init() {}

    public func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    public func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }
}

extension RespringExclusions {
    /// The app(s) hosting this process: getpid() and its ancestors.
    public static func forCurrentProcess(ancestry: ProcessAncestry = SystemProcessAncestry()) -> RespringExclusions {
        host(of: getpid(), ancestry: ancestry)
    }
}

/// Quits and opens real apps. Use only on a user's explicit request (dw respring without --dry-run, or the sheet's
/// "Respring Selected" button).
public final class WorkspaceAppController: AppController {
    public var openTimeout: TimeInterval = 30

    public init() {}

    public func terminate(_ app: RunningApp, method: RespringQuitMethod) -> Bool {
        switch method {
        case .terminate:
            guard let r = NSRunningApplication(processIdentifier: app.pid) else { return false }
            return r.terminate()
        case .signal:
            // What `killall` does; launchd starts macOS's UI agents again by itself.
            return kill(app.pid, SIGTERM) == 0
        case .appleEventQuit:
            // Finder ignores terminate(). Asking it to quit needs Automation permission for whatever runs this.
            let script = "tell application id \"\(app.bundleID)\" to quit"
            guard let out = try? ProcessRunner.run("/usr/bin/osascript", ["-e", script]) else { return false }
            return out.status == 0
        }
    }

    /// A CLI has no run loop, so NSRunningApplication.isTerminated never updates; ask the kernel.
    public func isRunning(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    public func runningPIDs(bundleID: String) -> [Int32] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier).filter { isRunning(pid: $0) }
    }

    public func open(bundleURL: URL, options: RespringOpenOptions) throws -> Int32 {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = options.activates
        config.hides = options.hides
        config.addsToRecentItems = false
        config.promptsUserIfNeeded = false
        if let env = options.environment { config.environment = env }
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var pid: Int32?; var error: Error? }
        let box = Box()
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { app, error in
            box.pid = app?.processIdentifier
            box.error = error
            done.signal()
        }
        guard done.wait(timeout: .now() + openTimeout) == .success else {
            throw RespringControlError.openFailed("no answer from LaunchServices after \(Int(openTimeout)) s")
        }
        if let pid = box.pid, pid > 0 { return pid }
        throw RespringControlError.openFailed(box.error?.localizedDescription ?? "LaunchServices returned no process")
    }

    public func loadedDylibs(pid: Int32, candidates: [String]) -> Set<String>? {
        LsofDylibInspector().loadedDylibs(pids: [pid], candidates: candidates)[pid]
    }

    /// `/bin/sh` in its own session (so it outlives the app and a closing terminal): waits for `pid` to exit, then
    /// `open -g`. If the app is still running after `timeout` (the user cancelled the quit), it does nothing.
    public func scheduleReopen(bundleURL: URL, afterExitOf pid: Int32, timeout: TimeInterval) throws {
        let script = #"i=0; while kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ "$i" -gt "$3" ] && exit 0; sleep 0.25; done; exec /usr/bin/open -g "$2""#
        let args = ["/bin/sh", "-c", script, "dw-respring-reopen", String(pid), bundleURL.path, String(Int(timeout * 4))]
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        let cargs = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        var child: pid_t = 0
        let rc = posix_spawn(&child, "/bin/sh", &actions, &attr, cargs, environ)
        guard rc == 0 else { throw RespringControlError.openFailed("couldn't start the reopen helper (\(String(cString: strerror(rc))))") }
    }
}

// MARK: - Live planner

extension RespringPlanner {
    /// The planner `dw respring` and Workbench use on the real system: the config text, dynjectd's log for service
    /// names, the manifests for tweak IDs, the tweaks directory for dylibs no longer configured, and Safe Mode's
    /// state.json. Everything here only reads.
    public static func live(configText: String, configPath: String, logText: String?,
                            manifests: [TweakManifest], dylibDirectory: String = SafeModeCatalog.defaultDylibDirectory,
                            safeModeState: SafeModeState?,
                            daemon: DaemonStatus? = nil,
                            runningApps: RunningAppSource = WorkspaceRunningApps(),
                            inspector: LoadedDylibInspecting = LsofDylibInspector(),
                            exclusions: RespringExclusions = .forCurrentProcess()) -> RespringPlanner {
        let log = logText.map(DynjectLogParser.parse)
        let catalog = SafeModeCatalog(manifests: manifests, dylibDirectory: dylibDirectory)
        var labels: [String: String] = [:]
        var safeModeTweaks: [String: String] = [:]
        for t in catalog.tweaks where t.hasManifest {
            labels[t.dylibPath] = labels[t.dylibPath].map { "\($0)/\(t.tweakID)" } ?? t.tweakID
            if SafeModeSupportChecker.shared.supportsSafeMode(dylibAt: t.dylibPath) == true { safeModeTweaks[t.dylibPath] = t.tweakID }
        }
        let inDirectory = catalog.tweaks.map(\.dylibPath).filter { $0.hasPrefix(dylibDirectory + "/") }
        // The config took effect when it was written or when dynjectd last started, whichever is later.
        let configDate = (daemon?.configModified) ?? RespringPlanner.fileModificationDate(configPath)
        let daemonStart = daemon?.processes.compactMap(\.started).max()
        let since = [configDate, daemonStart].compactMap { $0 }.max()
        return RespringPlanner(
            config: EffectiveConfig(document: ConfigDocument(text: configText)),
            runningApps: runningApps, inspector: inspector,
            serviceName: { ServiceNameResolver.resolve($0, log: log).value },
            tweakLabels: labels, extraTweakDylibs: inDirectory,
            configEffectiveSince: since,
            safeModeTweaks: safeModeTweaks,
            safeModeEvents: safeModeState.map(RespringSafeModeEvent.from(state:)) ?? [],
            exclusions: exclusions)
    }
}
