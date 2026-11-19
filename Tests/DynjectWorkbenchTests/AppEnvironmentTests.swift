@testable import DynjectWorkbench
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
