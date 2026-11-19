@testable import DynjectCore
import XCTest

final class ConfigEditorTests: XCTestCase {
    let brutalium = "/opt/dynject/lib/tweaks/libBrutalium.dylib"

    func set(_ on: Bool, _ dylib: String, _ app: InstalledApp, in text: String,
             apps: [InstalledApp] = Apps.all) throws -> InjectionEditResult {
        try ConfigEditor.setInjection(on, dylib: dylib, for: Apps.target(app), in: ConfigDocument(text: text),
                                      allTargets: Apps.targets(apps), fileExists: exists())
    }

    func injected(_ app: InstalledApp, _ text: String) -> [String] {
        PolicyEvaluator.evaluate(app: app, service: Apps.target(app).service,
                                 config: EffectiveConfig(document: ConfigDocument(text: text)),
                                 fileExists: exists()).injectedDylibs
    }

    func testEnableTextEditOnLiveConfigOnlyAddsLines() throws {
        let live = Fixtures.text("live.conf")
        let r = try set(true, brutalium, Apps.textEdit, in: live)
        let d = changedLines(live, r.document.text)
        XCTAssertEqual(d.removed, [])
        XCTAssertEqual(Set(d.added), [
            "dylib-override:/opt/dynject/lib/tweaks/libBrutalium.dylib:allow:com.apple.TextEdit",
            "allow:TextEdit",
        ])
        // Override lands right after the existing override; gate right after allow:Finder.
        XCTAssertEqual(r.document.lines.map(\.text), [
            "# Brutalium trial: Finder only.",
            "dylib:/opt/dynject/lib/tweaks/libBrutalium.dylib:deny",
            "dylib-override:/opt/dynject/lib/tweaks/libBrutalium.dylib:allow:com.apple.Finder",
            "dylib-override:/opt/dynject/lib/tweaks/libBrutalium.dylib:allow:com.apple.TextEdit",
            "allow:Finder",
            "allow:TextEdit",
            "ui_apps:no",
            "skip_helpers:yes",
        ])
        XCTAssertEqual(injected(Apps.textEdit, r.document.text), [brutalium])
        XCTAssertEqual(injected(Apps.finder, r.document.text), [brutalium])
        XCTAssertEqual(r.sideEffects, [])
    }

    func testEnableThenDisableRestoresTheOriginalBytes() throws {
        for name in ["live.conf", "crlf-no-final-newline.conf"] {
            let original = Fixtures.text(name)
            let on = try set(true, brutalium, Apps.textEdit, in: original)
            let off = try set(false, brutalium, Apps.textEdit, in: on.document.text)
            XCTAssertEqual(off.document.text, original, name)
        }
    }

    func testDisableFinderRemovesItsOverrideAndGate() throws {
        let live = Fixtures.text("live.conf")
        let r = try set(false, brutalium, Apps.finder, in: live)
        let d = changedLines(live, r.document.text)
        XCTAssertEqual(d.added, [])
        XCTAssertEqual(Set(d.removed), [
            "dylib-override:/opt/dynject/lib/tweaks/libBrutalium.dylib:allow:com.apple.Finder",
            "allow:Finder",
        ])
        XCTAssertEqual(injected(Apps.finder, r.document.text), [])
    }

    func testGateIsKeptWhenAnotherDylibStillNeedsIt() throws {
        let text = """
        dylib:/a.dylib:deny
        dylib-override:/a.dylib:allow:com.apple.Finder
        dylib:/b.dylib:deny
        dylib-override:/b.dylib:allow:com.apple.Finder
        allow:Finder
        ui_apps:no

        """
        let r = try set(false, "/a.dylib", Apps.finder, in: text)
        XCTAssertTrue(r.document.text.contains("allow:Finder"))
        XCTAssertEqual(injected(Apps.finder, r.document.text), ["/b.dylib"])
    }

    func testFinderUsesItsLaunchdServiceNameNotItsBundleID() throws {
        // Finder's bundle ID is com.apple.finder but dynjectd sees "com.apple.Finder" (case-sensitive).
        let text = "dylib:/a.dylib:deny\nallow:Finder\nui_apps:no\n"
        let r = try set(true, "/a.dylib", Apps.finder, in: text)
        XCTAssertTrue(r.document.text.contains("dylib-override:/a.dylib:allow:com.apple.Finder\n"))
        XCTAssertFalse(r.document.text.contains("com.apple.finder"))
    }

    func testInsertsAboveABroaderRuleSoFirstMatchWins() throws {
        let multi = Fixtures.text("multi.conf")
        let alpha = "/opt/dynject/lib/tweaks/libAlpha.dylib"
        let r = try set(true, alpha, Apps.notes, in: multi)
        let lines = r.document.lines.map(\.text)
        let newLine = lines.firstIndex(of: "dylib-override:\(alpha):allow:com.apple.Notes")!
        let broad = lines.firstIndex(of: "dylib-override:\(alpha):deny:com.apple")!
        XCTAssertLessThan(newLine, broad)
        XCTAssertEqual(changedLines(multi, r.document.text).removed, [])
        XCTAssertTrue(injected(Apps.notes, r.document.text).contains(alpha))
        XCTAssertFalse(injected(Apps.textEdit, r.document.text).contains(alpha))
    }

    func testSharedPatternIsNotEditedInPlace() throws {
        let multi = Fixtures.text("multi.conf")
        let alpha = "/opt/dynject/lib/tweaks/libAlpha.dylib"
        // "com.apple.Safari" also matches Safari Technology Preview, so that line is left alone and a
        // narrower override is inserted above it.
        let r = try set(true, alpha, Apps.safari, in: multi)
        XCTAssertEqual(changedLines(multi, r.document.text).removed, [])
        XCTAssertEqual(changedLines(multi, r.document.text).added,
                       ["dylib-override:\(alpha):allow:application.com.apple.Safari."])
        XCTAssertTrue(injected(Apps.safari, r.document.text).contains(alpha))
        XCTAssertFalse(injected(Apps.safariTP, r.document.text).contains(alpha))
        XCTAssertEqual(r.sideEffects, [])

        // Without the look-alike installed, the line is specific. Removing it would fall through to
        // deny:com.apple, so its policy is flipped in place instead.
        let r2 = try set(true, alpha, Apps.safari, in: multi, apps: Apps.all.filter { $0 != Apps.safariTP })
        XCTAssertEqual(r2.changes, [.modified(old: "dylib-override:\(alpha):deny:com.apple.Safari",
                                              new: "dylib-override:\(alpha):allow:com.apple.Safari")])
    }

    func testRemovesASpecificOverrideWhenDefaultAlreadyGivesTheResult() throws {
        let text = "dylib:/a.dylib:allow\ndylib-override:/a.dylib:deny:com.apple.TextEdit\nui_apps:yes\n"
        let r = try set(true, "/a.dylib", Apps.textEdit, in: text)
        XCTAssertEqual(r.document.text, "dylib:/a.dylib:allow\nui_apps:yes\n")
    }

    func testFlipsPolicyInPlaceWhenRemovalWouldNotWork() throws {
        let text = "dylib:/a.dylib:deny\n  dylib-override:/a.dylib:deny:com.apple.TextEdit  \ndylib-override:/a.dylib:deny:com.apple\nui_apps:yes\n"
        let r = try set(true, "/a.dylib", Apps.textEdit, in: text)
        XCTAssertEqual(r.document.lines[1].text, "  dylib-override:/a.dylib:allow:com.apple.TextEdit  ")
        XCTAssertEqual(r.changes.count, 1)
    }

    func testBlockedByGlobalDenyRule() {
        XCTAssertThrowsError(try set(true, "/opt/dynject/lib/tweaks/libBeta.dylib", Apps.terminal,
                                     in: Fixtures.text("multi.conf"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("deny:Terminal"))
        }
    }

    func testBlockedForHelpers() {
        XCTAssertThrowsError(try set(true, "/opt/dynject/lib/tweaks/libBeta.dylib", Apps.helper,
                                     in: Fixtures.text("multi.conf")))
    }

    func testBlockedForDuplicateDeclarations() {
        XCTAssertThrowsError(try set(true, "/opt/dynject/lib/tweaks/libLate.dylib", Apps.notes,
                                     in: Fixtures.text("edge.conf")))
    }

    func testOutsideAppGetsAnAllowGateWhenUIAppsIsOn() throws {
        let r = try set(true, "/opt/dynject/lib/tweaks/libBeta.dylib", Apps.outside, in: Fixtures.text("multi.conf"))
        XCTAssertTrue(r.document.text.contains("allow:Tool\n"))
        XCTAssertEqual(injected(Apps.outside, r.document.text).contains("/opt/dynject/lib/tweaks/libBeta.dylib"), true)
    }

    func testNoOpWhenAlreadyInEffect() throws {
        let live = Fixtures.text("live.conf")
        let r = try set(true, brutalium, Apps.finder, in: live)
        XCTAssertEqual(r.document.text, live)
        XCTAssertEqual(r.changes, [])
    }

    func testReportsSideEffectsOfBroadAllowGate() throws {
        // With a default-allow dylib, the allow:Finder gate added for Finder is a substring match,
        // so it also admits "Path Finder" — the editor must report that.
        let text = "dylib:/a.dylib:allow\nui_apps:no\n"
        let r = try set(true, "/a.dylib", Apps.finder, in: text)
        XCTAssertEqual(r.sideEffects.map(\.app.displayName), ["Path Finder"])
    }

    func testCRLFIsPreservedOnInsert() throws {
        let text = Fixtures.text("crlf-no-final-newline.conf")
        let r = try set(true, brutalium, Apps.textEdit, in: text)
        XCTAssertFalse(r.document.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    func testAddDylibGoesAfterTheDylibBlockAndDefaultsToDeny() throws {
        let live = Fixtures.text("live.conf")
        let doc = try ConfigEditor.addDylib("/opt/dynject/lib/tweaks/libNew.dylib", to: ConfigDocument(text: live))
        XCTAssertEqual(doc.lines.map(\.text)[3], "dylib:/opt/dynject/lib/tweaks/libNew.dylib:deny")
        XCTAssertEqual(changedLines(live, doc.text).added, ["dylib:/opt/dynject/lib/tweaks/libNew.dylib:deny"])
        XCTAssertEqual(changedLines(live, doc.text).removed, [])
        XCTAssertFalse(EffectiveConfig(document: doc).dylib(path: "/opt/dynject/lib/tweaks/libNew.dylib")!.defaultAllow)
        // Then it can be enabled for one app like any other dylib.
        let on = try set(true, "/opt/dynject/lib/tweaks/libNew.dylib", Apps.textEdit, in: doc.text)
        XCTAssertEqual(injected(Apps.textEdit, on.document.text), ["/opt/dynject/lib/tweaks/libNew.dylib"])
        XCTAssertEqual(injected(Apps.finder, on.document.text), [brutalium])

        XCTAssertThrowsError(try ConfigEditor.addDylib(brutalium, to: ConfigDocument(text: live)))
        XCTAssertThrowsError(try ConfigEditor.addDylib("relative.dylib", to: ConfigDocument(text: live)))
        XCTAssertThrowsError(try ConfigEditor.addDylib("/a:b.dylib", to: ConfigDocument(text: live)))
        // No dylib lines yet: goes before the process rules.
        let bare = try ConfigEditor.addDylib("/x.dylib", to: ConfigDocument(text: "# c\nallow:Finder\nui_apps:no\n"))
        XCTAssertEqual(bare.text, "# c\ndylib:/x.dylib:deny\nallow:Finder\nui_apps:no\n")
    }

    func testRewritePolicyKeepsBytes() throws {
        XCTAssertEqual(try ConfigEditor.rewritePolicy(in: "dylib-override:  /a:deny:x:y ", to: true),
                       "dylib-override:  /a:allow:x:y ")
    }
}
