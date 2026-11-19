import AppKit
import DynjectCore
import Observation

enum SidebarSection: String, CaseIterable, Identifiable {
    case injection, tweaks, dylibs, config, plists, daemon
    var id: String { rawValue }

    var title: String {
        switch self {
        case .injection: return "Apps & Injection"
        case .tweaks: return "Tweaks"
        case .dylibs: return "Dylibs"
        case .config: return "Raw Config"
        case .plists: return "Plist Editor"
        case .daemon: return "Daemon"
        }
    }

    var icon: String {
        switch self {
        case .injection: return "square.stack.3d.down.right"
        case .tweaks: return "puzzlepiece.extension"
        case .dylibs: return "shippingbox"
        case .config: return "doc.plaintext"
        case .plists: return "list.bullet.indent"
        case .daemon: return "gearshape.2"
        }
    }
}

struct Banner: Identifiable, Equatable {
    enum Kind { case info, success, warning, error }
    let id = UUID()
    var kind: Kind
    var title: String
    var detail: String?
}

struct EditSummary: Equatable {
    var appName: String
    var dylib: String
    var enabled: Bool
    var changes: [ConfigChange]
    var notes: [String]
    var sideEffects: [AffectedApp]
}

/// Per-app, per-dylib status shown in the UI.
struct InjectionStatus {
    var pending: Bool          // working text differs from disk for this dylib/app
    var configured: Bool       // effective in the working config
    var savedConfigured: Bool  // effective in the on-disk config
    var running: Bool
    var inspected: Bool        // lsof could read the running process
    var loaded: Bool
}

@MainActor @Observable
final class WorkbenchModel {
    let env: AppEnvironment
    let restarter: DaemonRestarter
    let writer: ProtectedFileWriter
    let backups: BackupStore
    let associationStore: AssociationStore

    var section: SidebarSection = .injection
    var banner: Banner?

    // MARK: Config state
    private(set) var diskData: Data?
    private(set) var diskText = ""
    var workingText = "" { didSet { if workingText != oldValue { recomputeConfig() } } }
    private(set) var configLoadError: String?
    private(set) var workingDoc = ConfigDocument(text: "")
    private(set) var workingConfig = EffectiveConfig()
    private(set) var diskConfig = EffectiveConfig()
    private(set) var diagnostics: [ConfigDiagnostic] = []
    var lastEdit: EditSummary?
    var hasUnsavedConfig: Bool { workingText != diskText }
    var blockingErrors: [ConfigDiagnostic] { diagnostics.filter { $0.severity == .error } }

    // MARK: Apps
    private(set) var apps: [InstalledApp] = []
    private(set) var services: [String: ServiceName] = [:]
    private(set) var workingEvals: [String: AppEvaluation] = [:]
    private(set) var diskEvals: [String: AppEvaluation] = [:]
    private(set) var isScanning = false
    var searchText = ""
    var onlyInjected = false
    var selectedAppID: String?

    // MARK: Runtime
    private(set) var log: DynjectLogSnapshot?
    private(set) var daemon: DaemonStatus?
    private(set) var errorLogTail = ""
    private(set) var runningPIDs: [String: [Int32]] = [:]
    private(set) var loaded: [String: Set<String>] = [:]
    private(set) var inspected: Set<String> = []
    private(set) var runtimeCheckedAt: Date?
    private(set) var isRefreshingRuntime = false

    // MARK: Apply
    var showApplySheet = false
    private(set) var isWriting = false
    private(set) var lastOutcome: WriteOutcome?
    /// Running apps whose injection changed with the last save.
    private(set) var relaunchNeeded: [AffectedApp] = []

    // MARK: Plists
    private(set) var associations: [PlistAssociation] = []
    private(set) var plistDoc: PlistDocument?
    var plistText = "" { didSet { if plistText != oldValue { validatePlist() } } }
    private(set) var plistError: String?
    private(set) var plistLoadError: String?
    private(set) var lastPlistBackup: URL?

    // MARK: Tweaks
    let tweakBackend: TweakPrefsBackend
    private(set) var tweaks: [TweakManifest] = []
    private(set) var tweakIssues: [ManifestIssue] = []
    private(set) var tweakSettings: [String: TweakSettings] = [:]
    private(set) var tweakApplyStatus: [String: String] = [:]
    var selectedTweakID: String?
    @ObservationIgnored private var tweakPersistTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var tweakSnapshotsSaved: Set<String> = []

    init(env: AppEnvironment) {
        self.env = env
        tweakBackend = env.fixtureMode ? FileTweakBackend(path: env.tweakPrefsFile) : CFPreferencesTweakBackend()
        backups = BackupStore(root: env.supportDirectory.appendingPathComponent("Backups", isDirectory: true))
        associationStore = AssociationStore(url: env.supportDirectory.appendingPathComponent("associations.json"))
        if env.fixtureMode {
            restarter = SimulatedRestarter()
            writer = ProtectedFileWriter(backups: backups, executor: RefusingExecutor())
        } else {
            let exec = OsascriptExecutor()
            restarter = PrivilegedRestarter(executor: exec)
            writer = ProtectedFileWriter(backups: backups, executor: exec)
        }
        associations = associationStore.load()
        reloadConfig()
        loadTweaks()
    }

    // MARK: Loading

    func start() {
        scanApps()
        refreshRuntime()
    }

    func reloadConfig() {
        if let data = FileManager.default.contents(atPath: env.configPath) {
            diskData = data
            diskText = String(decoding: data, as: UTF8.self)
            configLoadError = nil
        } else {
            diskData = nil
            diskText = ""
            configLoadError = "Could not read \(env.configPath)."
        }
        diskConfig = EffectiveConfig(document: ConfigDocument(text: diskText))
        workingText = diskText
        recomputeConfig()
    }

    func scanApps() {
        isScanning = true
        let roots = env.appRoots
        Task.detached(priority: .userInitiated) {
            let found = AppDiscovery.scan(roots: roots)
            await MainActor.run {
                self.apps = found
                self.isScanning = false
                self.resolveServices()
            }
        }
    }

    func refreshRuntime() {
        isRefreshingRuntime = true
        // Match running apps to installed bundles by path.
        var pidsByPath: [String: [Int32]] = [:]
        for r in NSWorkspace.shared.runningApplications {
            guard let url = r.bundleURL else { continue }
            pidsByPath[url.resolvingSymlinksInPath().path, default: []].append(r.processIdentifier)
        }
        let apps = self.apps
        let dylibs = Array(Set(workingConfig.dylibPaths + diskConfig.dylibPaths))
        let env = self.env
        Task.detached(priority: .userInitiated) {
            var running: [String: [Int32]] = [:]
            for app in apps {
                let path = URL(fileURLWithPath: app.bundlePath).resolvingSymlinksInPath().path
                if let pids = pidsByPath[path] { running[app.id] = pids }
            }
            let byPID = LoadedImageInspector.inspect(pids: running.values.flatMap { $0 }, dylibs: dylibs)
            var loaded: [String: Set<String>] = [:]
            var inspected: Set<String> = []
            for (id, pids) in running {
                for pid in pids where byPID[pid] != nil {
                    inspected.insert(id)
                    loaded[id, default: []].formUnion(byPID[pid]!)
                }
            }
            let logText = DynjectLogParser.readTail(path: env.logPath)
            let snapshot = logText.map(DynjectLogParser.parse)
            let status = DaemonInspector.status(configPath: env.configPath)
            let errTail = DynjectLogParser.readTail(path: env.errorLogPath, maxBytes: 4000) ?? ""
            let (runningResult, loadedResult, inspectedResult) = (running, loaded, inspected)
            await MainActor.run {
                self.runningPIDs = runningResult
                self.loaded = loadedResult
                self.inspected = inspectedResult
                self.log = snapshot
                self.daemon = status
                self.errorLogTail = errTail
                self.runtimeCheckedAt = Date()
                self.isRefreshingRuntime = false
                self.resolveServices()
            }
        }
    }

    private func resolveServices() {
        var map: [String: ServiceName] = [:]
        for app in apps { map[app.id] = ServiceNameResolver.resolve(app, log: log) }
        services = map
        recomputeEvaluations()
    }

    private func recomputeConfig() {
        workingDoc = ConfigDocument(text: workingText)
        workingConfig = EffectiveConfig(document: workingDoc)
        diagnostics = ConfigValidator.diagnose(workingDoc)
        recomputeEvaluations()
    }

    private func recomputeEvaluations() {
        var w: [String: AppEvaluation] = [:], d: [String: AppEvaluation] = [:]
        for app in apps {
            let service = service(for: app).value
            w[app.id] = PolicyEvaluator.evaluate(app: app, service: service, config: workingConfig)
            d[app.id] = PolicyEvaluator.evaluate(app: app, service: service, config: diskConfig)
        }
        workingEvals = w
        diskEvals = d
    }

    // MARK: Queries

    func service(for app: InstalledApp) -> ServiceName {
        services[app.id] ?? ServiceNameResolver.resolve(app, log: log)
    }

    var targets: [InjectionTarget] {
        apps.map { InjectionTarget(app: $0, service: service(for: $0).value) }
    }

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedAppID } }

    var filteredApps: [InstalledApp] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return apps.filter { app in
            if onlyInjected, (workingEvals[app.id]?.injectedDylibs.isEmpty ?? true), loaded[app.id]?.isEmpty ?? true { return false }
            guard !q.isEmpty else { return true }
            return app.displayName.localizedCaseInsensitiveContains(q)
                || app.bundleID.localizedCaseInsensitiveContains(q)
                || app.executableName.localizedCaseInsensitiveContains(q)
        }
    }

    func status(_ app: InstalledApp, _ dylib: String) -> InjectionStatus {
        let configured = workingEvals[app.id]?.isInjected(dylib) ?? false
        let saved = diskEvals[app.id]?.isInjected(dylib) ?? false
        let running = runningPIDs[app.id] != nil
        return InjectionStatus(pending: configured != saved, configured: configured, savedConfigured: saved,
                               running: running, inspected: inspected.contains(app.id),
                               loaded: loaded[app.id]?.contains(dylib) ?? false)
    }

    /// Ordered steps the user still has to take for this app.
    func guidance(for app: InstalledApp) -> [String] {
        var steps: [String] = []
        let dylibs = Array(Set(workingConfig.dylibPaths + diskConfig.dylibPaths)).sorted()
        let statuses = dylibs.map { ($0, status(app, $0)) }
        if statuses.contains(where: { $0.1.pending }) {
            steps.append("Save the config. Your change is only in this window so far.")
        }
        if let d = daemon, d.needsRestart || statuses.contains(where: { $0.1.pending }) {
            if d.processes.isEmpty {
                steps.append("dynjectd is not running. Restart Dynject, or nothing gets injected.")
            } else if d.isDuplicated {
                steps.append("Restart Dynject: \(d.processes.count) dynjectd processes are running, each with the config it started with.")
            } else {
                steps.append("Restart Dynject. dynjectd reads its config only at startup.")
            }
        }
        let name = app.displayName
        if runningPIDs[app.id] != nil {
            let mismatch = statuses.filter { inspected.contains(app.id) && $0.1.configured != $0.1.loaded }
            if !mismatch.isEmpty {
                let names = mismatch.map { (($0.0 as NSString).lastPathComponent) + ($0.1.configured ? " (should load)" : " (should unload)") }
                steps.append("Quit and relaunch \(name): \(names.joined(separator: ", ")). Injection happens only at launch; nothing can be added to or removed from a running process.")
            } else if !steps.isEmpty {
                steps.append("Then quit and relaunch \(name). The running copy keeps the dylibs it launched with.")
            }
        } else if !steps.isEmpty || statuses.contains(where: { $0.1.configured }) {
            steps.append("\(name) isn't running. Changes apply the next time it launches.")
        }
        return steps
    }

    // MARK: Editing

    func setInjection(_ enabled: Bool, dylib: String, app: InstalledApp) {
        do {
            let target = InjectionTarget(app: app, service: service(for: app).value)
            let r = try ConfigEditor.setInjection(enabled, dylib: dylib, for: target, in: workingDoc, allTargets: targets)
            workingText = r.document.text
            lastEdit = EditSummary(appName: app.displayName, dylib: dylib, enabled: enabled,
                                   changes: r.changes, notes: r.notes, sideEffects: r.sideEffects)
            banner = nil
        } catch {
            banner = Banner(kind: .warning, title: "\(app.displayName) can't be changed automatically",
                            detail: error.localizedDescription)
        }
    }

    /// Adds a `dylib:<path>:deny` line to the working config (saved through the usual review sheet).
    func addDylib(_ path: String) {
        do {
            workingText = try ConfigEditor.addDylib(path, to: workingDoc).text
            banner = Banner(kind: .info, title: "Added \((path as NSString).lastPathComponent) (deny by default)",
                            detail: "Turn it on per app on the Apps & Injection page, then Review & Save.")
        } catch {
            banner = Banner(kind: .warning, title: "Can't add dylib", detail: error.localizedDescription)
        }
    }

    func discardConfigChanges() {
        workingText = diskText
        lastEdit = nil
    }

    /// Apps (any, running or not) whose injected set differs between disk and the working text.
    var pendingAppChanges: [AffectedApp] {
        ConfigEditor.affectedApps(from: ConfigDocument(text: diskText), to: workingDoc, targets: targets)
    }

    var configNeedsAdmin: Bool { !AtomicFile.canWriteDirectly(env.configPath) }

    func saveConfig(restart: Bool) {
        guard !isWriting else { return }
        guard blockingErrors.isEmpty else {
            banner = Banner(kind: .error, title: "Fix the errors first", detail: blockingErrors.map(\.message).joined(separator: "\n"))
            return
        }
        isWriting = true
        let data = Data(workingText.utf8)
        let expected = diskData
        let path = env.configPath
        let writer = self.writer
        let restarter: DaemonRestarter? = restart ? self.restarter : nil
        let changed = pendingAppChanges
        let running = runningPIDs
        Task.detached(priority: .userInitiated) {
            let result = Result { try writer.write(data, to: path, expectedCurrent: expected, category: "config", restartWith: restarter) }
            await MainActor.run {
                self.isWriting = false
                switch result {
                case let .success(outcome):
                    self.lastOutcome = outcome
                    self.lastEdit = nil
                    self.showApplySheet = false
                    self.relaunchNeeded = changed.filter { running[$0.app.id] != nil }
                    self.reloadConfig()
                    self.refreshRuntime()
                    var detail = "Backup: \(outcome.backup?.path ?? "none (new file)")"
                    if let r = outcome.restart {
                        detail += r.simulated ? "\nRestart simulated (fixture mode)." : "\ndynjectd before: \(r.before.map(String.init).joined(separator: " ")); after: \(r.after.map(String.init).joined(separator: " "))"
                    } else {
                        detail += "\ndynjectd was not restarted, so it still uses the previous config."
                    }
                    if !self.relaunchNeeded.isEmpty {
                        detail += "\nRelaunch to apply: " + self.relaunchNeeded.map(\.app.displayName).joined(separator: ", ")
                    }
                    self.banner = Banner(kind: .success, title: "Saved \(path)", detail: detail)
                case let .failure(error):
                    self.banner = Banner(kind: error as? WriteError == .cancelled ? .info : .error,
                                         title: "Config not saved", detail: error.localizedDescription)
                }
            }
        }
    }

    func restartDaemon() {
        guard !isWriting else { return }
        isWriting = true
        let restarter = self.restarter
        Task.detached(priority: .userInitiated) {
            let result = Result { try restarter.restart() }
            await MainActor.run {
                self.isWriting = false
                switch result {
                case let .success(r):
                    self.banner = Banner(kind: .success, title: r.simulated ? "Restart simulated" : "dynjectd restarted",
                                         detail: r.simulated ? r.transcript : "Before: \(r.before.map(String.init).joined(separator: " ")). Now running: \(r.after.map(String.init).joined(separator: " ")). Relaunch target apps to pick up the change.")
                case let .failure(error):
                    self.banner = Banner(kind: error as? WriteError == .cancelled ? .info : .error,
                                         title: "Restart failed", detail: error.localizedDescription)
                }
                self.refreshRuntime()
            }
        }
    }

    // MARK: Relaunch

    func relaunch(_ app: InstalledApp) {
        guard !env.fixtureMode else {
            banner = Banner(kind: .info, title: "Relaunch disabled in fixture mode")
            return
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        let url = URL(fileURLWithPath: app.bundlePath)
        running.forEach { $0.terminate() }
        Task {
            for _ in 0..<100 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if running.contains(where: { !$0.isTerminated }) {
                banner = Banner(kind: .warning, title: "\(app.displayName) did not quit",
                                detail: "It may be showing a save dialog. Quit it yourself, then open it again.")
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            relaunchNeeded.removeAll { $0.app.id == app.id }
            refreshRuntime()
        }
    }

    // MARK: Tweaks

    func loadTweaks() {
        let (manifests, issues) = TweakManifestLoader.load(directories: env.tweakDirectories)
        tweaks = manifests
        tweakIssues = issues
        var settings: [String: TweakSettings] = [:]
        for m in manifests { settings[m.id] = tweakSettings[m.id].flatMap { $0.manifest.sourcePath == m.sourcePath ? $0 : nil }
            ?? TweakSettings(manifest: m, backend: tweakBackend) }
        tweakSettings = settings
        if selectedTweakID == nil || !manifests.contains(where: { $0.id == selectedTweakID }) {
            selectedTweakID = manifests.first?.id
        }
    }

    var tweaksFolder: String { env.tweakDirectories.first ?? env.supportDirectory.appendingPathComponent("Tweaks").path }

    func tweaks(forDylib dylib: String) -> [TweakManifest] { tweaks.filter { $0.dylib == dylib } }

    /// Running apps that currently have this tweak's dylib loaded (confirmed with lsof).
    func appsWithTweakLoaded(_ m: TweakManifest) -> [InstalledApp] {
        apps.filter { loaded[$0.id]?.contains(m.dylib) ?? false }
    }

    /// Called after every settings change: publish ~0.3 s after the last change (sliders, typing).
    func tweakDidChange(_ id: String) {
        tweakPersistTasks[id]?.cancel()
        tweakPersistTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.persistTweak(id)
        }
    }

    func persistTweak(_ id: String) {
        guard let s = tweakSettings[id] else { return }
        // Keep the pre-session state on disk too, the first time this session changes the tweak.
        if !tweakSnapshotsSaved.contains(id), case let .some(.some(snap)) = s.sessionSnapshot {
            if let data = try? PropertyListSerialization.data(fromPropertyList: snap, format: .xml, options: 0) {
                _ = try? backups.backup(data, originalPath: "tweak-\(id).plist", category: "tweaks")
            }
            tweakSnapshotsSaved.insert(id)
        }
        do {
            try s.persist()
        } catch {
            tweakApplyStatus[id] = "Save failed: \(error.localizedDescription)"
            return
        }
        guard let cmd = s.manifest.applyCommand else {
            tweakApplyStatus[id] = "Saved \(Date().formatted(date: .omitted, time: .standard))"
            return
        }
        tweakApplyStatus[id] = "Saved; running apply command…"
        Task.detached {
            let r = ApplyCommandRunner.run(cmd)
            await MainActor.run {
                self.tweakApplyStatus[id] = r.ok ? "Saved and applied \(Date().formatted(date: .omitted, time: .standard))"
                                                 : "Saved, but the apply command failed: \(r.message)"
            }
        }
    }

    func revertTweak(_ id: String) {
        guard let s = tweakSettings[id] else { return }
        tweakPersistTasks[id]?.cancel()
        do {
            try s.revertSession()
            tweakApplyStatus[id] = "Reverted to how it was when this session started"
            if let cmd = s.manifest.applyCommand { Task.detached { _ = ApplyCommandRunner.run(cmd) } }
        } catch {
            tweakApplyStatus[id] = "Revert failed: \(error.localizedDescription)"
        }
    }

    func installedAppName(_ bundleID: String) -> String {
        apps.first { $0.bundleID == bundleID }?.displayName ?? bundleID
    }

    // MARK: Plists

    func openPlist(_ path: String) {
        do {
            let doc = try PlistDocument(path: path)
            plistDoc = doc
            plistLoadError = nil
            plistText = doc.initialXML
            lastPlistBackup = nil
            validatePlist()
        } catch {
            plistDoc = nil
            plistLoadError = error.localizedDescription
            plistText = ""
        }
    }

    func validatePlist() {
        guard plistDoc != nil else { plistError = nil; return }
        switch PlistDocument.validate(plistText) {
        case .success: plistError = nil
        case let .failure(e): plistError = e.localizedDescription
        }
    }

    var plistIsDirty: Bool {
        guard let doc = plistDoc else { return false }
        return !doc.isUnchanged(plistText)
    }

    func revertPlist() {
        if let doc = plistDoc { plistText = doc.initialXML }
    }

    func savePlist() {
        guard let doc = plistDoc else { return }
        do {
            let data = try doc.encoded(plistText)
            let outcome = try writer.write(data, to: doc.path, expectedCurrent: doc.originalData, category: "plists")
            lastPlistBackup = outcome.backup
            let reopened = try PlistDocument(path: doc.path)
            plistDoc = reopened
            plistText = reopened.initialXML
            banner = Banner(kind: .success, title: "Saved \((doc.path as NSString).lastPathComponent) (\(doc.format.rawValue))",
                            detail: "Backup: \(outcome.backup?.path ?? "none")" + (outcome.usedAdministratorRights ? "\nWritten with administrator rights." : ""))
        } catch {
            banner = Banner(kind: error as? WriteError == .cancelled ? .info : .error,
                            title: "Plist not saved", detail: error.localizedDescription)
        }
    }

    /// The running app that most likely owns this preferences file, if any.
    func runningOwner(ofPlist path: String) -> NSRunningApplication? {
        let domain = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return NSRunningApplication.runningApplications(withBundleIdentifier: domain).first
    }

    func isPreferencesFile(_ path: String) -> Bool {
        path.contains("/Library/Preferences/")
    }

    func associate(plist: String, dylib: String) {
        let item = PlistAssociation(dylibPath: dylib, plistPath: plist)
        guard !associations.contains(item) else { return }
        associations.append(item)
        persistAssociations()
    }

    func removeAssociation(_ item: PlistAssociation) {
        associations.removeAll { $0 == item }
        persistAssociations()
    }

    private func persistAssociations() {
        do { try associationStore.save(associations) } catch {
            banner = Banner(kind: .error, title: "Could not save associations", detail: error.localizedDescription)
        }
    }
}
