@testable import DynjectWorkbench
import DynjectCore
import XCTest

// The Respring sheet's model, link handling and isolation. Everything runs against a RespringFixtureWorld and
// SimulatedAppController: nothing here looks at, quits or opens a real app.

private let menu = "/opt/dynject/lib/tweaks/libMenuLoader.dylib"
private let brut = "/opt/dynject/lib/tweaks/libBrutalium.dylib"
private let config = """
dylib:\(menu):allow
dylib:\(brut):deny
dylib-override:\(brut):allow:com.apple.Finder
ui_apps:yes

"""

private func installed(_ name: String, _ bundleID: String, dir: String = "/System/Applications") -> InstalledApp {
    let bundle = "\(dir)/\(name).app"
    return InstalledApp(displayName: name, bundleID: bundleID, executableName: name,
                        executablePath: "\(bundle)/Contents/MacOS/\(name)", bundlePath: bundle)
}

private let textEdit = installed("TextEdit", "com.apple.TextEdit")
private let notes = installed("Notes", "com.apple.Notes")
private let calculator = installed("Calculator", "com.apple.calculator")
private let finder = installed("Finder", "com.apple.finder", dir: "/System/Library/CoreServices")
private let terminal = installed("Terminal", "com.apple.Terminal", dir: "/System/Applications/Utilities")

@MainActor
final class RespringWorkbenchTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dw-respring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: dir.appendingPathComponent("dynjectd.conf"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func env(_ extra: [String] = []) -> AppEnvironment {
        AppEnvironment.current(arguments: ["DynjectWorkbench", "-DWConfigPath", dir.appendingPathComponent("dynjectd.conf").path,
                                           "-DWSupportDir", dir.path, "-DWLogPath", dir.appendingPathComponent("none.log").path,
                                           "-DWTweakDylibDir", dir.appendingPathComponent("dylibs").path] + extra)
    }

    private func inputs(_ e: AppEnvironment, apps: [InstalledApp] = [textEdit, notes, calculator, finder, terminal]) -> RespringInputs {
        RespringInputs(configText: config, configPath: e.configPath, logPath: e.logPath, manifests: [],
                       dylibDirectory: e.tweakDylibDirectory, safeModeStateDirectory: e.safeModeStateDirectory, daemon: nil,
                       installedApps: apps, injectedApps: apps, appsScanned: true)
    }

    private func writeFixture(_ f: RespringFixture) throws -> String {
        let path = dir.appendingPathComponent("respring.json").path
        try JSONEncoder().encode(f).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private var fixture: RespringFixture {
        RespringFixture(apps: [
            .init(bundleID: "com.apple.TextEdit", launchedMinutesAgo: 90, loaded: []),                 // missing MenuLoader
            .init(bundleID: "com.apple.Notes", launchedMinutesAgo: 90, loaded: [menu], refusesToQuit: true), // updated, stuck
            .init(bundleID: "com.apple.calculator", launchedMinutesAgo: 5, loaded: [menu]),            // up to date
            .init(bundleID: "com.apple.finder", launchedMinutesAgo: 90, loaded: [menu]),               // missing Brutalium
            .init(bundleID: "com.apple.Terminal", launchedMinutesAgo: 90, loaded: []),                 // developer tool
            .init(bundleID: "local.dynject.workbench", name: "Dynject Workbench", bundlePath: "/Applications/Dynject Workbench.app",
                  launchedMinutesAgo: 90, loaded: [], hostsCaller: true),
        ], dylibModifiedMinutesAgo: [menu: 30, brut: 600])
    }

    private func model(_ e: AppEnvironment, apps: [InstalledApp]? = nil) -> RespringModel {
        let m = RespringModel(env: e)
        m.simulatedPace = 0
        let i = apps.map { inputs(e, apps: $0) } ?? inputs(e)
        m.inputs = { i }
        return m
    }

    // MARK: Links and isolation

    func testLinkParsing() {
        for s in ["dynject-workbench://respring", "DYNJECT-WORKBENCH://Respring/", "dynject-workbench:respring",
                  "dynject-workbench://respring?from=menu"] {
            XCTAssertEqual(WorkbenchLink(url: URL(string: s)!), .respring, s)
        }
        for s in ["dynject-workbench://settings", "https://respring.example", "dynject-workbench://"] {
            XCTAssertNil(WorkbenchLink(url: URL(string: s)!), s)
        }
    }

    func testInfoPlistRegistersTheScheme() throws {
        let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let d = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        let schemes = (d["CFBundleURLTypes"] as? [[String: Any]])?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, [WorkbenchLink.scheme])
    }

    func testOnlyALiveLaunchUsesTheRealController() {
        XCTAssertFalse(AppEnvironment.current(arguments: ["DynjectWorkbench"]).isolatesRespring)
        XCTAssertFalse(AppEnvironment.current(arguments: ["DynjectWorkbench", "-DWTweaksDir", "/tmp/t"]).isolatesRespring,
                       "previewing manifests keeps the config live")
        for args in [["-DWConfigPath", "/tmp/dw.conf"], ["-DWSmokeTest", "/tmp/r"], ["-DWRespringFixture", "/tmp/f.json"]] {
            let e = AppEnvironment.current(arguments: ["DynjectWorkbench"] + args)
            XCTAssertTrue(e.isolatesRespring, args[0])
            XCTAssertTrue(RespringModel(env: e).simulated, args[0])
        }
    }

    /// A link only opens the sheet; nothing runs until Respring Selected.
    func testLinkOpensTheSheetWithoutRelaunching() async throws {
        let e = env(["-DWRespringFixture", try writeFixture(fixture)])
        let wb = WorkbenchModel(env: e)
        XCTAssertTrue(wb.respring.simulated)
        wb.handle(url: URL(string: "dynject-workbench://respring")!)
        XCTAssertTrue(wb.respring.showSheet)
        XCTAssertEqual(wb.respring.linkRequests, 1)
        XCTAssertFalse(wb.respring.isRunning)
        XCTAssertTrue(wb.respring.runList.isEmpty)
        wb.respring.close()

        // While the save review is up, the sheet waits for it.
        wb.showApplySheet = true
        wb.handle(url: URL(string: "dynject-workbench://respring")!)
        XCTAssertFalse(wb.respring.showSheet)
        wb.showApplySheet = false
        let shown = await waitFor(3) { wb.respring.showSheet }
        XCTAssertTrue(shown)
        XCTAssertFalse(wb.respring.isRunning)

        wb.handle(url: URL(string: "dynject-workbench://nope")!)
        XCTAssertEqual(wb.banner?.title, "Unknown link")
    }

    // MARK: Plan, selection, run

    func testFixturePlanSelectionAndSimulatedRun() async throws {
        let m = model(env(["-DWRespringFixture", try writeFixture(fixture)]))
        m.present()
        let planned = await waitFor { m.plan != nil }
        XCTAssertTrue(planned)
        let plan = try XCTUnwrap(m.plan)
        func cand(_ id: String) throws -> RespringCandidate { try XCTUnwrap(plan.candidate(bundleID: id), id) }

        XCTAssertEqual(Set(plan.pending.map(\.app.bundleID)),
                       ["com.apple.TextEdit", "com.apple.Notes", "com.apple.finder", "com.apple.Terminal", "local.dynject.workbench"])
        XCTAssertEqual(try cand("com.apple.TextEdit").reasons.map(\.kind), [.missing])
        XCTAssertEqual(try cand("com.apple.Notes").reasons.map(\.kind), [.updated])
        XCTAssertEqual(try cand("com.apple.finder").reasons.map(\.kind), [.missing, .updated])
        XCTAssertEqual(try cand("com.apple.finder").exclusion, .finder)
        XCTAssertEqual(try cand("com.apple.Terminal").exclusion, .developerTool)
        XCTAssertTrue(try cand("local.dynject.workbench").hostsCaller)

        // Exclusions start unchecked, with a note; the sheet lists pending apps only until "show all".
        XCTAssertEqual(Set(m.selectedCandidates.map(\.app.bundleID)), ["com.apple.TextEdit", "com.apple.Notes"])
        XCTAssertTrue(m.note(for: try cand("com.apple.Terminal"))?.hasPrefix("Unchecked: terminal or editor") ?? false)
        XCTAssertTrue(m.note(for: try cand("local.dynject.workbench"))?.contains("This is Workbench") ?? false)
        XCTAssertNil(m.note(for: try cand("com.apple.TextEdit")))
        XCTAssertFalse(m.visibleCandidates.contains { $0.app.bundleID == "com.apple.calculator" })
        m.showAllApps = true
        XCTAssertTrue(m.visibleCandidates.contains { $0.app.bundleID == "com.apple.calculator" })

        m.setSelected(true, try cand("com.apple.finder"))
        m.setSelected(true, try cand("local.dynject.workbench"))
        XCTAssertTrue(m.note(for: try cand("com.apple.finder"))?.hasPrefix("Checked even though") ?? false)

        m.run()
        XCTAssertEqual(m.runList.map(\.app.bundleID),
                       ["com.apple.finder", "com.apple.Notes", "com.apple.TextEdit", "local.dynject.workbench"],
                       "by name, the app hosting Workbench last")
        let done = await waitFor { !m.isRunning && m.results.count == 4 }
        XCTAssertTrue(done)
        func outcome(_ id: String) throws -> RespringResult { try XCTUnwrap(m.results[try cand(id).id], id) }
        XCTAssertEqual(try outcome("com.apple.TextEdit").outcome, .relaunched)
        XCTAssertTrue(try outcome("com.apple.TextEdit").succeeded)
        XCTAssertTrue(try outcome("com.apple.finder").succeeded)
        XCTAssertEqual(try outcome("com.apple.Notes").outcome, .didNotQuit(timeout: 15))
        XCTAssertEqual(try outcome("local.dynject.workbench").outcome, .handedOff)
        XCTAssertEqual(m.runSummary, "3 of 4 relaunched as expected; 1 skipped (simulated).")

        // Only the simulated controller was asked, Finder by Apple Event; Terminal and Calculator were never touched.
        let calls = m.simulatedCalls
        XCTAssertTrue(calls.contains(.terminate(try cand("com.apple.finder").app.pid, .appleEventQuit)))
        XCTAssertTrue(calls.contains(.terminate(try cand("com.apple.Notes").app.pid, .terminate)))
        XCTAssertTrue(calls.contains(.scheduleReopen("/Applications/Dynject Workbench.app", try cand("local.dynject.workbench").app.pid)))
        for id in ["com.apple.Terminal", "com.apple.calculator"] {
            let pid = try cand(id).app.pid
            XCTAssertFalse(calls.contains { if case let .terminate(p, _) = $0 { return p == pid } else { return false } }, id)
        }
        XCTAssertEqual(calls.filter { if case .open = $0 { return true } else { return false } }.count, 2)

        // The fixture world now has the relaunched processes, so only the stuck app and Terminal stay pending.
        let replanned = await waitFor { m.planCount >= 2 && !m.isPlanning }
        XCTAssertTrue(replanned)
        XCTAssertEqual(Set(m.plan?.pending.map(\.app.bundleID) ?? []), ["com.apple.Notes", "com.apple.Terminal"])
        m.backToList()
        XCTAssertTrue(m.runList.isEmpty)
    }

    func testStopAfterThisAppCancelsTheRest() async throws {
        var f = fixture
        f.apps[1].refusesToQuit = nil
        let m = model(env(["-DWRespringFixture", try writeFixture(f)]))
        m.simulatedPace = 0.2
        m.refresh()
        let planned = await waitFor { m.plan != nil }
        XCTAssertTrue(planned)
        m.run()
        let started = await waitFor { !m.activity.isEmpty }
        XCTAssertTrue(started)
        m.stop()
        let done = await waitFor { !m.isRunning }
        XCTAssertTrue(done)
        let outcomes = m.runList.compactMap { m.results[$0.id]?.outcome }
        XCTAssertEqual(outcomes.first, .relaunched, "the app in progress finishes")
        XCTAssertTrue(outcomes.dropFirst().allSatisfy { $0 == .cancelled }, "\(outcomes)")
    }

    /// Without a fixture file: the injected scanned apps, Finder, a terminal and Workbench as the host.
    func testDefaultFixtureWorld() async throws {
        let m = model(env(), apps: [textEdit, finder, terminal])
        m.refresh()
        let planned = await waitFor { m.plan != nil }
        XCTAssertTrue(planned)
        let plan = try XCTUnwrap(m.plan)
        XCTAssertEqual(Set(plan.candidates.map(\.app.bundleID)),
                       ["com.apple.TextEdit", "com.apple.finder", "com.apple.Terminal", "local.dynject.workbench"])
        XCTAssertEqual(plan.candidate(bundleID: "com.apple.TextEdit")?.reasons.map(\.kind), [.missing])
        XCTAssertTrue(plan.candidate(bundleID: "local.dynject.workbench")?.hostsCaller ?? false)
        XCTAssertEqual(plan.defaultSelection.map(\.app.bundleID), ["com.apple.TextEdit"])
    }

    func testUnreadableFixtureIsReportedAndEmpty() async throws {
        let m = model(env(["-DWRespringFixture", dir.appendingPathComponent("missing.json").path]))
        m.refresh()
        let planned = await waitFor { m.plan != nil }
        XCTAssertTrue(planned)
        XCTAssertNotNil(m.fixtureError)
        XCTAssertEqual(m.plan?.candidates.count, 0)
    }
}
