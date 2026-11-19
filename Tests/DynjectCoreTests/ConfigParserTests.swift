@testable import DynjectCore
import XCTest

final class ConfigParserTests: XCTestCase {
    func testClassifyMirrorsDynjectd() {
        XCTAssertEqual(ConfigParser.classify(""), .blank)
        XCTAssertEqual(ConfigParser.classify("   \t "), .blank)
        XCTAssertEqual(ConfigParser.classify("  # comment"), .comment)
        XCTAssertEqual(ConfigParser.classify("dylib:/a/b.dylib:deny"), .dylib(path: "/a/b.dylib", policyToken: "deny"))
        XCTAssertEqual(ConfigParser.classify("dylib:/a/b.dylib"), .dylib(path: "/a/b.dylib", policyToken: nil))
        // value has leading spaces stripped; line has trailing spaces stripped; leading tabs stripped
        XCTAssertEqual(ConfigParser.classify("\tdylib:   /a/b.dylib:allow   "), .dylib(path: "/a/b.dylib", policyToken: "allow"))
        XCTAssertEqual(ConfigParser.classify("dylib-override:/a.dylib:allow:com.x.y"),
                       .override(path: "/a.dylib", policyToken: "allow", pattern: "com.x.y"))
        // Pattern keeps further colons.
        XCTAssertEqual(ConfigParser.classify("dylib-override:/a.dylib:deny:a:b"),
                       .override(path: "/a.dylib", policyToken: "deny", pattern: "a:b"))
        XCTAssertEqual(ConfigParser.classify("dylib-override:/a.dylib:allow"), .malformedOverride)
        XCTAssertEqual(ConfigParser.classify("allow:Finder"), .allow("Finder"))
        XCTAssertEqual(ConfigParser.classify("deny:"), .deny(""))
        XCTAssertEqual(ConfigParser.classify("ui_apps:no"), .uiApps("no"))
        XCTAssertEqual(ConfigParser.classify("Dylib:/x"), .unknownKey(key: "Dylib", value: "/x"))
        XCTAssertEqual(ConfigParser.classify("dylib :/x"), .unknownKey(key: "dylib ", value: "/x"))
        XCTAssertEqual(ConfigParser.classify("no colon here"), .noColon)
        XCTAssertEqual(ConfigParser.classify("allow:Finder\r"), .allow("Finder"))
    }

    func testPolicyTokens() {
        XCTAssertTrue(LineKind.policyAllows(nil))
        XCTAssertTrue(LineKind.policyAllows("allow"))
        XCTAssertFalse(LineKind.policyAllows("Allow"))
        XCTAssertFalse(LineKind.policyAllows("allowed"))
        XCTAssertFalse(LineKind.policyAllows("deny"))
        XCTAssertTrue(LineKind.flagEnabled("maybe"))
        XCTAssertFalse(LineKind.flagEnabled("0"))
    }

    func testRoundTripIsByteExact() {
        for name in ["live.conf", "multi.conf", "edge.conf", "crlf-no-final-newline.conf"] {
            let text = Fixtures.text(name)
            XCTAssertEqual(ConfigDocument(text: text).text, text, name)
        }
        XCTAssertEqual(ConfigDocument(text: "").text, "")
        XCTAssertEqual(ConfigDocument(text: "\n\n").lines.count, 2)
    }

    func testLiveConfigMatchesDaemonLog() {
        // The daemon logged "dylib[0] …libBrutalium.dylib (deny-all, 1 override(s))" for this file.
        let e = EffectiveConfig(document: ConfigDocument(text: Fixtures.text("live.conf")))
        XCTAssertEqual(e.dylibs.count, 1)
        XCTAssertEqual(e.dylibs[0].path, "/opt/dynject/lib/tweaks/libBrutalium.dylib")
        XCTAssertFalse(e.dylibs[0].defaultAllow)
        XCTAssertEqual(e.dylibs[0].overrides.map(\.pattern), ["com.apple.Finder"])
        XCTAssertEqual(e.allowRules.map(\.value), ["Finder"])
        XCTAssertFalse(e.uiApps)
        XCTAssertTrue(e.skipHelpers)
        XCTAssertTrue(ConfigValidator.diagnose(ConfigDocument(text: Fixtures.text("live.conf")), fileExists: exists())
            .filter { $0.severity >= .warning }.isEmpty)
    }

    func testEdgeCasesFollowDaemonSemantics() {
        let doc = ConfigDocument(text: Fixtures.text("edge.conf"))
        let e = EffectiveConfig(document: doc)
        // Two declarations; "Allow" means deny.
        XCTAssertEqual(e.dylibs.map(\.defaultAllow), [false, true])
        // Override on line 1 precedes any declaration → dropped. Later ones attach to the FIRST declaration.
        XCTAssertEqual(e.dylibs[0].overrides.map(\.pattern), ["com.apple", "com.apple.Notes"])
        XCTAssertEqual(e.dylibs[1].overrides.count, 0)
        XCTAssertEqual(e.allowRules.map(\.value), [""])
        XCTAssertTrue(e.uiApps)

        let diags = ConfigValidator.diagnose(doc, fileExists: exists())
        func has(_ line: Int, _ needle: String) -> Bool {
            diags.contains { $0.line == line - 1 && $0.message.contains(needle) }
        }
        XCTAssertTrue(has(1, "before its dylib line"))
        XCTAssertTrue(has(2, "treated as deny"))
        XCTAssertTrue(has(3, "Duplicate dylib"))
        XCTAssertTrue(has(5, "Never takes effect"))
        XCTAssertTrue(has(6, "Unknown key"))
        XCTAssertTrue(has(7, "No ':'"))
        XCTAssertTrue(has(8, "path:policy:pattern"))
        XCTAssertTrue(has(9, "matches every process"))
        XCTAssertTrue(has(10, "read as enabled"))
    }

    func testNoDylibsIsAnError() {
        let diags = ConfigValidator.diagnose(ConfigDocument(text: "allow:Finder\nui_apps:no\n"), fileExists: exists())
        XCTAssertTrue(diags.contains { $0.severity == .error && $0.line == nil && $0.message.contains("refuses to start") })
    }

    func testMissingDylibAndLongLineDiagnostics() {
        let long = "allow:" + String(repeating: "x", count: 1100)
        let doc = ConfigDocument(text: "dylib:/nope.dylib:allow\n\(long)\n")
        let diags = ConfigValidator.diagnose(doc, fileExists: exists(except: ["/nope.dylib"]))
        XCTAssertTrue(diags.contains { $0.line == 0 && $0.message.contains("File not found") })
        XCTAssertTrue(diags.contains { $0.line == 1 && $0.severity == .error })
    }

    func testLimits() {
        var text = ""
        for i in 0..<34 { text += "dylib:/d\(i).dylib\n" }
        let e = EffectiveConfig(document: ConfigDocument(text: text))
        XCTAssertEqual(e.dylibs.count, 32)
    }
}

final class PolicyEvaluatorTests: XCTestCase {
    let live = EffectiveConfig(document: ConfigDocument(text: Fixtures.text("live.conf")))
    let multi = EffectiveConfig(document: ConfigDocument(text: Fixtures.text("multi.conf")))

    func eval(_ app: InstalledApp, _ config: EffectiveConfig) -> AppEvaluation {
        PolicyEvaluator.evaluate(app: app, service: ServiceNameResolver.resolve(app, log: nil).value,
                                 config: config, fileExists: exists())
    }

    func testLiveConfigInjectsFinderOnly() {
        let finder = eval(Apps.finder, live)
        XCTAssertEqual(finder.serviceName, "com.apple.Finder")
        XCTAssertEqual(finder.injectedDylibs, ["/opt/dynject/lib/tweaks/libBrutalium.dylib"])

        let textEdit = eval(Apps.textEdit, live)
        XCTAssertTrue(textEdit.serviceGate.passed)
        XCTAssertFalse(textEdit.processGate.passed)          // ui_apps:no and no allow rule
        XCTAssertFalse(textEdit.decision(for: "/opt/dynject/lib/tweaks/libBrutalium.dylib")!.allowed)
        XCTAssertEqual(textEdit.injectedDylibs, [])
    }

    func testAllowRuleIsASubstringMatch() {
        // allow:Finder also lets "Path Finder" through the process gate (dylib still default-deny).
        let pf = eval(Apps.pathFinder, live)
        XCTAssertTrue(pf.processGate.passed)
        XCTAssertEqual(pf.injectedDylibs, [])
    }

    func testFirstMatchingOverrideWins() {
        let safari = eval(Apps.safari, multi)
        XCTAssertEqual(safari.decision(for: "/opt/dynject/lib/tweaks/libAlpha.dylib")?.reasonText,
                       "override deny \"com.apple.Safari\" (line 3)")
        let notes = eval(Apps.notes, multi)
        XCTAssertEqual(notes.decision(for: "/opt/dynject/lib/tweaks/libAlpha.dylib")?.allowed, false)
        XCTAssertEqual(notes.injectedDylibs, ["/opt/dynject/lib/tweaks/libGamma.dylib"])
        let textEdit = eval(Apps.textEdit, multi)
        XCTAssertEqual(textEdit.injectedDylibs, ["/opt/dynject/lib/tweaks/libBeta.dylib", "/opt/dynject/lib/tweaks/libGamma.dylib"])
    }

    func testProcessGateRules() {
        XCTAssertFalse(eval(Apps.terminal, multi).processGate.passed)           // deny:Terminal
        XCTAssertTrue(eval(Apps.terminal, multi).processGate.reason.contains("deny:Terminal"))
        XCTAssertFalse(eval(Apps.helper, multi).processGate.passed)             // " Helper"
        XCTAssertFalse(eval(Apps.outside, multi).processGate.passed)            // outside /Applications
        XCTAssertTrue(eval(Apps.safari, multi).processGate.passed)
    }

    func testSystemDaemonAndNonUIServices() {
        XCTAssertFalse(PolicyEvaluator.serviceGate("com.apple.mdworker.shared.0A", config: multi).passed)
        XCTAssertFalse(PolicyEvaluator.serviceGate("com.example.agent", config: multi).passed)
        XCTAssertTrue(PolicyEvaluator.serviceGate("com.apple.Finder", config: multi).passed)
        // An allow rule can admit a non-UI service.
        XCTAssertTrue(PolicyEvaluator.serviceGate("com.example.Finder-sync", config: multi).passed)
    }

    func testMissingDylibIsNotInjected() {
        let e = PolicyEvaluator.evaluate(app: Apps.finder, service: "com.apple.Finder", config: live,
                                         fileExists: exists(except: ["/opt/dynject/lib/tweaks/libBrutalium.dylib"]))
        XCTAssertTrue(e.decisions[0].allowed)
        XCTAssertTrue(e.decisions[0].fileMissing)
        XCTAssertEqual(e.injectedDylibs, [])
    }
}
