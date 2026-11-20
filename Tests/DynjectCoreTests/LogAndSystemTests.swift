@testable import DynjectCore
import XCTest

final class LogAndSystemTests: XCTestCase {
    func testParsesDaemonStartsAndEvents() {
        let snap = DynjectLogParser.parse(Fixtures.text("dynjectd-excerpt.log"))
        XCTAssertEqual(snap.starts.map(\.pid), [4654, 7237, 45044])
        XCTAssertEqual(snap.starts[1].dylibSummaries, ["/opt/dynject/lib/tweaks/libBrutalium.dylib (deny-all, 2 override(s))"])
        let match = snap.lastMatch(bundleID: "com.apple.finder", executable: "Finder", service: "com.apple.Finder")
        XCTAssertEqual(match?.service, "com.apple.Finder")
        XCTAssertEqual(snap.observedLaunchdServices["Finder"], "com.apple.Finder")
        XCTAssertTrue(snap.observedApplicationBundleIDs.contains("com.apple.TextEdit"))
        XCTAssertTrue(snap.observedApplicationBundleIDs.contains("com.example.Clerestory"))
        XCTAssertTrue(snap.events.contains { $0.outcome == "SKIP (system_daemon)" })
    }

    func testBundleIDFromService() {
        XCTAssertEqual(DynjectLogSnapshot.bundleID(fromService: "application.com.apple.TextEdit.1152921500311909930.1152921500311909935"),
                       "com.apple.TextEdit")
        XCTAssertEqual(DynjectLogSnapshot.bundleID(fromService: "application.com.example.Clerestory.6305789.6312238.D6C3C512-A657-4AB6-AAC7-E2571A9E4AC9"),
                       "com.example.Clerestory")
        XCTAssertEqual(DynjectLogSnapshot.bundleID(fromService: "application.com.tweak.brutalium.settings.6386441.6387817"),
                       "com.tweak.brutalium.settings")
        XCTAssertNil(DynjectLogSnapshot.bundleID(fromService: "com.apple.Finder"))
    }

    func testServiceNameResolution() {
        let snap = DynjectLogParser.parse(Fixtures.text("dynjectd-excerpt.log"))
        XCTAssertEqual(ServiceNameResolver.resolve(Apps.finder, log: snap), ServiceName("com.apple.Finder", source: .observed))
        XCTAssertEqual(ServiceNameResolver.resolve(Apps.finder, log: nil).source, .launchdLabel)
        XCTAssertEqual(ServiceNameResolver.resolve(Apps.textEdit, log: snap).source, .observed)
        XCTAssertEqual(ServiceNameResolver.resolve(Apps.notes, log: snap), ServiceName("application.com.apple.Notes.0.0", source: .predicted))
    }

    func testLsofParsing() {
        let out = "p45576\nfcwd\nn/\nftxt\nn/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder\nftxt\nn/opt/dynject/lib/tweaks/libBrutalium.dylib\np99\nftxt\nn/usr/lib/dyld\n"
        let parsed = LoadedImageInspector.parseLsof(out)
        XCTAssertEqual(parsed[45576]?.contains("/opt/dynject/lib/tweaks/libBrutalium.dylib"), true)
        XCTAssertEqual(parsed[99], ["/usr/lib/dyld"])
    }

    func testPSParsingFindsDuplicates() {
        // Captured from this machine.
        let ps = """
         7237     1 Thu Nov 19 02:04:52 2026     /opt/dynject/bin/dynjectd -c /opt/dynject/etc/dynjectd.conf -l /opt/dynject/log/dynjectd.log
        45044     1 Thu Nov 19 02:55:05 2026     /opt/dynject/bin/dynjectd -c /opt/dynject/etc/dynjectd.conf -l /opt/dynject/log/dynjectd.log
          500     1 Thu Nov 19 01:00:00 2026     /usr/bin/other
        """
        let procs = DaemonInspector.parsePS(ps, pids: [7237, 45044])
        XCTAssertEqual(procs.map(\.pid), [7237, 45044])
        XCTAssertNotNil(procs[0].started)
        XCTAssertEqual(procs[0].command, "/opt/dynject/bin/dynjectd -c /opt/dynject/etc/dynjectd.conf -l /opt/dynject/log/dynjectd.log")
        let configTime = DaemonInspector.lstartFormatter.date(from: "Thu Nov 19 02:55:00 2026")
        let status = DaemonStatus(processes: procs, job: nil, configModified: configTime)
        XCTAssertTrue(status.isDuplicated)
        XCTAssertEqual(status.staleProcesses.map(\.pid), [7237])
        XCTAssertTrue(status.needsRestart)
        // ps truncates to the second: a daemon restarted in the same second as the save is current.
        let restart = DaemonInspector.parsePS(" 78263     1 Thu Nov 19 18:49:39 2026     /opt/dynject/bin/dynjectd\n", pids: [78263])
        let saved = DaemonInspector.lstartFormatter.date(from: "Thu Nov 19 18:49:39 2026")!.addingTimeInterval(0.43)
        XCTAssertEqual(DaemonStatus(processes: restart, job: nil, configModified: saved).staleProcesses, [])
        XCTAssertEqual(DaemonStatus(processes: restart, job: nil, configModified: saved + 1).staleProcesses.map(\.pid), [78263])
    }

    func testLaunchctlPrintParsing() {
        let text = "system/com.dynject.dynjectd = {\n\tactive count = 0\n\tpath = /Library/LaunchDaemons/com.dynject.dynjectd.plist\n\ttype = LaunchDaemon\n\tstate = not running\n\n\tprogram = /opt/dynject/bin/dynject_loader\n\targuments = {\n\t\t/opt/dynject/bin/dynject_loader\n\t\t-d\n\t}\n\n\truns = 3\n\tlast exit code = 0\n\tresource coalition = {\n\t\tstate = active\n\t}\n}\n"
        let info = DaemonInspector.parseLaunchctlPrint(text)
        XCTAssertEqual(info.state, "not running")
        XCTAssertEqual(info.runs, 3)
        XCTAssertEqual(info.lastExitCode, "0")
        XCTAssertEqual(info.program, "/opt/dynject/bin/dynject_loader")
        XCTAssertEqual(info.arguments, ["/opt/dynject/bin/dynject_loader", "-d"])
    }

    func testAppDiscoveryReadsBundles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        func makeApp(_ rel: String, _ info: [String: Any]) throws {
            let contents = root.appendingPathComponent(rel).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try makeApp("Alpha.app", ["CFBundleIdentifier": "com.ex.alpha", "CFBundleExecutable": "AlphaBin", "CFBundleDisplayName": "Alpha Pro"])
        try makeApp("Utilities/Beta.app", ["CFBundleIdentifier": "com.ex.beta", "CFBundleExecutable": "Beta"])
        try makeApp("Broken.app", ["CFBundleExecutable": "NoID"])
        let apps = AppDiscovery.scan(roots: [root.path])
        XCTAssertEqual(apps.map(\.displayName), ["Alpha Pro", "Beta"])
        XCTAssertEqual(apps[0].executableName, "AlphaBin")
        XCTAssertTrue(apps[0].executablePath.hasSuffix("Alpha.app/Contents/MacOS/AlphaBin"))
        XCTAssertEqual(apps[1].bundleID, "com.ex.beta")
    }

    func testLineDiff() {
        let ops = LineDiff.diff("a\nb\nc", "a\nx\nc")
        XCTAssertEqual(ops, [.same("a"), .removed("b"), .added("x"), .same("c")])
    }
}
