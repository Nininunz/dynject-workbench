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

    func testUnsavedConfigEditsBlockInstalling() {
        let e = AppEnvironment.current(arguments: ["DynjectWorkbench", "-DWConfigPath", dir.appendingPathComponent("dynjectd.conf").path,
                                                   "-DWSupportDir", dir.path])
        let wb = WorkbenchModel(env: e)
        XCTAssertNil(wb.installBlocker)
        wb.workingText += "# edit\n"
        XCTAssertNotNil(wb.installBlocker)
    }
}
