import DynjectCore
import Foundation
import Observation

/// State behind the Bridge panel: the broker's LaunchAgent (local.dynject.bridge), whether its token is published,
/// and its recent decisions (Bridge/log.json, written by the broker). docs/bridge.md.
///
/// Live mode uses ~/Library/LaunchAgents, launchctl and the real token key (read; removed on Uninstall, like `dw bridge
/// agent uninstall`). When the environment isolates it (fixture mode, smoke tests, other manifests or reports), the
/// agent's files go under the isolation root with preview names, launchctl is simulated, the token lives in memory
/// and the log is the isolation root's.
@MainActor @Observable
final class BridgeModel {
    let agent: BridgeAgent
    let isolated: Bool
    let names: BridgeNames
    let logURL: URL
    let dwBinaryPath: String
    @ObservationIgnored let tokenStore: BridgeTokenStore
    /// Written into the preview agent's plist so a copy of it could never serve under the real names.
    let agentExtraArguments: [String]

    private(set) var agentStatus: LaunchAgentStatus?
    private(set) var tokenPublished = false
    /// Newest first.
    private(set) var entries: [BridgeLogEntry] = []
    private(set) var refreshedAt: Date?
    var message: (text: String, isError: Bool)?

    @ObservationIgnored private var observing = false

    init(env: AppEnvironment) {
        isolated = env.isolatesBridge
        names = env.bridgeNames
        logURL = env.bridgeLogURL
        dwBinaryPath = env.dwBinaryPath
        if isolated {
            agent = BridgeAgent(launchAgentsDirectory: env.launchAgentsDirectory, binDirectory: env.agentBinDirectory,
                                runner: SimulatedLaunchctlRunner(), label: names.service)
            tokenStore = MemoryBridgeTokenStore()
            agentExtraArguments = ["--service", names.service, "--token-key", names.tokenKey, "--version-key", names.versionKey,
                                   "--notification", names.notification, "--log-file", logURL.path]
        } else {
            agent = BridgeAgent(launchAgentsDirectory: env.launchAgentsDirectory, binDirectory: env.agentBinDirectory,
                                runner: SystemLaunchctlRunner())
            tokenStore = CFPreferencesBridgeTokenStore(names: names)
            agentExtraArguments = []
        }
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
    }

    func start() {
        if !observing && !isolated {
            observing = true
            let observer = Unmanaged.passUnretained(self).toOpaque()
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<BridgeModel>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { me.refresh() } }
            }, names.notification as CFString, nil, .deliverImmediately)
        }
        refresh()
        refreshAgentStatus()
    }

    /// Re-reads the log and the token (cheap).
    func refresh() {
        // The file can be edited by anyone; escape control and bidi characters again before showing it.
        entries = BridgeDecisionLog.load(logURL).reversed().map(BridgeLogText.clean)
        tokenPublished = tokenStore.token() != nil
        refreshedAt = Date()
    }

    func refreshAgentStatus() {
        let agent = self.agent
        Task.detached(priority: .utility) {
            let s = agent.status()
            await MainActor.run { self.agentStatus = s }
        }
    }

    var dwBinaryAvailable: Bool { FileManager.default.isExecutableFile(atPath: dwBinaryPath) }

    var deniedCount: Int { entries.filter { !$0.allowed }.reduce(0) { $0 + $1.count } }

    func entries(forTweak id: String) -> [BridgeLogEntry] { entries.filter { $0.tweak == id } }

    func installAgent() {
        guard dwBinaryAvailable else {
            message = ("No dw binary at \(dwBinaryPath). Build the app with scripts/build-app.sh, which bundles it.", true)
            return
        }
        do {
            let r = try agent.install(sourceBinary: dwBinaryPath, extraArguments: agentExtraArguments)
            message = ("Installed the bridge: \(r.plist)" + (isolated ? " (simulated launchctl: nothing was loaded)" : ""), false)
        } catch {
            message = ("Could not install the bridge: \(error.localizedDescription)", true)
        }
        refresh()
        refreshAgentStatus()
    }

    func uninstallAgent() {
        do {
            try agent.uninstall()
            // The token names a service that's gone; tweaks then report "not installed" without trying to connect.
            try tokenStore.clear()
            message = ("Removed the bridge. Tweaks' bridge requests now fail with \"not installed\".", false)
        } catch {
            message = ("Could not remove the bridge: \(error.localizedDescription)", true)
        }
        refresh()
        refreshAgentStatus()
    }
}
