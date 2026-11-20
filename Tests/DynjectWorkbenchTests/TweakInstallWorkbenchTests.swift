@testable import DynjectWorkbench
import DynjectCore
import XCTest

/// Install Tweak… and Uninstall… in fixture mode: the same TweakInstaller as `dw tweak`, with every file under the
/// support folder, a simulated restart and no administrator prompt.
@MainActor
final class TweakInstallWorkbenchTests: XCTestCase {
    private var dir: URL!
    private let config = "dylib:/opt/dynject/lib/tweaks/libOther.dylib:deny\n"

    override func setUp() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dw-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        dir = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)!), isDirectory: true)
        try Data(config.utf8).write(to: dir.appendingPathComponent("dynjectd.conf"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// One signed arm64e+arm64+x86_64 dylib header, enough for the installer's Mach-O check.
    private func fakeDylib() -> Data {
        func le(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func be(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
        let cpus: [(UInt32, UInt32)] = [(0x0100_0007, 3), (0x0100_000C, 0), (0x0100_000C, 0x8000_0002)]
        var out = be(0xCAFE_BABE) + be(3)
        for (i, c) in cpus.enumerated() { out += be(c.0) + be(c.1) + be(UInt32(4096 * (i + 1))) + be(48) + be(12) }
        for (i, c) in cpus.enumerated() {
            out += [UInt8](repeating: 0, count: 4096 * (i + 1) - out.count)
            out += le(0xFEED_FACF) + le(c.0) + le(c.1) + le(6) + le(1) + le(16) + le(0) + le(0) + le(0x1D) + le(16) + le(0) + le(0)
        }
        return Data(out)
    }

    private func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testInstallAndUninstallStayInsideTheFixture() async throws {
        let e = AppEnvironment.current(arguments: ["DynjectWorkbench", "-DWConfigPath", dir.appendingPathComponent("dynjectd.conf").path,
                                                   "-DWSupportDir", dir.path, "-DWLogPath", dir.appendingPathComponent("none.log").path])
        let wb = WorkbenchModel(env: e)
        XCTAssertTrue(wb.canInstallTweaks)
        XCTAssertFalse(wb.restarter.isLive)

        let src = dir.appendingPathComponent("src/Fixture")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("build"), withIntermediateDirectories: true)
        let t = try TweakTemplate(name: "Fixture", identifier: "local.dynject.fixturetweak")
        try t.manifest.write(to: src.appendingPathComponent("Fixture.workbench.plist"), atomically: true, encoding: .utf8)
        try fakeDylib().write(to: src.appendingPathComponent("build/libFixture.dylib"))

        wb.beginInstall(path: src.path)
        XCTAssertNil(wb.installReview?.error)
        let plan = try XCTUnwrap(wb.installReview?.plan)
        XCTAssertEqual(plan.dylibFilePath, dir.appendingPathComponent("lib/tweaks/libFixture.dylib").path)
        XCTAssertTrue(plan.summary.contains("  + dylib:/opt/dynject/lib/tweaks/libFixture.dylib:deny"))
        wb.confirmInstall()
        let installed = await waitFor { wb.installReview == nil && !wb.isInstallingTweak }
        XCTAssertTrue(installed, wb.installReview?.error ?? "")
        XCTAssertEqual(wb.banner?.title, "Installed Fixture")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("lib/tweaks/libFixture.dylib").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Tweaks/Fixture.workbench.plist").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/opt/dynject/lib/tweaks/libFixture.dylib"))
        XCTAssertTrue(wb.diskText.contains("dylib:/opt/dynject/lib/tweaks/libFixture.dylib:deny"))
        XCTAssertEqual(wb.selectedTweakID, "local.dynject.fixturetweak")

        let manifest = try XCTUnwrap(wb.tweaks.first { $0.id == "local.dynject.fixturetweak" })
        wb.beginUninstall(manifest)
        XCTAssertNil(wb.uninstallReview?.error)
        XCTAssertNotNil(wb.uninstallReview?.plan?.dylibToRemove)
        wb.confirmUninstall()
        let removed = await waitFor { wb.uninstallReview == nil && !wb.isInstallingTweak }
        XCTAssertTrue(removed, wb.uninstallReview?.error ?? "")
        XCTAssertEqual(wb.diskText, config)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("lib/tweaks/libFixture.dylib").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Tweaks/Fixture.workbench.plist").path))
        XCTAssertFalse(wb.tweaks.contains { $0.id == "local.dynject.fixturetweak" })
    }

    /// A downgrade needs the sheet's explicit checkbox; so does removing a tweak another one depends on.
    func testDowngradeAndDependentsNeedExplicitConfirmation() async throws {
        let e = AppEnvironment.current(arguments: ["DynjectWorkbench", "-DWConfigPath", dir.appendingPathComponent("dynjectd.conf").path,
                                                   "-DWSupportDir", dir.path, "-DWLogPath", dir.appendingPathComponent("none.log").path])
        let wb = WorkbenchModel(env: e)
        let src = dir.appendingPathComponent("src/Fixture")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("build"), withIntermediateDirectories: true)
        let t = try TweakTemplate(name: "Fixture", identifier: "local.dynject.fixturetweak")
        let manifestURL = src.appendingPathComponent("Fixture.workbench.plist")
        try t.manifest.replacingOccurrences(of: "<string>0.1.0</string>", with: "<string>1.0.0</string>")
            .write(to: manifestURL, atomically: true, encoding: .utf8)
        try fakeDylib().write(to: src.appendingPathComponent("build/libFixture.dylib"))
        wb.beginInstall(path: src.path)
        XCTAssertEqual(wb.installReview?.plan?.compatibility.change, .fresh("1.0.0"))
        wb.confirmInstall()
        let installed = await waitFor { wb.installReview == nil && !wb.isInstallingTweak }
        XCTAssertTrue(installed, wb.installReview?.error ?? "")

        try t.manifest.write(to: manifestURL, atomically: true, encoding: .utf8)   // 0.1.0
        wb.beginInstall(path: src.path)
        XCTAssertEqual(wb.installReview?.plan?.isRefused, true)
        XCTAssertEqual(wb.installReview?.plan?.compatibility.refusals.map(\.kind), [.downgrade])
        wb.confirmInstall()
        XCTAssertFalse(wb.isInstallingTweak, "a refused plan doesn't run")
        wb.installReview?.allowDowngrade = true
        wb.replanInstall()
        XCTAssertEqual(wb.installReview?.plan?.isRefused, false)
        wb.installReview = nil

        // Another installed tweak depends on it.
        let other: [String: Any] = ["formatVersion": 1, "identifier": "local.dynject.needsfixture", "name": "Needs Fixture",
                                    "dylib": "/opt/dynject/lib/tweaks/libOther.dylib", "depends": ["local.dynject.fixturetweak"],
                                    "sections": [["items": [["type": "switch", "key": "x"]]]]]
        try PropertyListSerialization.data(fromPropertyList: other, format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("Tweaks/NeedsFixture.workbench.plist"))
        wb.loadTweaks()
        let manifest = try XCTUnwrap(wb.tweaks.first { $0.id == "local.dynject.fixturetweak" })
        XCTAssertEqual(wb.dependencyChecker.dependents(of: manifest.id).map(\.id), ["local.dynject.needsfixture"])
        wb.beginUninstall(manifest)
        XCTAssertNil(wb.uninstallReview?.plan)
        XCTAssertTrue(wb.uninstallReview?.error?.contains("Needs Fixture (local.dynject.needsfixture) depends on Fixture") == true,
                      wb.uninstallReview?.error ?? "")
        wb.uninstallReview?.force = true
        wb.replanUninstall()
        XCTAssertNotNil(wb.uninstallReview?.plan)
    }

    func testUnsavedConfigEditsBlockInstalling() {
        let e = AppEnvironment.current(arguments: ["DynjectWorkbench", "-DWConfigPath", dir.appendingPathComponent("dynjectd.conf").path,
                                                   "-DWSupportDir", dir.path])
        let wb = WorkbenchModel(env: e)
        XCTAssertNil(wb.installBlocker)
        wb.workingText += "# edit\n"
        XCTAssertNotNil(wb.installBlocker)
    }
}
