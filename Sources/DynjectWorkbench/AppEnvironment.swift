import DynjectCore
import Foundation

/// Where the app reads and writes. Defaults are the live Dynject install; any override puts the
/// app in fixture mode, where restarts are simulated and privilege escalation is refused.
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

    var fixtureMode: Bool { configPath != Self.liveConfigPath }

    /// Reads `-DWConfigPath`, `-DWLogPath`, `-DWAppRoots` (colon-separated), `-DWSupportDir`,
    /// and `-DWSmokeTest <report-dir>` from the launch arguments.
    static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppEnvironment {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let support = value("-DWSupportDir").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Dynject Workbench", isDirectory: true)
        return AppEnvironment(
            configPath: value("-DWConfigPath") ?? liveConfigPath,
            logPath: value("-DWLogPath") ?? liveLogPath,
            errorLogPath: value("-DWErrorLogPath") ?? liveErrorLogPath,
            appRoots: value("-DWAppRoots")?.split(separator: ":").map(String.init) ?? AppDiscovery.defaultRoots,
            supportDirectory: support,
            smokeTestReportDirectory: value("-DWSmokeTest")
        )
    }
}

/// Used in fixture mode so a fixture can never trigger an administrator prompt.
struct RefusingExecutor: PrivilegedExecutor {
    func run(_ arguments: [String], prompt: String) throws -> String {
        throw WriteError.helperFailed("Fixture mode never asks for administrator rights. Make the fixture file writable.")
    }
}
