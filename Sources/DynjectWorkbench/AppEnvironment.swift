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
    var smokeTestReportDirectory: String?
    /// Folders searched for tweak manifests (`-DWTweaksDir` replaces the defaults).
    var tweakDirectories: [String]
    /// `-DWTweaksDir` or `-DWSupportDir` was given: the manifests are not (only) the installed ones.
    var overridesTweakSources = false

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

    /// Reads `-DWConfigPath`, `-DWLogPath`, `-DWErrorLogPath`, `-DWAppRoots` (colon-separated), `-DWSupportDir`,
    /// `-DWTweaksDir` and `-DWSmokeTest <report-dir>` from the launch arguments.
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
            smokeTestReportDirectory: value("-DWSmokeTest"),
            tweakDirectories: tweakDirs,
            overridesTweakSources: value("-DWTweaksDir") != nil || value("-DWSupportDir") != nil
        )
    }
}

/// Used in fixture mode so a fixture can never trigger an administrator prompt.
struct RefusingExecutor: PrivilegedExecutor {
    func run(_ arguments: [String], prompt: String) throws -> String {
        throw WriteError.helperFailed("Fixture mode never asks for administrator rights. Make the fixture file writable.")
    }
}
