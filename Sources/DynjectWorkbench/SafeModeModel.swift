import AppKit
import DynjectCore
import Observation

/// State behind the Safe Mode panel: the "dynject.safemode" key and state.json (through DynjectCore's SafeMode),
/// the watcher LaunchAgent, and which tweaks honour the key.
///
/// Live mode uses the real key, state.json, ~/Library/LaunchAgents and launchctl. When the environment isolates
/// Safe Mode (fixture mode, smoke tests, other manifests or reports), the key lives in a plist file under the
/// support folder with the test notification name, state.json and the agent's files go under the support folder,
/// and launchctl is simulated, so nothing reaches launchd or the global preferences.
@MainActor @Observable
final class SafeModeModel {
    let safeMode: SafeMode
    let agent: SafeModeAgent
    let isolated: Bool
    let reportsDirectory: String
    let dylibDirectory: String
    let dwBinaryPath: String
    /// Directory options written into the agent's plist (isolated mode only), so a copy of it would never watch
    /// or write the real ones.
    let agentExtraArguments: [String]
    let notifier: SafeModeNotifier
    let support = SafeModeSupportChecker.shared

    private(set) var snapshot: SafeModeSnapshot
    private(set) var catalog: SafeModeCatalog
    /// tweakID → how much of Safe Mode it honours (nil: unknown, the dylib can't be read).
    private(set) var supportByTweak: [String: SafeModeSupport?] = [:]
    private(set) var agentStatus: SafeModeAgentStatus?
    private(set) var lastScan: SafeModeScanResult?
    private(set) var lastScanAt: Date?
    private(set) var refreshedAt: Date?
    private(set) var refreshCount = 0
    /// Result of the last action ("Re-enabled …", errors).
    var message: (text: String, isError: Bool)?

    var manifests: [TweakManifest] = [] { didSet { rebuildCatalog() } }

    @ObservationIgnored private var stateSource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var debounce: DispatchWorkItem?
    @ObservationIgnored private var observing = false

    init(env: AppEnvironment, tweakBackend: TweakPrefsBackend) {
        isolated = env.isolatesSafeMode
        reportsDirectory = env.safeModeReportsDirectory
        dylibDirectory = env.tweakDylibDirectory
        dwBinaryPath = env.dwBinaryPath
        let stateStore = SafeModeStateStore(directory: env.safeModeStateDirectory)
        if isolated {
            // Never the real key: the fixture file (shared with tweak settings) or a preview file, test names.
            let store = (tweakBackend as? FileTweakBackend) ?? FileTweakBackend(path: env.safeModeKeyFile)
            safeMode = SafeMode(keys: SafeModeKeyStore(store: store, names: .forDomain(SafeModeNames.testDomain)),
                                stateStore: stateStore)
            agent = SafeModeAgent(launchAgentsDirectory: env.launchAgentsDirectory, binDirectory: env.agentBinDirectory,
                                  runner: SimulatedLaunchctlRunner())
            agentExtraArguments = ["--domain", SafeModeNames.testDomain,
                                   "--state-dir", env.safeModeStateDirectory.path,
                                   "--reports-dir", env.safeModeReportsDirectory,
                                   "--dylib-dir", env.tweakDylibDirectory]
                + (env.tweakDirectories.first.map { ["--tweaks-dir", $0] } ?? [])
            notifier = RecordingNotifier()
        } else {
            safeMode = SafeMode(keys: SafeModeKeyStore(store: CFPreferencesTweakBackend(), names: .production),
                                stateStore: stateStore)
            agent = SafeModeAgent(launchAgentsDirectory: env.launchAgentsDirectory, binDirectory: env.agentBinDirectory,
                                  runner: SystemLaunchctlRunner())
            agentExtraArguments = []
            notifier = OsascriptNotifier()
        }
        catalog = SafeModeCatalog(tweaks: [], dylibDirectory: env.tweakDylibDirectory)
        snapshot = safeMode.snapshot(catalog: nil, support: nil)
    }

    deinit {
        // The Darwin observer holds an unretained pointer to self.
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
        stateSource?.cancel()
    }

    var names: SafeModeNames { safeMode.keys.names }
    var stateFile: String { safeMode.stateStore.fileURL.path }
    /// The fixture file holding the isolated key; nil in live mode.
    var keyFile: String? { (safeMode.keys.store as? FileTweakBackend)?.path }

    // MARK: Refreshing

    /// Starts observing the change notification and state.json, then loads everything.
    func start() {
        if !observing {
            observing = true
            observeDarwinNotification()
            watchStateDirectory()
        }
        refresh()
        refreshAgentStatus()
    }

    func refresh() {
        snapshot = safeMode.snapshot(catalog: catalog, support: support)
        refreshedAt = Date()
        refreshCount += 1
    }

    private func rebuildCatalog() {
        catalog = SafeModeCatalog(manifests: manifests, dylibDirectory: dylibDirectory)
        var map: [String: SafeModeSupport?] = [:]
        for t in catalog.tweaks { map[t.tweakID] = support.support(dylibAt: t.dylibPath) }
        supportByTweak = map
        refresh()
    }

    /// `launchctl print` runs off the main thread (live mode) and the result comes back here.
    func refreshAgentStatus() {
        let agent = self.agent
        Task.detached(priority: .utility) {
            let s = agent.status()
            await MainActor.run { self.agentStatus = s }
        }
    }

    private func observeDarwinNotification() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let me = Unmanaged<SafeModeModel>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.scheduleRefresh() } }
        }, names.notification as CFString, nil, .deliverImmediately)
    }

    /// state.json is replaced atomically (rename), which is a write to its directory.
    private func watchStateDirectory() {
        let dir = safeMode.stateStore.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleRefresh() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        stateSource = source
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: Queries

    func tweak(_ id: String) -> SafeModeTweak? { catalog.tweak(id) }

    /// nil: unknown. Unmanifested dylibs can't be named in the key, so they count as unsupported.
    func supportLevel(_ tweakID: String) -> SafeModeSupport? {
        guard let t = catalog.tweak(tweakID) else { return nil }
        if !t.hasManifest { return .unsupported }
        return supportByTweak[tweakID] ?? nil
    }

    /// Whether the tweak honours its own entry in the key. nil: unknown.
    func supportsSafeMode(_ tweakID: String) -> Bool? { supportLevel(tweakID)?.honoursKey }

    /// Tweaks that keep loading whatever the key says.
    var tweaksIgnoringSafeMode: [SafeModeTweak] { catalog.tweaks.filter { supportLevel($0.tweakID) == .unsupported } }

    /// Tweaks built with an older DynjectHook: they honour their own entries but not the panic switch.
    var tweaksIgnoringPanic: [SafeModeTweak] { catalog.tweaks.filter { supportLevel($0.tweakID) == .perTweak } }

    var disabledCount: Int { snapshot.disabled.count }

    // MARK: Actions

    private func perform(_ success: String, _ body: () throws -> Void) {
        do {
            try body()
            message = (success, false)
        } catch {
            message = (error.localizedDescription, true)
        }
        refresh()
    }

    /// `configInjects`: whether the saved Dynject config injects the tweak's dylib into that app (nil: unknown).
    /// It decides what a re-enable means for a tweak that ignores Safe Mode, whose entry never stopped it.
    func reenable(_ item: SafeModeDisabledItem, appName: String? = nil, configInjects: Bool? = nil) {
        let name = displayName(item.tweakID)
        let target = item.bundleID == SafeModeNames.all ? "every app" : appName ?? item.bundleID
        do {
            let still = try safeMode.enable(tweakID: item.tweakID, bundleID: item.bundleID)
            let text: String
            if item.supportsSafeMode == false {
                text = "Removed \(name)'s Safe Mode entry for \(target). \(name) ignores Safe Mode, so the entry never stopped it: "
                    + (configInjects == false ? "the Dynject config still keeps it out of \(target)."
                                              : "it loads wherever the Dynject config injects it.")
            } else if !still.isEmpty {
                text = "Removed \(name)'s entry for \(target), but it still stays out because \(SafeModeStillOff.describe(still))."
            } else {
                text = "Re-enabled \(name) in \(target). Relaunch the app to load it again."
            }
            message = (text, false)
        } catch {
            message = (error.localizedDescription, true)
        }
        refresh()
    }

    func setPanic(_ on: Bool) {
        let old = tweaksIgnoringPanic.map(\.name)
        perform(on ? "Panic switch on: DynjectHook tweaks stay out of every app launched from now on."
                     + (old.isEmpty ? "" : " Built with an older DynjectHook, these still load: \(old.joined(separator: ", ")).")
                   : "Panic switch off. Apps launched from now on load their tweaks again.") {
            try safeMode.setPanic(on)
        }
    }

    func clearAll() {
        perform("Re-enabled everything and turned the panic switch off. Earlier crashes no longer count.") {
            try safeMode.clear()
        }
    }

    func updateSettings(_ body: (inout SafeModeSettings) -> Void) {
        do { try safeMode.updateSettings(body) } catch { message = (error.localizedDescription, true) }
        refresh()
    }

    /// One pass of the watcher over the reports folder, from Workbench (useful without the agent).
    func scanNow() {
        let current = catalog
        let scanner = SafeModeScanner(reportsDirectory: reportsDirectory, safeMode: safeMode,
                                      catalog: { current }, support: support, notifier: notifier)
        let r = scanner.scan()
        lastScan = r
        lastScanAt = Date()
        var text = "Checked \(r.examined.count) new report\(r.examined.count == 1 ? "" : "s"): "
            + "\(r.crashes.count) tweak-related crash record\(r.crashes.count == 1 ? "" : "s"), "
            + "\(r.disabled.count) disabled."
        if r.pending > 0 { text += " \(r.pending) too new to read yet; check again in a few seconds." }
        if r.retrying > 0 { text += " \(r.retrying) couldn't be acted on and will be checked again." }
        if !r.problems.isEmpty { text += " Problems: " + r.problems.joined(separator: "; ") }
        message = (text, !r.problems.isEmpty && r.examined.isEmpty)
        refresh()
    }

    var dwBinaryAvailable: Bool { FileManager.default.isExecutableFile(atPath: dwBinaryPath) }

    func installAgent() {
        guard dwBinaryAvailable else {
            message = ("No dw binary at \(dwBinaryPath). Build the app with scripts/build-app.sh, which bundles it.", true)
            return
        }
        do {
            let r = try agent.install(sourceBinary: dwBinaryPath, extraArguments: agentExtraArguments)
            message = ("Installed the watcher: \(r.plist)" + (isolated ? " (simulated launchctl: nothing was loaded)" : ""), false)
        } catch {
            message = ("Could not install the watcher: \(error.localizedDescription)", true)
        }
        refreshAgentStatus()
    }

    func uninstallAgent() {
        do {
            try agent.uninstall()
            message = ("Removed the watcher. Tweaks stay disabled where they are; new crashes are no longer handled.", false)
        } catch {
            message = ("Could not remove the watcher: \(error.localizedDescription)", true)
        }
        refreshAgentStatus()
    }

    func displayName(_ tweakID: String) -> String {
        if tweakID == SafeModeNames.all { return "Every DynjectHook tweak" }
        return catalog.tweak(tweakID)?.name ?? tweakID
    }
}
