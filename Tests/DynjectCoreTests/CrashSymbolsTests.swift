@testable import DynjectCore
import XCTest

/// A symbolicator that answers from tables, and counts what it was asked.
final class FakeSymbolicator: CrashSymbolicating, @unchecked Sendable {
    var lines: [UInt64: (file: String, line: Int)] = [:]
    var map: [CrashHookMapEntry] = []
    var lineCalls = 0, mapCalls = 0

    func lines(_ report: CrashReport, imageIndex: Int, offsets: [UInt64]) -> [UInt64: (file: String, line: Int)] {
        lineCalls += 1
        return lines.filter { offsets.contains($0.key) }
    }

    func hookMap(_ report: CrashReport) -> [CrashHookMapEntry] {
        mapCalls += 1
        return map
    }
}

final class CrashSymbolsTests: XCTestCase {
    static let tweakPath = "/opt/dynject/lib/tweaks/libch.dylib"
    let catalog = SafeModeCatalog(tweaks: [SafeModeTweak(tweakID: "local.ch", name: "CH", dylibPath: CrashSymbolsTests.tweakPath,
                                                         hasManifest: true)])

    /// A report: image 0 the host, image 1 the tweak; `frames` as (image, offset, symbol, symbolLocation).
    func report(_ frames: [(Int, UInt64, String?, UInt64?)], extra: [String: Any] = [:]) -> CrashReport {
        let header: [String: Any] = ["bug_type": "309", "app_name": "Host", "incident_id": UUID().uuidString]
        var body: [String: Any] = [
            "procName": "Host", "procPath": "/Applications/Host.app/Contents/MacOS/Host", "pid": 4242,
            "procLaunch": "2026-11-23 15:15:36.5000 -0600", "captureTime": "2026-11-23 15:15:37.1000 -0600",
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"], "faultingThread": 0,
            "threads": [["triggered": true, "frames": frames.map { f -> [String: Any] in
                var d: [String: Any] = ["imageIndex": f.0, "imageOffset": f.1]
                if let s = f.2 { d["symbol"] = s }
                if let l = f.3 { d["symbolLocation"] = l }
                return d
            }]],
            "usedImages": [
                ["name": "Host", "path": "/Applications/Host.app/Contents/MacOS/Host", "base": 4_294_967_296, "size": 16384,
                 "uuid": "2a2a75f3-2b09-3082-8093-74e92a3837c9", "arch": "arm64e"],
                ["name": "libch.dylib", "path": CrashSymbolsTests.tweakPath, "base": 4_335_026_176, "size": 16384,
                 "uuid": "20248097-0e2d-3b89-bc35-e979eace50af", "arch": "arm64e"],
            ],
        ]
        body.merge(extra) { _, new in new }
        let text = String(data: try! JSONSerialization.data(withJSONObject: header), encoding: .utf8)! + "\n"
            + String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
        return try! CrashReportParser.parse(data: Data(text.utf8), path: "/r.ips")
    }

    // MARK: parsing

    func testParsesUUIDsLinesAndLaunch() throws {
        let text = """
        {"bug_type":"309"}
        {"pid":77,"procLaunch":"2026-11-23 15:15:36.5000 -0600","faultingThread":0,
         "threads":[{"frames":[{"imageIndex":0,"imageOffset":972,"symbol":"boom","symbolLocation":0,"inline":true,"sourceFile":"lib.c","sourceLine":4},
                               {"imageIndex":0,"imageOffset":972,"symbol":"replacement","symbolLocation":12,"sourceFile":"lib.c","sourceLine":5}]}],
         "usedImages":[{"name":"libCrashNote.dylib","uuid":"20248097-0e2d-3b89-bc35-e979eace50af","arch":"arm64e","base":1}]}
        """
        let r = try CrashReportParser.parse(data: Data(text.utf8), path: "/r.ips")
        XCTAssertEqual(r.pid, 77)
        XCTAssertEqual(r.launchDate, CrashReportParser.parseDate("2026-11-23 15:15:36.5000 -0600"))
        XCTAssertEqual(r.images[0].uuid, "20248097-0E2D-3B89-BC35-E979EACE50AF")
        XCTAssertEqual(r.images[0].arch, "arm64e")
        XCTAssertEqual(r.faultingFrames[0].sourceLine, 4)
        XCTAssertEqual(r.faultingFrames[0].sourceFile, "lib.c")
        XCTAssertTrue(r.faultingFrames[0].isInline)
        XCTAssertNil(r.faultingFrames[0].functionOffset, "an inlined function has no start of its own")
        XCTAssertEqual(r.faultingFrames[1].functionOffset, 960)
    }

    func testHookMapLines() {
        XCTAssertEqual(CrashHookMapEntry.parse("dynject.hooks:map libch.dylib 0x1a2c -[NSScreen _notchFrame]"),
                       CrashHookMapEntry(image: "libch.dylib", offset: 0x1A2C, target: "-[NSScreen _notchFrame]"))
        XCTAssertEqual(CrashHookMapEntry.parse("2026-11-23 15:15:36.6 Df host[1:2] [dynject.hooks:map] dynject.hooks:map libX.dylib 0x10 import getenv from libSystem.B.dylib"),
                       CrashHookMapEntry(image: "libX.dylib", offset: 0x10, target: "import getenv from libSystem.B.dylib"))
        XCTAssertNil(CrashHookMapEntry.parse("dynject.hooks:map libX.dylib 16 -[A b]"), "offsets are hex")
        XCTAssertNil(CrashHookMapEntry.parse("dynject.hooks:map libX.dylib 0x10"))
        XCTAssertNil(CrashHookMapEntry.parse("something else"))
    }

    func testAtosLines() {
        XCTAssertTrue(CrashSymbolicator.sourceLocation("-[Foo bar:] (in libX.dylib) (Foo.m:42)")! == ("Foo.m", 42))
        XCTAssertTrue(CrashSymbolicator.sourceLocation("CHExplode (in libch.dylib) (ch.m:11)")! == ("ch.m", 11))
        XCTAssertNil(CrashSymbolicator.sourceLocation("foo (in libX.dylib) + 28"), "no line without debug info")
        XCTAssertNil(CrashSymbolicator.sourceLocation("0x00001234"))
        XCTAssertNil(CrashSymbolicator.sourceLocation("foo (in libX.dylib)"))
    }

    // MARK: attribution

    func testLinesAndTheHookUnderTheCrash() {
        // CHExplode (function at 0x100) crashed, called from -[CHValueHook value] (at 0x200), the hook of -[CHTarget value].
        let r = report([(1, 0x120, "CHExplode", 0x20), (1, 0x210, "-[CHValueHook value]", 0x10), (0, 0x50, "main", 0x10)])
        let sym = FakeSymbolicator()
        sym.lines = [0x120: ("ch.m", 11), 0x210: ("ch.m", 17)]
        sym.map = [CrashHookMapEntry(image: "libch.dylib", offset: 0x200, target: "-[CHTarget value]"),
                   CrashHookMapEntry(image: "libother.dylib", offset: 0x100, target: "-[Wrong image]")]
        let a = CrashAttributor.attribute(r, catalog: catalog, symbolicator: sym)
        XCTAssertEqual(a.frameSummary, "EXC_BAD_ACCESS (SIGSEGV) in libch.dylib: CHExplode (ch.m:11), under its hook of -[CHTarget value]")
        XCTAssertEqual(a.loaded.first?.frame, "libch.dylib: CHExplode (ch.m:11), under its hook of -[CHTarget value]")
        XCTAssertEqual(sym.lineCalls, 1, "one call for the tweak image, none for the host")
    }

    func testCrashInTheReplacementItself() {
        let r = report([(1, 0x210, "-[CHValueHook value]", 0x10), (0, 0x50, "main", 0x10)])
        let sym = FakeSymbolicator()
        sym.map = [CrashHookMapEntry(image: "libch.dylib", offset: 0x200, target: "-[CHTarget value]")]
        let a = CrashAttributor.attribute(r, catalog: catalog, symbolicator: sym)
        XCTAssertEqual(a.loaded.first?.frame, "libch.dylib: -[CHValueHook value], its hook of -[CHTarget value]",
                       "no line: the symbolicator found none")
    }

    func testLinesTheReportHasAreKept() {
        let text = report([(1, 0x120, "CHExplode", 0x20)])
        var r = text
        r.faultingFrames[0].sourceFile = "/src/ch.m"
        r.faultingFrames[0].sourceLine = 11
        let sym = FakeSymbolicator()
        let a = CrashAttributor.attribute(r, catalog: catalog, symbolicator: sym)
        XCTAssertEqual(a.loaded.first?.frame, "libch.dylib: CHExplode (ch.m:11)", "the reporter's line, file name only")
        XCTAssertEqual(sym.lineCalls, 0, "nothing left to look up")
    }

    func testWithoutSymbolicatorTheTextIsAsBefore() {
        let r = report([(1, 0x120, "CHExplode", 0x20), (1, 0x210, "-[CHValueHook value]", 0x10)])
        XCTAssertEqual(CrashAttributor.attribute(r, catalog: catalog).frameSummary, "EXC_BAD_ACCESS (SIGSEGV) in libch.dylib: CHExplode")
    }

    func testNoLogReadForCrashesOutsideTweaks() {
        let r = report([(0, 0x50, "main", 0x10)])
        let sym = FakeSymbolicator()
        let a = CrashAttributor.attribute(r, catalog: catalog, symbolicator: sym)
        XCTAssertEqual(sym.mapCalls, 0, "the hook map is only read for a crash in a tweak")
        XCTAssertEqual(a.culprits, [])
    }

    // MARK: the store

    func testKeepsTheDSYMOfABuild() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("crash-symbols-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("t.c")
        let dylib = dir.appendingPathComponent("libT.dylib").path
        let store = TweakSymbolStore(directory: dir.appendingPathComponent("Symbols"))
        func build(_ body: String, debug: Bool = true) throws {
            try "int entry(int *p) { \(body) }\n".write(to: src, atomically: true, encoding: .utf8)
            let out = try ProcessRunner.run("/usr/bin/xcrun", ["clang"] + (debug ? ["-g"] : []) +
                                            ["-arch", "arm64", "-arch", "x86_64", "-dynamiclib", src.path, "-o", dylib])
            try XCTSkipIf(out.status != 0, "no clang: \(out.stderr)")
        }

        try build("return *p;", debug: false)
        XCTAssertEqual(store.keep(dylibAt: dylib), .noDSYM)

        try build("return *p;")
        guard case let .kept(uuids) = store.keep(dylibAt: dylib) else { return XCTFail("not kept") }
        XCTAssertEqual(uuids.count, 2, "one UUID per architecture")
        XCTAssertEqual(Set(uuids), Set(MachOInfo.inspect(FileManager.default.contents(atPath: dylib)!)!.uuids.values))
        for u in uuids { XCTAssertNotNil(store.dsym(uuid: u.lowercased()), "found by any of its UUIDs, any case") }
        XCTAssertEqual(store.keep(dylibAt: dylib), .kept(uuids), "keeping it again is fine")

        let old = dir.appendingPathComponent("old.dSYM").path
        try FileManager.default.copyItem(atPath: dylib + ".dSYM", toPath: old)
        try build("return *p + 1;")
        try FileManager.default.removeItem(atPath: dylib + ".dSYM")
        try FileManager.default.moveItem(atPath: old, toPath: dylib + ".dSYM")
        XCTAssertEqual(store.keep(dylibAt: dylib), .mismatch, "a dSYM of another build isn't kept")
    }

    func testPruneKeepsTheNewestBuilds() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("crash-symbols-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<12 {
            let b = dir.appendingPathComponent(String(format: "libT.dylib-%08d.dSYM", i))
            try fm.createDirectory(at: b, withIntermediateDirectories: true)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(i))], ofItemAtPath: b.path)
        }
        try fm.createDirectory(at: dir.appendingPathComponent("libOther.dylib-00000000.dSYM"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("AAAA.dSYM").path, withDestinationPath: "libT.dylib-00000000.dSYM")
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("BBBB.dSYM").path, withDestinationPath: "libT.dylib-00000011.dSYM")
        TweakSymbolStore(directory: dir).prune(name: "libT.dylib")
        let left = Set(try fm.contentsOfDirectory(atPath: dir.path))
        XCTAssertFalse(left.contains("libT.dylib-00000000.dSYM"))
        XCTAssertFalse(left.contains("libT.dylib-00000001.dSYM"))
        XCTAssertTrue(left.contains("libT.dylib-00000002.dSYM"))
        XCTAssertTrue(left.contains("libT.dylib-00000011.dSYM"))
        XCTAssertTrue(left.contains("libOther.dylib-00000000.dSYM"), "other dylibs' builds are left alone")
        XCTAssertFalse(left.contains("AAAA.dSYM"), "a link to a removed build goes")
        XCTAssertTrue(left.contains("BBBB.dSYM"))
    }
}
