@testable import DynjectCore
import XCTest

/// `dw dev`'s decisions: which changes rebuild, how a folder tests itself, how a test host's output reads, and which
/// apps get relaunched.
final class DevLoopTests: XCTestCase {
    let folder = "/Users/x/MyTweak"

    func testWhichChangesRebuild() {
        for rel in ["MyTweak.m", "MyTweak.workbench.plist", "build.sh", "testhost/TestHost.m", "sdk/DynjectHook.h", "Sources/A.swift",
                    "Hooks/B.mm", "Makefile"] {
            XCTAssertTrue(DevLoop.isRelevant(folder + "/" + rel, folder: folder), rel)
        }
        for rel in ["build/libMyTweak.dylib", "build/test/MyTweakTestHost.app/Contents/Info.plist", ".git/index", ".DS_Store",
                    "MyTweak.m~", ".MyTweak.m.swp", "#MyTweak.m#", "README.md", "notes.txt", "shot.png", "sub/.hidden/x.m",
                    "DerivedData/x.o"] {
            XCTAssertFalse(DevLoop.isRelevant(folder + "/" + rel, folder: folder), rel)
        }
        XCTAssertFalse(DevLoop.isRelevant("/Users/x/Other/a.m", folder: folder), "outside the folder")
        XCTAssertFalse(DevLoop.isRelevant("/Users/x/MyTweakOther/a.m", folder: folder), "a sibling with the same prefix")
        XCTAssertTrue(DevLoop.isRelevant(folder + "/./MyTweak.m", folder: folder + "/"), "paths are standardized")
    }

    func testHowAFolderTestsItself() {
        let generated = #"[ "${1:-}" = "test" ] || exit 0"#
        XCTAssertEqual(DevLoop.testCommand(folder: folder, fileExists: { _ in false }, buildScript: generated), .buildTest)
        XCTAssertEqual(DevLoop.testCommand(folder: folder, fileExists: { $0 == "/Users/x/MyTweak/testhost/run.sh" }, buildScript: generated),
                       .runScript, "testhost/run.sh wins (MenuLoader)")
        XCTAssertEqual(DevLoop.testCommand(folder: folder, fileExists: { _ in false }, buildScript: "#!/bin/sh\nclang ..."), .none)
        XCTAssertEqual(DevLoop.testCommand(folder: folder, fileExists: { _ in false }, buildScript: nil), .none)
    }

    func testReadingTestHostOutput() {
        var r = DevLoop.testResult("  [PASS] a\n  [PASS] b\n2 checks, all passed\n")
        XCTAssertEqual(r, DevLoop.TestResult(passed: true, summary: "2 checks, all passed", failures: []))
        r = DevLoop.testResult("  [PASS] a\n  [FAIL] b (got c)\n2 checks, FAILED\n")
        XCTAssertEqual(r.passed, false)
        XCTAssertEqual(r.summary, "2 checks, FAILED")
        XCTAssertEqual(r.failures, ["[FAIL] b (got c)"])
        r = DevLoop.testResult("== loaded ==\n  ok    x\n  FAIL  y\nhost: FAILED\n")   // Inspector's host
        XCTAssertEqual(r.passed, false)
        XCTAssertEqual(r.failures, ["FAIL  y"])
        XCTAssertEqual(DevLoop.testResult("  ok    x\nhost: all checks passed\nALL PASSED\n").passed, true)
        XCTAssertEqual(DevLoop.testResult("  [PASS] x\nALL PASSED\n").passed, true)   // TitleBadge
        XCTAssertNil(DevLoop.testResult("Built libX.dylib\n").passed, "no verdict")
        XCTAssertEqual(DevLoop.testResult("  [FAIL] y\n").passed, false, "a failed check without a summary")
    }

    func testWhichAppsAreRelaunched() {
        let id = "local.mytweak"
        XCTAssertEqual(DevLoop.targets(explicit: ["com.a"], markers: [CtorMarker(tweakID: id, bundleIDs: ["com.b"])], tweakID: id),
                       .apps(["com.a"]), "--for wins")
        XCTAssertEqual(DevLoop.targets(explicit: [], markers: [CtorMarker(tweakID: id, bundleIDs: ["com.b", "com.c"])], tweakID: id),
                       .apps(["com.b", "com.c"]))
        XCTAssertEqual(DevLoop.targets(explicit: [], markers: [CtorMarker(tweakID: id, bundleIDs: [])], tweakID: id), .everyApp)
        XCTAssertEqual(DevLoop.targets(explicit: [], markers: [CtorMarker(tweakID: id, bundleIDs: nil)], tweakID: id), .unknown)
        XCTAssertEqual(DevLoop.targets(explicit: [], markers: [], tweakID: id), .unknown, "a build from before the marker")
        XCTAssertEqual(DevLoop.targets(explicit: [], markers: [CtorMarker(tweakID: "other", bundleIDs: ["com.x"]),
                                                               CtorMarker(tweakID: id, bundleIDs: ["com.y"])], tweakID: id),
                       .apps(["com.y"]), "the marker with the tweak's own ID")
    }
}
