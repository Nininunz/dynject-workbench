@testable import DynjectCore
import Foundation
import XCTest

/// The manifest key `requires` and the evaluator behind `dw doctor --apis`, against the real system frameworks.
final class TweakRequirementTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    func parse(_ requires: Any?) -> (requires: [TweakRequirement]?, errors: [String], warnings: [String]) {
        var d: [String: Any] = ["formatVersion": 1, "identifier": "a.b", "dylib": "/x.dylib",
                                "sections": [["items": [["type": "switch", "key": "on"]]]]]
        if let requires { d["requires"] = requires }
        let (m, issues) = TweakManifestParser.parse(data: manifestData(d), path: "/m", fileExists: { _ in true })
        return (m?.requires, issues.filter { $0.severity == .error }.map(\.message), issues.filter { $0.severity == .warning }.map(\.message))
    }

    // MARK: parsing

    func testValidRequirements() {
        let r = parse([
            ["class": "_NSAppleMenu", "image": "AppKit", "methods": ["-_addAppleMenuItems", "+sharedThing", "-a:b:c:"], "ivars": ["_menu"]],
            ["symbol": "sandbox_extension_consume", "image": "libsystem_sandbox", "optional": true],
            ["string": "TBrowserWindow", "image": "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"],
            ["class": "Module.SwiftThing", "image": "/usr/lib/libX.dylib"],
        ])
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(r.warnings, [])
        XCTAssertEqual(r.requires, [
            .objcClass("_NSAppleMenu", image: "AppKit", methods: ["-_addAppleMenuItems", "+sharedThing", "-a:b:c:"], ivars: ["_menu"]),
            .symbol("sandbox_extension_consume", image: "libsystem_sandbox", optional: true),
            .string("TBrowserWindow", image: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"),
            .objcClass("Module.SwiftThing", image: "/usr/lib/libX.dylib"),
        ])
        XCTAssertEqual(r.requires?[0].summary, "_NSAppleMenu (AppKit) + 3 methods, 1 ivar")
        XCTAssertEqual(r.requires?[2].summary, "\"TBrowserWindow\" in Finder")
    }

    func testAbsentAndEmpty() {
        XCTAssertNil(parse(nil).requires, "absent: nothing declared")
        XCTAssertEqual(parse([Any]()).requires, [], "empty: needs nothing")
        XCTAssertEqual(parse([Any]()).errors, [])
    }

    func testInvalidEntriesAreSkippedWithErrors() {
        let notArray = parse(["class": "X"])
        XCTAssertNil(notArray.requires)
        XCTAssertEqual(notArray.errors, ["requires must be an array of requirements; ignored."])

        let r = parse([
            "not a dict",
            ["class": "A", "symbol": "b", "image": "AppKit"],
            ["image": "AppKit"],
            ["class": "A"],
            ["class": "", "image": "AppKit"],
            ["class": "A", "image": "Frameworks/AppKit"],
            ["string": "x", "image": "Finder"],
            ["class": "Not A Class", "image": "AppKit"],
            ["symbol": "has space", "image": "libSystem.B"],
            ["class": "Kept", "image": "AppKit", "methods": ["noPrefix", "-ok", 3], "optional": "yes", "colour": "red"],
            ["symbol": "kept", "image": "libSystem.B", "methods": ["-x"]],
        ])
        XCTAssertEqual(r.requires, [.objcClass("Kept", image: "AppKit", methods: ["-ok"]), .symbol("kept", image: "libSystem.B")])
        XCTAssertEqual(r.errors, [
            "requires[0]: must be a dictionary; skipped.",
            "requires[1]: needs exactly one of class, symbol or string; skipped.",
            "requires[2]: needs exactly one of class, symbol or string; skipped.",
            "requires[3]: image is required (a framework or library name, or an absolute path); skipped.",
            "requires[4]: class must be a non-empty string; skipped.",
            "requires[5]: image \"Frameworks/AppKit\" must be a short name (AppKit) or an absolute path; skipped.",
            "requires[6]: a string requirement needs image to be the absolute path of a binary; skipped.",
            "requires[7]: \"Not A Class\" isn't a class name; skipped.",
            "requires[8]: \"has space\" isn't a C symbol name; skipped.",
            "requires[9]: optional must be a boolean; treated as false.",
            "requires[9].methods: entries must be non-empty strings; one ignored.",
            "requires[9].methods: \"noPrefix\" must be -selector or +selector; ignored.",
            "requires[10]: methods only applies to class; ignored.",
        ])
        XCTAssertEqual(r.warnings, ["requires[9]: unknown key \"colour\"; ignored."])
    }

    func testBundledManifestsDeclareWhatTheyNeed() throws {
        func load(_ path: String) throws -> TweakManifest {
            let p = Self.repoRoot.appendingPathComponent(path).path
            let (m, issues) = TweakManifestParser.parse(data: try XCTUnwrap(FileManager.default.contents(atPath: p)), path: p,
                                                        fileExists: { _ in true })
            XCTAssertEqual(issues.filter { $0.severity == .error }.map(\.message), [])
            return try XCTUnwrap(m)
        }
        XCTAssertEqual(try load("Tweaks/MenuLoader/MenuLoader.workbench.plist").requires,
                       [.objcClass("_NSAppleMenu", image: "AppKit", methods: ["-_addAppleMenuItems", "-updateMenu:withEvent:withFlags:"])])
        let finder = "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
        XCTAssertEqual(try load("Examples/OLEDFinder/OLEDFinder.workbench.plist").requires, [
            .string("TBrowserWindow", image: finder), .string("TDesktopWindow", image: finder),
            .objcClass("NSGlassEffectView", image: "AppKit", methods: ["-setContentView:", "-contentView", "-cornerRadius"], optional: true),
            .objcClass("NSScrollPocket", image: "AppKit", optional: true),
        ])
        XCTAssertEqual(try load("Tweaks/Inspector/Inspector.workbench.plist").requires, [])
    }

    func testBridgeCapabilitiesImplyTheClientSPI() throws {
        let d: [String: Any] = ["formatVersion": 1, "identifier": "a.b", "dylib": "/x.dylib", "sections": [], "bridge": ["notify"],
                                "requires": [["symbol": "strlen", "image": "libSystem.B"]]]
        let m = try XCTUnwrap(TweakManifestParser.parse(data: manifestData(d), path: "/m", fileExists: { _ in true }).0)
        XCTAssertEqual(m.effectiveRequirements, [.symbol("strlen", image: "libSystem.B")] + TweakRequirement.bridgeClient)
    }

    // MARK: evaluating, in this process

    func testClassesMethodsAndIvarsInRealFrameworks() {
        let e = TweakRequirementEvaluator()
        XCTAssertEqual(e.evaluate(.objcClass("NSObject", image: "Foundation", methods: ["-description", "+new"], ivars: ["isa"])).missing, [])
        XCTAssertEqual(e.evaluate(.objcClass("NSObject", image: "Foundation", methods: ["+description", "-dwNoSuchMethod:"])).missing,
                       ["-[NSObject dwNoSuchMethod:]"], "+description exists too: NSObject's class methods include its instance methods")
        XCTAssertEqual(e.evaluate(.objcClass("NSObject", image: "Foundation", ivars: ["dwNoSuchIvar"])).missing, ["ivar NSObject.dwNoSuchIvar"])
        XCTAssertEqual(e.evaluate(.objcClass("DWMadeUpClass", image: "Foundation")).missing, ["class DWMadeUpClass"])
        XCTAssertEqual(e.evaluate(.objcClass("NSView", image: "AppKit", methods: ["-setNeedsDisplay:"])).missing, [])
        let bad = e.evaluate(.objcClass("NSObject", image: "DWNoSuchFramework")).missing
        XCTAssertEqual(bad.count, 1)
        XCTAssertTrue(bad[0].hasPrefix("DWNoSuchFramework: can't load"), bad[0])
    }

    func testSymbols() {
        let e = TweakRequirementEvaluator()
        XCTAssertTrue(e.evaluate(.symbol("strlen", image: "libSystem.B")).satisfied, "short name -> /usr/lib/libSystem.B.dylib")
        XCTAssertTrue(e.evaluate(.symbol("strlen", image: "/usr/lib/libSystem.B.dylib")).satisfied)
        XCTAssertEqual(e.evaluate(.symbol("dw_no_such_function", image: "libSystem.B")).missing, ["dw_no_such_function() in libSystem.B"])
        XCTAssertTrue(e.evaluate(.symbol("CFRunLoopGetMain", image: "CoreFoundation")).satisfied)
        // What Workbench's broker uses exists on the machine running the tests.
        XCTAssertEqual(e.evaluate(TweakRequirement.bridgeBroker + TweakRequirement.bridgeClient).flatMap(\.missing), [])
    }

    func testCandidatePaths() {
        XCTAssertEqual(TweakRequirementEvaluator.candidatePaths(image: "AppKit"), [
            "/System/Library/Frameworks/AppKit.framework/AppKit", "/System/Library/PrivateFrameworks/AppKit.framework/AppKit",
            "/usr/lib/system/AppKit.dylib", "/usr/lib/AppKit.dylib",
        ])
        XCTAssertEqual(TweakRequirementEvaluator.candidatePaths(image: "/a/b"), ["/a/b"])
        XCTAssertEqual(TweakRequirementEvaluator.candidatePaths(image: "libxpc.dylib").suffix(2), ["/usr/lib/system/libxpc.dylib", "/usr/lib/libxpc.dylib"])
    }

    /// A universal test binary: one string in every slice, one only in the x86_64 slice. The arm64e slice is searched.
    func testStringsInABinaryYouCantLoad() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun"))
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("t.c")
        try """
        #include <stdio.h>
        #if defined(__x86_64__)
        static const char *intel = "DWOnlyInIntel";
        #else
        static const char *intel = "";
        #endif
        int main(void) { puts("DWCanaryMarker"); puts(intel); return 0; }
        """.write(to: src, atomically: true, encoding: .utf8)
        let bin = dir.appendingPathComponent("t")
        let out = try ProcessRunner.run("/usr/bin/xcrun", ["clang", "-arch", "x86_64", "-arch", "arm64e", "-o", bin.path, src.path])
        try XCTSkipUnless(out.status == 0, "couldn't compile: \(out.stderr)")
        let data = try Data(contentsOf: bin)
        XCTAssertEqual(MachOInfo.inspect(data)?.archs, ["x86_64", "arm64e"])
        XCTAssertNotNil(data.range(of: Data("DWOnlyInIntel".utf8)), "the file has it, in the slice that isn't searched")

        let e = TweakRequirementEvaluator()
        XCTAssertTrue(e.evaluate(.string("DWCanaryMarker", image: bin.path)).satisfied)
        XCTAssertEqual(e.evaluate(.string("DWCanary", image: bin.path)).missing, ["\"DWCanary\" in t"], "whole C strings only")
        XCTAssertFalse(e.evaluate(.string("DWOnlyInIntel", image: bin.path)).satisfied, "only the arm64e slice counts")
        XCTAssertEqual(e.evaluate(.string("x", image: dir.appendingPathComponent("missing").path)).missing.first?.hasSuffix("can't read \(dir.appendingPathComponent("missing").path)"), true)
    }

    func testPreferredSliceOfAFakeUniversalFile() {
        let fat = FakeMachO.make([FakeMachO.x86_64, FakeMachO.arm64e])
        let slices = MachOInfo.inspect(fat)!.slices
        XCTAssertEqual(slices.map(\.offset), [4096, 8192])
        XCTAssertEqual(MachOInfo.preferredSlice(of: fat), fat.subdata(in: 8192..<(8192 + slices[1].size)))
        XCTAssertEqual(MachOInfo.preferredSlice(of: Data("plain".utf8)), Data("plain".utf8), "not Mach-O: the whole file")
    }
}
