@testable import DynjectCore
import XCTest

/// `dw why`: the DH_CTOR marker, finding the tweak and the app, and `Why.explain` on made-up inputs.
final class TweakWhyTests: XCTestCase {
    static let dylib = "/opt/dynject/lib/tweaks/libFoo.dylib"
    static let id = "local.test.foo"

    // MARK: marker

    func testMarkerParse() {
        XCTAssertEqual(CtorMarker.parse(#""local.a"|"com.apple.finder", "com.apple.TextEdit""#),
                       CtorMarker(tweakID: "local.a", bundleIDs: ["com.apple.finder", "com.apple.TextEdit"]))
        XCTAssertEqual(CtorMarker.parse(#""local.a"|"#), CtorMarker(tweakID: "local.a", bundleIDs: []), "no bundle IDs: every app")
        XCTAssertEqual(CtorMarker.parse(#""local.a"|MY_APPS"#), CtorMarker(tweakID: "local.a", bundleIDs: nil), "not literals: unknown")
        XCTAssertEqual(CtorMarker.parse(#"MY_ID|"com.x""#), CtorMarker(tweakID: nil, bundleIDs: ["com.x"]))
        XCTAssertEqual(CtorMarker.parse(#""local." "a"|"com." "x", "y""#), CtorMarker(tweakID: "local.a", bundleIDs: ["com.x", "y"]),
                       "adjacent literals concatenate")
        XCTAssertEqual(CtorMarker.parse(#""a\"b|c"|"d""#), CtorMarker(tweakID: "a\"b|c", bundleIDs: ["d"]), "escapes; | inside a literal")
        XCTAssertNil(CtorMarker.parse(#""unterminated|"x""#))
        XCTAssertNil(CtorMarker.parse(#""no bar""#))
    }

    func testMarkersInData() {
        var d = Data([0x7F, 0])
        for _ in 0..<2 { d.append(Data("dynject.ctor:\"local.a\"|\"com.x\"\u{0}junk".utf8)) }   // one per slice
        d.append(Data("dynject.ctor:\"local.b\"|\u{0}".utf8))
        d.append(Data("dynject.ctor:\"unterminated\"|".utf8))
        XCTAssertEqual(CtorMarker.markers(in: d), [CtorMarker(tweakID: "local.a", bundleIDs: ["com.x"]),
                                                   CtorMarker(tweakID: "local.b", bundleIDs: [])])
        XCTAssertEqual(CtorMarker.markers(in: Data("nothing here".utf8)), [])
    }

    /// DynjectHook.h writes the prefix the parser looks for (DHTCtorMatchTests checks it reaches the image).
    func testHeaderUsesThePrefix() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let header = try String(contentsOf: root.appendingPathComponent("TweakSDK/include/DynjectHook.h"), encoding: .utf8)
        XCTAssertTrue(header.contains("\"\(CtorMarker.prefix)\" DH_STRINGIFY_(TWEAK_ID) \"|\" DH_STRINGIFY_(__VA_ARGS__)"))
    }

    // MARK: lookup

    func manifest(_ id: String, name: String, dylib: String) -> TweakManifest {
        let d: [String: Any] = ["formatVersion": 1, "identifier": id, "name": name, "dylib": dylib,
                                "sections": [["items": [["type": "switch", "key": "enabled"]]]]]
        return TweakManifestParser.parse(data: manifestData(d), path: "/m/\(id).workbench.plist", fileExists: { _ in true }).0!
    }

    func testTweakLookup() {
        let ms = [manifest("local.a.oled", name: "OLED Finder", dylib: "/t/libOLEDFinder.dylib"),
                  manifest("local.a.menu", name: "MenuLoader", dylib: "/t/libMenuLoader.dylib"),
                  manifest("local.b.menu", name: "Menu Extra", dylib: "/t/libMenuExtra.dylib")]
        let config = ["/t/libOLEDFinder.dylib", "/t/libBare.dylib"]
        func pick(_ a: String) -> String? {
            if case let .success(c) = WhyLookup.tweak(a, manifests: ms, configDylibs: config) { return c.manifest?.id ?? c.dylibPath }
            return nil
        }
        XCTAssertEqual(pick("LOCAL.A.OLED"), "local.a.oled")
        XCTAssertEqual(pick("oled finder"), "local.a.oled")
        XCTAssertEqual(pick("OLEDFinder"), "local.a.oled")
        XCTAssertEqual(pick("libOLEDFinder.dylib"), "local.a.oled")
        XCTAssertEqual(pick("/t/libOLEDFinder.dylib"), "local.a.oled")
        XCTAssertEqual(pick("Bare"), "/t/libBare.dylib", "a config dylib without a manifest")
        XCTAssertNil(pick("nothing"))
        if case let .failure(e) = WhyLookup.tweak("nothing", manifests: ms, configDylibs: config) {
            XCTAssertEqual(e, .noTweak("nothing", known: ["local.a.menu", "local.a.oled", "local.b.menu", "libBare.dylib"]))
        }
        let twins = ms + [manifest("local.c", name: "menuloader", dylib: "/t/libOther.dylib")]
        if case let .failure(e) = WhyLookup.tweak("MenuLoader", manifests: twins, configDylibs: []) {
            XCTAssertEqual(e, .ambiguousTweak("MenuLoader", matches: ["local.a.menu", "local.c"]))
        } else { XCTFail("two names match") }
    }

    func testAppLookup() {
        let finder = InstalledApp(displayName: "Finder", bundleID: "com.apple.finder", executableName: "Finder",
                                  executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
                                  bundlePath: "/System/Library/CoreServices/Finder.app")
        let code = InstalledApp(displayName: "Code", bundleID: "com.microsoft.VSCode", executableName: "Electron",
                                executablePath: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
                                bundlePath: "/Applications/Visual Studio Code.app")
        let apps = [finder, code]
        func pick(_ a: String, read: @escaping (String) -> InstalledApp? = { _ in nil }) -> String? {
            if case let .success(x) = WhyLookup.app(a, apps: apps, readBundle: read) { return x.bundleID }
            return nil
        }
        XCTAssertEqual(pick("COM.APPLE.FINDER"), "com.apple.finder")
        XCTAssertEqual(pick("visual studio code"), "com.microsoft.VSCode", "the bundle's file name")
        XCTAssertEqual(pick("code"), "com.microsoft.VSCode", "the display name")
        XCTAssertEqual(pick("Visual Studio Code.app"), "com.microsoft.VSCode")
        XCTAssertEqual(pick("electron"), "com.microsoft.VSCode")
        XCTAssertEqual(pick("/Downloads/Tool.app", read: { $0 == "/Downloads/Tool.app" ? code : nil }), "com.microsoft.VSCode")
        XCTAssertNil(pick("/Downloads/Missing.app"))
        XCTAssertNil(pick("TextEdit"))
        var copy = finder
        copy.bundlePath = "/Users/x/Applications/Finder.app"
        if case let .failure(e) = WhyLookup.app("finder", apps: [finder, copy]) {
            XCTAssertEqual(e, .ambiguousApp("finder", matches: [finder.bundlePath, copy.bundlePath]))
        } else { XCTFail("two copies") }
    }

    func testProcessArch() {
        XCTAssertEqual(Why.processArch(appArchs: ["x86_64", "arm64e"], bundleID: "com.apple.finder", appleSilicon: true), "arm64e")
        XCTAssertEqual(Why.processArch(appArchs: ["x86_64", "arm64", "arm64e"], bundleID: "com.example", appleSilicon: true), "arm64")
        XCTAssertEqual(Why.processArch(appArchs: ["arm64e"], bundleID: "com.example", appleSilicon: true), "arm64e")
        XCTAssertEqual(Why.processArch(appArchs: ["x86_64"], bundleID: "com.example", appleSilicon: true), "x86_64", "Rosetta")
        XCTAssertEqual(Why.processArch(appArchs: ["x86_64", "arm64"], bundleID: "com.example", appleSilicon: false), "x86_64")
        XCTAssertNil(Why.processArch(appArchs: ["arm64"], bundleID: "com.example", appleSilicon: false))
    }

    func testArchitecturesFromTheHeader() throws {
        let dir = try temporaryDirectory()
        func write(_ bytes: [UInt8], _ name: String) throws -> String {
            let p = dir.appendingPathComponent(name).path
            try Data(bytes).write(to: URL(fileURLWithPath: p))
            return p
        }
        // thin arm64e: magic feedfacf (LE), cputype 0x0100000c, subtype 2
        let thin = try write([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0, 0, 0x01, 0x02, 0, 0, 0x80] + [UInt8](repeating: 0, count: 20), "thin")
        XCTAssertEqual(MachOInfo.architectures(ofFileAt: thin), ["arm64e"])
        // universal: x86_64 + arm64 (offsets past the 4 KB read don't matter)
        var fat: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2]
        fat += [0x01, 0, 0, 0x07, 0, 0, 0, 3, 0, 1, 0, 0, 0, 0, 0x10, 0, 0, 0, 0, 14]
        fat += [0x01, 0, 0, 0x0C, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0x10, 0, 0, 0, 0, 14]
        XCTAssertEqual(MachOInfo.architectures(ofFileAt: try write(fat, "fat")), ["x86_64", "arm64"])
        XCTAssertNil(MachOInfo.architectures(ofFileAt: try write([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], "junk")))
        XCTAssertNil(MachOInfo.architectures(ofFileAt: dir.appendingPathComponent("missing").path))
    }

    func testLogParse() {
        let out = """
        Timestamp               Ty Process[PID:TID]
        2026-11-20 18:57:06.249 Df Clerestory[41566:6ecea3] [local.test.foo:hook] local.test.foo: not loading into com.x: the Shift key is held down
        2026-11-20 19:00:01.000 E  Code Helper (Renderer)[12:ab] [local.test.foo:hook] something else
        """
        let lines = WhyLogLine.parse(out)
        XCTAssertEqual(lines.map(\.process), ["Clerestory", "Code Helper (Renderer)"])
        XCTAssertEqual(lines.map(\.message), ["local.test.foo: not loading into com.x: the Shift key is held down", "something else"])
        XCTAssertNotNil(lines[0].date)
    }

    // MARK: explain

    let app = InstalledApp(displayName: "TextEdit", bundleID: "com.apple.TextEdit", executableName: "TextEdit",
                           executablePath: "/System/Applications/TextEdit.app/Contents/MacOS/TextEdit",
                           bundlePath: "/System/Applications/TextEdit.app")

    func slices(_ archs: [String], signed: Bool = true) -> [MachOInfo.Slice] {
        archs.map { MachOInfo.Slice(arch: $0, isDylib: true, isSigned: signed) }
    }

    /// Everything lets it through; tests change one thing each.
    func inputs(config: String = "dylib:\(TweakWhyTests.dylib):allow\n") -> WhyInputs {
        WhyInputs(
            tweakName: "Foo", tweakID: Self.id, manifest: nil, dylibPath: Self.dylib, dylibFileExists: true,
            dylibSlices: slices(["x86_64", "arm64", "arm64e"]),
            ctorMarkers: [CtorMarker(tweakID: Self.id, bundleIDs: ["com.apple.TextEdit"])],
            safeModeSupport: .perTweakAndPanic, compatibilityIssues: [], app: app, appArchs: ["x86_64", "arm64e"],
            appleSilicon: true, service: ServiceName("application.com.apple.TextEdit.1.2", source: .observed),
            config: EffectiveConfig(document: ConfigDocument(text: config)),
            daemon: DaemonStatus(processes: [DaemonProcess(pid: 9, parentPID: 1, started: Date(timeIntervalSince1970: 100), startedText: "", command: "dynjectd")],
                                 job: nil, configModified: Date(timeIntervalSince1970: 50)),
            safeModeEntries: [:], running: .notRunning, log: [])
    }

    func step(_ r: WhyReport, _ check: String) -> WhyStep? { r.steps.first { $0.check == check } }

    func testEverythingPasses() {
        let r = Why.explain(inputs())
        XCTAssertTrue(r.loads)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.steps.map(\.section).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } },
                       ["dynjectd", "dynjectd.conf (at launch)", "dyld (at launch)", "the tweak (in the app, before main)", "now"])
        XCTAssertEqual(r.steps.filter { $0.section == "the tweak (in the app, before main)" }.map(\.check),
                       ["targets", "safe mode", "shift"], "in DHShouldLoad's order")
        XCTAssertEqual(step(r, "architecture")?.detail, "TextEdit runs as arm64e; the dylib has x86_64 arm64 arm64e")
        XCTAssertEqual(step(r, "targets")?.detail, "targets com.apple.TextEdit")
        XCTAssertEqual(r.verdict, "nothing stops it: it should load at TextEdit's next launch")
        XCTAssertTrue(r.text().hasSuffix("→ nothing stops it: it should load at TextEdit's next launch"))
        let json = try! JSONSerialization.jsonObject(with: r.json()) as! [String: Any]
        XCTAssertEqual(json["loads"] as? Bool, true)
        XCTAssertEqual((json["steps"] as? [[String: Any]])?.first?.keys.sorted(), ["check", "detail", "fix", "section", "status"])
    }

    /// The approval step follows what the running dynjectd does: nothing (stock), audit (warns), enforce (stops it).
    func testApprovalStep() {
        let hex = String(repeating: "ab", count: 32), other = String(repeating: "cd", count: 32)
        func run(_ mode: DaemonApprovalMode?, approved: String?, file: String? = hex) -> WhyReport {
            var i = inputs(config: "dylib:\(Self.dylib):allow\n" + (approved.map { "dylib-sha256:\(Self.dylib):\($0)\n" } ?? ""))
            i.approvalMode = mode
            i.dylibSHA256 = file
            return Why.explain(i)
        }
        var r = run(nil, approved: nil)
        XCTAssertEqual(step(r, "approval")?.status, .info)
        XCTAssertEqual(step(r, "approval")?.detail, "the running dynjectd doesn't check approvals")
        XCTAssertTrue(r.loads)
        r = run(.enforce, approved: hex)
        XCTAssertEqual(step(r, "approval")?.status, .pass)
        XCTAssertTrue(r.loads)
        let order = r.steps.map(\.check)
        XCTAssertEqual(order.firstIndex(of: "approval"), order.firstIndex(of: "dylib rule").map { $0 + 1 }, "\(order)")
        r = run(.audit, approved: nil)
        XCTAssertEqual(step(r, "approval")?.status, .warning)
        XCTAssertEqual(step(r, "approval")?.detail, "libFoo.dylib has no dylib-sha256 approval, so dynjectd injects it anyway and logs it (audit)")
        r = run(.enforce, approved: nil)
        XCTAssertEqual(step(r, "approval")?.status, .fail)
        XCTAssertEqual(step(r, "approval")?.fix, "dw tweak approve \(Self.dylib)")
        XCTAssertFalse(r.loads)
        r = run(.enforce, approved: other)
        XCTAssertEqual(step(r, "approval")?.status, .fail)
        XCTAssertTrue(step(r, "approval")?.detail.hasPrefix("the file isn't the approved build (approved cdcdcdcdcdcdcdcd…, file abababababababab…)") == true)
        XCTAssertEqual(step(run(.audit, approved: hex, file: nil), "approval")?.status, .unknown)
    }

    func testLoginwindowIsNeverReached() {
        var i = inputs()
        i.app = InstalledApp(displayName: "loginwindow", bundleID: "com.apple.loginwindow", executableName: "loginwindow",
                             executablePath: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
                             bundlePath: "/System/Library/CoreServices/loginwindow.app")
        let r = Why.explain(i)
        XCTAssertFalse(r.loads)
        XCTAssertEqual(step(r, "reaches it")?.status, .fail)
        XCTAssertTrue(r.verdict.hasPrefix("it doesn't load: dynjectd never sees loginwindow start"), r.verdict)
        XCTAssertNil(step(Why.explain(inputs()), "reaches it"), "other apps don't get the check")
    }

    func testConfigGates() {
        var r = Why.explain(inputs(config: "dylib:\(Self.dylib):deny\n"))
        XCTAssertEqual(step(r, "dylib rule")?.status, .fail)
        XCTAssertEqual(step(r, "dylib rule")?.fix, "dw enable \(Self.dylib) com.apple.TextEdit")
        XCTAssertEqual(r.verdict, "it doesn't load: libFoo.dylib: default deny (line 1), so it isn't injected here")
        XCTAssertEqual(r.exitCode, 1)

        r = Why.explain(inputs(config: "dylib:\(Self.dylib):deny\ndylib-override:\(Self.dylib):allow:com.apple.TextEdit\n"))
        XCTAssertEqual(step(r, "dylib rule")?.status, .pass)

        r = Why.explain(inputs(config: ""))
        XCTAssertEqual(step(r, "declared")?.status, .fail)
        XCTAssertNil(step(r, "dylib rule"))

        r = Why.explain(inputs(config: "dylib:\(Self.dylib):allow\ndeny:TextEdit\n"))
        XCTAssertEqual(step(r, "process gate")?.status, .fail)
        XCTAssertTrue(step(r, "process gate")?.fix?.contains("deny:") ?? false)

        var i = inputs()
        i.app.executablePath = "/Users/x/Downloads/Tool.app/Contents/MacOS/Tool"
        i.app.executableName = "Tool"
        r = Why.explain(i)
        XCTAssertEqual(step(r, "process gate")?.fix, "dw enable \(Self.dylib) com.apple.TextEdit (adds allow:Tool)")

        i = inputs()
        i.app.executableName = "TextEdit Helper"
        XCTAssertTrue(step(Why.explain(i), "process gate")?.fix?.hasPrefix("turn skip_helpers off") ?? false)

        i = inputs()
        i.service = ServiceName("com.apple.mdworker.shared", source: .observed)
        r = Why.explain(i)
        XCTAssertEqual(step(r, "service gate")?.status, .fail)
        XCTAssertNil(step(r, "service gate")?.fix, "system daemons are never injected")

        i = inputs()
        i.dylibFileExists = false
        r = Why.explain(i)
        XCTAssertEqual(step(r, "file")?.status, .fail)
        XCTAssertNil(step(r, "architecture"))
        XCTAssertNil(step(r, "targets"))
    }

    func testDaemon() {
        var i = inputs()
        i.daemon = DaemonStatus(processes: [], job: nil, configModified: nil)
        XCTAssertEqual(step(Why.explain(i), "running")?.status, .fail)
        i = inputs()
        i.daemon.configModified = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(Why.explain(i).steps.first?.status, .warning, "started before the config changed")
    }

    func testArchitectureAndSignature() {
        var i = inputs()
        i.dylibSlices = slices(["x86_64", "arm64"])
        var r = Why.explain(i)
        XCTAssertEqual(step(r, "architecture")?.status, .fail)
        XCTAssertEqual(step(r, "architecture")?.detail, "TextEdit runs as arm64e; the dylib has x86_64 arm64, so dyld can't load it")

        i = inputs()
        i.dylibSlices = slices(["arm64e"], signed: false)
        r = Why.explain(i)
        XCTAssertEqual(step(r, "signature")?.status, .fail)

        i = inputs()
        i.app.bundleID = "com.example.tool"
        i.appArchs = ["arm64", "x86_64"]
        i.ctorMarkers = [CtorMarker(tweakID: Self.id, bundleIDs: [])]
        i.dylibSlices = slices(["arm64e"])
        XCTAssertEqual(step(Why.explain(i), "architecture")?.status, .pass, "an arm64 process loads arm64e slices too")
        XCTAssertEqual(step(Why.explain(i), "architecture")?.detail,
                       "TextEdit runs as arm64; the dylib has arm64e (it loads the arm64e slice)")
        i.dylibSlices = slices(["x86_64"])
        XCTAssertEqual(step(Why.explain(i), "architecture")?.status, .fail)

        i = inputs()
        i.appArchs = nil
        XCTAssertEqual(step(Why.explain(i), "architecture")?.status, .unknown)
    }

    func testTargets() {
        var i = inputs()
        i.ctorMarkers = [CtorMarker(tweakID: Self.id, bundleIDs: ["com.apple.finder"])]
        var r = Why.explain(i)
        XCTAssertEqual(step(r, "targets")?.status, .fail)
        XCTAssertEqual(step(r, "targets")?.detail, "its DH_CTOR targets only com.apple.finder, not com.apple.TextEdit")

        i.ctorMarkers = [CtorMarker(tweakID: Self.id, bundleIDs: ["com.apple.textedit"])]
        r = Why.explain(i)
        XCTAssertEqual(step(r, "targets")?.status, .fail)
        XCTAssertTrue(step(r, "targets")?.detail.contains("case included") ?? false)
        XCTAssertEqual(step(r, "targets")?.fix, "change it to \"com.apple.TextEdit\" in DH_CTOR, rebuild and reinstall")

        i.ctorMarkers = [CtorMarker(tweakID: Self.id, bundleIDs: [])]
        XCTAssertEqual(step(Why.explain(i), "targets")?.detail, "targets every app (DH_CTOR lists no bundle IDs)")

        i.ctorMarkers = [CtorMarker(tweakID: Self.id, bundleIDs: nil)]
        XCTAssertEqual(step(Why.explain(i), "targets")?.status, .unknown)

        i.ctorMarkers = []
        r = Why.explain(i)
        XCTAssertEqual(step(r, "targets")?.status, .unknown)
        XCTAssertTrue(r.loads, "unknown doesn't block")
        XCTAssertTrue(r.verdict.hasSuffix("; 1 check couldn't be made (?)"))

        i = inputs()
        i.tweakID = nil
        i.ctorMarkers = [CtorMarker(tweakID: "local.from.marker", bundleIDs: [])]
        i.safeModeEntries = ["local.from.marker": ["com.apple.TextEdit"]]
        r = Why.explain(i)
        XCTAssertEqual(step(r, "safe mode")?.status, .fail, "the marker supplies the tweak ID")
        XCTAssertEqual(r.tweak, "Foo (local.from.marker)")

        i = inputs()
        i.safeModeSupport = .unsupported
        r = Why.explain(i)
        XCTAssertEqual(step(r, "dynjecthook")?.status, .info)
        XCTAssertNil(step(r, "targets"))
        XCTAssertNil(step(r, "safe mode"))
    }

    func testSafeMode() {
        var i = inputs()
        i.safeModeEntries = [Self.id: ["com.apple.TextEdit"]]
        i.safeModeDisabled = [SafeModeDisabledEntry(tweakID: Self.id, bundleID: "com.apple.TextEdit", since: Date(timeIntervalSince1970: 0),
                                                    reason: .crashInTweak, reportPath: nil, frameSummary: nil)]
        var r = Why.explain(i)
        XCTAssertEqual(step(r, "safe mode")?.status, .fail)
        XCTAssertTrue(step(r, "safe mode")?.detail.hasPrefix("Safe Mode has it off in TextEdit (crash in tweak, since") ?? false)
        XCTAssertEqual(step(r, "safe mode")?.fix, "dw safemode enable \(Self.id) com.apple.TextEdit")

        i = inputs()
        i.safeModeEntries = [Self.id: ["*"]]
        XCTAssertEqual(step(Why.explain(i), "safe mode")?.fix, "dw safemode enable \(Self.id) '*'")

        i = inputs()
        i.safeModeEntries = ["*": ["*"]]
        r = Why.explain(i)
        XCTAssertEqual(step(r, "safe mode")?.fix, "dw safemode panic off")
        i.safeModeSupport = .perTweak
        XCTAssertEqual(step(Why.explain(i), "safe mode")?.status, .info, "an older DynjectHook ignores the panic switch")

        i = inputs()
        i.safeModeEntries = ["*": ["com.apple.TextEdit"]]
        XCTAssertEqual(step(Why.explain(i), "safe mode")?.fix, "dw safemode enable '*' com.apple.TextEdit")
    }

    func testRunningAndLog() {
        let running = RunningApp(pid: 42, bundleID: app.bundleID, name: "TextEdit", bundlePath: app.bundlePath,
                                 executablePath: app.executablePath, launchDate: Date(timeIntervalSince1970: 300))
        func candidate(loaded: Set<String>?, reasons: [RespringReason] = [], exclusion: RespringExclusion? = nil) -> WhyRunning {
            .running(RespringCandidate(app: running, service: "s", expected: [Self.dylib], loaded: loaded, reasons: reasons, exclusion: exclusion))
        }
        var i = inputs()
        i.running = candidate(loaded: [Self.dylib])
        var r = Why.explain(i)
        XCTAssertEqual(step(r, "running")?.status, .pass)
        XCTAssertEqual(r.verdict, "it's loaded in the running TextEdit")

        i.running = candidate(loaded: [Self.dylib], reasons: [RespringReason(.updated, dylib: Self.dylib, tweak: "Foo", date: Date())])
        r = Why.explain(i)
        XCTAssertEqual(r.steps.last { $0.check == "running" }?.status, .warning)
        XCTAssertEqual(r.steps.last { $0.check == "running" }?.fix, "dw respring --only com.apple.TextEdit")
        XCTAssertEqual(r.verdict, "nothing stops it: it should load at TextEdit's next launch")

        i.running = candidate(loaded: [], reasons: [RespringReason(.missing, dylib: Self.dylib, tweak: "Foo")], exclusion: .injectionBlocked)
        r = Why.explain(i)
        XCTAssertEqual(r.steps.last { $0.check == "running" }?.status, .fail)

        i.running = candidate(loaded: [], reasons: [RespringReason(.missing, dylib: Self.dylib, tweak: "Foo")], exclusion: .hostsThisProcess)
        XCTAssertEqual(Why.explain(i).steps.last { $0.check == "running" }?.fix, "quit and reopen it yourself")

        i.running = candidate(loaded: nil)
        XCTAssertEqual(Why.explain(i).steps.last { $0.check == "running" }?.status, .unknown)

        i = inputs()
        i.log = [WhyLogLine(date: nil, process: "TextEdit", message: "hooked"),
                 WhyLogLine(date: nil, process: "TextEdit", message: "\(Self.id): not loading into com.apple.TextEdit: the Shift key is held down")]
        XCTAssertEqual(step(Why.explain(i), "log")?.detail, "last launch, ?: not loading into com.apple.TextEdit: the Shift key is held down")
        i.log = [WhyLogLine(date: nil, process: "TextEdit", message: "\(Self.id): exception in tweak constructor: X: y")]
        XCTAssertEqual(step(Why.explain(i), "log")?.status, .warning)
        i.log = [WhyLogLine(date: nil, process: "TextEdit", message: "hooked")]
        XCTAssertEqual(step(Why.explain(i), "log")?.detail, "it logged in TextEdit at ?, and didn't skip itself")
        i.log = nil
        XCTAssertNil(step(Why.explain(i), "log"), "not searched")
    }

    func testMacOSMinimum() {
        var i = inputs()
        i.compatibilityIssues = [CompatibilityIssue(tweakID: Self.id, severity: .error, kind: .systemTooOld,
                                                    message: "needs macOS 28.0 or later; this Mac has 27.2", fix: nil)]
        let r = Why.explain(i)
        XCTAssertEqual(step(r, "macos")?.status, .fail)
        XCTAssertEqual(r.steps.filter { $0.section == "the tweak (in the app, before main)" }.map(\.check).last, "macos",
                       "the body's DH_REQUIRE_SYSTEM runs after DHShouldLoad")
    }
}
