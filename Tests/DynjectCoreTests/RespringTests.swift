@testable import DynjectCore
import XCTest

// Respring planner and engine, with fakes only: nothing here looks at or signals a real process.

private struct FakeRunningApps: RunningAppSource {
    var apps: [RunningApp]
    func runningApps() -> [RunningApp] { apps }
}

private final class FakeInspector: LoadedDylibInspecting {
    var loaded: [Int32: Set<String>]
    var askedFor: [String] = []
    init(_ loaded: [Int32: Set<String>]) { self.loaded = loaded }
    func loadedDylibs(pids: [Int32], candidates: [String]) -> [Int32: Set<String>] {
        askedFor = candidates
        return loaded.filter { pids.contains($0.key) }.mapValues { $0.intersection(candidates) }
    }
}

private struct FakeAncestry: ProcessAncestry {
    var parents: [Int32: Int32]
    var paths: [Int32: String]
    func parentPID(of pid: Int32) -> Int32? { parents[pid] }
    func executablePath(of pid: Int32) -> String? { paths[pid] }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

private let menu = "/opt/dynject/lib/tweaks/libMenuLoader.dylib"
private let badge = "/opt/dynject/lib/tweaks/libTitleBadge.dylib"
private let brut = "/opt/dynject/lib/tweaks/libBrutalium.dylib"
private let old = "/opt/dynject/lib/tweaks/libOld.dylib"

private let configText = """
dylib:\(menu):allow
dylib-override:\(menu):deny:com.apple.Dock.
dylib:\(badge):deny
dylib-override:\(badge):allow:com.apple.calculator
dylib:\(brut):deny
dylib-override:\(brut):allow:com.apple.Finder
ui_apps:yes
"""

private func app(_ name: String, _ bundleID: String, pid: Int32, launched: Double? = 0,
                 dir: String = "/System/Applications", hidden: Bool = false) -> RunningApp {
    let bundle = "\(dir)/\(name).app"
    return RunningApp(pid: pid, bundleID: bundleID, name: name, bundlePath: bundle,
                      executablePath: "\(bundle)/Contents/MacOS/\(name)", launchDate: launched.map(at), isHidden: hidden)
}

private let calculator = app("Calculator", "com.apple.calculator", pid: 101)
private let notes = app("Notes", "com.apple.Notes", pid: 102)
private let maps = app("Maps", "com.apple.Maps", pid: 103, launched: 30)
private let tool = app("Tool", "com.example.tool", pid: 104, dir: "/Users/someone/Downloads")
private let finder = app("Finder", "com.apple.finder", pid: 105, dir: "/System/Library/CoreServices")
private let code = app("Visual Studio Code", "com.microsoft.VSCode", pid: 106, dir: "/Applications")
private let ghostty = app("Ghostty", "com.mitchellh.ghostty", pid: 107, dir: "/Applications")
private let workbench = app("Dynject Workbench", "local.dynject.workbench", pid: 108, dir: "/Applications")
private let loginwindow = app("loginwindow", "com.apple.loginwindow", pid: 109, dir: "/System/Library/CoreServices")
private let pycharm = app("PyCharm", "com.jetbrains.pycharm", pid: 110, dir: "/Applications")
private let textEdit = app("TextEdit", "com.apple.TextEdit", pid: 111)

private func planner(_ apps: [RunningApp], loaded: [Int32: Set<String>], mtimes: [String: Date] = [:],
                     exclusions: RespringExclusions = RespringExclusions(), since: Date? = nil,
                     safeModeTweaks: [String: String] = [:], events: [RespringSafeModeEvent] = []) -> RespringPlanner {
    RespringPlanner(config: EffectiveConfig(document: ConfigDocument(text: configText)),
                    runningApps: FakeRunningApps(apps: apps), inspector: FakeInspector(loaded),
                    fileExists: { _ in true }, modificationDate: { mtimes[$0] ?? at(-60) }, now: { at(100) },
                    tweakLabels: [menu: "local.dynject.menuloader", badge: "local.dynject.titlebadge"],
                    extraTweakDylibs: [old], configEffectiveSince: since,
                    safeModeTweaks: safeModeTweaks, safeModeEvents: events, exclusions: exclusions)
}

final class RespringPlannerTests: XCTestCase {
    func testPendingReasons() {
        let p = planner([calculator, notes, maps, tool, textEdit], loaded: [
            101: [menu, badge],      // badge replaced on disk after launch
            102: [],                 // launched before MenuLoader went global
            103: [menu],             // up to date
            104: [],                 // outside the Applications folders: no Dynject involvement
            111: [menu, brut, old],  // Brutalium not allowed here; libOld no longer configured
        ], mtimes: [badge: at(10)]).plan()

        XCTAssertEqual(p.candidates.map(\.app.name), ["Calculator", "Maps", "Notes", "TextEdit", "Tool"])
        let calc = p.candidate(bundleID: "com.apple.calculator")!
        XCTAssertEqual(calc.expected, [menu, badge])
        XCTAssertEqual(calc.reasons, [RespringReason(.updated, dylib: badge, tweak: "local.dynject.titlebadge", date: at(10))])
        XCTAssertEqual(calc.reasonSummary, "updated local.dynject.titlebadge")

        XCTAssertEqual(p.candidate(bundleID: "com.apple.Notes")!.reasonSummary, "missing local.dynject.menuloader")
        XCTAssertEqual(p.candidate(bundleID: "com.apple.TextEdit")!.reasons.map(\.kind), [.unwanted, .unwanted])
        XCTAssertEqual(p.candidate(bundleID: "com.apple.TextEdit")!.reasonSummary,
                       "unwanted libBrutalium.dylib, unwanted libOld.dylib")

        let mapsC = p.candidate(bundleID: "com.apple.Maps")!
        XCTAssertFalse(mapsC.isPending)
        XCTAssertTrue(mapsC.isInvolved)
        let toolC = p.candidate(bundleID: "com.example.tool")!
        XCTAssertFalse(toolC.isPending)
        XCTAssertFalse(toolC.isInvolved)
        XCTAssertEqual(p.pending.map(\.app.name), ["Calculator", "Notes", "TextEdit"])
        XCTAssertEqual(p.defaultSelection.map(\.app.name), ["Calculator", "Notes", "TextEdit"])
        XCTAssertEqual(p.date, at(100))
    }

    func testAsksLsofAboutConfiguredExtraAndSafeModeDylibs() {
        let inspector = FakeInspector([:])
        var pl = planner([notes], loaded: [:], safeModeTweaks: ["/x/libSM.dylib": "x.sm"])
        pl.inspector = inspector
        _ = pl.plan()
        XCTAssertEqual(inspector.askedFor, [menu, badge, brut, old, "/x/libSM.dylib"])
    }

    func testUninspectableAppIsNotPending() {
        let p = planner([notes], loaded: [:]).plan()
        let c = p.candidates[0]
        XCTAssertNil(c.loaded)
        XCTAssertFalse(c.isPending)
        XCTAssertEqual(p.notInspected.map(\.app.pid), [102])
    }

    func testUpdatedNeedsALaunchDate() {
        let undated = app("Notes", "com.apple.Notes", pid: 102, launched: nil)
        let p = planner([undated], loaded: [102: [menu]], mtimes: [menu: at(5)]).plan()
        XCTAssertFalse(p.candidates[0].isPending)
    }

    func testSafeModeChangesAfterLaunch() {
        let sm = [menu: "local.dynject.menuloader"]
        func reasons(_ events: [RespringSafeModeEvent]) -> [RespringReason.Kind] {
            planner([notes], loaded: [102: [menu]], safeModeTweaks: sm, events: events).plan().candidates[0].reasons.map(\.kind)
        }
        XCTAssertEqual(reasons([.init(tweakID: "local.dynject.menuloader", bundleID: "com.apple.Notes", date: at(5), turnedOff: true)]),
                       [.safeModeOff])
        // Before launch: the running process already honours it.
        XCTAssertEqual(reasons([.init(tweakID: "local.dynject.menuloader", bundleID: "com.apple.Notes", date: at(-5), turnedOff: true)]), [])
        // Another app, another tweak.
        XCTAssertEqual(reasons([.init(tweakID: "local.dynject.menuloader", bundleID: "com.apple.Maps", date: at(5), turnedOff: true),
                                .init(tweakID: "other", bundleID: "*", date: at(5), turnedOff: true)]), [])
        // The panic switch, then a later re-enable: the latest change wins.
        XCTAssertEqual(reasons([.init(tweakID: "*", bundleID: "*", date: at(5), turnedOff: true),
                                .init(tweakID: "local.dynject.menuloader", bundleID: "*", date: at(6), turnedOff: false)]), [.safeModeOn])
        // A tweak that ignores Safe Mode (not in safeModeTweaks) never gets a Safe Mode reason.
        let plain = planner([notes], loaded: [102: [menu]],
                            events: [.init(tweakID: "*", bundleID: "*", date: at(5), turnedOff: true)]).plan()
        XCTAssertFalse(plain.candidates[0].isPending)
    }

    func testSafeModeEventsFromState() {
        var s = SafeModeState()
        s.disabled = [SafeModeDisabledEntry(tweakID: "a", bundleID: "com.x", since: at(1), reason: .manual)]
        s.reenabled = [SafeModeReenable(tweakID: "b", bundleID: "*", date: at(2))]
        s.panicSince = at(3)
        XCTAssertEqual(RespringSafeModeEvent.from(state: s), [
            .init(tweakID: "a", bundleID: "com.x", date: at(1), turnedOff: true),
            .init(tweakID: "b", bundleID: "*", date: at(2), turnedOff: false),
            .init(tweakID: "*", bundleID: "*", date: at(3), turnedOff: true),
        ])
    }

    func testInjectionBlockedWhenLaunchedAfterTheConfigTookEffect() {
        // Maps launched at +30, after the config (+20) and the file (-60), and still lacks MenuLoader.
        let p = planner([maps, notes], loaded: [103: [], 102: []], since: at(20)).plan()
        let m = p.candidate(bundleID: "com.apple.Maps")!
        XCTAssertTrue(m.isPending)
        XCTAssertEqual(m.exclusion, .injectionBlocked)
        XCTAssertFalse(m.selectedByDefault)
        // Notes launched before it: an ordinary pending app.
        XCTAssertNil(p.candidate(bundleID: "com.apple.Notes")!.exclusion)
        // A file written after launch means a relaunch may well help.
        let q = planner([maps], loaded: [103: []], mtimes: [menu: at(40)], since: at(20)).plan()
        XCTAssertNil(q.candidates[0].exclusion)
    }

    func testOutermostAppBundle() {
        XCTAssertEqual(RespringPaths.outermostAppBundle(
            in: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"),
            "/Applications/Visual Studio Code.app")
        XCTAssertEqual(RespringPaths.outermostAppBundle(in: "/Applications/Ghostty.app/Contents/MacOS/ghostty"), "/Applications/Ghostty.app")
        XCTAssertEqual(RespringPaths.outermostAppBundle(in: "/Applications/Foo.app"), "/Applications/Foo.app")
        XCTAssertNil(RespringPaths.outermostAppBundle(in: "/bin/zsh"))
        XCTAssertEqual(RespringPaths.normalized("/Applications/Foo.app/"), "/Applications/Foo.app")
    }

    func testParentChainFindsTheHostingEditor() {
        // dw (500) ← zsh (499) ← Code Helper (Plugin) (498) ← Code (106) ← launchd
        let ancestry = FakeAncestry(
            parents: [500: 499, 499: 498, 498: 106, 106: 1],
            paths: [500: "/tmp/dw", 499: "/bin/zsh",
                    498: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
                    106: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"])
        let host = RespringExclusions.host(of: 500, ancestry: ancestry)
        XCTAssertEqual(host.hostPIDs, [500, 499, 498, 106])
        XCTAssertEqual(host.hostBundlePaths, ["/Applications/Visual Studio Code.app"])
        XCTAssertTrue(host.hosts(code))
        XCTAssertFalse(host.hosts(ghostty))

        // A broken chain (re-parented to launchd) still matches by bundle path.
        let orphan = RespringExclusions.host(of: 500, ancestry: FakeAncestry(
            parents: [500: 498, 498: 1], paths: ancestry.paths))
        XCTAssertTrue(orphan.hosts(code))

        // A cycle or a runaway chain stops.
        let loop = RespringExclusions.host(of: 7, ancestry: FakeAncestry(parents: [7: 8, 8: 7], paths: [:]))
        XCTAssertEqual(loop.hostPIDs, [7, 8])
    }

    func testDefaultExclusions() {
        let host = RespringExclusions(hostPIDs: [500, 106])
        let apps = [calculator, finder, code, ghostty, workbench, loginwindow, pycharm]
        let loaded = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, Set<String>()) })
        let p = planner(apps, loaded: loaded, exclusions: host).plan()
        func ex(_ id: String) -> RespringExclusion? { p.candidate(bundleID: id)!.exclusion }
        XCTAssertNil(ex("com.apple.calculator"))
        XCTAssertEqual(ex("com.apple.finder"), .finder)
        XCTAssertEqual(ex("com.microsoft.VSCode"), .hostsThisProcess)
        XCTAssertTrue(p.candidate(bundleID: "com.microsoft.VSCode")!.hostsCaller)
        XCTAssertEqual(ex("com.mitchellh.ghostty"), .developerTool)
        XCTAssertEqual(ex("com.jetbrains.pycharm"), .developerTool)
        XCTAssertEqual(ex("local.dynject.workbench"), .workbench)
        XCTAssertEqual(ex("com.apple.loginwindow"), .protectedSystem)
        XCTAssertTrue(RespringExclusions.isDeveloperTool("dev.warp.Warp-Stable"))
        XCTAssertTrue(RespringExclusions.isDeveloperTool("com.todesktop.230313mzl4w4u92"))
        XCTAssertFalse(RespringExclusions.isDeveloperTool("com.apple.Notes"))
    }

    func testSelection() {
        let host = RespringExclusions(hostPIDs: [106])
        // Everything pending (missing MenuLoader) except TextEdit, which is up to date.
        let apps = [calculator, notes, finder, code, ghostty, workbench, loginwindow, textEdit]
        var loaded = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, Set<String>()) })
        loaded[111] = [menu]
        loaded[101] = [menu, badge]
        loaded[102] = [menu]
        let p = planner(apps, loaded: loaded, exclusions: host).plan()
        XCTAssertEqual(Set(p.pending.map(\.app.bundleID)),
                       ["com.apple.finder", "com.microsoft.VSCode", "com.mitchellh.ghostty", "local.dynject.workbench", "com.apple.loginwindow"])
        // Calculator and Notes are fine, so nothing is selected by default; the rest are excluded.
        let d = p.selection(RespringOptions())
        XCTAssertEqual(d.apps, [])
        XCTAssertEqual(Set(d.skipped.map(\.candidate.app.bundleID)), Set(p.pending.map(\.app.bundleID)))

        // --all: every app, Finder included, still without hosts, tools, Workbench and loginwindow.
        let all = p.selection(RespringOptions(all: true))
        XCTAssertEqual(all.apps.map(\.app.name), ["Calculator", "Finder", "Notes", "TextEdit"])

        // Explicit includes bring in excluded and up-to-date apps; Workbench and the host go last.
        let inc = p.selection(RespringOptions(include: ["com.microsoft.VSCode", "local.dynject.workbench", "com.mitchellh.ghostty",
                                                        "com.apple.TextEdit", "com.apple.loginwindow", "com.example.gone"]))
        XCTAssertEqual(inc.apps.map(\.app.name), ["Ghostty", "TextEdit", "Dynject Workbench", "Visual Studio Code"])
        XCTAssertEqual(inc.notRunning, ["com.example.gone"])
        XCTAssertTrue(inc.skipped.contains { $0.candidate.app.bundleID == "com.apple.loginwindow" })

        // --exclude beats everything.
        let exc = p.selection(RespringOptions(all: true, include: ["com.apple.Notes"], exclude: ["com.apple.Notes", "com.apple.finder"]))
        XCTAssertEqual(exc.apps.map(\.app.name), ["Calculator", "TextEdit"])
        XCTAssertEqual(exc.skipped.filter { $0.why == "excluded with --exclude" }.count, 2)
    }

    func testOnlyConsidersJustTheNamedApps() {
        let host = RespringExclusions(hostPIDs: [106])
        let apps = [calculator, notes, code, finder]
        let p = planner(apps, loaded: [101: [], 102: [menu], 106: [], 105: []], exclusions: host).plan()
        let s = p.selection(RespringOptions(only: ["com.apple.Notes", "com.apple.finder", "com.example.gone"]))
        // Calculator is pending but not named; Notes is up to date but named; Finder is named, so selected.
        XCTAssertEqual(s.apps.map(\.app.name), ["Finder", "Notes"])
        XCTAssertEqual(s.skipped, [])
        XCTAssertEqual(s.notRunning, ["com.example.gone"])
        XCTAssertEqual(p.selection(RespringOptions(only: [])).apps, [])
    }

    func testAnAppAnotherAppStartedIsLeftOut() {
        // ChatGPT starts ChatGPT Computer Use itself, so it inherits ChatGPT's DYLD_INSERT_LIBRARIES: dw saw an
        // "unwanted" tweak a relaunch of its own can't remove, and quitting ChatGPT took it down mid-run.
        let chatgpt = app("ChatGPT", "com.openai.codex", pid: 201, dir: "/Applications")
        let cua = app("ChatGPT Computer Use", "com.openai.sky.CUAService", pid: 202, dir: "/Users/someone/.codex/computer-use")
        let viaHelper = app("Sidecar", "com.example.sidecar", pid: 203, dir: "/Applications")
        let fromLaunchd = app("Plain", "com.example.plain", pid: 204, dir: "/Applications")
        var p = planner([chatgpt, cua, viaHelper, fromLaunchd],
                        loaded: [201: [menu], 202: [menu, old], 203: [menu, old], 204: [menu, old]])
        // 203's parent is a helper process inside ChatGPT (not itself a running app).
        p.ancestry = FakeAncestry(parents: [201: 1, 202: 201, 203: 300, 300: 201, 204: 1], paths: [:])
        let plan = p.plan()
        let c = plan.candidate(bundleID: "com.openai.sky.CUAService")!
        XCTAssertEqual(c.exclusion, .launchedByApp)
        XCTAssertEqual(c.launchedBy, "ChatGPT")
        XCTAssertTrue(c.isPending, "still reported: it does have the tweak")
        XCTAssertFalse(c.selectedByDefault)
        XCTAssertEqual(plan.candidate(bundleID: "com.example.sidecar")?.launchedBy, "ChatGPT")
        XCTAssertNil(plan.candidate(bundleID: "com.example.plain")?.exclusion)
        XCTAssertNil(plan.candidate(bundleID: "com.openai.codex")?.exclusion)

        let sel = plan.selection(RespringOptions())
        XCTAssertEqual(sel.apps.map(\.app.bundleID), ["com.example.plain"])
        let why = sel.skipped.first { $0.candidate.app.bundleID == "com.openai.sky.CUAService" }?.why
        XCTAssertEqual(why, "started by ChatGPT: it inherits its tweaks and comes back when ChatGPT is relaunched")
        // --all doesn't bring it in; naming it does.
        XCTAssertFalse(plan.selection(RespringOptions(all: true)).apps.contains { $0.app.pid == 202 })
        XCTAssertTrue(plan.selection(RespringOptions(include: ["com.openai.sky.CUAService"])).apps.contains { $0.app.pid == 202 })
        XCTAssertEqual(Doctor.respringFix(c), "relaunch ChatGPT; it comes back with it")

        // Without a process tree (tests, fixture mode) nothing is marked.
        p.ancestry = nil
        XCTAssertNil(p.plan().candidate(bundleID: "com.openai.sky.CUAService")?.exclusion)
    }

    func testAllCoversInjectionBlockedButDefaultDoesNot() {
        let p = planner([maps], loaded: [103: []], since: at(20)).plan()
        XCTAssertEqual(p.selection(RespringOptions()).apps, [])
        XCTAssertEqual(p.selection(RespringOptions(all: true)).apps.map(\.app.name), ["Maps"])
    }
}

final class RespringerTests: XCTestCase {
    private func candidate(_ a: RunningApp, expected: [String] = [menu], loaded: Set<String>? = [],
                           exclusion: RespringExclusion? = nil, hosts: Bool = false) -> RespringCandidate {
        let reasons = expected.filter { !(loaded ?? []).contains($0) }.map { RespringReason(.missing, dylib: $0, tweak: ($0 as NSString).lastPathComponent) }
        return RespringCandidate(app: a, service: "application.\(a.bundleID).0.0", expected: expected, loaded: loaded,
                                 reasons: reasons, exclusion: exclusion, hostsCaller: hosts)
    }

    private func engine(_ c: SimulatedAppController, environment: [String: String]? = nil) -> (Respringer, RespringClock) {
        let clock = RespringClock.manual(start: at(0))
        return (Respringer(controller: c, clock: clock, settings: .init(environment: environment)), clock)
    }

    func testRelaunchesQuietlyAndVerifies() {
        let hiddenNotes = app("Notes", "com.apple.Notes", pid: 102, hidden: true)
        let c = SimulatedAppController(apps: [calculator, hiddenNotes])
        c.loadedAfterOpen = ["com.apple.calculator": [menu], "com.apple.Notes": [menu]]
        var phases: [String] = []
        let results = engine(c, environment: ["DYLD_INSERT_LIBRARIES": "/x.dylib"]).0.run([candidate(hiddenNotes), candidate(calculator)]) { p in
            switch p.phase {
            case .quitting: phases.append("\(p.index):quit")
            case .waitingToQuit: phases.append("\(p.index):wait")
            case .opening: phases.append("\(p.index):open")
            case .waitingForLaunchd: phases.append("\(p.index):launchd")
            case .verifying: phases.append("\(p.index):verify")
            case .forceQuitting: phases.append("\(p.index):force")
            case .reopeningAfterExit: phases.append("\(p.index):again")
            case .finished: phases.append("\(p.index):done")
            }
        }
        XCTAssertEqual(results.map(\.candidate.app.name), ["Calculator", "Notes"])
        XCTAssertTrue(results.allSatisfy(\.succeeded))
        XCTAssertEqual(results.map(\.outcome), [.relaunched, .relaunched])
        XCTAssertEqual(results.map(\.newPID), [90_000, 90_001])
        XCTAssertEqual(results[0].summary(), "relaunched (pid 90000), verified")
        XCTAssertEqual(phases, ["0:quit", "0:open", "0:verify", "0:done", "1:quit", "1:open", "1:verify", "1:done"])
        let env = ["DYLD_INSERT_LIBRARIES": "/x.dylib"]
        XCTAssertEqual(c.calls, [
            .terminate(101, .terminate),
            .open("/System/Applications/Calculator.app", RespringOpenOptions(activates: false, hides: false, environment: env)),
            .terminate(102, .terminate),
            .open("/System/Applications/Notes.app", RespringOpenOptions(activates: false, hides: true, environment: env)),
        ])
    }

    func testTimeoutSkipsAndMovesOn() {
        let c = SimulatedAppController(apps: [calculator, notes])
        c.refusesToQuit = ["com.apple.calculator"]
        c.loadedAfterOpen = ["com.apple.Notes": [menu]]
        let (e, clock) = engine(c)
        let results = e.run([candidate(calculator), candidate(notes)])
        XCTAssertEqual(results[0].outcome, .didNotQuit(timeout: 15))
        XCTAssertNil(results[0].newPID)
        XCTAssertEqual(results[0].summary(), "skipped: still running after 15 s (unsaved changes or a dialog?)")
        XCTAssertFalse(results[0].succeeded)
        XCTAssertTrue(results[1].succeeded)
        // Waited the full 15 s, never opened the stuck app.
        XCTAssertGreaterThanOrEqual(clock.now().timeIntervalSince(at(0)), 15)
        XCTAssertFalse(c.calls.contains { if case let .open(path, _) = $0 { return path.contains("Calculator") } else { return false } })
        XCTAssertTrue(c.isRunning(pid: 101))
    }

    func testForceQuitAfterTheTimeout() {
        let c = SimulatedAppController(apps: [calculator])
        c.refusesToQuit = ["com.apple.calculator"]
        c.loadedAfterOpen = ["com.apple.calculator": [menu]]
        let clock = RespringClock.manual(start: at(0))
        var phases: [String] = []
        let r = Respringer(controller: c, clock: clock, settings: .init(quitTimeout: 3, forceQuit: true))
            .run([candidate(calculator)]) { if case .forceQuitting = $0.phase { phases.append("force") } }
        XCTAssertEqual(r[0].outcome, .relaunched)
        XCTAssertTrue(r[0].forced)
        XCTAssertTrue(r[0].succeeded)
        XCTAssertEqual(phases, ["force"])
        XCTAssertEqual(Array(c.calls.prefix(2)), [.terminate(101, .terminate), .terminate(101, .forceTerminate)])
        XCTAssertTrue(r[0].summary().hasPrefix("force-quit after the timeout; relaunched (pid 90000)"), r[0].summary())

        // Without --force the same app is skipped, and never force-quit.
        let c2 = SimulatedAppController(apps: [calculator])
        c2.refusesToQuit = ["com.apple.calculator"]
        let r2 = Respringer(controller: c2, clock: .manual(start: at(0)), settings: .init(quitTimeout: 3)).run([candidate(calculator)])
        XCTAssertEqual(r2[0].outcome, .didNotQuit(timeout: 3))
        XCTAssertFalse(c2.calls.contains(.terminate(101, .forceTerminate)))
    }

    func testAnAppThatQuitsRightAfterItsReopenIsOpenedOnceMore() {
        // ChatGPT, 2026-11-24: reopened, verified with its tweaks, gone a few seconds later.
        let c = SimulatedAppController(apps: [calculator, notes])
        c.loadedAfterOpen = ["com.apple.calculator": [menu], "com.apple.Notes": [menu]]
        c.exitsAfterOpen = ["com.apple.calculator": 1]
        var phases: [String] = []
        let r = engine(c).0.run([candidate(calculator), candidate(notes)]) { p in
            if case .reopeningAfterExit = p.phase { phases.append("\(p.candidate.app.name):again") }
        }
        XCTAssertEqual(phases, ["Calculator:again"])
        XCTAssertEqual(r[0].outcome, .relaunched)
        XCTAssertTrue(r[0].reopenedAgain)
        XCTAssertEqual(r[0].newPID, 90_002)
        XCTAssertTrue(r[0].succeeded)
        XCTAssertTrue(r[0].summary().hasPrefix("quit again right after reopening, opened once more; relaunched (pid 90002)"))
        XCTAssertFalse(r[1].reopenedAgain)
        XCTAssertTrue(c.isRunning(pid: 90_002))

        // Quits again after the second open too: reported, not retried a third time.
        let c2 = SimulatedAppController(apps: [calculator])
        c2.loadedAfterOpen = ["com.apple.calculator": [menu]]
        c2.exitsAfterOpen = ["com.apple.calculator": 2]
        let r2 = engine(c2).0.run([candidate(calculator)])
        XCTAssertEqual(r2[0].outcome, .exitedAfterOpen)
        XCTAssertFalse(r2[0].succeeded)
        XCTAssertEqual(c2.calls.filter { if case .open = $0 { return true } else { return false } }.count, 2)

        // Started again by something else meanwhile: that copy is checked, nothing is opened.
        let c3 = SimulatedAppController(apps: [calculator])
        c3.loadedAfterOpen = ["com.apple.calculator": [menu]]
        c3.exitsAfterOpen = ["com.apple.calculator": 1]
        let clock = RespringClock.manual(start: at(0))
        let e3 = Respringer(controller: c3, clock: clock, settings: .init())
        c3.running.insert(777)
        c3.pidsByBundleID["com.apple.calculator", default: []].append(777)
        let r3 = e3.run([candidate(calculator)])
        XCTAssertEqual(r3[0].outcome, .relaunched)
        XCTAssertEqual(r3[0].newPID, 777)
        XCTAssertFalse(r3[0].reopenedAgain)
    }

    func testCustomTimeout() {
        let c = SimulatedAppController(apps: [calculator])
        c.refusesToQuit = ["com.apple.calculator"]
        let clock = RespringClock.manual(start: at(0))
        let r = Respringer(controller: c, clock: clock, settings: .init(quitTimeout: 3)).run([candidate(calculator)])
        XCTAssertEqual(r[0].outcome, .didNotQuit(timeout: 3))
        XCTAssertLessThan(clock.now().timeIntervalSince(at(0)), 4)
    }

    func testVerificationFailures() {
        let c = SimulatedAppController(apps: [calculator, notes, textEdit])
        c.loadedAfterOpen = ["com.apple.calculator": [], "com.apple.Notes": [menu, brut], "com.apple.TextEdit": nil]
        let (e, clock) = engine(c)
        let r = e.run([candidate(calculator), candidate(notes), candidate(textEdit, loaded: [brut])])
        XCTAssertEqual(r[0].verification, RespringVerification(missing: [menu], unexpected: [], inspected: true))
        XCTAssertEqual(r[0].summary(labels: [menu: "local.dynject.menuloader"]),
                       "relaunched (pid 90000) but still missing local.dynject.menuloader")
        XCTAssertFalse(r[0].succeeded)
        // brut wasn't loaded before, but the engine looks for every configured tweak it is told about.
        XCTAssertEqual(r[1].verification?.unexpected, [])
        XCTAssertEqual(r[2].verification?.inspected, false)
        XCTAssertEqual(r[2].summary(), "relaunched (pid 90002); couldn't inspect the new process")
        // Each failed check polled for the verify timeout (5 s).
        XCTAssertGreaterThanOrEqual(clock.now().timeIntervalSince(at(0)), 10)

        let c2 = SimulatedAppController(apps: [notes])
        c2.loadedAfterOpen = ["com.apple.Notes": [menu, brut]]
        let clock2 = RespringClock.manual(start: at(0))
        let r2 = Respringer(controller: c2, clock: clock2, settings: .init(tweakDylibs: [brut])).run([candidate(notes)])
        XCTAssertEqual(r2[0].verification?.unexpected, [brut])
        XCTAssertEqual(r2[0].summary(), "relaunched (pid 90000) but still has libBrutalium.dylib")
    }

    func testOrderingPutsWorkbenchThenTheHostLast() {
        let wb = candidate(workbench, exclusion: .workbench)
        let host = candidate(code, exclusion: .hostsThisProcess, hosts: true)
        let ordered = Respringer.ordered([host, wb, candidate(notes), candidate(calculator)])
        XCTAssertEqual(ordered.map(\.app.name), ["Calculator", "Notes", "Dynject Workbench", "Visual Studio Code"])

        let c = SimulatedAppController(apps: [workbench, code, notes, calculator])
        let results = engine(c).0.run([host, wb, candidate(notes), candidate(calculator)])
        XCTAssertEqual(results.map(\.candidate.app.name), ["Calculator", "Notes", "Dynject Workbench", "Visual Studio Code"])
        XCTAssertEqual(c.calls.compactMap { call -> Int32? in if case let .terminate(pid, _) = call { return pid } else { return nil } }, [101, 102, 108, 106])
        // The host is handed to a detached reopener, scheduled before it is asked to quit.
        XCTAssertEqual(results.last?.outcome, .handedOff)
        XCTAssertEqual(Array(c.calls.suffix(2)), [.scheduleReopen("/Applications/Visual Studio Code.app", 106), .terminate(106, .terminate)])
    }

    func testDryRunTouchesNothing() {
        let c = SimulatedAppController(apps: [calculator, code])
        let r = engine(c).0.run([candidate(code, hosts: true), candidate(calculator)], dryRun: true)
        XCTAssertEqual(r.map(\.outcome), [.wouldRelaunch, .wouldHandOff])
        XCTAssertTrue(r.allSatisfy(\.succeeded))
        XCTAssertEqual(c.calls, [])
    }

    func testFinderQuitsByAppleEventAndAdoptsLaunchdsRestart() {
        let c = SimulatedAppController(apps: [finder])
        c.loadedAfterOpen = ["com.apple.finder": [brut]]
        c.onQuit = { $0.bundleID == "com.apple.finder" ? 4242 : nil }
        let r = engine(c).0.run([candidate(finder, expected: [brut])])
        XCTAssertEqual(r[0].outcome, .relaunched)
        XCTAssertEqual(r[0].newPID, 4242)
        XCTAssertTrue(r[0].succeeded)
        XCTAssertEqual(c.calls, [.terminate(105, .appleEventQuit)])
    }

    func testOtherOutcomes() {
        let c = SimulatedAppController(apps: [calculator, notes, textEdit])
        c.running.remove(101)
        c.quitRequestFails = ["com.apple.Notes"]
        c.openFails = ["com.apple.TextEdit"]
        let r = engine(c).0.run([candidate(calculator), candidate(notes), candidate(textEdit)])
        XCTAssertEqual(r[0].outcome, .notRunning)
        XCTAssertEqual(r[1].outcome, .quitRefused)
        XCTAssertEqual(r[2].outcome, .openFailed("simulated failure (tried twice)"))
        XCTAssertEqual(c.calls.filter { if case .open = $0 { return true } else { return false } }.count, 2, "one retry, not more")
        XCTAssertFalse(r.contains(where: \.succeeded))

        // A reopen that fails once (LaunchServices while the old process goes away) works on the second try.
        let once = SimulatedAppController(apps: [textEdit])
        once.openFailsOnce = ["com.apple.TextEdit"]
        once.loadedAfterOpen = ["com.apple.TextEdit": [menu]]
        let r1 = engine(once).0.run([candidate(textEdit)])
        XCTAssertEqual(r1[0].outcome, .relaunched)
        XCTAssertTrue(r1[0].openRetried)
        XCTAssertTrue(r1[0].succeeded)
        XCTAssertTrue(r1[0].summary().hasPrefix("the first reopen failed, the second worked; relaunched"), r1[0].summary())

        let c2 = SimulatedAppController(apps: [calculator, notes])
        var n = 0
        let r2 = engine(c2).0.run([candidate(calculator), candidate(notes)], isCancelled: { defer { n += 1 }; return n > 0 })
        XCTAssertEqual(r2.map(\.outcome), [.relaunched, .cancelled])
        XCTAssertFalse(c2.calls.contains(.terminate(102, .terminate)))
    }

    func testSimulatedControllerFromPlanVerifies() {
        let p = planner([calculator, notes], loaded: [101: [menu, badge], 102: []]).plan()
        let c = SimulatedAppController(plan: p)
        let r = engine(c).0.run(p.defaultSelection)
        XCTAssertEqual(r.map(\.candidate.app.name), ["Notes"])
        XCTAssertTrue(r[0].succeeded)
    }
}

final class RespringSystemTests: XCTestCase {
    /// Read-only: this test process's own parent chain.
    func testSystemAncestryReadsThisProcess() {
        let a = SystemProcessAncestry()
        XCTAssertEqual(a.parentPID(of: getpid()), getppid())
        XCTAssertNotNil(a.executablePath(of: getpid()))
        let host = RespringExclusions.forCurrentProcess()
        XCTAssertTrue(host.hostPIDs.contains(getpid()))
        XCTAssertTrue(host.hostPIDs.contains(getppid()))
    }

    /// A copy that keeps the source's dates (copyItem, `cp -p`, a Finder drag) still counts as changed now: found by
    /// the end-to-end test, where a replaced dylib wasn't reported as updated.
    func testFileDateSeesACopyThatKeepsTheOldModificationDate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("respring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a.dylib").path
        let dst = dir.appendingPathComponent("b.dylib").path
        FileManager.default.createFile(atPath: src, contents: Data("x".utf8))
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old, .creationDate: old], ofItemAtPath: src)
        let before = Date().addingTimeInterval(-1)
        try FileManager.default.copyItem(atPath: src, toPath: dst)
        let mtime = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: dst)[.modificationDate] as? Date)
        XCTAssertLessThan(mtime, before) // copyItem kept the old date…
        XCTAssertGreaterThan(try XCTUnwrap(RespringPlanner.fileModificationDate(dst)), before) // …ctime didn't
        XCTAssertNil(RespringPlanner.fileModificationDate(dir.appendingPathComponent("none").path))
    }
}

final class RespringRunningAppsTests: XCTestCase {
    func listed(_ path: String, regular: Bool = false, accessory: Bool = true, background: Bool = false) -> Bool {
        WorkspaceRunningApps.isListed(regular: regular, accessory: accessory, bundlePath: path, includeBackground: background)
    }

    func testMenuBarAppsOfTheirOwnAreListed() {
        XCTAssertTrue(listed("/Applications/TokenTracker.app"), "a third-party menu bar app")
        XCTAssertTrue(listed("/Users/me/Applications/Clerestory.app/"), "trailing slash")
        XCTAssertTrue(listed("/Applications/Safari.app", regular: true, accessory: false))
        XCTAssertTrue(listed("/System/Applications/Notes.app", regular: true, accessory: false), "Dock apps from /System too")
    }

    func testMacOSAndHelperAppsAreLeftToDwWhy() {
        XCTAssertFalse(listed("/System/Library/CoreServices/ControlCenter.app"), "launchd starts it")
        XCTAssertFalse(listed("/System/Library/CoreServices/MenuBarAgent.app"))
        XCTAssertFalse(listed("/Applications/Big.app/Contents/Library/LoginItems/Big Helper.app"), "its owner starts it")
        XCTAssertFalse(listed("/Applications/Big.app/Big Agent.app"))
        XCTAssertFalse(listed("/Applications/Daemonish.app", regular: false, accessory: false), "no UI at all (.prohibited)")
        XCTAssertTrue(listed("/System/Library/CoreServices/ControlCenter.app", background: true))
        XCTAssertTrue(listed("/Applications/Big.app/Contents/Library/LoginItems/Big Helper.app", background: true))
        XCTAssertFalse(listed("/Applications/Daemonish.app", regular: false, accessory: false, background: true))
    }
}

/// `dw respring --system`: macOS's UI agents, quit with SIGTERM and started again by launchd.
final class RespringSystemAgentTests: XCTestCase {
    private let menuBar = RunningApp(pid: 120, bundleID: "com.apple.MenuBarAgent", name: "MenuBarAgent",
                                     bundlePath: "/System/Library/CoreServices/MenuBarAgent.app",
                                     executablePath: "/System/Library/CoreServices/MenuBarAgent.app/Contents/MacOS/MenuBarAgent",
                                     launchDate: at(0), isSystemAgent: true)

    func testOnlyWithSystemOrNamed() {
        // The test config gives a launchd service nothing, so a MenuLoader it has loaded is unwanted: pending.
        let p = planner([menuBar, calculator], loaded: [120: [menu], 101: []], since: at(20)).plan()
        XCTAssertTrue(p.candidates.first { $0.app.pid == 120 }!.isPending, "pending like any app")
        XCTAssertEqual(p.selection(RespringOptions()).apps.map(\.app.name), ["Calculator"], "not without --system")
        XCTAssertEqual(p.selection(RespringOptions(all: true)).apps.map(\.app.name), ["Calculator"], "--all alone doesn't bring them in")
        XCTAssertEqual(Set(p.selection(RespringOptions(system: true)).apps.map(\.app.name)), ["Calculator", "MenuBarAgent"])
        let named = p.selection(RespringOptions(only: ["com.apple.menubaragent"]))
        XCTAssertEqual(named.apps.map(\.app.name), ["MenuBarAgent"], "named in any case")
        XCTAssertEqual(named.notRunning, [])
        XCTAssertTrue(RespringOptions(only: ["com.apple.Dock"]).listsSystemAgents)
        XCTAssertTrue(RespringOptions(system: true).listsSystemAgents)
        XCTAssertFalse(RespringOptions(include: ["com.apple.Notes"]).listsSystemAgents)
    }

    private func candidate(_ a: RunningApp) -> RespringCandidate {
        RespringCandidate(app: a, service: "com.apple.MenuBarAgent", expected: [menu], loaded: [],
                          reasons: [RespringReason(.missing, dylib: menu, tweak: "libMenuLoader.dylib")], exclusion: nil, hostsCaller: false)
    }

    func testQuitBySignalAndLaunchdsNewProcessIsVerified() {
        let c = SimulatedAppController(apps: [menuBar])
        c.loadedAfterOpen = ["com.apple.MenuBarAgent": [menu]]
        c.onQuit = { $0.bundleID == "com.apple.MenuBarAgent" ? 5151 : nil }
        let r = Respringer(controller: c, clock: .manual(start: at(0))).run([candidate(menuBar)])
        XCTAssertEqual(r[0].outcome, .relaunched)
        XCTAssertEqual(r[0].newPID, 5151)
        XCTAssertTrue(r[0].succeeded)
        XCTAssertEqual(c.calls, [.terminate(120, .signal)], "never opened: launchd starts it")
    }

    func testLaunchdNotStartingItAgainIsReportedNotOpened() {
        let c = SimulatedAppController(apps: [menuBar])
        let clock = RespringClock.manual(start: at(0))
        let r = Respringer(controller: c, clock: clock).run([candidate(menuBar)])
        guard case let .openFailed(message) = r[0].outcome else { return XCTFail("\(r[0].outcome)") }
        XCTAssertTrue(message.contains("launchd didn't start it again within 10 s") && message.contains("/com.apple.MenuBarAgent"), message)
        XCTAssertEqual(c.calls, [.terminate(120, .signal)], "no second copy outside launchd")
        XCTAssertGreaterThanOrEqual(clock.now().timeIntervalSince(at(0)), 10)
    }
}
