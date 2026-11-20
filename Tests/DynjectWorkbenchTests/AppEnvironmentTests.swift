@testable import DynjectWorkbench
import DynjectCore
import XCTest

/// Which launch arguments keep the MenuLoader list away from the real `dynject.menuloader` key.
final class AppEnvironmentTests: XCTestCase {
    private func env(_ args: [String]) -> AppEnvironment { AppEnvironment.current(arguments: ["DynjectWorkbench"] + args) }

    func testNoArgumentsIsLiveAndPublishesToTheRealKey() {
        let e = env([])
        XCTAssertFalse(e.fixtureMode)
        XCTAssertFalse(e.overridesTweakSources)
        XCTAssertFalse(e.isolatesMenuLoader)
    }

    func testEachOverrideOfTheManifestSourcesIsolatesMenuLoader() {
        for args in [["-DWTweaksDir", "/tmp/dw-tweaks"], ["-DWSupportDir", "/tmp/dw-support"],
                     ["-DWConfigPath", "/tmp/dw.conf"], ["-DWSmokeTest", "/tmp/dw-report"]] {
            XCTAssertTrue(env(args).isolatesMenuLoader, "\(args[0]) must not publish to dynject.menuloader")
        }
    }

    func testTweaksDirAloneKeepsLiveConfigButIsolatesMenuLoader() {
        let e = env(["-DWTweaksDir", "/tmp/dw-tweaks"])
        XCTAssertFalse(e.fixtureMode, "the config stays live")
        XCTAssertEqual(e.tweakDirectories, ["/tmp/dw-tweaks"])
        XCTAssertTrue(e.isolatesMenuLoader)
        XCTAssertTrue(e.menuLoaderPreviewFile.hasSuffix("/Dynject Workbench/menuloader-preview.plist"))
    }

    func testSupportDirAloneIsolatesMenuLoaderIntoThatFolder() {
        let e = env(["-DWSupportDir", "/tmp/dw-support"])
        XCTAssertFalse(e.fixtureMode)
        XCTAssertTrue(e.isolatesMenuLoader)
        XCTAssertEqual(e.menuLoaderPreviewFile, "/tmp/dw-support/menuloader-preview.plist")
    }

    func testFlagWithoutValueIsIgnored() {
        XCTAssertFalse(env(["-DWTweaksDir"]).isolatesMenuLoader)
    }
}

/// Which launch arguments keep Safe Mode away from the real key, state.json, ~/Library/LaunchAgents and launchd.
final class SafeModeEnvironmentTests: XCTestCase {
    private func env(_ args: [String]) -> AppEnvironment { AppEnvironment.current(arguments: ["DynjectWorkbench"] + args) }

    func testLiveUsesTheRealLocations() {
        let e = env([])
        XCTAssertFalse(e.isolatesSafeMode)
        XCTAssertEqual(e.safeModeStateDirectory, SafeModeStateStore.defaultDirectory)
        XCTAssertEqual(e.launchAgentsDirectory, SafeModeAgent.defaultLaunchAgentsDirectory)
        XCTAssertEqual(e.agentBinDirectory, SafeModeAgent.defaultBinDirectory)
        XCTAssertEqual(e.safeModeReportsDirectory, SafeModeScanner.defaultReportsDirectory)
        XCTAssertEqual(e.tweakDylibDirectory, SafeModeCatalog.defaultDylibDirectory)
    }

    func testEveryOverrideIsolatesSafeModeUnderTheSupportFolder() {
        for args in [["-DWTweaksDir", "/tmp/dw-tweaks"], ["-DWSupportDir", "/tmp/dw-support"], ["-DWConfigPath", "/tmp/dw.conf"],
                     ["-DWSmokeTest", "/tmp/dw-report"], ["-DWReportsDir", "/tmp/dw-reports"], ["-DWTweakDylibDir", "/tmp/dw-dylibs"]] {
            let e = env(args + ["-DWSupportDir", "/tmp/dw-support"])
            XCTAssertTrue(e.isolatesSafeMode, "\(args[0]) must not touch the real Safe Mode")
            for p in [e.safeModeStateDirectory.path, e.launchAgentsDirectory.path, e.agentBinDirectory.path, e.safeModeKeyFile] {
                XCTAssertTrue(p.hasPrefix("/tmp/dw-support/"), "\(args[0]): \(p)")
            }
        }
        XCTAssertEqual(env(["-DWReportsDir", "/tmp/dw-reports"]).safeModeReportsDirectory, "/tmp/dw-reports")
        XCTAssertEqual(env(["-DWConfigPath", "/tmp/dw.conf", "-DWSupportDir", "/tmp/s"]).safeModeReportsDirectory,
                       "/tmp/s/DiagnosticReports", "isolated without a reports folder: an empty one, not the real one")
    }

    /// Without -DWSupportDir the support folder is the real one, which holds the real SafeMode/state.json and
    /// bin/dw: isolated files must go somewhere else.
    func testIsolatingFlagsWithoutASupportFolderNeverShareTheRealFiles() {
        let real = [SafeModeStateStore.defaultDirectory.standardizedFileURL.path, SafeModeAgent.defaultBinDirectory.standardizedFileURL.path,
                    SafeModeAgent.defaultLaunchAgentsDirectory.standardizedFileURL.path, SafeModeScanner.defaultReportsDirectory]
        for args in [["-DWTweaksDir", "/tmp/dw-tweaks"], ["-DWConfigPath", "/tmp/dw.conf"], ["-DWSmokeTest", "/tmp/dw-report"],
                     ["-DWReportsDir", "/tmp/dw-reports"], ["-DWTweakDylibDir", "/tmp/dw-dylibs"]] {
            let e = env(args)
            XCTAssertTrue(e.isolatesSafeMode, "\(args[0])")
            XCTAssertFalse(e.overridesSupportDirectory)
            let preview = e.supportDirectory.appendingPathComponent("SafeModePreview").path
            for p in [e.safeModeStateDirectory, e.agentBinDirectory, e.launchAgentsDirectory].map(\.standardizedFileURL.path)
                + [e.safeModeKeyFile, e.safeModeReportsDirectory] {
                XCTAssertFalse(real.contains(p), "\(args[0]) shares the real \(p)")
                if args[0] != "-DWReportsDir" || p != "/tmp/dw-reports" {
                    XCTAssertTrue(p.hasPrefix(preview + "/"), "\(args[0]): \(p)")
                }
            }
        }
    }

    /// Re-enable says what really happens: a tweak that ignores Safe Mode stays out through the config, and a
    /// row whose tweak is also off through "*" entries doesn't come back. Panic names older DynjectHook builds.
    @MainActor
    func testReenableAndPanicMessagesSayWhatStillHappens() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-sm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tweaks = dir.appendingPathComponent("Tweaks")
        try FileManager.default.createDirectory(at: tweaks, withIntermediateDirectories: true)
        let plain = dir.appendingPathComponent("libPlain.dylib"), old = dir.appendingPathComponent("libOld.dylib")
        try Data("no DynjectHook".utf8).write(to: plain)
        try Data("x\0dynject.safemode\0y".utf8).write(to: old)
        for (id, name, dylib) in [("com.example.plain", "Plain", plain), ("com.example.old", "Old", old)] {
            let m: [String: Any] = ["formatVersion": 1, "identifier": id, "name": name, "dylib": dylib.path]
            try PropertyListSerialization.data(fromPropertyList: m, format: .xml, options: 0)
                .write(to: tweaks.appendingPathComponent("\(name).workbench.plist"))
        }
        let e = env(["-DWConfigPath", dir.appendingPathComponent("dynjectd.conf").path, "-DWSupportDir", dir.path,
                     "-DWTweakDylibDir", dir.path])
        let sm = SafeModeModel(env: e, tweakBackend: FileTweakBackend(path: e.tweakPrefsFile))
        sm.manifests = TweakManifestLoader.load(directories: [tweaks.path]).manifests
        XCTAssertEqual(sm.tweaksIgnoringSafeMode.map(\.tweakID), ["com.example.plain"])
        XCTAssertEqual(sm.tweaksIgnoringPanic.map(\.tweakID), ["com.example.old"])

        try sm.safeMode.disable(tweakID: "com.example.plain", bundleID: "com.example.app")
        sm.refresh()
        let row = try XCTUnwrap(sm.snapshot.disabled.first)
        XCTAssertEqual(row.supportsSafeMode, false)
        sm.reenable(row, appName: "App", configInjects: false)
        XCTAssertTrue(sm.message?.text.contains("the Dynject config still keeps it out of App") ?? false, sm.message?.text ?? "")
        try sm.safeMode.disable(tweakID: "com.example.plain", bundleID: "com.example.app")
        sm.refresh()
        sm.reenable(try XCTUnwrap(sm.snapshot.disabled.first), appName: "App", configInjects: true)
        XCTAssertTrue(sm.message?.text.contains("loads wherever the Dynject config injects it") ?? false, sm.message?.text ?? "")

        try sm.safeMode.disable(tweakID: "com.example.old", bundleID: "com.example.app")
        try sm.safeMode.disable(tweakID: "*", bundleID: "com.example.app")
        sm.refresh()
        let oldRow = try XCTUnwrap(sm.snapshot.disabled.first { $0.tweakID == "com.example.old" })
        XCTAssertEqual(oldRow.alsoOffBecause, [.allTweaksInApp])
        sm.reenable(oldRow, appName: "App")
        XCTAssertTrue(sm.message?.text.contains("still stays out because every tweak is disabled in this app") ?? false,
                      sm.message?.text ?? "")
        XCTAssertEqual(sm.message?.isError, false)

        sm.setPanic(true)
        XCTAssertTrue(sm.message?.text.contains("older DynjectHook, these still load: Old") ?? false, sm.message?.text ?? "")
        sm.setPanic(false)
    }

    func testSimulatedLaunchctlTracksLoadState() {
        let r = SimulatedLaunchctlRunner()
        XCTAssertEqual(r.run(["print", "gui/501/x"]).status, 113)
        XCTAssertEqual(r.run(["bootstrap", "gui/501", "/tmp/x.plist"]).status, 0)
        let printed = r.run(["print", "gui/501/x"])
        XCTAssertEqual(printed.status, 0)
        XCTAssertEqual(SafeModeAgent.parsePrint(printed.output).state, "running")
        XCTAssertEqual(r.run(["bootout", "gui/501/x"]).status, 0)
        XCTAssertNotEqual(r.run(["print", "gui/501/x"]).status, 0)
    }

    @MainActor
    func testIsolatedModelWritesOnlyTheFixtureFileAndSupportFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-sm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeDW = dir.appendingPathComponent("dw")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: fakeDW)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDW.path)
        let e = env(["-DWConfigPath", dir.appendingPathComponent("dynjectd.conf").path, "-DWSupportDir", dir.path,
                     "-DWTweakDylibDir", dir.path, "-DWDwBinary", fakeDW.path])
        let backend = FileTweakBackend(path: e.tweakPrefsFile)
        let sm = SafeModeModel(env: e, tweakBackend: backend)
        XCTAssertTrue(sm.isolated)
        XCTAssertEqual(sm.names, .forDomain(SafeModeNames.testDomain))

        sm.setPanic(true)
        XCTAssertTrue(sm.snapshot.panic)
        XCTAssertEqual((backend.dictionary(forKey: SafeModeNames.productionKey)?["*"] as? [String]), ["*"])
        XCTAssertEqual(backend.posted, ["local.dynject.safemode.test.changed"])
        sm.setPanic(false)
        XCTAssertNil(backend.dictionary(forKey: SafeModeNames.productionKey))

        try sm.safeMode.disable(tweakID: "com.example.t", bundleID: "com.example.app")
        sm.refresh()
        let item = try XCTUnwrap(sm.snapshot.disabled.first)
        XCTAssertEqual(item.reason, .manual)
        sm.reenable(item)
        XCTAssertTrue(sm.snapshot.disabled.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("SafeMode/state.json").path))

        sm.installAgent()
        XCTAssertEqual(sm.message?.isError, false, sm.message?.text ?? "")
        let plist = dir.appendingPathComponent("LaunchAgents/\(SafeModeAgent.label).plist")
        let args = try XCTUnwrap((PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])?["ProgramArguments"] as? [String])
        XCTAssertEqual(args.first, dir.appendingPathComponent("bin/dw").path)
        XCTAssertTrue(args.contains(SafeModeNames.testDomain), "an isolated agent's plist never names the real domain")
        XCTAssertTrue((sm.agent.runner as? SimulatedLaunchctlRunner)?.loaded == true)
        sm.uninstallAgent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }
}
