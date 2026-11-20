@testable import DynjectCore
import XCTest

// MARK: - Synthetic crash reports

/// Builds two-document .ips text shaped like real macOS 27 reports (header line + pretty-printed body).
struct IPS {
    static let host = 0, kernel = 1, pthread = 2, libc = 3, cxxabi = 4, objc = 5, cf = 6, appKit = 7, dyld = 8, unknown = 9
    static let firstTweak = 10

    var appName = "SafeModeHost"
    var bundleID: String? = "local.dynject.safemode.host"
    var bugType = "309"
    var simulated = false
    var incident = UUID().uuidString
    var procPath = "/Users/USER/*/SafeModeHost.app/Contents/MacOS/SafeModeHost"
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var exception: [String: Any] = ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "subtype": "KERN_INVALID_ADDRESS at 0x10"]
    /// Tweak images, appended after the standard ones (index firstTweak, firstTweak + 1, ...).
    var tweakImages: [(path: String?, name: String?)] = []
    /// Faulting thread frames, innermost first: (imageIndex, symbol).
    var faulting: [(Int, String?)] = [(IPS.cf, "CFRelease"), (IPS.appKit, "-[NSApplication run]"), (IPS.host, "main")]
    var exceptionBacktrace: [(Int, String?)]?

    static let abortFrames: [(Int, String?)] = [
        (kernel, "__pthread_kill"), (pthread, "pthread_kill"), (libc, "abort"), (cxxabi, "__abort_message"),
        (cxxabi, "demangling_terminate_handler()"), (objc, "_objc_terminate()"), (cxxabi, "std::__terminate(void (*)())"),
        (cxxabi, "__cxa_throw"), (objc, "objc_exception_throw"),
    ]

    static func captureTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: -6 * 3600)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        return f.string(from: d)
    }

    var images: [[String: Any]] {
        var list: [[String: Any]] = [
            ["source": "P", "arch": "arm64", "base": 4_328_767_488, "size": 16384, "path": procPath, "name": appName],
            ["source": "P", "arch": "arm64e", "base": 6_955_429_888, "size": 256_604, "path": "/usr/lib/system/libsystem_kernel.dylib", "name": "libsystem_kernel.dylib"],
            ["source": "P", "arch": "arm64e", "base": 6_955_687_936, "size": 51372, "path": "/usr/lib/system/libsystem_pthread.dylib", "name": "libsystem_pthread.dylib"],
            ["source": "P", "arch": "arm64e", "base": 6_955_814_912, "size": 535_764, "path": "/usr/lib/system/libsystem_c.dylib", "name": "libsystem_c.dylib"],
            ["source": "P", "arch": "arm64e", "base": 7_030_239_232, "size": 106_240, "path": "/usr/lib/libc++abi.dylib", "name": "libc++abi.dylib"],
            ["source": "P", "arch": "arm64e", "base": 6_954_106_880, "size": 325_208, "path": "/usr/lib/libobjc.A.dylib", "name": "libobjc.A.dylib"],
            ["source": "P", "arch": "arm64e", "base": 7_024_148_480, "size": 4_797_232,
             "path": "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation", "name": "CoreFoundation"],
            ["source": "P", "arch": "arm64e", "base": 7_121_608_704, "size": 23_873_264,
             "path": "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", "name": "AppKit"],
            ["source": "P", "arch": "arm64e", "base": 6_954_643_456, "size": 785_540, "path": "/usr/lib/dyld", "name": "dyld"],
            ["size": 0, "source": "A", "base": 0],
        ]
        for (i, t) in tweakImages.enumerated() {
            var d: [String: Any] = ["source": "P", "arch": "arm64e", "base": 4_329_177_088 + i * 65536, "size": 49152]
            d["path"] = t.path
            d["name"] = t.name
            list.append(d)
        }
        return list
    }

    static func frames(_ f: [(Int, String?)]) -> [[String: Any]] {
        f.enumerated().map { i, fr in
            var d: [String: Any] = ["imageIndex": fr.0, "imageOffset": 4000 + i * 16]
            if let s = fr.1 { d["symbol"] = s; d["symbolLocation"] = 12 }
            return d
        }
    }

    var header: [String: Any] {
        var h: [String: Any] = ["app_name": appName, "timestamp": Self.captureTime(date),
                                "app_version": "", "build_version": "", "platform": 1, "share_with_app_devs": 0, "is_first_party": 0,
                                "bug_type": bugType, "os_version": "macOS 27.2.1 (26B131)", "roots_installed": 0, "name": appName,
                                "incident_id": incident]
        if let bundleID { h["bundleID"] = bundleID }
        if simulated { h["is_simulated"] = 1 }
        return h
    }

    var body: [String: Any] {
        var b: [String: Any] = [
            "procName": appName, "procPath": procPath, "captureTime": Self.captureTime(date), "incident": incident,
            "pid": 4242, "exception": exception, "faultingThread": 0, "bug_type": bugType,
            "threads": [["triggered": true, "id": 1, "queue": "com.apple.main-thread", "frames": Self.frames(faulting)],
                        ["id": 2, "frames": Self.frames([(IPS.kernel, "__workq_kernreturn")])]],
            "usedImages": images,
        ]
        if let bundleID { b["bundleInfo"] = ["CFBundleIdentifier": bundleID] }
        if let exceptionBacktrace { b["lastExceptionBacktrace"] = Self.frames(exceptionBacktrace) }
        return b
    }

    var text: String {
        let h = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let b = try! JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: h, as: UTF8.self) + "\n" + String(decoding: b, as: UTF8.self)
    }

    func report(path: String = "/reports/x.ips") -> CrashReport {
        try! CrashReportParser.parse(data: Data(text.utf8), path: path)
    }
}

let tweaksDir = "/opt/dynject/lib/tweaks"
let goodTweak = SafeModeTweak(tweakID: "local.dynject.safemode.good", name: "Good", dylibPath: "\(tweaksDir)/libGood.dylib", hasManifest: true)
let otherTweak = SafeModeTweak(tweakID: "local.dynject.safemode.other", name: "Other", dylibPath: "\(tweaksDir)/libOther.dylib", hasManifest: true)
let loneDylib = SafeModeTweak(tweakID: "dylib:libLone.dylib", name: "libLone.dylib", dylibPath: "\(tweaksDir)/libLone.dylib", hasManifest: false)
let testCatalog = SafeModeCatalog(tweaks: [goodTweak, otherTweak, loneDylib])
let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

func manifest(_ id: String, dylib: String, name: String? = nil) -> TweakManifest {
    TweakManifest(id: id, name: name ?? id, dylib: dylib, summary: nil, version: nil, author: nil, takesEffect: .relaunch,
                  applyCommand: nil, sections: [], sourcePath: "/m/\(id).workbench.plist")
}

// MARK: - Parser

final class CrashReportParserTests: XCTestCase {
    func testParsesRealisticObjCExceptionReport() throws {
        let r = try CrashReportParser.parse(fileAt: Fixtures.url("safemode/S2-objc-exception.ips").path)
        XCTAssertTrue(r.isCrash)
        XCTAssertTrue(r.hasBody)
        XCTAssertEqual(r.bundleID, "local.dynject.menuloader.skeptic2")
        XCTAssertEqual(r.appName, "S2")
        XCTAssertEqual(r.processName, "S2")
        XCTAssertEqual(r.incidentID, "91E88724-D13E-4738-883F-6F98EA23CF38")
        XCTAssertEqual(r.exceptionDescription, "EXC_CRASH (SIGABRT)")
        XCTAssertEqual(r.faultingThread, 0)
        XCTAssertEqual(r.faultingFrames.first?.symbol, "__pthread_kill")
        XCTAssertEqual(r.lastExceptionBacktrace.first?.symbol, "__exceptionPreprocess")
        XCTAssertEqual(r.images.first?.fileName, "libMenuLoader.dylib")
        XCTAssertTrue(r.images.first!.isAnonymised)
        XCTAssertTrue(r.images.contains { $0.path == nil && $0.fileName == nil }, "the unknown image (source A) parses")
        XCTAssertEqual(r.date, CrashReportParser.parseDate("2026-11-19 15:52:11.3363 -0600"))
    }

    func testParsesDates() {
        let d = CrashReportParser.parseDate("2026-11-19 06:32:44.9746 -0600")
        let whole = CrashReportParser.parseDate("2026-11-19 06:32:44 -0600")
        XCTAssertNotNil(whole)
        XCTAssertEqual(d!.timeIntervalSince(whole!), 0.9746, accuracy: 0.0001)
        XCTAssertNotNil(CrashReportParser.parseDate("2026-11-19 06:32:45.00 -0600"))
        XCTAssertNil(CrashReportParser.parseDate("yesterday"))
        XCTAssertEqual(IPS(date: baseDate).report().date!.timeIntervalSince1970, baseDate.timeIntervalSince1970, accuracy: 0.001)
    }

    func testToleratesMissingWrongTypedAndFutureFields() throws {
        // Header only, bundle ID only in the header, a numeric CFBundleIdentifier (seen in real reports), no threads.
        let text = """
        {"bug_type":"309","bundleID":"local.dynject.safemode.h","incident_id":"I1","timestamp":"2026-11-19 06:32:45.00 -0600","newHeaderField":[1,2]}
        {"bundleInfo":{"CFBundleIdentifier":42},"faultingThread":"zero","usedImages":[{"name":"libA.dylib"},7,{"path":"/x/libB.dylib"}],"threads":"nope","v2":{"x":1}}
        """
        let r = try CrashReportParser.parse(data: Data(text.utf8), path: "/r.ips")
        XCTAssertTrue(r.hasBody)
        XCTAssertEqual(r.bundleID, "local.dynject.safemode.h")
        XCTAssertNil(r.faultingThread)
        XCTAssertEqual(r.faultingFrames, [])
        XCTAssertEqual(r.images.map(\.fileName), ["libA.dylib", nil, "libB.dylib"])
        XCTAssertNotNil(r.date)
        // The triggered thread is used when faultingThread is missing.
        let t2 = """
        {"bug_type":"309"}
        {"threads":[{"frames":[]},{"triggered":true,"frames":[{"imageIndex":0,"imageOffset":16}]}],"usedImages":[{"name":"x"}]}
        """
        XCTAssertEqual(try CrashReportParser.parse(data: Data(t2.utf8), path: "/r").faultingFrames.count, 1)
    }

    func testMalformedReports() {
        XCTAssertThrowsError(try CrashReportParser.parse(data: Data("not json\n{}".utf8), path: "/bad.ips"))
        XCTAssertThrowsError(try CrashReportParser.parse(data: Data(), path: "/empty.ips"))
        let truncated = try! CrashReportParser.parse(data: Data("{\"bug_type\":\"309\"}\n{\"procName\":\"X\",".utf8), path: "/t.ips")
        XCTAssertFalse(truncated.hasBody)
        XCTAssertTrue(truncated.isCrash)
    }

    func testCrashTypes() {
        XCTAssertTrue(IPS().report().isCrash)
        XCTAssertFalse(IPS(bugType: "288").report().isCrash, "stackshots aren't crashes")
        XCTAssertFalse(IPS(simulated: true).report().isCrash, "ExcUserFault reports are simulated")
    }
}

// MARK: - Catalog, attribution, support

final class SafeModeAttributionTests: XCTestCase {
    func testCatalogFromManifestsAndDylibDirectory() {
        let dylibs: [String: Data] = [
            "/opt/t/libMenu.dylib": Data("xx\0local.a.menu\0yy dynject.safemode".utf8),
        ]
        let c = SafeModeCatalog(
            manifests: [manifest("local.a.menu", dylib: "/opt/t/libMenu.dylib", name: "Menu"),
                        manifest("local.a.menu.trial", dylib: "/opt/t/libMenu.dylib"),
                        manifest("local.a.badge", dylib: "/opt/t/libBadge.dylib"),
                        manifest("local.a.x", dylib: "/opt/t/libX.dylib"), manifest("local.a.y", dylib: "/opt/t/libX.dylib")],
            dylibDirectory: "/opt/t",
            listDirectory: { _ in ["libMenu.dylib", "libBadge.dylib", "libBrutal.dylib", "notes.txt", "libX.dylib"] },
            readFile: { dylibs[$0] })
        XCTAssertEqual(c.tweaks.map(\.tweakID),
                       ["local.a.badge", "local.a.menu", "local.a.x", "local.a.y", "dylib:libBrutal.dylib"],
                       "the manifest whose ID is compiled into a shared dylib wins; unreadable shared dylibs keep all")
        XCTAssertFalse(c.tweak("dylib:libBrutal.dylib")!.canUseSafeModeKey)
        XCTAssertEqual(c.tweak("dylib:libBrutal.dylib")!.dylibPath, "/opt/t/libBrutal.dylib")
    }

    func testImageMatching() {
        let c = testCatalog
        XCTAssertEqual(c.tweaks(matching: .init(path: "\(tweaksDir)/libGood.dylib", name: "libGood.dylib")), [goodTweak])
        XCTAssertEqual(c.tweaks(matching: .init(path: "/Users/USER/*/libGood.dylib", name: "libGood.dylib")), [goodTweak],
                       "anonymised paths match by file name")
        XCTAssertEqual(c.tweaks(matching: .init(path: nil, name: "libGood.dylib")), [goodTweak])
        XCTAssertEqual(c.tweaks(matching: .init(path: "/Applications/X.app/Contents/Frameworks/libGood.dylib", name: "libGood.dylib")), [],
                       "an intact path elsewhere is a different library")
        XCTAssertEqual(c.tweaks(matching: .init(path: "/usr/lib/libobjc.A.dylib", name: "libobjc.A.dylib")), [])
    }

    func testCrashInsideTweakAfterAbortMachinery() {
        var ips = IPS(tweakImages: [("\(tweaksDir)/libGood.dylib", "libGood.dylib"), ("/Users/USER/*/libOther.dylib", "libOther.dylib")])
        ips.faulting = [(IPS.objc, "objc_msgSend"), (IPS.firstTweak, "-[GoodHook layout]"), (IPS.appKit, "-[NSView layout]"), (IPS.host, "main")]
        let a = CrashAttributor.attribute(ips.report(), catalog: testCatalog)
        XCTAssertEqual(a.tweakIDs, [goodTweak.tweakID, otherTweak.tweakID])
        XCTAssertEqual(a.culprits, [goodTweak])
        XCTAssertEqual(a.loaded[0].frame, "libGood.dylib: -[GoodHook layout]")
        XCTAssertEqual(a.frameSummary, "EXC_BAD_ACCESS (SIGSEGV) in libGood.dylib: -[GoodHook layout]")
    }

    func testCrashElsewhereWithTweakDeepInStack() {
        var ips = IPS(tweakImages: [("\(tweaksDir)/libGood.dylib", "libGood.dylib")])
        ips.faulting = [(IPS.cf, "CFRelease")] + Array(repeating: (IPS.appKit, "-[NSWindow sendEvent:]"), count: 6)
            + [(IPS.firstTweak, "-[GoodHook sendEvent:]"), (IPS.host, "main")]
        let a = CrashAttributor.attribute(ips.report(), catalog: testCatalog)
        XCTAssertEqual(a.tweakIDs, [goodTweak.tweakID])
        XCTAssertEqual(a.culprits, [])
        XCTAssertEqual(a.frameSummary, "EXC_BAD_ACCESS (SIGSEGV) in CoreFoundation: CFRelease")
        XCTAssertEqual(CrashAttributor.attribute(ips.report(), catalog: testCatalog, depth: 8).culprits, [goodTweak])
    }

    func testObjCExceptionThrownFromTweak() {
        var ips = IPS(tweakImages: [("\(tweaksDir)/libGood.dylib", "libGood.dylib")])
        ips.exception = ["type": "EXC_CRASH", "signal": "SIGABRT"]
        ips.faulting = IPS.abortFrames + [(IPS.cf, "-[__NSArrayI objectAtIndex:]"), (IPS.appKit, "-[NSApplication run]")]
        ips.exceptionBacktrace = [(IPS.cf, "__exceptionPreprocess"), (IPS.objc, "objc_exception_throw"),
                                  (IPS.cf, "-[NSObject(NSObject) doesNotRecognizeSelector:]"), (IPS.cf, "___forwarding___"),
                                  (IPS.cf, "_CF_forwarding_prep_0"), (IPS.firstTweak, nil), (IPS.appKit, "-[NSApplication run]")]
        let a = CrashAttributor.attribute(ips.report(), catalog: testCatalog)
        XCTAssertEqual(a.culprits, [goodTweak])
        XCTAssertTrue(a.frameSummary.hasPrefix("EXC_CRASH (SIGABRT) in libGood.dylib + 0x"), a.frameSummary)
    }

    func testRealReportWithAnonymisedTweakNotInTopFrames() throws {
        let r = try CrashReportParser.parse(fileAt: Fixtures.url("safemode/S2-objc-exception.ips").path)
        let menu = SafeModeTweak(tweakID: "local.dynject.menuloader", name: "MenuLoader",
                                 dylibPath: "\(tweaksDir)/libMenuLoader.dylib", hasManifest: true)
        let a = CrashAttributor.attribute(r, catalog: SafeModeCatalog(tweaks: [menu]))
        XCTAssertEqual(a.tweakIDs, ["local.dynject.menuloader"], "matched by file name through the anonymised path")
        XCTAssertEqual(a.culprits, [], "the exception was thrown by the app's own block")
        XCTAssertEqual(a.frameSummary, "EXC_CRASH (SIGABRT) in CoreFoundation: -[__NSSingleObjectArrayI objectAtIndex:]")
        // Had the host been the tweak, the thrown-from frame would be in it.
        let s2 = SafeModeTweak(tweakID: "x", name: "S2", dylibPath: "/opt/t/S2", hasManifest: true)
        var r2 = r
        r2.processPath = "/Applications/Other.app/Contents/MacOS/Other"
        XCTAssertEqual(CrashAttributor.attribute(r2, catalog: SafeModeCatalog(tweaks: [s2])).culprits, [s2])
        XCTAssertEqual(CrashAttributor.attribute(r, catalog: SafeModeCatalog(tweaks: [s2])).tweakIDs, [],
                       "the app's own executable is never a tweak")
    }

    func testReportWithoutTweaks() {
        XCTAssertEqual(CrashAttributor.attribute(IPS().report(), catalog: testCatalog).loaded, [])
    }

    func testSupportCheck() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let yes = dir.appendingPathComponent("libYes.dylib"), no = dir.appendingPathComponent("libNo.dylib")
        try Data("\u{0}\u{1}junk\u{0}dynject.safemode\u{0}more".utf8).write(to: yes)
        try Data("\u{0}junk (dynject.safemode)\u{0}local.dynject.safemode.x\u{0}".utf8).write(to: no)
        let current = dir.appendingPathComponent("libCurrent.dylib")
        try Data("\u{0}dynject.safemode\u{0}x\u{0}dynject.safemode:all-tweaks\u{0}".utf8).write(to: current)
        let checker = SafeModeSupportChecker()
        XCTAssertEqual(checker.supportsSafeMode(dylibAt: yes.path), true)
        XCTAssertEqual(checker.support(dylibAt: yes.path), .perTweak, "an older DynjectHook: no panic switch")
        XCTAssertEqual(checker.honoursPanic(dylibAt: yes.path), false)
        XCTAssertEqual(checker.support(dylibAt: current.path), .perTweakAndPanic)
        XCTAssertEqual(checker.support(dylibAt: no.path), .unsupported)
        XCTAssertEqual(checker.supportsSafeMode(dylibAt: no.path), false)
        XCTAssertNil(checker.supportsSafeMode(dylibAt: dir.appendingPathComponent("missing").path))
        // Cached by size and mtime: a rebuilt dylib is checked again.
        try Data("rebuilt with\u{0}dynject.safemode\u{0}".utf8).write(to: no)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: no.path)
        XCTAssertEqual(checker.supportsSafeMode(dylibAt: no.path), true)
    }

    /// The byte check relies on DynjectHook embedding the key as a string literal.
    func testDynjectHookSourceEmbedsTheMarker() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("TweakSDK/DynjectHook.m"), encoding: .utf8)
        XCTAssertTrue(source.contains("CFSTR(\"dynject.safemode\")"))
        XCTAssertTrue(source.contains("\"dynject.safemode:all-tweaks\""), "the panic-switch capability marker")
    }
}

// MARK: - Rules

final class SafeModeRulesTests: XCTestCase {
    var state = SafeModeState()
    let now = baseDate.addingTimeInterval(60)

    func crash(_ ips: IPS) -> SafeModeEvaluation {
        let r = ips.report(path: "/reports/\(ips.incident).ips")
        return SafeModeRules.evaluate(r, attribution: CrashAttributor.attribute(r, catalog: testCatalog), state: &state, now: now)
    }

    func inTweak(at date: Date = baseDate) -> IPS {
        var ips = IPS(date: date, tweakImages: [("\(tweaksDir)/libGood.dylib", "libGood.dylib")])
        ips.faulting = [(IPS.firstTweak, "-[GoodHook boom]"), (IPS.host, "main")]
        return ips
    }

    func elsewhere(at date: Date, bundleID: String = "local.dynject.safemode.host") -> IPS {
        IPS(bundleID: bundleID, date: date, tweakImages: [("\(tweaksDir)/libGood.dylib", "libGood.dylib")])
    }

    func testCrashInTweakDisablesImmediately() {
        let e = crash(inTweak())
        XCTAssertEqual(e.decisions.map(\.tweak), [goodTweak])
        XCTAssertEqual(e.decisions.first?.reason, .crashInTweak)
        XCTAssertEqual(e.decisions.first?.bundleID, "local.dynject.safemode.host")
        XCTAssertEqual(e.crashes.first?.inTweak, true)
        XCTAssertEqual(state.recentCrashes.count, 1)
    }

    func testRepeatedCrashesWithinWindow() {
        XCTAssertEqual(crash(elsewhere(at: baseDate.addingTimeInterval(-300))).decisions, [])
        let e = crash(elsewhere(at: baseDate))
        XCTAssertEqual(e.decisions.map(\.reason), [.repeatedCrashes])
        XCTAssertEqual(e.decisions.first?.crashCount, 2)
    }

    func testRepeatedCrashesOutsideWindow() {
        XCTAssertEqual(crash(elsewhere(at: baseDate.addingTimeInterval(-11 * 60))).decisions, [])
        XCTAssertEqual(crash(elsewhere(at: baseDate)).decisions, [], "11 minutes apart with a 10-minute window")
        state.settings.windowMinutes = 15
        XCTAssertEqual(crash(elsewhere(at: baseDate.addingTimeInterval(1))).decisions.count, 1)
    }

    func testCrashesInOtherAppsDontCount() {
        _ = crash(elsewhere(at: baseDate.addingTimeInterval(-60), bundleID: "local.dynject.safemode.a"))
        XCTAssertEqual(crash(elsewhere(at: baseDate, bundleID: "local.dynject.safemode.b")).decisions, [])
    }

    func testThresholdSetting() {
        state.settings.threshold = 3
        _ = crash(elsewhere(at: baseDate.addingTimeInterval(-120)))
        XCTAssertEqual(crash(elsewhere(at: baseDate.addingTimeInterval(-60))).decisions, [])
        XCTAssertEqual(crash(elsewhere(at: baseDate)).decisions.count, 1)
    }

    func testIgnoresNonCrashesAndDuplicates() {
        XCTAssertEqual(crash(IPS(bugType: "288", tweakImages: [("\(tweaksDir)/libGood.dylib", nil)])), .notACrash)
        XCTAssertEqual(crash(IPS(simulated: true, tweakImages: [("\(tweaksDir)/libGood.dylib", nil)])), .notACrash)
        let ips = inTweak()
        XCTAssertEqual(crash(ips).decisions.count, 1)
        XCTAssertEqual(crash(ips), .duplicate, "same incident_id (e.g. a .000.ips copy)")
        XCTAssertEqual(state.recentCrashes.count, 1)
    }

    func testReportWithoutTweaks() {
        XCTAssertEqual(crash(IPS()), .noTweaks)
        XCTAssertEqual(state.recentCrashes, [])
    }

    func testTweakWithoutManifestIsRecordedButNotDisabled() {
        var ips = IPS(tweakImages: [("\(tweaksDir)/libLone.dylib", "libLone.dylib")])
        ips.faulting = [(IPS.firstTweak, nil)]
        let e = crash(ips)
        XCTAssertEqual(e.crashes.map(\.tweakID), ["dylib:libLone.dylib"])
        XCTAssertEqual(e.crashes.first?.inTweak, true)
        XCTAssertEqual(e.decisions, [])
    }

    func testNoBundleIDNeverDisables() {
        var ips = inTweak()
        ips.bundleID = nil
        let e = crash(ips)
        XCTAssertEqual(e.crashes.count, 1)
        XCTAssertNil(e.crashes.first?.bundleID)
        XCTAssertEqual(e.decisions, [])
    }

    func testReenableThenOldCrash() {
        _ = crash(elsewhere(at: baseDate.addingTimeInterval(-120)))
        state.recordReenable(tweakID: goodTweak.tweakID, bundleID: "local.dynject.safemode.host", at: baseDate.addingTimeInterval(-60))
        // An older in-tweak report processed late (e.g. the watcher was stopped) doesn't count.
        XCTAssertEqual(crash(inTweak(at: baseDate.addingTimeInterval(-90))).decisions, [])
        // The crash before the re-enable doesn't make the next one the second.
        XCTAssertEqual(crash(elsewhere(at: baseDate)).decisions, [])
        XCTAssertEqual(crash(elsewhere(at: baseDate.addingTimeInterval(30))).decisions.count, 1)
    }

    func testReenableEverywhereAndClear() {
        state.recordReenable(tweakID: goodTweak.tweakID, bundleID: "*", at: baseDate.addingTimeInterval(10))
        XCTAssertEqual(crash(inTweak()).decisions, [])
        state = SafeModeState()
        state.recordReenable(tweakID: "*", bundleID: "*", at: baseDate.addingTimeInterval(10))
        XCTAssertEqual(crash(inTweak()).decisions, [])
        XCTAssertEqual(crash(inTweak(at: baseDate.addingTimeInterval(20))).decisions.count, 1)
    }

    func testOldReportsNeverDisable() {
        XCTAssertEqual(crash(inTweak(at: now.addingTimeInterval(-2 * 3600))).decisions, [])
        XCTAssertEqual(state.recentCrashes.count, 1, "still listed as a recent crash")
    }

    func testDynjectItselfIsIgnored() {
        var ips = inTweak()
        ips.procPath = "/opt/dynject/bin/dynjectd"
        XCTAssertEqual(crash(ips), .dynject)
    }

    func testInertTweaksAreSkipped() {
        let r = elsewhere(at: baseDate).report()
        let e = SafeModeRules.evaluate(r, attribution: CrashAttributor.attribute(r, catalog: testCatalog), state: &state,
                                       now: now, isInert: { t, _ in t == goodTweak })
        XCTAssertEqual(e, .noTweaks)
        // A frame in the tweak proves it ran, whatever isInert says.
        let r2 = inTweak().report()
        let e2 = SafeModeRules.evaluate(r2, attribution: CrashAttributor.attribute(r2, catalog: testCatalog), state: &state,
                                        now: now, isInert: { t, _ in t == goodTweak })
        XCTAssertEqual(e2.decisions.map(\.reason), [.crashInTweak])
    }

    func testWasSuppressedUsesWhenEachEntryBegan() {
        let t = goodTweak.tweakID, app = "com.a"
        var s = SafeModeState()
        s.setDisabled(.init(tweakID: t, bundleID: app, since: baseDate, reason: .manual))
        let entries = [t: [app]]
        XCTAssertFalse(SafeModeRules.wasSuppressed(tweakID: t, bundleID: app, at: baseDate.addingTimeInterval(-1), entries: entries,
                                                   state: s, support: .perTweakAndPanic), "crashed before it was disabled")
        XCTAssertTrue(SafeModeRules.wasSuppressed(tweakID: t, bundleID: app, at: baseDate.addingTimeInterval(1), entries: entries,
                                                  state: s, support: .perTweak))
        XCTAssertFalse(SafeModeRules.wasSuppressed(tweakID: t, bundleID: app, at: baseDate.addingTimeInterval(1), entries: entries,
                                                   state: s, support: .unsupported))
        XCTAssertTrue(SafeModeRules.wasSuppressed(tweakID: t, bundleID: "com.b", at: baseDate, entries: ["other": ["x"], t: ["*"]],
                                                  state: s, support: .perTweak), "no record: taken to predate the crash")
        s.panicSince = baseDate
        let panic = ["*": ["*"]]
        XCTAssertFalse(SafeModeRules.wasSuppressed(tweakID: t, bundleID: app, at: baseDate.addingTimeInterval(-1), entries: panic,
                                                   state: s, support: .perTweakAndPanic))
        XCTAssertTrue(SafeModeRules.wasSuppressed(tweakID: t, bundleID: app, at: baseDate.addingTimeInterval(1), entries: panic,
                                                  state: s, support: .perTweakAndPanic))
        XCTAssertFalse(SafeModeRules.wasSuppressed(tweakID: t, bundleID: app, at: baseDate.addingTimeInterval(1), entries: panic,
                                                   state: s, support: .perTweak), "older DynjectHook ignores \"*\"")
    }
}

// MARK: - Key store

final class SafeModeKeyStoreTests: XCTestCase {
    func testReadModifyWritePreservesOtherEntries() throws {
        let mem = MemoryTweakBackend()
        mem.keyed["dynject.safemode"] = ["someone.else": ["com.a"], "weird": 5, "mixed": ["com.b", 7]]
        let keys = SafeModeKeyStore(store: mem, names: .forDomain(SafeModeNames.testDomain))
        XCTAssertEqual(keys.entries(), ["someone.else": ["com.a"], "mixed": ["com.b"]])

        XCTAssertTrue(try keys.add(tweakID: "t", bundleID: "com.x"))
        XCTAssertFalse(try keys.add(tweakID: "t", bundleID: "com.x"))
        XCTAssertTrue(try keys.add(tweakID: "mixed", bundleID: "com.c"))
        XCTAssertEqual(mem.notifications, ["local.dynject.safemode.test.changed", "local.dynject.safemode.test.changed"])
        let raw = mem.keyed["dynject.safemode"]!
        XCTAssertEqual(raw["weird"] as? Int, 5, "values of other shapes are kept")
        XCTAssertEqual((raw["mixed"] as? [Any])?.count, 3)
        XCTAssertTrue(keys.isListed(tweakID: "t", bundleID: "com.x"))
        XCTAssertFalse(keys.isListed(tweakID: "t", bundleID: "com.y"))

        XCTAssertTrue(try keys.add(tweakID: "t", bundleID: "*"))
        XCTAssertEqual(keys.entries()["t"], ["*"], "\"*\" replaces the per-app entries")
        XCTAssertTrue(keys.isListed(tweakID: "t", bundleID: "com.y"))
        XCTAssertFalse(try keys.add(tweakID: "t", bundleID: "com.z"), "already covered by *")
        XCTAssertFalse(try keys.remove(tweakID: "t", bundleID: "com.x"))
        XCTAssertEqual(keys.entries()["t"], ["*"])
        XCTAssertTrue(try keys.remove(tweakID: "t", bundleID: "*"))
        XCTAssertNil(keys.entries()["t"])

        XCTAssertFalse(keys.isPanicOn)
        XCTAssertFalse(keys.isSuppressed(tweakID: "any", bundleID: "com.q"))
        XCTAssertTrue(try keys.add(tweakID: "*", bundleID: "com.q"))
        XCTAssertTrue(keys.isSuppressed(tweakID: "any", bundleID: "com.q"), "\"*\" lists apps every tweak stays out of")
        XCTAssertFalse(keys.isPanicOn)
        XCTAssertTrue(try keys.setPanic(true))
        XCTAssertTrue(keys.isSuppressed(tweakID: "any", bundleID: "com.r"))
        XCTAssertTrue(keys.isPanicOn)
        XCTAssertEqual(keys.entries()["*"], ["com.q", "*"])
        XCTAssertTrue(try keys.setPanic(false))
        XCTAssertEqual(keys.entries()["*"], ["com.q"], "panic off keeps the per-app \"every tweak\" entry")
        XCTAssertTrue(try keys.remove(tweakID: "*", bundleID: "com.q"))
        XCTAssertNil(keys.entries()["*"])
        XCTAssertNotNil(mem.keyed["dynject.safemode"]?["someone.else"])

        XCTAssertTrue(try keys.removeAll())
        XCTAssertNil(mem.keyed["dynject.safemode"], "an empty dictionary removes the key")
        XCTAssertFalse(try keys.removeAll())
    }

    func testRemovingLastAppRemovesTheTweakAndTheKey() throws {
        let mem = MemoryTweakBackend()
        let keys = SafeModeKeyStore(store: mem, names: .production)
        try keys.add(tweakID: "t", bundleID: "com.x")
        let writes = mem.writes
        XCTAssertFalse(try keys.remove(tweakID: "t", bundleID: "com.other"))
        XCTAssertEqual(mem.writes, writes, "no-op changes don't write")
        try keys.remove(tweakID: "t", bundleID: "com.x")
        XCTAssertNil(mem.keyed["dynject.safemode"])
        XCTAssertEqual(mem.notifications.last, "dynject.safemode.changed")
    }
}

/// The real CFPreferences backend in the test domain: the stored value has the shape DynjectHook's
/// DHShouldLoad reads (a dictionary of arrays of strings).
final class SafeModePreferencesTests: XCTestCase {
    let domain = SafeModeNames.testDomain

    override func tearDown() {
        CFPreferencesSetValue(SafeModeNames.productionKey as CFString, nil, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let plist = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Preferences/\(domain).plist")
        try? FileManager.default.removeItem(atPath: plist)
    }

    func raw() -> Any? {
        CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(SafeModeNames.productionKey as CFString, domain as CFString,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    func testRoundTripThroughCFPreferences() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sm = SafeMode.inDomain(domain, stateDirectory: dir)
        XCTAssertEqual(sm.keys.names.notification, "local.dynject.safemode.test.changed")
        try sm.disable(tweakID: "local.dynject.safemode.good", bundleID: "local.dynject.safemode.host")
        try sm.setPanic(true)
        XCTAssertEqual(raw() as? [String: [String]],
                       ["local.dynject.safemode.good": ["local.dynject.safemode.host"], "*": ["*"]])
        // A second instance (another process, in real life) sees the same entries.
        XCTAssertEqual(SafeMode.inDomain(domain, stateDirectory: dir).keys.entries(),
                       ["local.dynject.safemode.good": ["local.dynject.safemode.host"], "*": ["*"]])
        try sm.clear()
        XCTAssertNil(raw())
    }
}

// MARK: - State and facade

final class SafeModeStateTests: XCTestCase {
    func testStateRoundTripsAndToleratesDamage() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SafeModeStateStore(directory: dir)
        XCTAssertEqual(store.load(), SafeModeState())
        let d = Date(timeIntervalSince1970: 1_800_000_000.123)
        try store.update { s in
            s.settings.threshold = 3
            s.processedReports["a.ips"] = .init(size: 10, mtime: 1_800_000_000.123456, incidentID: "I")
            s.recentCrashes.append(.init(tweakID: "t", bundleID: "b", appName: "A", date: d, reportPath: "/r", inTweak: true,
                                         frameSummary: "x", incidentID: "I"))
            s.setDisabled(.init(tweakID: "t", bundleID: "b", since: d, reason: .crashInTweak, reportPath: "/r"))
            s.recordReenable(tweakID: "u", bundleID: "*", at: d)
        }
        let loaded = store.load()
        XCTAssertEqual(loaded.settings.threshold, 3)
        XCTAssertTrue(loaded.processedReports["a.ips"]!.matches(size: 10, mtime: 1_800_000_000.123456))
        XCTAssertEqual(loaded.recentCrashes.first?.date.timeIntervalSince1970 ?? 0, d.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loaded.disabled.first?.reason, .crashInTweak)
        XCTAssertEqual(loaded.reenabledAt(tweakID: "u", bundleID: "com.any"), loaded.reenabled.first?.date)
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(json.contains("\"crash in tweak\""))
        XCTAssertTrue(json.contains("\"windowMinutes\""))

        // One broken entry doesn't lose the rest; bad settings fall back to defaults.
        let damaged = """
        {"formatVersion": 9, "settings": {"threshold": 0, "windowMinutes": "ten", "notify": false},
         "recentCrashes": [{"tweakID": "t"}, {"tweakID": "t", "date": "2026-11-19T12:00:00Z", "reportPath": "/r",
           "inTweak": false, "frameSummary": "f"}],
         "disabled": "nope", "future": true}
        """
        try Data(damaged.utf8).write(to: store.fileURL)
        let s = store.load()
        XCTAssertEqual(s.settings.threshold, 1)
        XCTAssertEqual(s.settings.windowMinutes, 10)
        XCTAssertFalse(s.settings.notify)
        XCTAssertEqual(s.recentCrashes.count, 1)
        XCTAssertEqual(s.disabled, [])

        // An unreadable file is set aside, not silently lost.
        try Data("{garbage".utf8).write(to: store.fileURL)
        try store.update { $0.settings.notify = false }
        XCTAssertEqual(store.load().settings.notify, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.json.unreadable").path))
    }

    func testRecentCrashesAreCapped() {
        var s = SafeModeState()
        for i in 0..<(SafeModeState.maxRecentCrashes + 5) {
            s.recentCrashes.append(.init(tweakID: "t", bundleID: "b", appName: nil, date: Date(timeIntervalSince1970: Double(i)),
                                         reportPath: "/r\(i)", inTweak: false, frameSummary: "", incidentID: nil))
        }
        s.trimCrashes()
        XCTAssertEqual(s.recentCrashes.count, SafeModeState.maxRecentCrashes)
        XCTAssertEqual(s.recentCrashes.first?.reportPath, "/r5")
    }

    func testFacadeKeepsKeyAndStateConsistent() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mem = MemoryTweakBackend()
        mem.keyed["dynject.safemode"] = ["hand.added": ["com.h"]]
        let sm = SafeMode(keys: SafeModeKeyStore(store: mem, names: .production), stateStore: SafeModeStateStore(directory: dir))
        try sm.disable(tweakID: goodTweak.tweakID, bundleID: "com.a", now: baseDate)
        try sm.disable(tweakID: goodTweak.tweakID, bundleID: "com.b", now: baseDate)
        try sm.setPanic(true)
        try sm.disable(tweakID: "*", bundleID: "com.all", now: baseDate)

        let snap = sm.snapshot(catalog: testCatalog, support: nil)
        XCTAssertTrue(snap.panic)
        XCTAssertEqual(snap.disabled.map(\.id),
                       ["*|com.all", "hand.added|com.h", "\(goodTweak.tweakID)|com.a", "\(goodTweak.tweakID)|com.b"],
                       "the panic entry itself is reported as `panic`, not as a row")
        XCTAssertNil(snap.disabled[1].reason, "added outside Workbench")
        XCTAssertNil(snap.disabled[1].tweak)
        XCTAssertEqual(snap.disabled[2].reason, .manual)
        XCTAssertEqual(snap.disabled[2].since, baseDate)
        XCTAssertEqual(snap.disabled[2].tweak, goodTweak)

        try sm.enable(tweakID: goodTweak.tweakID, bundleID: "com.a", now: baseDate.addingTimeInterval(5))
        XCTAssertEqual(sm.keys.entries()[goodTweak.tweakID], ["com.b"])
        XCTAssertEqual(sm.stateStore.load().reenabledAt(tweakID: goodTweak.tweakID, bundleID: "com.a"), baseDate.addingTimeInterval(5))
        XCTAssertEqual(sm.stateStore.load().disabled.filter { $0.tweakID == goodTweak.tweakID }.map(\.bundleID), ["com.b"])

        try sm.enable(tweakID: goodTweak.tweakID, bundleID: "*", now: baseDate.addingTimeInterval(6))
        XCTAssertNil(sm.keys.entries()[goodTweak.tweakID])
        XCTAssertEqual(sm.stateStore.load().disabled.map(\.tweakID), ["*"])
        try sm.setPanic(false)
        XCTAssertEqual(sm.keys.entries()["*"], ["com.all"])

        try sm.clear(now: baseDate.addingTimeInterval(7))
        XCTAssertNil(mem.keyed["dynject.safemode"])
        XCTAssertFalse(sm.isPanicOn)
        XCTAssertEqual(sm.stateStore.load().reenabledAt(tweakID: "any", bundleID: "any"), baseDate.addingTimeInterval(7))

        try sm.updateSettings { $0.threshold = 4 }
        XCTAssertEqual(sm.settings().threshold, 4)
    }
}

// MARK: - Scanner (end to end on a temporary reports directory)

final class SafeModeScannerTests: XCTestCase {
    var root: URL!
    var reports: URL!
    var mem: MemoryTweakBackend!
    var notifier: RecordingNotifier!
    var dylibDir: URL!
    var clock = Date()

    override func setUpWithError() throws {
        root = try temporaryDirectory()
        reports = root.appendingPathComponent("DiagnosticReports")
        dylibDir = root.appendingPathComponent("tweaks")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dylibDir, withIntermediateDirectories: true)
        try Data("DynjectHook\0dynject.safemode\0local.dynject.safemode.good\0dynject.safemode:all-tweaks\0".utf8)
            .write(to: dylibDir.appendingPathComponent("libGood.dylib"))
        try Data("DynjectHook\0dynject.safemode\0local.dynject.safemode.old\0".utf8).write(to: dylibDir.appendingPathComponent("libOld.dylib"))
        try Data("plain dylib\0local.dynject.safemode.plain\0".utf8).write(to: dylibDir.appendingPathComponent("libPlain.dylib"))
        try Data("external".utf8).write(to: dylibDir.appendingPathComponent("libLone.dylib"))
        mem = MemoryTweakBackend()
        notifier = RecordingNotifier()
        clock = Date()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    var catalog: SafeModeCatalog {
        SafeModeCatalog(manifests: [manifest("local.dynject.safemode.good", dylib: dylibDir.appendingPathComponent("libGood.dylib").path, name: "Good"),
                                    manifest("local.dynject.safemode.plain", dylib: dylibDir.appendingPathComponent("libPlain.dylib").path, name: "Plain"),
                                    manifest("local.dynject.safemode.old", dylib: dylibDir.appendingPathComponent("libOld.dylib").path, name: "Old")],
                        dylibDirectory: dylibDir.path)
    }

    /// The key's store; tests may swap in one whose writes fail.
    var store: GlobalPrefsStore?

    func scanner() -> SafeModeScanner {
        let sm = SafeMode(keys: SafeModeKeyStore(store: store ?? mem, names: .forDomain(SafeModeNames.testDomain)),
                          stateStore: SafeModeStateStore(directory: root.appendingPathComponent("state")))
        let catalog = catalog
        return SafeModeScanner(reportsDirectory: reports.path, safeMode: sm, catalog: { catalog },
                               support: SafeModeSupportChecker(), notifier: notifier, now: { [unowned self] in clock })
    }

    @discardableResult
    func write(_ name: String, _ text: String, age: TimeInterval = 30) throws -> URL {
        let url = reports.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: clock.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    func ips(_ dylib: String, inTweak: Bool, at date: Date? = nil) -> IPS {
        ips([dylib], culprit: inTweak ? dylib : nil, at: date)
    }

    /// A crash with several tweaks loaded, inside `culprit` (nil: in the app's own code).
    func ips(_ dylibs: [String], culprit: String?, at date: Date? = nil) -> IPS {
        var i = IPS(appName: "SafeModeHost", date: date ?? clock.addingTimeInterval(-30),
                    tweakImages: dylibs.map { (dylibDir.appendingPathComponent($0).path, $0) })
        if let culprit, let n = dylibs.firstIndex(of: culprit) { i.faulting = [(IPS.firstTweak + n, "-[Hook boom]")] }
        return i
    }

    func testDisablesNotifiesAndNeverReprocesses() throws {
        try write("SafeModeHost-1.ips", ips("libGood.dylib", inTweak: true).text)
        try write("Other-1.ips", IPS(appName: "Other", bundleID: "local.dynject.safemode.other").text)
        try write("Hang-1.ips", IPS(bugType: "288").text)
        try write("notes.txt", "ignored")
        let r = scanner().scan()
        XCTAssertEqual(Set(r.examined), ["SafeModeHost-1.ips", "Other-1.ips", "Hang-1.ips"])
        XCTAssertEqual(r.disabled.map(\.tweak.tweakID), ["local.dynject.safemode.good"])
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(mem.keyed["dynject.safemode"] as NSDictionary?,
                       ["local.dynject.safemode.good": ["local.dynject.safemode.host"]] as NSDictionary)
        XCTAssertEqual(mem.notifications, ["local.dynject.safemode.test.changed"])
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertEqual(notifier.posted.first?.title, "Safe Mode: Good disabled in SafeModeHost")
        XCTAssertTrue(notifier.posted.first!.message.contains("Re-enable"))

        let s = scanner()
        let snap = s.safeMode.snapshot(catalog: catalog, support: SafeModeSupportChecker())
        XCTAssertEqual(snap.disabled.first?.reason, .crashInTweak)
        XCTAssertEqual(snap.disabled.first?.supportsSafeMode, true)
        XCTAssertTrue(snap.disabled.first!.reportPath!.hasSuffix("SafeModeHost-1.ips"))
        XCTAssertEqual(snap.recentCrashes.count, 1)

        // A restarted watcher (new scanner, same state) processes nothing again.
        let again = s.scan()
        XCTAssertEqual(again.examined, [])
        XCTAssertEqual(notifier.posted.count, 1)
        // A copy of the same incident under another name counts once.
        try write("SafeModeHost-1.000.ips", try String(contentsOf: reports.appendingPathComponent("SafeModeHost-1.ips"), encoding: .utf8))
        try scanner().safeMode.enable(tweakID: "local.dynject.safemode.good", bundleID: "*", now: clock.addingTimeInterval(-60))
        let copy = scanner().scan()
        XCTAssertEqual(copy.examined, ["SafeModeHost-1.000.ips"])
        XCTAssertEqual(copy.crashes, [])
        XCTAssertEqual(copy.disabled, [])
    }

    func testRepeatedCrashesAcrossScansAndUnsupportedTweak() throws {
        try write("A-1.ips", ips("libPlain.dylib", inTweak: false, at: clock.addingTimeInterval(-200)).text)
        XCTAssertEqual(scanner().scan().disabled, [])
        try write("A-2.ips", ips("libPlain.dylib", inTweak: false, at: clock.addingTimeInterval(-20)).text)
        let r = scanner().scan()
        XCTAssertEqual(r.disabled.map(\.reason), [.repeatedCrashes])
        XCTAssertTrue(notifier.posted.first!.message.contains("ignores Safe Mode"), notifier.posted.first!.message)
        let snap = scanner().safeMode.snapshot(catalog: catalog, support: SafeModeSupportChecker())
        XCTAssertEqual(snap.disabled.first?.supportsSafeMode, false)
    }

    func testUnmanifestedDylibIsRecordedOnly() throws {
        try write("L-1.ips", ips("libLone.dylib", inTweak: true).text)
        let r = scanner().scan()
        XCTAssertEqual(r.crashes.map(\.tweakID), ["dylib:libLone.dylib"])
        XCTAssertEqual(r.disabled, [])
        XCTAssertNil(mem.keyed["dynject.safemode"])
    }

    func testAlreadyDisabledOrPanicTweaksAreInert() throws {
        let s = scanner()
        try s.safeMode.setPanic(true, now: clock.addingTimeInterval(-100))
        XCTAssertEqual(s.safeMode.stateStore.load().panicSince?.timeIntervalSince1970 ?? 0,
                       clock.addingTimeInterval(-100).timeIntervalSince1970, accuracy: 0.001)
        try write("P-1.ips", ips("libGood.dylib", inTweak: false).text)
        let r = s.scan()
        XCTAssertEqual(r.crashes, [], "DynjectHook tweaks don't run during panic")
        XCTAssertEqual(r.disabled, [])
        XCTAssertEqual(mem.keyed["dynject.safemode"] as NSDictionary?, ["*": ["*"]] as NSDictionary)
    }

    func testNotificationsCanBeTurnedOff() throws {
        try scanner().safeMode.updateSettings { $0.notify = false }
        try write("N-1.ips", ips("libGood.dylib", inTweak: true).text)
        XCTAssertEqual(scanner().scan().disabled.count, 1)
        XCTAssertEqual(notifier.posted.count, 0)
    }

    func testSurvivesMalformedAndHalfWrittenReports() throws {
        try write("Bad-1.ips", "this is not json", age: 120)
        try write("Bad-2.ips", "{\"bug_type\":\"309\"}\n{\"procName\": \"half", age: 120)
        try write("Young-1.ips", "{\"bug_type\":\"309\"}\n{\"procName\": \"half", age: 5)
        try write("New-1.ips", ips("libPlain.dylib", inTweak: true).text, age: 0.5)
        try write("Good-1.ips", ips("libGood.dylib", inTweak: true).text)
        let s = scanner()
        let r = s.scan()
        XCTAssertEqual(Set(r.examined), ["Bad-1.ips", "Bad-2.ips", "Good-1.ips"])
        XCTAssertEqual(r.problems.count, 2, "\(r.problems)")
        XCTAssertEqual(r.pending, 2, "a young half-written report and one still settling are retried")
        XCTAssertEqual(r.disabled.count, 1)
        // Once complete and settled, they are picked up; the broken ones aren't retried.
        clock = clock.addingTimeInterval(120)
        try write("Young-1.ips", IPS(bugType: "288").text, age: 60)
        let r2 = s.scan()
        XCTAssertEqual(Set(r2.examined), ["Young-1.ips", "New-1.ips"])
        XCTAssertEqual(r2.problems, [])
        XCTAssertEqual(r2.crashes.map(\.tweakID), ["local.dynject.safemode.plain"])
        XCTAssertEqual(r2.disabled.map(\.reason), [.crashInTweak])
    }

    // MARK: Robustness

    var key: [String: [String]] { SafeModeKeyStore(store: mem, names: .production).entries() }
    var state: SafeModeState { scanner().safeMode.stateStore.load() }

    /// The panic switch takes the state lock like every other key writer, so it can't interleave with the
    /// watcher's read-modify-write.
    func testPanicSwitchWaitsForTheStateLock() throws {
        let s = scanner()
        let holder = SafeModeStateStore(directory: s.safeMode.stateStore.directory)
        let locked = DispatchSemaphore(value: 0)
        let done = expectation(description: "lock released")
        DispatchQueue.global().async {
            try? holder.update { _ in
                locked.signal()
                Thread.sleep(forTimeInterval: 0.4)
            }
            done.fulfill()
        }
        locked.wait()
        let start = Date()
        try s.safeMode.setPanic(true, now: clock)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.3, "setPanic waited for the lock")
        wait(for: [done], timeout: 5)
        XCTAssertTrue(s.safeMode.isPanicOn)
        XCTAssertEqual(state.panicSince?.timeIntervalSince1970 ?? 0, clock.timeIntervalSince1970, accuracy: 0.001)
        try s.safeMode.setPanic(true, now: clock.addingTimeInterval(9))
        XCTAssertEqual(state.panicSince?.timeIntervalSince1970 ?? 0, clock.timeIntervalSince1970, accuracy: 0.001,
                       "turning it on again keeps the original time")
        try s.safeMode.setPanic(false)
        XCTAssertNil(state.panicSince)
    }

    /// A pass stopped after writing the key but before saving state.json: the next pass fills in why.
    func testKeyWrittenButStateLostIsRecoveredOnTheNextPass() throws {
        try write("K-1.ips", ips("libGood.dylib", inTweak: true).text)
        mem.keyed["dynject.safemode"] = ["local.dynject.safemode.good": ["local.dynject.safemode.host"]]
        let r = scanner().scan()
        XCTAssertEqual(r.disabled.map(\.reason), [.crashInTweak])
        XCTAssertEqual(notifier.posted.count, 1, "the notification the stopped pass never posted")
        let entry = try XCTUnwrap(state.disabledEntry(tweakID: "local.dynject.safemode.good", bundleID: "local.dynject.safemode.host"))
        XCTAssertTrue(entry.reportPath?.hasSuffix("K-1.ips") ?? false)
        XCTAssertEqual(scanner().scan().disabled, [], "and only once")
    }

    /// The scanner saves state.json right after each key write, while the pass goes on.
    func testCommitSavesMidUpdate() throws {
        let store = SafeModeStateStore(directory: root.appendingPathComponent("state"))
        struct Stop: Error {}
        XCTAssertThrowsError(try store.updateCommitting { state, commit in
            state.settings.threshold = 7
            try commit(state)
            state.settings.threshold = 9
            throw Stop()
        })
        XCTAssertEqual(store.load().settings.threshold, 7, "what was committed survives a pass that dies later")
    }

    func testReportWithFutureModificationTimeIsReadNow() throws {
        try write("F-1.ips", ips("libGood.dylib", inTweak: true).text, age: -3600)
        let r = scanner().scan()
        XCTAssertEqual(r.pending, 0, "not left pending until the clock catches up")
        XCTAssertEqual(r.examined, ["F-1.ips"])
        XCTAssertEqual(r.disabled.map(\.reason), [.crashInTweak])
        try write("F-2.ips", "{\"bug_type\":\"309\"}\n{\"procName\": \"half", age: -3600)
        let r2 = scanner().scan()
        XCTAssertEqual(r2.pending, 0)
        XCTAssertEqual(r2.problems.count, 1)
    }

    /// Panic or a disable turned on after the crash, before the scan, doesn't discard the crash.
    func testSuppressionAddedAfterTheCrashDoesntDiscardIt() throws {
        let s = scanner()
        try write("A-1.ips", ips("libGood.dylib", inTweak: false, at: clock.addingTimeInterval(-200)).text)
        try write("A-2.ips", ips("libGood.dylib", inTweak: false, at: clock.addingTimeInterval(-100)).text)
        try s.safeMode.setPanic(true, now: clock.addingTimeInterval(-50))
        let r = s.scan()
        XCTAssertEqual(r.crashes.count, 2, "both crashes happened before panic")
        XCTAssertEqual(r.disabled.map(\.reason), [.repeatedCrashes])
        XCTAssertEqual(key["local.dynject.safemode.good"], ["local.dynject.safemode.host"],
                       "the per-app entry is there when panic goes off")
        // A crash after panic, outside the tweak: it wasn't running.
        try write("A-3.ips", ips("libGood.dylib", inTweak: false, at: clock.addingTimeInterval(-10)).text)
        XCTAssertEqual(scanner().scan().crashes, [])
    }

    func testInTweakCrashCountsEvenWhenTheKeyListsTheTweak() throws {
        // Listed with `defaults` (no record of when): taken to predate the crash, except that a frame in the
        // tweak proves it ran.
        mem.keyed["dynject.safemode"] = ["*": ["*"]]
        try write("B-1.ips", ips("libGood.dylib", inTweak: false).text)
        try write("B-2.ips", ips("libGood.dylib", inTweak: true).text)
        let r = scanner().scan()
        XCTAssertEqual(r.crashes.map(\.inTweak), [true])
        XCTAssertEqual(r.disabled.map(\.reason), [.crashInTweak])
    }

    /// Old DynjectHook builds ignore the panic switch: they ran, so their crashes count.
    func testOldDynjectHookBuildIsNotInertUnderPanic() throws {
        let s = scanner()
        try s.safeMode.setPanic(true, now: clock.addingTimeInterval(-500))
        try write("O-1.ips", ips("libOld.dylib", inTweak: false, at: clock.addingTimeInterval(-60)).text)
        try write("O-2.ips", ips("libOld.dylib", inTweak: false, at: clock.addingTimeInterval(-30)).text)
        let r = s.scan()
        XCTAssertEqual(r.crashes.map(\.tweakID), ["local.dynject.safemode.old", "local.dynject.safemode.old"])
        XCTAssertEqual(r.disabled.map(\.tweak.tweakID), ["local.dynject.safemode.old"])
        // Its own entry does stop it.
        clock = clock.addingTimeInterval(60)
        try write("O-3.ips", ips("libOld.dylib", inTweak: false, at: clock.addingTimeInterval(-5)).text)
        XCTAssertEqual(scanner().scan().crashes, [])
    }

    /// A crash pinned on one tweak doesn't count against another that merely shared the process.
    func testCrashesPinnedOnAnotherTweakDontCountAgainstBystanders() throws {
        // Plain ignores Safe Mode, keeps loading and keeps crashing in its own code; Good is a bystander.
        try write("C-1.ips", ips(["libPlain.dylib", "libGood.dylib"], culprit: "libPlain.dylib", at: clock.addingTimeInterval(-90)).text)
        try write("C-2.ips", ips(["libPlain.dylib", "libGood.dylib"], culprit: "libPlain.dylib", at: clock.addingTimeInterval(-60)).text)
        let r = scanner().scan()
        XCTAssertEqual(r.disabled.map(\.tweak.tweakID), ["local.dynject.safemode.plain"])
        XCTAssertNil(key["local.dynject.safemode.good"], "both crashes were Plain's")
        // One crash with no culprit: Good's count is 1, not 3.
        try write("C-3.ips", ips(["libPlain.dylib", "libGood.dylib"], culprit: nil, at: clock.addingTimeInterval(-30)).text)
        XCTAssertFalse(scanner().scan().disabled.contains { $0.tweak.tweakID == "local.dynject.safemode.good" })
        XCTAssertNil(key["local.dynject.safemode.good"])
    }

    /// A failed key write leaves the report to be evaluated again instead of losing the disable.
    func testFailedKeyWriteIsRetried() throws {
        let flaky = FlakyStore(mem)
        store = flaky
        flaky.failWrites = true
        try write("R-1.ips", ips("libGood.dylib", inTweak: true).text)
        let r = scanner().scan()
        XCTAssertEqual(r.retrying, 1)
        XCTAssertEqual(r.disabled, [])
        XCTAssertEqual(r.problems.count, 1)
        XCTAssertEqual(state.recentCrashes, [], "not recorded, so the retry isn't a duplicate")
        XCTAssertNil(state.processedReports["R-1.ips"])
        flaky.failWrites = false
        let r2 = scanner().scan()
        XCTAssertEqual(r2.disabled.map(\.reason), [.crashInTweak])
        XCTAssertEqual(r2.examined, ["R-1.ips"])
    }

    /// Entries removed with `defaults delete` count as re-enabled: the crashes behind them don't count again.
    func testEntryRemovedOutsideSafeModeCountsAsReenabled() throws {
        try write("D-1.ips", ips("libGood.dylib", inTweak: false, at: clock.addingTimeInterval(-120)).text)
        try write("D-2.ips", ips("libGood.dylib", inTweak: false, at: clock.addingTimeInterval(-100)).text)
        XCTAssertEqual(scanner().scan().disabled.map(\.reason), [.repeatedCrashes])
        clock = clock.addingTimeInterval(60)
        mem.keyed["dynject.safemode"] = nil   // defaults delete -g dynject.safemode
        try write("D-3.ips", ips("libGood.dylib", inTweak: false, at: clock.addingTimeInterval(-20)).text)
        let r = scanner().scan()
        XCTAssertEqual(r.crashes.count, 1)
        XCTAssertEqual(r.disabled, [], "one new crash is not two")
        XCTAssertEqual(state.disabled, [], "the stale record is gone")
        XCTAssertNotNil(state.reenabledAt(tweakID: "local.dynject.safemode.good", bundleID: "local.dynject.safemode.host"))
    }

    func testReenableReportsWhatStillKeepsTheTweakOut() throws {
        let sm = scanner().safeMode
        let t = "local.dynject.safemode.good"
        try sm.disable(tweakID: t, bundleID: "com.a")
        try sm.disable(tweakID: t, bundleID: "*")
        XCTAssertEqual(key[t], ["*"])
        XCTAssertThrowsError(try sm.enable(tweakID: t, bundleID: "com.a")) { e in
            XCTAssertEqual(e as? SafeModeError, .disabledEverywhere(tweakID: t, bundleID: "com.a"))
        }
        XCTAssertEqual(key[t], ["*"], "nothing changed")
        XCTAssertNil(sm.stateStore.load().reenabledAt(tweakID: t, bundleID: "com.a"))
        XCTAssertEqual(try sm.enable(tweakID: t, bundleID: "*"), [])

        try sm.disable(tweakID: t, bundleID: "com.b")
        try sm.disable(tweakID: "*", bundleID: "com.b")
        try sm.setPanic(true)
        let row = sm.snapshot(catalog: catalog, support: nil).disabled.first { $0.id == "\(t)|com.b" }
        XCTAssertEqual(row?.alsoOffBecause, [.allTweaksInApp, .panic])
        XCTAssertEqual(try sm.enable(tweakID: t, bundleID: "com.b"), [.allTweaksInApp, .panic])
        XCTAssertNil(key[t])
    }

    func testMissingReportsDirectory() {
        let sm = SafeMode(keys: SafeModeKeyStore(store: mem, names: .production), stateStore: SafeModeStateStore(directory: root))
        let s = SafeModeScanner(reportsDirectory: root.appendingPathComponent("nope").path, safeMode: sm, catalog: { testCatalog })
        XCTAssertEqual(s.scan().problems.count, 1)
    }

    func testWatcherReactsToNewReports() throws {
        let s = scanner()
        s.settleTime = 0
        let watcher = SafeModeWatcher(scanner: s, rescanInterval: 30, debounce: 0.1)
        let found = expectation(description: "the new report is processed")
        let initial = expectation(description: "initial scan")
        var sawInitial = false
        watcher.onScan = { r in
            if !sawInitial { sawInitial = true; initial.fulfill(); return }
            if r.disabled.count == 1 { found.fulfill() }
        }
        watcher.start()
        wait(for: [initial], timeout: 5)
        clock = Date()
        try write("W-1.ips", ips("libGood.dylib", inTweak: true, at: Date()).text, age: 0)
        wait(for: [found], timeout: 10)
        watcher.stop()
    }
}

/// A key store whose writes can be made to fail (cfprefsd unavailable).
final class FlakyStore: GlobalPrefsStore {
    let inner: MemoryTweakBackend
    var failWrites = false
    init(_ inner: MemoryTweakBackend) { self.inner = inner }
    func dictionary(forKey key: String) -> [String: Any]? { inner.dictionary(forKey: key) }
    func setDictionary(_ value: [String: Any]?, forKey key: String) throws {
        if failWrites { throw WriteError.io("simulated CFPreferencesSynchronize failure") }
        try inner.setDictionary(value, forKey: key)
    }
    func postNotification(_ name: String) { inner.postNotification(name) }
}

// MARK: - LaunchAgent

final class SafeModeAgentTests: XCTestCase {
    func testPlistInstallStatusUninstall() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("dw-src")
        try Data("#!/bin/sh\necho dw\n".utf8).write(to: src)
        let runner = RecordingLaunchctlRunner()
        let agent = SafeModeAgent(launchAgentsDirectory: dir.appendingPathComponent("LaunchAgents"),
                                  binDirectory: dir.appendingPathComponent("bin"), runner: runner, uid: 501)

        let p = agent.plist()
        XCTAssertEqual(p["Label"] as? String, "local.dynject.safemode")
        XCTAssertEqual(p["ProgramArguments"] as? [String], [dir.appendingPathComponent("bin/dw").path, "safemode", "watch"])
        XCTAssertEqual(p["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(p["KeepAlive"] as? Bool, true)

        XCTAssertFalse(agent.status().plistInstalled)
        let report = try agent.install(sourceBinary: src.path, extraArguments: ["--state-dir", "/tmp/s"])
        XCTAssertEqual(report.plist, dir.appendingPathComponent("LaunchAgents/local.dynject.safemode.plist").path)
        XCTAssertEqual(Array(runner.calls.suffix(2)), [["bootout", "gui/501/local.dynject.safemode"],
                                      ["bootstrap", "gui/501", report.plist]])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: report.binary))
        XCTAssertEqual(FileManager.default.contents(atPath: report.binary), FileManager.default.contents(atPath: src.path))
        let lint = try ProcessRunner.run("/usr/bin/plutil", ["-lint", report.plist])
        XCTAssertEqual(lint.status, 0, lint.stdout + lint.stderr)
        let written = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: report.plist)),
                                                                 format: nil) as! [String: Any]
        XCTAssertEqual(written["ProgramArguments"] as? [String], [report.binary, "safemode", "watch", "--state-dir", "/tmp/s"])

        runner.respond = { args in
            args.first == "print" ? (0, "gui/501/local.dynject.safemode = {\n\tactive count = 1\n\tstate = running\n\tpid = 777\n\tlast exit code = (never exited)\n\tendpoints = {\n\t\tstate = nested\n\t}\n}\n") : (0, "")
        }
        let st = agent.status()
        XCTAssertTrue(st.plistInstalled && st.binaryInstalled && st.loaded && st.running && st.plistMatches)
        XCTAssertEqual(st.pid, 777)
        XCTAssertEqual(st.summary, "running (pid 777)")

        runner.respond = { _ in (5, "Bootstrap failed: 5: Input/output error") }
        XCTAssertThrowsError(try agent.install(sourceBinary: src.path))
        XCTAssertThrowsError(try agent.install(sourceBinary: dir.appendingPathComponent("missing").path))

        runner.respond = { args in args.first == "print" ? (113, "Could not find service") : (0, "") }
        try agent.uninstall()
        XCTAssertEqual(runner.calls.last { $0.first == "bootout" }, ["bootout", "gui/501/local.dynject.safemode"])
        let after = agent.status()
        XCTAssertFalse(after.plistInstalled || after.binaryInstalled || after.loaded)
        XCTAssertEqual(after.summary, "not installed")
    }

    func testNotificationScriptQuoting() {
        XCTAssertEqual(OsascriptNotifier.script(title: "A \"B\"", message: "c\\d"),
                       "display notification \"c\\\\d\" with title \"A \\\"B\\\"\"")
    }
}
