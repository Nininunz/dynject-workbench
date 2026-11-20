import DynjectCore
import Foundation

/// Where the app reads and writes. Defaults are the live Dynject install. Overriding the config path
/// (`-DWConfigPath`) puts the app in fixture mode, where restarts are simulated and privilege escalation is
/// refused. Any override of where config, tweak manifests or support files come from also keeps the
/// MenuLoader list away from the real global key (`isolatesMenuLoader`).
struct AppEnvironment {
    static let liveConfigPath = "/opt/dynject/etc/dynjectd.conf"
    static let liveLogPath = "/opt/dynject/log/dynjectd.log"
    static let liveErrorLogPath = "/opt/dynject/log/dynjectd.error.log"

    var configPath: String
    var logPath: String
    var errorLogPath: String
    var appRoots: [String]
    var supportDirectory: URL
    /// `-DWSupportDir` was given (supportDirectory is not the real one).
    var overridesSupportDirectory = false
    var smokeTestReportDirectory: String?
    /// Folders searched for tweak manifests (`-DWTweaksDir` replaces the defaults).
    var tweakDirectories: [String]
    /// `-DWTweaksDir` or `-DWSupportDir` was given: the manifests are not (only) the installed ones.
    var overridesTweakSources = false
    /// Crash reports Safe Mode's "Check Reports Now" reads (`-DWReportsDir`).
    var reportsDirectoryOverride: String?
    /// Installed tweak dylibs Safe Mode lists (`-DWTweakDylibDir`; default /opt/dynject/lib/tweaks, read only).
    var tweakDylibDirectory: String = SafeModeCatalog.defaultDylibDirectory
    var overridesTweakDylibDirectory = false
    /// The `dw` binary the Safe Mode agent installs (`-DWDwBinary`; default: next to Workbench's executable).
    var dwBinaryOverride: String?
    /// Running apps the Respring sheet shows instead of the real ones (`-DWRespringFixture <json>`; see
    /// RespringFixture).
    var respringFixturePath: String?

    var fixtureMode: Bool { configPath != Self.liveConfigPath }

    /// Fixture mode keeps tweak settings in a plist in the support folder instead of the global domain.
    var tweakPrefsFile: String { supportDirectory.appendingPathComponent("tweak-prefs.plist").path }

    /// Fixture mode and smoke tests must never publish the MenuLoader list to the real global key, even if
    /// `-DWSmokeTest` is passed without a fixture config (SmokeTest refuses to run then, but the model has
    /// already loaded by that point). Neither may a launch that previews other manifests (`-DWTweaksDir`,
    /// `-DWSupportDir`): publishing replaces the whole list, so it would drop the installed tweaks' items
    /// from every injected app's Apple menu.
    var isolatesMenuLoader: Bool { fixtureMode || smokeTestReportDirectory != nil || overridesTweakSources }

    /// Where an isolated MenuLoader list goes when tweak settings are live (not in fixture mode).
    var menuLoaderPreviewFile: String { supportDirectory.appendingPathComponent("menuloader-preview.plist").path }

    /// Workbench's own MenuLoader preferences in fixture mode (live mode uses the app's user defaults).
    var menuLoaderSettingsFile: URL { supportDirectory.appendingPathComponent("menuloader-settings.json") }

    // MARK: Respring

    /// The Respring sheet never quits or opens a real app in fixture mode, in a smoke test, or with a respring
    /// fixture: it plans over made-up running apps and relaunches them with SimulatedAppController.
    var isolatesRespring: Bool { fixtureMode || smokeTestReportDirectory != nil || respringFixturePath != nil }

    // MARK: Safe Mode

    /// Safe Mode stays away from the real "dynject.safemode" key, the real state.json, ~/Library/LaunchAgents and
    /// launchd whenever MenuLoader is isolated, or when crash reports or tweak dylibs come from somewhere else
    /// (a scan of other reports must not disable tweaks for real). Then the key goes to a plist file, the
    /// notification name is the test one, state.json and the agent's plist and binary go under the support
    /// folder, and launchctl is simulated.
    var isolatesSafeMode: Bool { isolatesMenuLoader || reportsDirectoryOverride != nil || overridesTweakDylibDirectory }

    /// Where isolated Safe Mode files go: the support folder `-DWSupportDir` names, or, when an isolating flag
    /// (`-DWTweaksDir`, `-DWConfigPath`, `-DWReportsDir`, `-DWTweakDylibDir`) comes without it, a preview folder
    /// inside the real one. The real support folder itself holds the real SafeMode/state.json and bin/dw.
    var safeModeIsolationRoot: URL {
        overridesSupportDirectory ? supportDirectory : supportDirectory.appendingPathComponent("SafeModePreview", isDirectory: true)
    }

    /// Where an isolated "dynject.safemode" key goes when tweak settings are live (fixture mode shares the
    /// tweak-prefs file).
    var safeModeKeyFile: String { safeModeIsolationRoot.appendingPathComponent("safemode-prefs.plist").path }

    var safeModeStateDirectory: URL {
        isolatesSafeMode ? safeModeIsolationRoot.appendingPathComponent("SafeMode", isDirectory: true) : SafeModeStateStore.defaultDirectory
    }

    var safeModeReportsDirectory: String {
        reportsDirectoryOverride
            ?? (isolatesSafeMode ? safeModeIsolationRoot.appendingPathComponent("DiagnosticReports").path
                                 : SafeModeScanner.defaultReportsDirectory)
    }

    var launchAgentsDirectory: URL {
        isolatesSafeMode ? safeModeIsolationRoot.appendingPathComponent("LaunchAgents", isDirectory: true)
                         : SafeModeAgent.defaultLaunchAgentsDirectory
    }

    var agentBinDirectory: URL {
        isolatesSafeMode ? safeModeIsolationRoot.appendingPathComponent("bin", isDirectory: true) : SafeModeAgent.defaultBinDirectory
    }

    /// The bundled `dw` (Contents/MacOS/dw, put there by scripts/build-app.sh; in a SwiftPM build, the sibling
    /// product).
    var dwBinaryPath: String {
        dwBinaryOverride ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent().appendingPathComponent("dw").path
    }

    /// Reads `-DWConfigPath`, `-DWLogPath`, `-DWErrorLogPath`, `-DWAppRoots` (colon-separated), `-DWSupportDir`,
    /// `-DWTweaksDir`, `-DWReportsDir`, `-DWTweakDylibDir`, `-DWDwBinary`, `-DWRespringFixture` and `-DWSmokeTest <report-dir>`
    /// from the launch arguments.
    static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppEnvironment {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let support = value("-DWSupportDir").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Dynject Workbench", isDirectory: true)
        let configPath = value("-DWConfigPath") ?? liveConfigPath
        let tweakDirs = value("-DWTweaksDir").map { [$0] }
            ?? (configPath == liveConfigPath ? TweakManifestLoader.defaultDirectories(supportDirectory: support)
                                             : [support.appendingPathComponent("Tweaks").path])
        return AppEnvironment(
            configPath: configPath,
            logPath: value("-DWLogPath") ?? liveLogPath,
            errorLogPath: value("-DWErrorLogPath") ?? liveErrorLogPath,
            appRoots: value("-DWAppRoots")?.split(separator: ":").map(String.init) ?? AppDiscovery.defaultRoots,
            supportDirectory: support,
            overridesSupportDirectory: value("-DWSupportDir") != nil,
            smokeTestReportDirectory: value("-DWSmokeTest"),
            tweakDirectories: tweakDirs,
            overridesTweakSources: value("-DWTweaksDir") != nil || value("-DWSupportDir") != nil,
            reportsDirectoryOverride: value("-DWReportsDir"),
            tweakDylibDirectory: value("-DWTweakDylibDir") ?? SafeModeCatalog.defaultDylibDirectory,
            overridesTweakDylibDirectory: value("-DWTweakDylibDir") != nil,
            dwBinaryOverride: value("-DWDwBinary"),
            respringFixturePath: value("-DWRespringFixture")
        )
    }
}

/// Used in fixture mode so a fixture can never trigger an administrator prompt.
struct RefusingExecutor: PrivilegedExecutor {
    func run(_ arguments: [String], prompt: String) throws -> String {
        throw WriteError.helperFailed("Fixture mode never asks for administrator rights. Make the fixture file writable.")
    }
}

/// launchctl for an isolated Safe Mode agent: nothing reaches launchd. It remembers bootstrap and bootout, so
/// the panel shows the agent as loaded and running after Install, like the real thing.
final class SimulatedLaunchctlRunner: LaunchctlRunner {
    private(set) var calls: [[String]] = []
    private(set) var loaded = false

    func run(_ arguments: [String]) -> (status: Int32, output: String) {
        calls.append(arguments)
        switch arguments.first {
        case "bootstrap":
            loaded = true
            return (0, "")
        case "bootout":
            defer { loaded = false }
            return loaded ? (0, "") : (3, "Boot-out failed: 3: No such process (simulated)")
        case "print":
            return loaded ? (0, "\(arguments.last ?? "") = {\n\tstate = running\n\tpid = 4242\n\tlast exit code = (never exited)\n}\n")
                          : (113, "Could not find service (simulated)")
        default:
            return (0, "")
        }
    }
}
