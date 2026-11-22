import Foundation

// `dw dev`: the decisions of the edit-build-test-install-relaunch loop, kept pure so they can be tested. The loop
// itself (watching files, running build.sh, the installer and respring, streaming the log) is in Sources/dw.

public enum DevLoop {
    /// What `dw dev` relaunches after an install.
    public enum Targets: Equatable, Sendable {
        /// These bundle IDs (from --for, or the tweak's DH_CTOR).
        case apps([String])
        /// DH_CTOR lists no apps: every app the config injects it into. --for picks the ones to relaunch.
        case everyApp
        /// The build doesn't say (no DH_CTOR marker, or not string literals).
        case unknown
    }

    public static func targets(explicit: [String], markers: [CtorMarker], tweakID: String?) -> Targets {
        if !explicit.isEmpty { return .apps(explicit) }
        let marker = markers.first { tweakID != nil && $0.tweakID == tweakID } ?? (markers.count == 1 ? markers[0] : nil)
        switch marker?.bundleIDs {
        case nil: return .unknown
        case let ids? where ids.isEmpty: return .everyApp
        case let ids?: return .apps(ids)
        }
    }

    /// Whether a change at `path` (absolute) inside the tweak `folder` should rebuild: sources, headers, the manifest,
    /// build scripts and the test host; not the build output, version control, editor and Finder litter, or docs.
    public static func isRelevant(_ path: String, folder: String) -> Bool {
        let root = (folder as NSString).standardizingPath
        let p = (path as NSString).standardizingPath
        guard p.hasPrefix(root + "/") else { return false }
        let rel = String(p.dropFirst(root.count + 1))
        let parts = rel.split(separator: "/").map(String.init)
        guard let name = parts.last, !name.isEmpty else { return false }
        if parts.dropLast().contains(where: { $0 == "build" || $0.hasPrefix(".") || $0 == "DerivedData" }) { return false }
        if parts.first == "build" { return false }
        if name.hasPrefix(".") || name.hasSuffix("~") || name.hasPrefix("#") || name.hasSuffix(".swp") || name.hasSuffix(".tmp") {
            return false
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if ["md", "txt", "png", "jpg", "log"].contains(ext) { return false }
        return true
    }

    /// How the tweak folder tests itself: testhost/run.sh, or `./build.sh test` when build.sh runs a test host
    /// (as `dw new` tweaks do), or nothing.
    public enum TestCommand: Equatable, Sendable {
        case runScript      // ./build.sh, then testhost/run.sh (which builds what it needs)
        case buildTest      // ./build.sh test
        case none
    }

    public static func testCommand(folder: String, fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                                   buildScript: String?) -> TestCommand {
        if fileExists((folder as NSString).appendingPathComponent("testhost/run.sh")) { return .runScript }
        if let s = buildScript, s.contains("= \"test\"") || s.contains("= test ]") { return .buildTest }
        return .none
    }

    /// What a test run said: passed or not (nil if it printed no verdict), its summary line, and the failed checks.
    public struct TestResult: Equatable, Sendable {
        public var passed: Bool?
        public var summary: String?
        public var failures: [String]
    }

    /// Reads the output of a test host: "N checks, all passed" / "N checks, FAILED" (dw new, the import host),
    /// "ALL PASSED" / "FAILED", "host: all checks passed"; failed checks are lines with "[FAIL]" or a leading "FAIL".
    public static func testResult(_ output: String) -> TestResult {
        var passed: Bool?
        var summary: String?
        var failures: [String] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains("[FAIL]") || line.hasPrefix("FAIL ") || line.hasPrefix("FAIL\t") { failures.append(line) }
            let lower = line.lowercased()
            if lower.hasSuffix("all passed") || lower == "all passed" || lower.hasSuffix("all checks passed") {
                if passed != false { passed = true }
                summary = line
            } else if lower.hasSuffix("failed") && (lower.contains("checks") || lower == "failed" || lower.hasPrefix("host:")) {
                passed = false
                summary = line
            }
        }
        if !failures.isEmpty { passed = false }
        return TestResult(passed: passed, summary: summary, failures: failures)
    }
}
