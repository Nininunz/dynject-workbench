@testable import DynjectCore
import XCTest

/// A minimal Mach-O: one 64-bit header per slice (dylib unless `fileType` says otherwise), optionally with an
/// LC_CODE_SIGNATURE load command; universal when there is more than one slice.
enum FakeMachO {
    static let x86_64: (UInt32, UInt32) = (0x0100_0007, 3)
    static let arm64: (UInt32, UInt32) = (0x0100_000C, 0)
    static let arm64e: (UInt32, UInt32) = (0x0100_000C, 0x8000_0002)

    static func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
    static func be(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }

    static func slice(_ cpu: (UInt32, UInt32), fileType: UInt32 = 6, signed: Bool = true) -> [UInt8] {
        var b = le(0xFEED_FACF) + le(cpu.0) + le(cpu.1) + le(fileType) + le(signed ? 1 : 0) + le(signed ? 16 : 0) + le(0) + le(0)
        if signed { b += le(0x1D) + le(16) + le(0) + le(0) }
        return b
    }

    static func make(_ cpus: [(UInt32, UInt32)], fileType: UInt32 = 6, signed: Bool = true, tag: String = "") -> Data {
        if cpus.count == 1 { return Data(slice(cpus[0], fileType: fileType, signed: signed) + Array(tag.utf8)) }
        var out = be(0xCAFE_BABE) + be(UInt32(cpus.count))
        for (i, c) in cpus.enumerated() { out += be(c.0) + be(c.1) + be(UInt32(4096 * (i + 1))) + be(64) + be(12) }
        for (i, c) in cpus.enumerated() {
            out += [UInt8](repeating: 0, count: 4096 * (i + 1) - out.count)
            out += slice(c, fileType: fileType, signed: signed)
        }
        return Data(out + Array(tag.utf8))
    }

    static var universal: Data { make([x86_64, arm64, arm64e]) }
}

/// Runs the real helper script as the current user for the file operations; a trailing "restart" is stripped
/// (never runs launchctl) and answered with a made-up PID. Counts invocations (= administrator prompts).
final class FileOnlyHelperExecutor: PrivilegedExecutor, @unchecked Sendable {
    var calls: [[String]] = []
    let tweaksDirectory: String
    init(tweaksDirectory: String) { self.tweaksDirectory = tweaksDirectory }

    func run(_ arguments: [String], prompt: String) throws -> String {
        calls.append(arguments)
        var args = arguments
        let restart = args.last == "restart"
        if restart { args.removeLast() }
        let out = try LocalShellExecutor(environment: ["DW_TEST_TWEAKS_DIR": tweaksDirectory]).run(args, prompt: prompt)
        return out + (restart ? "DW running-before 1\nDW running-after 4242\n" : "")
    }
}

final class TweakInstallerTests: XCTestCase {
    var root: URL!
    var src: URL!
    var loc: TweakLocations!
    let template = try! TweakTemplate(name: "MyTweak", identifier: "local.mytweak")
    var installPath: String { template.installPath }

    override func setUpWithError() throws {
        let tmp = try temporaryDirectory()
        root = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)!))
        loc = .sandbox(root: root.appendingPathComponent("engine"))
        for d in [loc.dylibFileDirectory, (loc.configPath as NSString).deletingLastPathComponent] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        try Fixtures.text("live.conf").write(toFile: loc.configPath, atomically: true, encoding: .utf8)
        src = root.appendingPathComponent("MyTweak")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("build"), withIntermediateDirectories: true)
        try template.manifest.write(to: src.appendingPathComponent("MyTweak.workbench.plist"), atomically: true, encoding: .utf8)
        try FakeMachO.universal.write(to: src.appendingPathComponent("build/libMyTweak.dylib"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    var config: String { (try? String(contentsOfFile: loc.configPath, encoding: .utf8)) ?? "" }
    var backups: BackupStore { BackupStore(root: root.appendingPathComponent("Backups")) }
    func writer(_ exec: PrivilegedExecutor = RecordingExecutor()) -> ProtectedFileWriter { ProtectedFileWriter(backups: backups, executor: exec) }

    func planInstall(_ ids: [String] = ["com.apple.TextEdit"], path: String? = nil, dylib: String? = nil) throws -> TweakInstallPlan {
        let source = try TweakSource.locate(path ?? src.path, dylib: dylib)
        return try TweakInstaller.plan(source: source, enableFor: ids, targets: Apps.targets(), locations: loc)
    }

    // MARK: Install

    func testInstallCopiesDeclaresEnablesAndRestartsOnce() throws {
        let plan = try planInstall()
        XCTAssertEqual(plan.dylibAction, .create)
        XCTAssertEqual(plan.architectures, ["x86_64", "arm64", "arm64e"])
        XCTAssertTrue(plan.declares)
        XCTAssertEqual(plan.enabledFor.map(\.bundleID), ["com.apple.TextEdit"])
        XCTAssertTrue(plan.warnings.isEmpty, "\(plan.warnings)")
        XCTAssertTrue(plan.restartsDaemon)
        XCTAssertTrue(plan.summary.contains("  + dylib:\(installPath):deny"), "\(plan.summary)")

        let exec = RecordingExecutor(), sim = SimulatedRestarter()
        let result = try TweakInstaller.execute(plan, writer: writer(exec), restarter: sim)
        XCTAssertTrue(exec.calls.isEmpty, "everything is writable here")
        XCTAssertEqual(sim.count, 1)
        XCTAssertEqual(result.outcome?.restart?.simulated, true)
        XCTAssertEqual(FileManager.default.contents(atPath: loc.dylibFileDirectory + "/libMyTweak.dylib"), FakeMachO.universal)
        let added = changedLines(Fixtures.text("live.conf"), config).added
        XCTAssertEqual(added, ["dylib:\(installPath):deny", "dylib-override:\(installPath):allow:com.apple.TextEdit", "allow:TextEdit"])
        XCTAssertTrue(ConfigValidator.diagnose(ConfigDocument(text: config)).filter { $0.severity == .error }.isEmpty)
        XCTAssertTrue(result.manifestWritten)
        XCTAssertEqual(FileManager.default.contents(atPath: loc.manifestsDirectory + "/MyTweak.workbench.plist"), Data(template.manifest.utf8))
        XCTAssertEqual(result.outcome?.backups.keys.sorted(), [loc.configPath])

        // Again: nothing to do, no restart.
        let again = try planInstall()
        XCTAssertTrue(again.changesNothing)
        XCTAssertEqual(again.alreadyEnabledFor.map(\.bundleID), ["com.apple.TextEdit"])
    }

    // MARK: Extensions (extensionsApp)

    /// A fake app with one extension, at src/build/MyTweak.app; the manifest names it.
    func addExtensionsApp(tag: String = "1") throws {
        let appex = src.appendingPathComponent("build/MyTweak.app/Contents/Extensions/Tweaks.appex/Contents")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        try Data("appex \(tag)".utf8).write(to: appex.appendingPathComponent("Info.plist"))
        let manifest = template.manifest.replacingOccurrences(
            of: "<key>identifier</key>", with: "<key>extensionsApp</key><string>build/MyTweak.app</string>\n\t<key>identifier</key>")
        XCTAssertNotEqual(manifest, template.manifest)
        try manifest.write(to: src.appendingPathComponent("MyTweak.workbench.plist"), atomically: true, encoding: .utf8)
    }

    final class Recorder: @unchecked Sendable {
        var calls: [String] = []
        var registrar: ExtensionRegistrar {
            ExtensionRegistrar(register: { self.calls.append("+ " + ($0 as NSString).lastPathComponent) },
                               unregister: { self.calls.append("- " + ($0 as NSString).lastPathComponent) })
        }
    }

    func testExtensionsAppIsCopiedRegisteredReplacedAndRemoved() throws {
        try addExtensionsApp()
        let installed = (loc.extensionsDirectory as NSString).appendingPathComponent("MyTweak.app")
        let plan = try planInstall()
        XCTAssertEqual(plan.extensionsAppDestination, installed)
        XCTAssertEqual(plan.extensionsAction, .create)
        XCTAssertEqual(plan.extensionNames, ["Tweaks.appex"])
        XCTAssertTrue(plan.summary.contains { $0.hasPrefix("Copy ") && $0.contains("register its extensions (Tweaks.appex)") }, "\(plan.summary)")

        let rec = Recorder()
        let result = try TweakInstaller.execute(plan, writer: writer(), restarter: SimulatedRestarter(), registrar: rec.registrar)
        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(result.extensionsRegistered, [installed + "/Contents/Extensions/Tweaks.appex"])
        XCTAssertEqual(rec.calls, ["+ Tweaks.appex"])
        XCTAssertNotNil(TweakExtensions.digest(installed))

        // Same build: nothing to do. A new build: unregistered, replaced, registered again.
        XCTAssertTrue(try planInstall().changesNothing)
        try addExtensionsApp(tag: "2")
        let again = try planInstall()
        XCTAssertEqual(again.extensionsAction, .replace)
        _ = try TweakInstaller.execute(again, writer: writer(), restarter: SimulatedRestarter(), registrar: rec.registrar)
        XCTAssertEqual(rec.calls, ["+ Tweaks.appex", "- Tweaks.appex", "+ Tweaks.appex"])
        XCTAssertEqual(TweakExtensions.digest(installed), TweakExtensions.digest(src.appendingPathComponent("build/MyTweak.app").path))

        let uninstall = try TweakInstaller.planUninstall("local.mytweak", keepFile: false, locations: loc, safeMode: nil)
        XCTAssertEqual(uninstall.extensionsAppToRemove, installed)
        XCTAssertTrue(uninstall.summary.contains("Unregister the extensions in \(installed) and delete it"), "\(uninstall.summary)")
        let removed = try TweakInstaller.executeUninstall(uninstall, writer: writer(), restarter: SimulatedRestarter(), safeMode: nil,
                                                          registrar: rec.registrar)
        XCTAssertEqual(removed.extensionsUnregistered.map { ($0 as NSString).lastPathComponent }, ["Tweaks.appex"])
        XCTAssertEqual(rec.calls.last, "- Tweaks.appex")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed))
    }

    func testExtensionsAppMustBeBuiltAndInsideTheFolder() throws {
        try addExtensionsApp()
        try FileManager.default.removeItem(at: src.appendingPathComponent("build/MyTweak.app"))
        XCTAssertThrowsError(try planInstall()) { XCTAssertTrue("\($0.localizedDescription)".contains("Build it first"), "\($0)") }
        for bad in ["/Applications/X.app", "../X.app", "build/X.bundle"] {
            let text = template.manifest.replacingOccurrences(
                of: "<key>identifier</key>", with: "<key>extensionsApp</key><string>\(bad)</string><key>identifier</key>")
            let (m, issues) = TweakManifestParser.parse(data: Data(text.utf8), path: "/x/MyTweak.workbench.plist", fileExists: { _ in true })
            XCTAssertNil(m?.extensionsApp, bad)
            XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.contains("extensionsApp") }, bad)
        }
    }

    func testFailedRestartAfterTheWritesStillInstallsTheManifestAndSaysSo() throws {
        // Live, 2026-11-19: dynject_loader exited with "amfid not found", so the restart failed after the dylib
        // and config were written, and the manifest step was skipped.
        struct FailingRestarter: DaemonRestarter {
            var isLive: Bool { false }
            func restart() throws -> RestartReport { throw WriteError.helperFailed("dynjectd did not start") }
        }
        let plan = try planInstall()
        XCTAssertThrowsError(try TweakInstaller.execute(plan, writer: writer(), restarter: FailingRestarter())) { error in
            guard case TweakInstallError.installedButNotRestarted = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains("Workbench → Daemon"), error.localizedDescription)
        }
        XCTAssertEqual(FileManager.default.contents(atPath: loc.dylibFileDirectory + "/libMyTweak.dylib"), FakeMachO.universal)
        XCTAssertTrue(config.contains("dylib:\(installPath):deny"))
        XCTAssertEqual(FileManager.default.contents(atPath: loc.manifestsDirectory + "/MyTweak.workbench.plist"), Data(template.manifest.utf8))
    }

    func testReinstallAfterRebuildReplacesOnlyTheDylibWithoutRestart() throws {
        _ = try TweakInstaller.execute(try planInstall(), writer: writer(), restarter: SimulatedRestarter())
        let configBefore = config
        let rebuilt = FakeMachO.make([FakeMachO.x86_64, FakeMachO.arm64, FakeMachO.arm64e], tag: "v2")
        try rebuilt.write(to: src.appendingPathComponent("build/libMyTweak.dylib"))

        let plan = try planInstall([])
        XCTAssertEqual(plan.dylibAction, .replace)
        XCTAssertNil(plan.configNew)
        XCTAssertEqual(plan.manifestAction, .unchanged)
        let sim = SimulatedRestarter()
        let result = try TweakInstaller.execute(plan, writer: writer(), restarter: sim)
        XCTAssertEqual(sim.count, 0)
        XCTAssertEqual(config, configBefore)
        let dylib = loc.dylibFileDirectory + "/libMyTweak.dylib"
        XCTAssertEqual(FileManager.default.contents(atPath: dylib), rebuilt)
        XCTAssertEqual(try Data(contentsOf: result.outcome!.backups[dylib]!), FakeMachO.universal)
    }

    func testProtectedInstallAndUninstallTakeOneHelperInvocationEach() throws {
        // A read-only config (like the live root-owned one) sends every change through the helper script, which
        // runs here as the current user and can still replace it.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: loc.configPath)
        XCTAssertFalse(AtomicFile.canWriteDirectly(loc.configPath))
        let exec = FileOnlyHelperExecutor(tweaksDirectory: loc.dylibFileDirectory)
        let restarter = PrivilegedRestarter(executor: exec)
        let result = try TweakInstaller.execute(try planInstall(), writer: writer(exec), restarter: restarter)
        XCTAssertEqual(exec.calls.count, 1)
        XCTAssertEqual(exec.calls[0].filter { $0 == "install" }.count, 2)
        XCTAssertEqual(exec.calls[0].last, "restart")
        XCTAssertEqual(exec.calls[0][1], loc.dylibFileDirectory + "/libMyTweak.dylib", "the dylib goes in before the config names it")
        XCTAssertEqual(result.outcome?.usedAdministratorRights, true)
        XCTAssertEqual(result.outcome?.restart?.after, [4242])
        XCTAssertEqual(FileManager.default.contents(atPath: loc.dylibFileDirectory + "/libMyTweak.dylib"), FakeMachO.universal)
        XCTAssertTrue(config.contains("dylib:\(installPath):deny"))

        let plan = try TweakInstaller.planUninstall("local.mytweak", keepFile: false, locations: loc, safeMode: nil)
        _ = try TweakInstaller.executeUninstall(plan, writer: writer(exec), restarter: restarter, safeMode: nil)
        XCTAssertEqual(exec.calls.count, 2)
        XCTAssertEqual(Array(exec.calls[1].prefix(1)), ["install"])
        XCTAssertTrue(exec.calls[1].contains("remove"))
        XCTAssertEqual(exec.calls[1].last, "restart")
        XCTAssertFalse(FileManager.default.fileExists(atPath: loc.dylibFileDirectory + "/libMyTweak.dylib"))
        XCTAssertFalse(config.contains("libMyTweak"))
    }

    /// The allow:<executable> rule an install added for an app outside the Applications folders goes with the
    /// tweak, unless --keep-rules, or unless another dylib now reaches that app through it (then the plan says so).
    func testUninstallRemovesTheAllowRuleItsInstallAdded() throws {
        let before = config
        let plan = try planInstall(["com.example.tool"])
        XCTAssertTrue(plan.notes.contains { $0.contains("Added allow:Tool") }, "\(plan.notes)")
        _ = try TweakInstaller.execute(plan, writer: writer(), restarter: SimulatedRestarter())
        XCTAssertTrue(config.contains("allow:Tool\n"))

        let kept = try TweakInstaller.planUninstall("local.mytweak", keepFile: true, locations: loc, safeMode: nil,
                                                    targets: Apps.targets(), keepRules: true)
        XCTAssertFalse(kept.removedConfigLines.contains("allow:Tool"))
        XCTAssertTrue(kept.notes.contains { $0.hasPrefix("Keeping allow:Tool (--keep-rules)") }, "\(kept.notes)")
        XCTAssertNil(try TweakInstaller.planUninstall("local.mytweak", keepFile: true, locations: loc, safeMode: nil)
                        .removedConfigLines.first { $0.hasPrefix("allow:") }, "without targets no rule is touched")

        let un = try TweakInstaller.planUninstall("local.mytweak", keepFile: true, locations: loc, safeMode: nil,
                                                  targets: Apps.targets())
        XCTAssertTrue(un.removedConfigLines.contains("allow:Tool"), "\(un.removedConfigLines)")
        XCTAssertTrue(un.notes.contains { $0.hasPrefix("allow:Tool goes too") }, "\(un.notes)")
        _ = try TweakInstaller.executeUninstall(un, writer: writer(), restarter: SimulatedRestarter(), safeMode: nil)
        XCTAssertEqual(config, before, "install then uninstall leaves the config as it was")

        // A dylib that injects everywhere by default now reaches Tool through the rule: it stays, and why.
        try (before + "dylib:/opt/dynject/lib/tweaks/libEverywhere.dylib:allow\n").write(toFile: loc.configPath, atomically: true, encoding: .utf8)
        _ = try TweakInstaller.execute(try planInstall(["com.example.tool"]), writer: writer(), restarter: SimulatedRestarter())
        let shared = try TweakInstaller.planUninstall("local.mytweak", keepFile: true, locations: loc, safeMode: nil,
                                                      targets: Apps.targets())
        XCTAssertFalse(shared.removedConfigLines.contains("allow:Tool"))
        XCTAssertTrue(shared.notes.contains { $0.hasPrefix("Keeping allow:Tool: libEverywhere.dylib still reach") }, "\(shared.notes)")

        // A rule that changes nothing (TextEdit passes ui_apps anyway) is the user's; uninstall leaves it alone.
        try (before.replacingOccurrences(of: "ui_apps:no", with: "ui_apps:yes") + "allow:TextEdit\n")
            .write(toFile: loc.configPath, atomically: true, encoding: .utf8)
        _ = try TweakInstaller.execute(try planInstall(["com.apple.TextEdit"]), writer: writer(), restarter: SimulatedRestarter())
        let redundant = try TweakInstaller.planUninstall("local.mytweak", keepFile: true, locations: loc, safeMode: nil,
                                                         targets: Apps.targets())
        XCTAssertFalse(redundant.removedConfigLines.contains("allow:TextEdit"), "\(redundant.removedConfigLines)")
        XCTAssertFalse(redundant.notes.contains { $0.contains("allow:TextEdit") }, "\(redundant.notes)")
    }

    func testInstallRefusals() throws {
        func refused(_ body: () throws -> Any, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try body(), file: file, line: line) { error in
                XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription, file: file, line: line)
            }
        }
        let dylib = src.appendingPathComponent("build/libMyTweak.dylib")
        refused({ try self.planInstall(["com.example.nope"]) }, "No installed app has the bundle ID com.example.nope")

        try FakeMachO.make([FakeMachO.x86_64, FakeMachO.arm64]).write(to: dylib)
        refused({ try self.planInstall() }, "no arm64e slice")
        try FakeMachO.make([FakeMachO.arm64e], fileType: 2).write(to: dylib)
        refused({ try self.planInstall() }, "not a dylib")
        try Data("#!/bin/sh\n".utf8).write(to: dylib)
        refused({ try self.planInstall() }, "not a 64-bit Mach-O")
        try FileManager.default.removeItem(at: dylib)
        refused({ try self.planInstall() }, "Build it first")
        try FakeMachO.universal.write(to: dylib)

        let manifest = src.appendingPathComponent("MyTweak.workbench.plist")
        try template.manifest.replacingOccurrences(of: installPath, with: "/usr/local/lib/libMyTweak.dylib")
            .write(to: manifest, atomically: true, encoding: .utf8)
        refused({ try self.planInstall() }, "is not directly in /opt/dynject/lib/tweaks")
        try template.manifest.replacingOccurrences(of: "<integer>1</integer>", with: "<integer>9</integer>")
            .write(to: manifest, atomically: true, encoding: .utf8)
        refused({ try self.planInstall() }, "formatVersion must be 1")
        try template.manifest.write(to: manifest, atomically: true, encoding: .utf8)

        try template.manifest.write(to: src.appendingPathComponent("Other.workbench.plist"), atomically: true, encoding: .utf8)
        refused({ try self.planInstall() }, "several manifests")
        XCTAssertNoThrow(try planInstall(path: manifest.path))

        // Another tweak's manifest already has the destination name.
        try FileManager.default.createDirectory(atPath: loc.manifestsDirectory, withIntermediateDirectories: true)
        try template.manifest.replacingOccurrences(of: "local.mytweak", with: "local.someoneelse")
            .write(toFile: loc.manifestsDirectory + "/MyTweak.workbench.plist", atomically: true, encoding: .utf8)
        refused({ try self.planInstall(path: manifest.path) }, "belongs to another tweak (local.someoneelse)")

        // A symlink where the dylib would go is never replaced.
        try FileManager.default.removeItem(atPath: loc.manifestsDirectory + "/MyTweak.workbench.plist")
        try FileManager.default.createSymbolicLink(atPath: loc.dylibFileDirectory + "/libMyTweak.dylib", withDestinationPath: "/usr/lib/libz.dylib")
        refused({ try self.planInstall(path: manifest.path) }, "is not a regular file")
        XCTAssertEqual(config, Fixtures.text("live.conf"))
    }

    func testAlsoAcceptsAnotherAppTheEditReaches() throws {
        // Rules match service names by substring: enabling for Control Center (launchd label com.apple.controlcenter)
        // also reaches com.apple.controlcenter.PreloginSystemBannerRenderer.
        let cc = Apps.make("ControlCenter", "com.apple.controlcenter", dir: "/System/Library/CoreServices")
        let prelogin = Apps.make("PreloginSystemBannerRenderer", "com.apple.controlcenter.PreloginSystemBannerRenderer",
                                 dir: "/System/Library/CoreServices")
        // The fixture has ui_apps:no; let the prelogin app through the process gate, as the live config does.
        try (config + "allow:PreloginSystemBannerRenderer\n").write(toFile: loc.configPath, atomically: true, encoding: .utf8)
        let source = try TweakSource.locate(src.path)
        let targets = Apps.targets(Apps.all + [cc, prelogin])
        XCTAssertThrowsError(try TweakInstaller.plan(source: source, enableFor: ["com.apple.controlcenter"], targets: targets, locations: loc)) { e in
            XCTAssertTrue(e.localizedDescription.contains("PreloginSystemBannerRenderer (com.apple.controlcenter.PreloginSystemBannerRenderer)") &&
                          e.localizedDescription.contains("--also com.apple.controlcenter.PreloginSystemBannerRenderer"), e.localizedDescription)
        }
        XCTAssertThrowsError(try TweakInstaller.plan(source: source, enableFor: ["com.apple.controlcenter"], targets: targets, locations: loc,
                                                     options: TweakInstallOptions(alsoAffecting: ["com.apple.TextEdit"])),
                             "accepting a different app doesn't accept this one")
        let plan = try TweakInstaller.plan(source: source, enableFor: ["com.apple.controlcenter"], targets: targets, locations: loc,
                                           options: TweakInstallOptions(alsoAffecting: ["com.apple.controlcenter.PreloginSystemBannerRenderer"]))
        XCTAssertTrue(plan.notes.contains { $0.contains("Also reaches PreloginSystemBannerRenderer") && $0.contains("--also") }, "\(plan.notes)")
        XCTAssertEqual(plan.enabledFor.map(\.bundleID), ["com.apple.controlcenter"])
    }

    func testDylibWarningsAndExplicitDylibPath() throws {
        let other = root.appendingPathComponent("elsewhere.dylib")
        try FakeMachO.make([FakeMachO.arm64e], signed: false).write(to: other)
        let plan = try planInstall([], dylib: other.path)
        XCTAssertTrue(plan.source.dylibPath.hasSuffix("/elsewhere.dylib"), plan.source.dylibPath)
        XCTAssertTrue(plan.warnings.contains { $0.contains("not universal: no x86_64 or arm64") }, "\(plan.warnings)")
        XCTAssertTrue(plan.warnings.contains { $0.contains("no code signature") })
        XCTAssertEqual(plan.enabledFor, [])
        XCTAssertEqual(MachOInfo.inspect(FakeMachO.universal)?.isUniversal, true)
    }

    func testAnOlderManifestOfTheSameTweakIsReplaced() throws {
        try FileManager.default.createDirectory(atPath: loc.manifestsDirectory, withIntermediateDirectories: true)
        let old = loc.manifestsDirectory + "/my-old-name.workbench.plist"
        try template.manifest.write(toFile: old, atomically: true, encoding: .utf8)
        let plan = try planInstall([])
        XCTAssertEqual(plan.manifestsReplaced, [old])
        _ = try TweakInstaller.execute(plan, writer: writer(), restarter: SimulatedRestarter())
        XCTAssertFalse(FileManager.default.fileExists(atPath: old))
        XCTAssertEqual(TweakManifestLoader.load(directories: [loc.manifestsDirectory]).manifests.map(\.id), ["local.mytweak"])
    }

    // MARK: Uninstall

    func testUninstallRemovesConfigLinesFileManifestAndSafeModeEntries() throws {
        _ = try TweakInstaller.execute(try planInstall(), writer: writer(), restarter: SimulatedRestarter())
        let mem = MemoryTweakBackend()
        let safeMode = SafeMode(keys: SafeModeKeyStore(store: mem, names: .forDomain(SafeModeNames.testDomain)),
                                stateStore: SafeModeStateStore(directory: root.appendingPathComponent("SafeMode")))
        try safeMode.disable(tweakID: "local.mytweak", bundleID: "com.apple.TextEdit")
        try safeMode.disable(tweakID: "local.other", bundleID: "com.apple.Notes")

        let plan = try TweakInstaller.planUninstall("local.mytweak", keepFile: false, locations: loc, safeMode: safeMode)
        XCTAssertEqual(plan.removedConfigLines, ["dylib:\(installPath):deny", "dylib-override:\(installPath):allow:com.apple.TextEdit"])
        XCTAssertNotNil(plan.dylibToRemove)
        XCTAssertEqual(plan.manifestFiles, [loc.manifestsDirectory + "/MyTweak.workbench.plist"])
        XCTAssertEqual(plan.safeModeEntries, ["com.apple.TextEdit"])

        let sim = SimulatedRestarter()
        let result = try TweakInstaller.executeUninstall(plan, writer: writer(), restarter: sim, safeMode: safeMode)
        XCTAssertEqual(result.problems, [])
        XCTAssertEqual(sim.count, 1)
        XCTAssertFalse(config.contains("libMyTweak"))
        XCTAssertTrue(config.contains("allow:TextEdit"), "global gate lines stay")
        XCTAssertFalse(FileManager.default.fileExists(atPath: loc.dylibFileDirectory + "/libMyTweak.dylib"))
        XCTAssertNotNil(result.outcome?.backups[loc.dylibFileDirectory + "/libMyTweak.dylib"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: loc.manifestsDirectory + "/MyTweak.workbench.plist"))
        XCTAssertEqual(safeMode.keys.entries(), ["local.other": ["com.apple.Notes"]])
        XCTAssertFalse(safeMode.stateStore.load().disabled.contains { $0.tweakID == "local.mytweak" })

        XCTAssertThrowsError(try TweakInstaller.planUninstall("local.mytweak", keepFile: false, locations: loc, safeMode: nil))
    }

    func testUninstallByManifestPathWithKeepFile() throws {
        _ = try TweakInstaller.execute(try planInstall([]), writer: writer(), restarter: SimulatedRestarter())
        let plan = try TweakInstaller.planUninstall(src.appendingPathComponent("MyTweak.workbench.plist").path, keepFile: true,
                                                    locations: loc, safeMode: nil)
        XCTAssertNil(plan.dylibToRemove)
        _ = try TweakInstaller.executeUninstall(plan, writer: writer(), restarter: SimulatedRestarter(), safeMode: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: loc.dylibFileDirectory + "/libMyTweak.dylib"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("MyTweak.workbench.plist").path),
                      "the source manifest is never touched")
        XCTAssertEqual(config, Fixtures.text("live.conf"))
    }

    func testUninstallRefusesToRemoveTheLastDylib() throws {
        try "dylib:\(installPath):deny\ndylib-override:\(installPath):allow:com.apple.TextEdit\nallow:TextEdit\n"
            .write(toFile: loc.configPath, atomically: true, encoding: .utf8)
        _ = try TweakInstaller.execute(try planInstall([]), writer: writer(), restarter: SimulatedRestarter())
        XCTAssertThrowsError(try TweakInstaller.planUninstall("local.mytweak", keepFile: false, locations: loc, safeMode: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("is the only dylib"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("no dylibs configured"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: loc.dylibFileDirectory + "/libMyTweak.dylib"))
    }

    func testUninstallRefusesASymlinkedDylibUnlessKept() throws {
        _ = try TweakInstaller.execute(try planInstall([]), writer: writer(), restarter: SimulatedRestarter())
        let file = loc.dylibFileDirectory + "/libMyTweak.dylib"
        let outside = root.appendingPathComponent("precious.dylib").path
        try FileManager.default.moveItem(atPath: file, toPath: outside)
        try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: outside)
        XCTAssertThrowsError(try TweakInstaller.planUninstall("local.mytweak", keepFile: false, locations: loc, safeMode: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("symbolic link"), error.localizedDescription)
        }
        // The writer refuses on its own too.
        XCTAssertThrowsError(try writer().apply([.remove(file, expectedCurrent: FakeMachO.universal, category: "dylibs")]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside))
        XCTAssertNoThrow(try TweakInstaller.planUninstall("local.mytweak", keepFile: true, locations: loc, safeMode: nil))
    }

    func testRemovalProblem() throws {
        let dir = loc.dylibFileDirectory
        try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/libA.dylib"))
        XCTAssertNil(ProtectedFileWriter.removalProblem(dir + "/libA.dylib", directory: dir))
        XCTAssertNotNil(ProtectedFileWriter.removalProblem(dir + "/../libA.dylib", directory: dir))
        XCTAssertNotNil(ProtectedFileWriter.removalProblem(dir + "/libA.txt", directory: dir))
        XCTAssertNotNil(ProtectedFileWriter.removalProblem("/usr/lib/libz.dylib", directory: dir))
        XCTAssertNotNil(ProtectedFileWriter.removalProblem(dir + "/libMissing.dylib", directory: dir))
    }

    // MARK: List

    func testListShowsPolicyAndFileState() throws {
        _ = try TweakInstaller.execute(try planInstall(), writer: writer(), restarter: SimulatedRestarter())
        let (tweaks, issues, unmanifested) = TweakInstaller.list(locations: loc)
        XCTAssertEqual(issues.filter { $0.severity == .error }, [])
        XCTAssertEqual(tweaks.map(\.manifest.id), ["local.mytweak"])
        XCTAssertTrue(tweaks[0].fileExists)
        XCTAssertEqual(tweaks[0].policy, "deny by default; allow: com.apple.TextEdit")
        XCTAssertEqual(tweaks[0].safeMode, .unsupported, "the fake dylib has no DynjectHook marker")
        XCTAssertEqual(unmanifested, ["/opt/dynject/lib/tweaks/libBrutalium.dylib"])
    }

    // MARK: Template

    static var repoSDK: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TweakSDK")
    }

    func testTemplateFilesAndManifest() throws {
        let t = try TweakTemplate(name: "WindowTitles", bundleID: "com.apple.TextEdit")
        XCTAssertEqual(t.identifier, "local.windowtitles")
        let dir = root.appendingPathComponent("WindowTitles")
        let sdk = try XCTUnwrap(TweakSDKFiles.at(Self.repoSDK))
        let files = try t.write(to: dir, sdk: sdk)
        XCTAssertEqual(Set(files), ["WindowTitles.m", "WindowTitles.workbench.plist", "build.sh", "testhost/TestHost.m",
                                    "README.md", ".gitignore", "sdk/DynjectHook.h", "sdk/DynjectHook.m", "sdk/DynjectTweak.h"])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("build.sh").path))
        let data = try Data(contentsOf: dir.appendingPathComponent("WindowTitles.workbench.plist"))
        let (m, issues) = TweakManifestParser.parse(data: data, path: "x", fileExists: { _ in true })
        XCTAssertEqual(issues, [])
        XCTAssertEqual(m?.dylib, "/opt/dynject/lib/tweaks/libWindowTitles.dylib")
        XCTAssertEqual(m?.version, "0.1.0")
        XCTAssertEqual(m?.takesEffect, .live)
        XCTAssertEqual(m?.item("enabled")?.kind, .switch)
        XCTAssertNil(TweakLocations.live().installPathProblem(m!.dylib))
        let source = try String(contentsOf: dir.appendingPathComponent("WindowTitles.m"), encoding: .utf8)
        XCTAssertTrue(source.contains("DH_CTOR(TWEAK_ID_C, TWEAK_APPS)"))
        XCTAssertTrue(source.contains("#define TWEAK_APPS \"com.apple.TextEdit\", \"local.windowtitles.testhost\""), "the test build")
        XCTAssertTrue(source.contains("#define TWEAK_ID_C \"local.windowtitles.test\""), "its own tweak ID")
        let host = try String(contentsOf: dir.appendingPathComponent("testhost/TestHost.m"), encoding: .utf8)
        XCTAssertTrue(host.contains("kTweakID = @\"local.windowtitles.test\""))
        let build = try String(contentsOf: dir.appendingPathComponent("build.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("<string>local.windowtitles.testhost</string>"), "the host's bundle ID matches TWEAK_APPS")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("sdk/DynjectHook.m")), try Data(contentsOf: sdk.hookSource))
        XCTAssertThrowsError(try t.write(to: dir, sdk: sdk), "an existing folder is never overwritten")

        XCTAssertThrowsError(try TweakTemplate(name: "my-tweak"))
        XCTAssertThrowsError(try TweakTemplate(name: "Ok", identifier: "bad id"))
        XCTAssertThrowsError(try TweakTemplate(name: "Ok", bundleID: "com.x\"; rm"))
    }

    /// Compiles a generated tweak with its own build.sh: zero warnings, no exported symbols, three architectures,
    /// and it passes the installer's checks.
    func testGeneratedTweakBuildsWithoutWarnings() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun"))
        let dir = root.appendingPathComponent("Built")
        try TweakTemplate(name: "Built").write(to: dir, sdk: try XCTUnwrap(TweakSDKFiles.at(Self.repoSDK)))
        let out = try ProcessRunner.run(dir.appendingPathComponent("build.sh").path, [], environment: ["SIGN_IDENTITY": "-"])
        let log = out.stdout + out.stderr
        XCTAssertEqual(out.status, 0, log)
        XCTAssertFalse(log.contains("warning:"), log)
        XCTAssertTrue(log.contains("exported symbols: 0"), log)
        let built = try Data(contentsOf: dir.appendingPathComponent("build/libBuilt.dylib"))
        let check = MachOInfo.check(built, name: "libBuilt.dylib")
        XCTAssertEqual(check.errors, [])
        XCTAssertEqual(check.warnings, [])
        XCTAssertEqual(Set(check.archs), ["x86_64", "arm64", "arm64e"])
        XCTAssertEqual(SafeModeSupportChecker.dataSupport(built), .perTweakAndPanic)
        XCTAssertEqual(SDKVersionChecker.version(in: built), WorkbenchInfo.version, "the SDK marker survives a release build")
    }

    func testSDKIsFoundInTheAppBundleOrAboveABuildFolder() throws {
        let app = root.appendingPathComponent("W.app/Contents")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Resources/TweakSDK"), withIntermediateDirectories: true)
        try Data().write(to: app.appendingPathComponent("MacOS/dw"))
        for f in ["DynjectHook.h", "DynjectHook.m", "DynjectTweak.h"] {
            try Data(f.utf8).write(to: app.appendingPathComponent("Resources/TweakSDK/\(f)"))
        }
        XCTAssertEqual(TweakSDKFiles.locate(executable: app.appendingPathComponent("MacOS/dw"))?.hookSource.lastPathComponent, "DynjectHook.m")

        let repo = Self.repoSDK.deletingLastPathComponent()
        let found = TweakSDKFiles.locate(executable: repo.appendingPathComponent(".build/arm64-apple-macosx/debug/dw"))
        XCTAssertEqual(found?.hookHeader.path, Self.repoSDK.appendingPathComponent("include/DynjectHook.h").path)
        XCTAssertNil(TweakSDKFiles.locate(executable: URL(fileURLWithPath: "/usr/bin/true")))
    }
}
