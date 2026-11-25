@testable import DynjectCore
import XCTest

// dylib-sha256 approvals (docs/install-approval.md): parsing, config editing, `dw tweak approve`'s plan, and reading
// the daemon's mode from its log. Temporary folders only.

private let a = "/opt/dynject/lib/tweaks/libA.dylib"
private let b = "/opt/dynject/lib/tweaks/libB.dylib"
private let hexA = String(repeating: "ab", count: 32)
private let hexB = String(repeating: "cd", count: 32)

final class TweakApprovalTests: XCTestCase {
    func testParsesApprovalLinesLikeDynjectd() {
        XCTAssertEqual(ConfigParser.classify("dylib-sha256:\(a):\(hexA)"), .approval(path: a, sha256: hexA))
        XCTAssertEqual(ConfigParser.classify("dylib-sha256:\(a):\(hexA.uppercased())"), .approval(path: a, sha256: hexA))
        XCTAssertEqual(ConfigParser.classify("dylib-sha256:\(a):\(hexA.dropLast())"), .malformedApproval)
        XCTAssertEqual(ConfigParser.classify("dylib-sha256:\(a):\(hexA.dropLast())z"), .malformedApproval)
        XCTAssertEqual(ConfigParser.classify("dylib-sha256:\(hexA)"), .malformedApproval)
        XCTAssertEqual(ConfigParser.classify("dylib-approval:enforce"), .approvalMode("enforce"))
        XCTAssertTrue(LineKind.approval(path: a, sha256: hexA).isDirective)
        XCTAssertFalse(LineKind.malformedApproval.isDirective)
    }

    func testEffectiveConfigReadsApprovalsInAnyOrder() {
        let doc = ConfigDocument(text: """
        dylib-sha256:\(a):\(hexB)
        dylib:\(a):allow
        dylib-sha256:\(a):\(hexA)
        dylib-approval:enforce
        """)
        let c = EffectiveConfig(document: doc)
        XCTAssertEqual(c.approvals[a], hexA, "a later line wins, and order around the dylib line doesn't matter")
        XCTAssertTrue(c.approvalEnforced)
        XCTAssertFalse(EffectiveConfig(document: ConfigDocument(text: "dylib:\(a)\ndylib-approval:strict\n")).approvalEnforced)
    }

    func testValidatorKnowsTheKeys() {
        let d = ConfigValidator.diagnose(ConfigDocument(text: """
        dylib:\(a):allow
        dylib-sha256:\(a):\(hexA)
        dylib-sha256:\(b):\(hexB)
        dylib-sha256:\(a):nothex
        dylib-approval:strict
        dylib-approval:audit
        """), fileExists: { _ in true })
        XCTAssertFalse(d.contains { $0.message.contains("Unknown key") }, "\(d)")
        XCTAssertTrue(d.contains { $0.line == 2 && $0.message.contains("No dylib line declares \(b)") })
        XCTAssertTrue(d.contains { $0.line == 3 && $0.message.contains("64 hex digits") })
        XCTAssertTrue(d.contains { $0.line == 4 && $0.message.contains("reads \"strict\" as audit") })
        XCTAssertFalse(d.contains { $0.line == 5 })
        XCTAssertFalse(d.contains { $0.severity == .error })
    }

    func testSetApprovalPutsOneLineRightAfterTheDylibLine() {
        let doc = ConfigDocument(text: "dylib:\(a):deny\ndylib-override:\(a):allow:com.x\ndylib:\(b):deny\nui_apps:yes\n")
        let one = ConfigEditor.setApproval(a, sha256: hexA.uppercased(), in: doc)
        XCTAssertEqual(one.text, "dylib:\(a):deny\ndylib-sha256:\(a):\(hexA)\ndylib-override:\(a):allow:com.x\ndylib:\(b):deny\nui_apps:yes\n")
        XCTAssertEqual(ConfigEditor.setApproval(a, sha256: hexA, in: one), one, "already there: unchanged")
        // A misplaced or duplicated approval is replaced by one in the right place.
        let messy = ConfigDocument(text: "dylib-sha256:\(a):\(hexB)\ndylib:\(a):deny\nui_apps:yes\ndylib-sha256:\(a):\(hexB)\n")
        XCTAssertEqual(ConfigEditor.setApproval(a, sha256: hexA, in: messy).text, "dylib:\(a):deny\ndylib-sha256:\(a):\(hexA)\nui_apps:yes\n")
        // Not declared: appended.
        XCTAssertEqual(ConfigEditor.setApproval(b, sha256: hexB, in: ConfigDocument(text: "ui_apps:yes")).text,
                       "ui_apps:yes\ndylib-sha256:\(b):\(hexB)\n")
        // A dylib added later goes after the approval, keeping each dylib's lines together.
        let added = try! ConfigEditor.addDylib(b, to: ConfigDocument(text: "dylib:\(a):deny\ndylib-sha256:\(a):\(hexA)\nui_apps:yes\n"))
        XCTAssertEqual(added.text, "dylib:\(a):deny\ndylib-sha256:\(a):\(hexA)\ndylib:\(b):deny\nui_apps:yes\n")
    }

    func testRemoveDylibTakesItsApprovalAndExceptionToo() {
        let doc = ConfigDocument(text: """
        dylib:\(a):deny
        dylib-sha256:\(a):\(hexA)
        dylib-unsafe-executable:\(a):/System/Applications/Calculator.app/Contents/MacOS/Calculator
        dylib:\(b):deny
        dylib-sha256:\(b):\(hexB)

        """)
        let (out, removed) = ConfigEditor.removeDylib(a, from: doc)
        XCTAssertEqual(removed.count, 3)
        XCTAssertEqual(out.text, "dylib:\(b):deny\ndylib-sha256:\(b):\(hexB)\n")
    }

    func testDaemonModeFromItsLatestStart() {
        let audit = """
        [dynjectd 10:00:00] dynjectd: starting
        [dynjectd 10:00:00] dynjectd: approval: audit; 0 of 6 dylib(s) have a dylib-sha256 line
        """
        XCTAssertEqual(DaemonApprovalMode.latest(in: audit), .audit)
        XCTAssertEqual(DaemonApprovalMode.latest(in: audit + "\n[dynjectd 11:00:00] dynjectd: starting\n"
                                                + "[dynjectd 11:00:00] dynjectd: approval: enforce; 6 of 6 dylib(s) have a dylib-sha256 line\n"), .enforce)
        // Stock dynjectd started after an approval-aware one: it says nothing about approvals.
        XCTAssertNil(DaemonApprovalMode.latest(in: audit + "\n[dynjectd 12:00:00] dynjectd: starting\n[dynjectd 12:00:00] dynjectd: dylib[0] x\n"))
        XCTAssertNil(DaemonApprovalMode.latest(in: ""))
    }

    /// The startup line can be megabytes back: one line per skipped launch since. The file reader finds it.
    func testDaemonModeFromALongLog() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("dynjectd.log").path
        var text = "[dynjectd 09:00:00] dynjectd: starting\n[dynjectd 09:00:00] dynjectd: approval: audit; 0 of 1 dylib(s) have a dylib-sha256 line\n"
            + "[dynjectd 10:00:00] dynjectd: starting\n[dynjectd 10:00:00] dynjectd: approval: enforce; 1 of 1 dylib(s) have a dylib-sha256 line\n"
        let skip = "[dynjectd 10:00:01] dynjectd: com.apple.mdworker.shared.0D000000-0200-0000-0000-000000000000 SKIP (system_daemon)\n"
        text += String(repeating: skip, count: 3 << 20 / skip.utf8.count)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(DaemonApprovalMode.latest(inLogAt: path), .enforce)
        XCTAssertNil(DaemonApprovalMode.latest(in: String(text.suffix(200_000))), "the last 200 KB alone doesn't say")
        XCTAssertNil(DaemonApprovalMode.latest(inLogAt: path, limit: 1 << 20), "past the limit: unknown")
        XCTAssertNil(DaemonApprovalMode.latest(inLogAt: root.appendingPathComponent("none.log").path))
    }

    func testApprovePlanHashesInstalledFilesAndWritesOnce() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loc = TweakLocations.sandbox(root: root)
        try FileManager.default.createDirectory(atPath: loc.dylibFileDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (loc.configPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let dataA = Data("AAAA".utf8), dataB = Data("BBBB".utf8)
        try dataA.write(to: URL(fileURLWithPath: loc.filePath(forDylib: a)))
        try dataB.write(to: URL(fileURLWithPath: loc.filePath(forDylib: b)))
        let c = "/opt/dynject/lib/tweaks/libC.dylib", link = "/opt/dynject/lib/tweaks/libLink.dylib"
        try FileManager.default.createSymbolicLink(atPath: loc.filePath(forDylib: link), withDestinationPath: loc.filePath(forDylib: a))
        let sha: (Data) -> String = { DylibDigest.sha256Hex($0) }
        XCTAssertEqual(sha(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let config = "dylib:\(a):deny\ndylib-sha256:\(a):\(sha(dataA))\ndylib:\(b):deny\ndylib-sha256:\(b):\(hexB)\ndylib:\(c):deny\ndylib:\(link):deny\nui_apps:yes\n"
        try config.write(toFile: loc.configPath, atomically: true, encoding: .utf8)

        let plan = try TweakApprovalPlan.plan(dylibs: nil, locations: loc)
        XCTAssertEqual(plan.entries.map(\.path), [a, b])
        XCTAssertEqual(plan.entries.map(\.changes), [false, true])
        XCTAssertEqual(plan.skipped.map(\.path), [c, link])
        XCTAssertTrue(plan.skipped[1].why.contains("not a regular file"), plan.skipped[1].why)
        XCTAssertEqual(changedLines(config, plan.configNew!).removed, ["dylib-sha256:\(b):\(hexB)"])
        XCTAssertEqual(changedLines(config, plan.configNew!).added, ["dylib-sha256:\(b):\(sha(dataB))"])
        XCTAssertTrue(plan.summaryLines[1].contains("replace approval"), "\(plan.summaryLines)")

        let sim = SimulatedRestarter()
        let writer = ProtectedFileWriter(backups: BackupStore(root: root.appendingPathComponent("Backups")), executor: RecordingExecutor())
        let outcome = try plan.execute(writer: writer, restarter: sim)
        XCTAssertNotNil(outcome)
        XCTAssertEqual(sim.count, 1)
        XCTAssertTrue(try TweakApprovalPlan.plan(dylibs: nil, locations: loc).changesNothing)

        // Naming one that the config doesn't declare: skipped, nothing written.
        let other = try TweakApprovalPlan.plan(dylibs: ["/opt/dynject/lib/tweaks/libNope.dylib"], locations: loc)
        XCTAssertTrue(other.changesNothing)
        XCTAssertEqual(other.skipped.first?.why, "the config doesn't declare it")
    }
}
