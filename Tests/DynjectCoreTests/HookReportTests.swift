@testable import DynjectCore
import XCTest

/// `dw hooks`: reading the report lines DynjectHook copies write (see "Hook reports" in DynjectHook.m) and what's
/// made of them.
final class HookReportTests: XCTestCase {
    let a = "/opt/dynject/lib/tweaks/libA.dylib", b = "/opt/dynject/lib/tweaks/libB.dylib"

    func lines(_ request: UInt32 = 7) -> [String] {
        [
            "R \(request) begin local.a sdk=0.1.3 image=\(a)",
            "R 99 begin local.other sdk=0.1.3 image=/x/libOther.dylib",   // another request: skipped
            "R \(request) begin local.b sdk=0.1.2 image=\(b)",
            "R \(request) hook local.a - NSWindow setTitle: installed beneath group=main group",
            "R \(request) hook local.b - NSWindow setTitle: installed top group=-",
            "R \(request) hook local.b + NSColor colorNamed: restored beneath group=off",
            "R \(request) import local.a getenv lib=libSystem.B.dylib sites=3 active",
            "R \(request) import local.a $s7SwiftUI4ViewPAAE7opacityyQrSdF lib=- sites=0 inactive",
            "R \(request) end local.a hooks=1 imports=2",
            "R \(request) end local.b hooks=2 imports=0",
            "R \(request) scan-begin tweak-images=2",
            "R \(request) foreign - NSWindow setTitle: imp=\(b) class=/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            "R \(request) foreign - NSView swizzled imp=/opt/dynject/lib/tweaks/libC.dylib class=/Applications/My App.app/Contents/MacOS/My App",
            "R \(request) scan-end found=2 ms=41",
            "unrelated message",
        ]
    }

    func testParse() {
        let r = HookReport.parse(lines(), request: 7)
        XCTAssertEqual(r.copies.map(\.tweakID), ["local.a", "local.b"])
        XCTAssertEqual(r.copies.map(\.sdk), ["0.1.3", "0.1.2"])
        XCTAssertTrue(r.copies.allSatisfy(\.complete))
        let wa = r.copies[0].hooks[0]
        XCTAssertEqual(wa, HookReport.Hook(image: a, tweakID: "local.a", classMethod: false, cls: "NSWindow", sel: "setTitle:",
                                           state: "installed", top: false, group: "main group"), "a group name with a space")
        XCTAssertEqual(r.copies[1].hooks[1].method, "+[NSColor colorNamed:]")
        XCTAssertNil(r.copies[1].hooks[0].group)
        XCTAssertEqual(r.copies[0].imports.map(\.symbol), ["getenv", "$s7SwiftUI4ViewPAAE7opacityyQrSdF"])
        XCTAssertEqual(r.copies[0].imports.map(\.library), ["libSystem.B.dylib", nil])
        XCTAssertEqual(r.copies[0].imports.map(\.sites), [3, 0])
        XCTAssertEqual(r.copies[0].imports.map(\.active), [true, false])
        XCTAssertTrue(r.scanned && r.scanFinished)
        XCTAssertEqual(r.scanMilliseconds, 41)
        XCTAssertEqual(r.foreign.map(\.classImage).last, "/Applications/My App.app/Contents/MacOS/My App", "paths with spaces")
        XCTAssertEqual(HookReport.parse(lines(), request: 8).copies.count, 0, "another request's lines")
    }

    func testIncompleteReport() {
        let r = HookReport.parse(Array(lines().prefix(5)), request: 7)
        XCTAssertEqual(r.copies.map(\.complete), [false, false])
        XCTAssertFalse(r.scanned)
    }

    func testConflictsAndScan() {
        let r = HookReport.parse(lines(), request: 7)
        XCTAssertEqual(r.conflicts, [HookReport.Conflict(method: "-[NSWindow setTitle:]", tweakIDs: ["local.a", "local.b"], top: "local.b")])
        XCTAssertEqual(r.foreignNotReported.map(\.method), ["-[NSView swizzled]"], "B's own DynjectHook hook isn't repeated")
        // A hook that is restored (group off) isn't in the method: no clash.
        let restored = HookReport.parse([
            "R 1 begin x sdk=0.1.3 image=/a", "R 1 hook x - C m restored beneath group=g", "R 1 end x hooks=1 imports=0",
            "R 1 begin y sdk=0.1.3 image=/b", "R 1 hook y - C m installed top group=-", "R 1 end y hooks=1 imports=0",
        ], request: 1)
        XCTAssertEqual(restored.conflicts, [])
        // Two hooks of one copy on one method: that tweak's business, not a clash between tweaks.
        let same = HookReport.parse([
            "R 1 begin x sdk=0.1.3 image=/a", "R 1 hook x - C m installed beneath group=-", "R 1 hook x - C m installed top group=-",
            "R 1 end x hooks=2 imports=0",
        ], request: 1)
        XCTAssertEqual(same.conflicts, [])
    }

    func testFunctionHooks() {
        let r = HookReport.parse([
            "R 3 begin local.a sdk=0.1.7 image=/a",
            "R 3 function local.a 0x2ec402dec libsystem_m.dylib`cbrt+0 active first group=-",
            "R 3 function local.a 0x100bc2e40 host`f_tbz+0 inactive first group=inline",
            "R 3 end local.a hooks=0 imports=0 functions=2",
            "R 3 begin local.b sdk=0.1.7 image=/b",
            "R 3 function local.b 0x2ec402dec libsystem_m.dylib`cbrt+0 active stacked group=-",
            "R 3 end local.b hooks=0 imports=0 functions=1",
        ], request: 3)
        XCTAssertEqual(r.copies.map(\.functions.count), [2, 1])
        XCTAssertEqual(r.copies[0].functions[1], HookReport.Function(image: "/a", tweakID: "local.a", address: "0x100bc2e40",
                                                                    name: "host`f_tbz+0", active: false, stacked: false, group: "inline"))
        XCTAssertEqual(r.conflicts, [HookReport.Conflict(method: "function libsystem_m.dylib`cbrt+0", tweakIDs: ["local.a", "local.b"],
                                                         top: "local.b")])
        let text = r.text(header: "h", names: ["local.b": "Bee"], silent: [], bundleID: "x")
        XCTAssertTrue(text.contains("function host`f_tbz+0"), text)
        XCTAssertTrue(text.contains("inactive, group inline"), text)
        XCTAssertTrue(text.contains("active, on top of another hook"), text)
        XCTAssertTrue(text.contains("! function libsystem_m.dylib`cbrt+0 is hooked by 2 tweaks: local.a, Bee (top)"), text)
        // One tweak hooking a function twice is its own business; and an old SDK's report has no function lines.
        let one = HookReport.parse(["R 1 begin x sdk=0.1.7 image=/a", "R 1 function x 0x1 f active first group=-",
                                    "R 1 function x 0x1 f active stacked group=-", "R 1 end x hooks=0 imports=0 functions=2"], request: 1)
        XCTAssertEqual(one.conflicts, [])
        XCTAssertEqual(HookReport.parse(lines(), request: 7).copies.map(\.functions), [[], []])
    }

    func testSilence() {
        XCTAssertEqual(HookReport.silence(supportsReports: false, usesDynjectHook: false), .noDynjectHook)
        XCTAssertEqual(HookReport.silence(supportsReports: false, usesDynjectHook: true), .tooOld)
        XCTAssertEqual(HookReport.silence(supportsReports: true, usesDynjectHook: true), .inactive)
        XCTAssertEqual(HookReport.silence(supportsReports: nil, usesDynjectHook: nil), .unknown)
    }

    func testText() {
        let r = HookReport.parse(lines(), request: 7)
        let t = r.text(header: "dw hooks: TextEdit", names: ["local.a": "Tweak A"],
                       silent: [("/opt/dynject/lib/tweaks/libOld.dylib", .tooOld, "local.old"),
                                ("/opt/dynject/lib/tweaks/libOff.dylib", .inactive, "local.off")], bundleID: "com.apple.TextEdit")
        XCTAssertTrue(t.contains("Tweak A  local.a  (libA.dylib, sdk 0.1.3)"), t)
        XCTAssertTrue(t.contains("installed, beneath another hook, group main group"), t)
        XCTAssertTrue(t.contains("installed, top"), t)
        XCTAssertTrue(t.contains("import getenv") && t.contains("3 sites (libSystem.B.dylib), active"), t)
        XCTAssertTrue(t.contains("! -[NSWindow setTitle:] is hooked by 2 tweaks: Tweak A, local.b (top)"), t)
        XCTAssertTrue(t.contains("-[NSView swizzled]  in libC.dylib, class from My App"), t)
        XCTAssertTrue(t.contains("libOld.dylib: built before hook reports"), t)
        XCTAssertTrue(t.contains("libOff.dylib: loaded but not active here") && t.contains("(dw why local.off com.apple.TextEdit)"), t)
        XCTAssertTrue(HookReport().text(header: "h", names: [:], silent: [], bundleID: "x").contains("no DynjectHook tweak in it answered"))
    }

    func testMarkerMatchesTheSDK() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("TweakSDK/DynjectHook.m"), encoding: .utf8)
        XCTAssertTrue(source.contains("\"\(HookReportSupport.marker)\""))
    }
}
