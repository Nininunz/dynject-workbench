import XCTest
@testable import DynjectCore

final class EngineRulesTests: XCTestCase {
    private func config(_ text: String, _ rules: EngineRules) -> EffectiveConfig {
        EffectiveConfig(document: ConfigDocument(text: text), rules: rules)
    }

    private func app(_ bundleID: String, _ name: String) -> InstalledApp {
        InstalledApp(displayName: name, bundleID: bundleID, executableName: name,
                     executablePath: "/Applications/\(name).app/Contents/MacOS/\(name)",
                     bundlePath: "/Applications/\(name).app")
    }

    // MARK: Which engine

    func testDetectsTheEngineFromTheLoadersLastStartLine() {
        let stock = "[dynject_loader 01:00:00] dynject_loader: done dynjectd running (pid=10)\n"
        let revised = "[dynject_loader 02:00:00] dynject_loader: done dynjectd running (pid=11); amfid hook removed (one signature approved)\n"
        XCTAssertEqual(EngineRules.detect(in: stock), .stock)
        XCTAssertEqual(EngineRules.detect(in: revised), .revised)
        XCTAssertEqual(EngineRules.detect(in: stock + revised), .revised)
        XCTAssertEqual(EngineRules.detect(in: revised + stock), .stock, "the latest start decides")
        XCTAssertNil(EngineRules.detect(in: "[dynjectd 01:00:00] dynjectd: starting\n"))
    }

    func testALabelThatQuotesTheLoaderIsNotAStartLine() {
        // dynjectd logs labels behind its own prefix, so they can't begin a line the way the loader does.
        let forged = "[dynjectd 03:00:00] dynjectd: x [dynject_loader 03:00:00] dynject_loader: done dynjectd running (pid=1); amfid hook removed SKIP (no_gui)\n"
        XCTAssertNil(EngineRules.detect(in: forged))
        let stock = "[dynject_loader 01:00:00] dynject_loader: done dynjectd running (pid=10)\n"
        XCTAssertEqual(EngineRules.detect(in: stock + forged), .stock)
    }

    func testFollowsALogAsItGrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("engine-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); EngineRules.active = .stock }
        let log = dir.appendingPathComponent("dynjectd.log")
        XCTAssertNil(EngineRules.detect(logAt: log.path))
        try "[dynject_loader 01:00:00] dynject_loader: done dynjectd running (pid=10)\n".write(to: log, atomically: true, encoding: .utf8)
        XCTAssertEqual(EngineRules.detect(logAt: log.path), .stock)
        EngineRules.follow(logAt: log.path)
        XCTAssertEqual(EngineRules.active, .stock)
        EngineRules.active = .revised
        XCTAssertEqual(EngineRules.active, .revised, "an assignment replaces following")
    }

    func testTheDefaultIsStock() {
        XCTAssertEqual(EngineRules.active, .stock)
    }

    // MARK: Reading the config

    func testYesNoWords() {
        let text = "ui_apps:false\nskip_helpers:OFF\ndylib:/x.dylib\n"
        XCTAssertTrue(config(text, .stock).uiApps)
        XCTAssertTrue(config(text, .stock).skipHelpers)
        XCTAssertFalse(config(text, .revised).uiApps)
        XCTAssertFalse(config(text, .revised).skipHelpers)
        // Another word changes nothing in the revised engine, and means yes in the stock one.
        let odd = "ui_apps:no\nui_apps:nope\n"
        XCTAssertTrue(config(odd, .stock).uiApps)
        XCTAssertFalse(config(odd, .revised).uiApps)
        XCTAssertTrue(config("ui_apps:no\nui_apps:True\n", .revised).uiApps)
    }

    func testAnOverrideAboveItsDylibLine() {
        let text = "dylib-override:/x.dylib:deny:com.apple.Finder\ndylib:/x.dylib:allow\ndylib-override:/x.dylib:allow:com.apple\n"
        XCTAssertEqual(config(text, .stock).dylibs[0].overrides.map(\.pattern), ["com.apple"])
        XCTAssertEqual(config(text, .revised).dylibs[0].overrides.map(\.pattern), ["com.apple.Finder", "com.apple"],
                       "both count, in file order")
        // One that names no dylib is dropped either way.
        XCTAssertTrue(config("dylib:/x.dylib\ndylib-override:/y.dylib:deny:a\n", .revised).dylibs[0].overrides.isEmpty)
    }

    func testValidatorFollowsTheRules() {
        let doc = ConfigDocument(text: "dylib-override:/x.dylib:deny:a\ndylib:/x.dylib\nui_apps:false\ndylib-override:/y.dylib:deny:a\n")
        let stock = ConfigValidator.diagnose(doc, rules: .stock, fileExists: { _ in true }).map(\.message)
        let revised = ConfigValidator.diagnose(doc, rules: .revised, fileExists: { _ in true }).map(\.message)
        XCTAssertTrue(stock.contains { $0.contains("before its dylib line") })
        XCTAssertFalse(revised.contains { $0.contains("before its dylib line") })
        XCTAssertTrue(stock.contains { $0.contains("read as enabled") })
        XCTAssertFalse(revised.contains { $0.contains("false") })
        XCTAssertTrue(stock.contains { $0.contains("No dylib line declares /y.dylib") })
        XCTAssertTrue(revised.contains { $0.contains("No dylib line declares /y.dylib") })
        let odd = ConfigDocument(text: "dylib:/x.dylib\nskip_helpers:maybe\n")
        XCTAssertTrue(ConfigValidator.diagnose(odd, rules: .revised, fileExists: { _ in true })
            .contains { $0.severity == .warning && $0.message.contains("keeps the setting") })
    }

    // MARK: Who gets a dylib

    func testDaemonNamesAreWholeWordsInTheRevisedEngine() {
        let thunderbird = "application.org.mozilla.thunderbird.123.456"
        XCTAssertEqual(PolicyEvaluator.systemDaemonPattern(in: thunderbird, rules: .stock), "bird")
        XCTAssertNil(PolicyEvaluator.systemDaemonPattern(in: thunderbird, rules: .revised))
        XCTAssertNil(PolicyEvaluator.systemDaemonPattern(in: "application.com.example.blogdesk.1.2", rules: .revised))
        XCTAssertNil(PolicyEvaluator.systemDaemonPattern(in: "application.com.example.birdfeed.1.2", rules: .revised))
        for label in ["com.apple.bird", "bird", "com.apple.logd_helper", "com.apple.trustdFileHelper",
                      "com.apple.security.cloudkeychainproxy3", "com.apple.mdworker.shared.01000000-0500",
                      "com.apple.AddressBook.abd", "com.apple.symptomsd-diag"] {
            XCTAssertNotNil(PolicyEvaluator.systemDaemonPattern(in: label, rules: .revised), label)
        }
        let cfg = config("dylib:/x.dylib\n", .revised)
        XCTAssertFalse(PolicyEvaluator.serviceGate(thunderbird, config: cfg, rules: .stock).passed)
        XCTAssertTrue(PolicyEvaluator.serviceGate(thunderbird, config: cfg, rules: .revised).passed)
    }

    func testTheLabelAndTheAppsIdentifierMustBothAllow() {
        let text = "dylib:/finder.dylib:deny\ndylib-override:/finder.dylib:allow:com.apple.Finder\n"
            + "dylib:/all.dylib:allow\ndylib-override:/all.dylib:deny:com.victim\n"
        let cfg = config(text, .revised)
        let victim = app("com.victim.app", "Victim")
        func injected(_ service: String, _ app: InstalledApp, _ rules: EngineRules) -> [String] {
            PolicyEvaluator.evaluate(app: app, service: service, config: cfg, rules: rules, fileExists: { _ in true })
                .injectedDylibs
        }
        // A label made up to contain Finder's pattern, around another app.
        let madeUp = "application.com.apple.Finder.x"
        XCTAssertEqual(injected(madeUp, victim, .stock), ["/finder.dylib", "/all.dylib"])
        XCTAssertEqual(injected(madeUp, victim, .revised), [])
        // Finder itself: its identifier is lower case, the pattern isn't.
        XCTAssertEqual(injected("com.apple.Finder", app("com.apple.finder", "Finder"), .revised),
                       ["/finder.dylib", "/all.dylib"])
        // The usual label of an app.
        XCTAssertEqual(injected("application.com.example.app.1.2", app("com.example.app", "Example"), .revised),
                       ["/all.dylib"])
        XCTAssertEqual(injected("application.com.victim.app.1.2", victim, .revised), [])

        let d = PolicyEvaluator.decisions(service: madeUp, bundleID: "com.victim.app", config: cfg, rules: .revised,
                                          fileExists: { _ in true })
        XCTAssertEqual(d[0].reason, .appIdentifier(bundleID: "com.victim.app", line: 0, pattern: nil,
                                                   label: .override(line: 1, pattern: "com.apple.Finder")))
        XCTAssertEqual(d[1].reason, .appIdentifier(bundleID: "com.victim.app", line: 3, pattern: "com.victim",
                                                   label: .defaultPolicy(line: 2)))
        XCTAssertTrue(d[0].reasonText.contains("the app's own identifier (com.victim.app) gets default deny"))
        // No bundle (nil): the service name alone decides, as in the stock engine.
        XCTAssertTrue(PolicyEvaluator.decisions(service: madeUp, config: cfg, rules: .revised,
                                                fileExists: { _ in true })[0].allowed)
        // A bundle without a readable identifier: no allow override can match.
        XCTAssertFalse(PolicyEvaluator.decisions(service: madeUp, bundleID: "", config: cfg, rules: .revised,
                                                 fileExists: { _ in true })[0].allowed)
    }

    func testDoctorReadsTheDaemonsConfigComplaints() {
        let log = "[dynjectd 01:00:00] dynjectd: starting\n[dynjectd 01:00:00] dynjectd: config: line 3: old\n"
            + "[dynjectd 02:00:00] dynjectd: starting\n"
            + "[dynjectd 02:00:00] dynjectd: config: line 13: dylib-override for /x.dylib, which has no dylib line; ignored\n"
            + "[dynjectd 02:00:05] dynjectd: label dynjectd: config: forged SKIP (no_gui)\n"
        XCTAssertEqual(Doctor.configComplaints(inLog: log),
                       ["line 13: dylib-override for /x.dylib, which has no dylib line; ignored"])
        XCTAssertEqual(Doctor.configComplaints(inLog: "[dynjectd 01:00:00] dynjectd: starting\n"), [])
    }

    func testDenyComesFirstAtTheServiceGateInTheRevisedEngine() {
        let text = "dylib:/x.dylib\nallow:Safari\ndeny:com.apple.Safari\n"
        let label = "application.com.apple.Safari.1.2"
        XCTAssertTrue(PolicyEvaluator.serviceGate(label, config: config(text, .stock), rules: .stock).passed)
        XCTAssertFalse(PolicyEvaluator.serviceGate(label, config: config(text, .revised), rules: .revised).passed)
        // Only one of them matches: the same answer from both.
        let other = "application.com.example.Safari-like.1.2"
        XCTAssertTrue(PolicyEvaluator.serviceGate(other, config: config(text, .revised), rules: .revised).passed)
        XCTAssertTrue(PolicyEvaluator.serviceGate(other, config: config(text, .stock), rules: .stock).passed)
    }

    func testEmptyRulesLongLinesAndUnknownApprovalMode() {
        let text = "dylib:/x.dylib:deny\ndylib-override:/x.dylib:allow:\nallow:\ndeny:\ndylib-approval:strict\n"
        let stock = config(text, .stock), revised = config(text, .revised)
        XCTAssertEqual(stock.dylibs[0].overrides.count, 1)
        XCTAssertEqual(stock.allowRules.count, 1)
        XCTAssertFalse(stock.approvalEnforced)
        XCTAssertTrue(revised.dylibs[0].overrides.isEmpty)
        XCTAssertTrue(revised.allowRules.isEmpty && revised.denyRules.isEmpty)
        XCTAssertTrue(revised.approvalEnforced, "a typo doesn't switch the check off")
        XCTAssertFalse(config("dylib:/x.dylib\ndylib-approval:audit\n", .revised).approvalEnforced)

        let long = "deny:" + String(repeating: "a", count: DynjectLimits.maxLineBytes) + "\ndylib:/y.dylib\n"
        XCTAssertTrue(config(long, .revised).denyRules.isEmpty)
        XCTAssertEqual(config(long, .revised).dylibs.map(\.path), ["/y.dylib"])
        let messages = ConfigValidator.diagnose(ConfigDocument(text: text), rules: .revised, fileExists: { _ in true })
            .map(\.message)
        XCTAssertTrue(messages.contains { $0.contains("dynjectd ignores this override") })
        XCTAssertTrue(messages.contains { $0.contains("as enforce") })
    }

    func testCryptexAppsAreAppsInTheRevisedEngine() {
        let safari = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"
        let cfg = config("dylib:/x.dylib\n", .revised)
        XCTAssertFalse(PolicyEvaluator.processGate(name: "Safari", path: safari, config: cfg, rules: .stock).passed)
        XCTAssertTrue(PolicyEvaluator.processGate(name: "Safari", path: safari, config: cfg, rules: .revised).passed)
        XCTAssertFalse(PolicyEvaluator.isUIAppPath("/System/Volumes/Preboot/Cryptexes/App/usr/bin/tool", rules: .revised))
        XCTAssertTrue(PolicyEvaluator.isUIAppPath("/Applications/Foo.app/Contents/MacOS/Foo", rules: .stock))
    }

    // MARK: The approval mode in the log

    func testApprovalModeCountsOnlyTheDaemonsOwnLines() {
        let real = "[dynjectd 01:00:00] dynjectd: starting\n[dynjectd 01:00:00] dynjectd: approval: audit; 6 of 6 dylib(s) have a dylib-sha256 line\n"
        XCTAssertEqual(DaemonApprovalMode.latest(in: real), .audit)
        // A launchd label that carries the words is logged behind the service name, not as the message.
        let forged = real + "[dynjectd 01:00:05] dynjectd: logd dynjectd: approval: enforce SKIP (system_daemon)\n"
            + "[dynjectd 01:00:06] dynjectd: x.dynjectd: starting SKIP (no_gui)\n"
        XCTAssertEqual(DaemonApprovalMode.latest(in: forged), .audit)
        XCTAssertEqual(DaemonApprovalMode.latest(in: real + "[dynjectd 02:00:00] dynjectd: starting\n"), nil)
        XCTAssertEqual(DaemonApprovalMode.latest(in: real + "[dynjectd 02:00:00] dynjectd: approval: enforce; 6 of 6\n"),
                       .enforce)
    }
}
