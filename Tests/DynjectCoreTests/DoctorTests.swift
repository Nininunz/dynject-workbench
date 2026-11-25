@testable import DynjectCore
import Foundation
import XCTest

/// `dw doctor` against a made-up setup in a temporary folder: engine files, config, manifests, agents with
/// simulated launchctl, an in-memory Apple-menu key and Safe Mode. Nothing real is read except the clock.
final class DoctorTests: XCTestCase {
    var root: URL!
    var now: Date!

    override func setUpWithError() throws {
        root = try temporaryDirectory()
        now = Date()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    static let customSIP = """
    System Integrity Protection status: unknown (Custom Configuration).

    Configuration:
    \tApple Internal: disabled
    \tKext Signing: enabled
    \tFilesystem Protections: disabled
    \tDebugging Restrictions: disabled
    \tDTrace Restrictions: enabled
    \tNVRAM Protections: enabled

    This is an unsupported configuration, likely to break in the future and leave your machine in an unknown state.
    """

    /// A manifest file in root/Tweaks for a dylib in /opt/dynject/lib/tweaks (bytes in root/lib/tweaks).
    func writeManifest(_ id: String, dylib: String, extra: [String: Any] = [:]) throws {
        var d: [String: Any] = ["formatVersion": 1, "identifier": id, "name": id, "dylib": "/opt/dynject/lib/tweaks/\(dylib)",
                                "sections": [["items": [["type": "switch", "key": "enabled", "default": true]]]]]
        for (k, v) in extra { d[k] = v }
        try manifestData(d).write(to: root.appendingPathComponent("Tweaks/\(id).workbench.plist"))
    }

    func file(_ path: String, _ data: Data = Data(), executable: Bool = false) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    func runningAgent(_ label: String, pid: Int32) -> RecordingLaunchctlRunner {
        RecordingLaunchctlRunner(respond: { args in
            args.first == "print" ? (0, "gui/501/\(label) = {\n\tstate = running\n\tpid = \(pid)\n}\n") : (0, "")
        })
    }

    struct Setup {
        var context: DoctorContext
        var menuStore: MemoryTweakBackend
        var safeModeKeys: MemoryTweakBackend
    }

    /// A healthy setup: one daemon, a clean config with one installed DynjectHook tweak, agents running the app's
    /// dw, the Apple-menu list published, nothing in Safe Mode.
    func healthy() throws -> Setup {
        try file("engine/bin/dynjectd", Data("d".utf8), executable: true)
        try file("engine/bin/dynject_loader", Data("l".utf8), executable: true)
        try file("LaunchDaemons/com.dynject.dynjectd.plist", Data("p".utf8))
        try file("engine/etc/dynjectd.conf", Data("dylib:/opt/dynject/lib/tweaks/libGood.dylib:deny\ndylib-override:/opt/dynject/lib/tweaks/libGood.dylib:allow:com.apple.TextEdit\nallow:TextEdit\n".utf8))
        try file("engine/log/dynjectd.log", Data("[dynjectd 01:00:00] dynjectd: starting\n".utf8))
        // A DynjectHook build (both Safe Mode markers) as a universal, signed Mach-O.
        var dylib = FakeMachO.universal
        dylib.append(SafeModeSupportChecker.marker)
        dylib.append(SafeModeSupportChecker.panicMarker)
        dylib.append(Data("\u{0}\(SDKVersionChecker.markerPrefix)\(WorkbenchInfo.version)\u{0}".utf8))
        try file("lib/tweaks/libGood.dylib", dylib)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tweaks"), withIntermediateDirectories: true)
        try writeManifest("com.example.good", dylib: "libGood.dylib")

        // The app, and both agents' copies of its dw.
        let app = root.appendingPathComponent("Apps/Dynject Workbench.app").path
        try file("Apps/Dynject Workbench.app/Contents/MacOS/dw", Data("dw build 1".utf8), executable: true)
        try file("Apps/Dynject Workbench.app/Contents/Info.plist",
                 try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": WorkbenchInfo.version],
                                                    format: .xml, options: 0))
        let agents = root.appendingPathComponent("LaunchAgents"), bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let watcher = SafeModeAgent(launchAgentsDirectory: agents, binDirectory: bin, runner: runningAgent(SafeModeAgent.label, pid: 11))
        let bridge = BridgeAgent(launchAgentsDirectory: agents, binDirectory: bin, runner: runningAgent(BridgeAgent.label, pid: 12))
        for a in [watcher, bridge] as [UserLaunchAgent] {
            try file("bin/\(a.binaryName)", Data("dw build 1".utf8), executable: true)
            try a.plistData().write(to: a.plistURL)
        }

        let locations = TweakLocations(configPath: root.appendingPathComponent("engine/etc/dynjectd.conf").path,
                                       dylibFileDirectory: root.appendingPathComponent("lib/tweaks").path,
                                       manifestsDirectory: root.appendingPathComponent("Tweaks").path)
        let configModified = now.addingTimeInterval(-600)
        let daemon = DaemonStatus(processes: [DaemonProcess(pid: 42, parentPID: 1, started: now.addingTimeInterval(-300),
                                                            startedText: "", command: "/opt/dynject/bin/dynjectd")],
                                  job: nil, configModified: configModified)
        let menuStore = MemoryTweakBackend()
        let keys = MemoryTweakBackend()
        var c = DoctorContext(
            locations: locations, daemonStatus: { daemon }, sipStatus: { Self.customSIP }, codeSignatureProblem: { _ in nil },
            safeModeAgent: watcher, bridgeAgent: bridge,
            bridgeToken: { "abc123;01;00000000;00000000;00000000;000000000000001a;com.apple.app-sandbox.mach;local.dynject.bridge" },
            menuStore: menuStore, menuSettings: { MenuLoaderSettings() },
            safeMode: SafeMode(keys: SafeModeKeyStore(store: keys, names: .production),
                               stateStore: SafeModeStateStore(directory: root.appendingPathComponent("SafeMode"))),
            respringPlan: { [now] _, _, _ in RespringPlan(date: now!, candidates: []) },
            workbenchApps: [app], thisDw: nil)
        c.now = now
        c.engineRoot = root.appendingPathComponent("engine").path
        c.launchDaemonPlist = root.appendingPathComponent("LaunchDaemons/com.dynject.dynjectd.plist").path
        // Publish what Workbench would, so the Apple-menu check passes.
        let manifests = TweakManifestLoader.load(directories: locations.manifestSearchDirectories).manifests
        try MenuLoaderPublisher(store: menuStore, names: .production).publish(manifests, settings: MenuLoaderSettings())
        return Setup(context: c, menuStore: menuStore, safeModeKeys: keys)
    }

    func statuses(_ r: DoctorReport, _ section: String) -> [DoctorStatus] {
        r.checks.filter { $0.section == section }.map(\.status)
    }

    func testHealthySetupHasNoWarningsOrProblems() throws {
        let r = Doctor.run(try healthy().context)
        XCTAssertEqual(r.checks.filter { $0.status != .ok }, [], r.text())
        XCTAssertEqual(r.exitCode, 0)
        var sections: [String] = []
        for c in r.checks where !sections.contains(c.section) { sections.append(c.section) }
        XCTAssertEqual(sections, ["engine", "config", "tweaks", "agents", "apple menu", "apps", "safe mode", "workbench"])
        XCTAssertTrue(r.text().contains("✓ dynjectd running (pid 42"), r.text())
        XCTAssertTrue(r.text().hasSuffix("all good"))
        XCTAssertEqual(r.text(quiet: true, header: "h"), "", "quiet with nothing to report prints nothing")
    }

    func testInlineHooksFromTheLog() throws {
        var c = try healthy().context
        let id = TweakManifestLoader.load(directories: c.locations.manifestSearchDirectories).manifests[0].id
        var since: Date?
        let line = "2026-11-24 04:47:00.591 Df "
        c.inlineHookLog = { date in
            since = date
            return [
                "Timestamp               Ty Process[PID:TID]",
                line + "Calculator[16250:a071fb] [\(id):hook] DHHookFunction libsystem_m.dylib`cbrt+0: hooking",
                line + "Calculator[16250:a071fb] [\(id):hook] DHHookFunction host`f+0: hooking (on top of another hook)",
                line + "ControlCenter[9:1] [\(id):hook] DHHookFunction libfoo.dylib`bar+0: hooking",
                line + "Finder[7:1] [\(id):hook] DHHookFunction AppKit`baz+0: not hooked: this process may not run code it made ((os/kern) protection failure)",
                line + "Finder[7:1] [\(id):hook] DHHookFunction AppKit`qux+0: not hooked: instruction 2 of its first four returns or branches away, so it is too short",
                line + "Finder[8:1] [\(id):hook] DHHookFunction AppKit`qux+0: not hooked: instruction 2 of its first four returns or branches away, so it is too short",
                line + "System Settings[5:2] [\(id):hook] DHHookFunction a`b+0: hooking",
                line + "host-arm64[3:1] [dynject.hook:hook] DHHookFunction host`f_short+0: not hooked: instruction 2 of its first four returns",
            ].joined(separator: "\n")
        }
        let r = Doctor.run(c)
        XCTAssertEqual(since, c.now.addingTimeInterval(-c.crashWindow))
        let section = r.checks.filter { $0.section == "inline hooks" }
        XCTAssertEqual(section.first { $0.check == "can patch code" }?.status, .problem)
        XCTAssertTrue(section.first { $0.check == "can patch code" }?.detail.contains("Finder (1)") == true, "\(section)")
        XCTAssertEqual(section.first { $0.check == "hooked" }?.detail, "4 function hook(s) in the last 24 h: Calculator (2), ControlCenter (1), System Settings (1)")
        XCTAssertEqual(section.filter { $0.check == "refused" }.count, 1, "the same refusal once; not the test host's (not an installed tweak)")
        XCTAssertTrue(section.first { $0.check == "refused" }?.detail.hasPrefix("\(id) in Finder: DHHookFunction AppKit`qux+0: not hooked") == true,
                      "\(section)")

        c.inlineHookLog = { _ in "" }
        XCTAssertEqual(Doctor.run(c).checks.filter { $0.section == "inline hooks" }.map(\.detail),
                       ["no installed tweak used DHHookFunction in the last 24 h"])
        c.inlineHookLog = nil
        XCTAssertTrue(Doctor.run(c).checks.filter { $0.section == "inline hooks" }.isEmpty, "skipped without a log reader")
    }

    func testBrokenEngineIsAProblemWithFixes() throws {
        var s = try healthy()
        s.context.daemonStatus = { DaemonStatus(processes: [], job: nil, configModified: nil) }
        s.context.sipStatus = { "System Integrity Protection status: enabled.\n" }
        try FileManager.default.removeItem(at: root.appendingPathComponent("engine/bin/dynject_loader"))
        let r = Doctor.run(s.context)
        XCTAssertEqual(r.exitCode, 1)
        let problems = r.checks.filter { $0.status == .problem }
        XCTAssertEqual(Set(problems.map(\.check)), ["engine binaries", "dynjectd running", "sip"])
        let running = try XCTUnwrap(problems.first { $0.check == "dynjectd running" })
        XCTAssertTrue(running.fix?.contains("com.apple.MobileFileIntegrity") == true, "the amfid cause is in the fix")
        XCTAssertTrue(problems.first { $0.check == "sip" }?.fix?.contains("--without fs --without debug") == true)
        let text = r.text()
        XCTAssertTrue(text.contains("  ✗ dynjectd isn't running"), text)
        XCTAssertTrue(text.contains("      → workbench -> daemon -> restart dynject"), text)
        XCTAssertTrue(text.hasSuffix("3 problems, 0 warnings"), text)
    }

    func testDuplicateAndStaleDaemonsAreWarnings() throws {
        var s = try healthy()
        let p = DaemonProcess(pid: 1, parentPID: 1, started: now.addingTimeInterval(-3600), startedText: "", command: "dynjectd")
        s.context.daemonStatus = { DaemonStatus(processes: [p, p], job: nil, configModified: nil) }
        XCTAssertEqual(Doctor.run(s.context).checks.first { $0.check == "dynjectd running" }?.status, .warning)
        s.context.daemonStatus = { [now] in DaemonStatus(processes: [p], job: nil, configModified: now!.addingTimeInterval(-60)) }
        let stale = try XCTUnwrap(Doctor.run(s.context).checks.first { $0.check == "dynjectd running" })
        XCTAssertEqual(stale.status, .warning)
        XCTAssertTrue(stale.detail.contains("before the config was written"))
    }

    func testRecentLogErrorsAreWarnedAboutOldOnesAreNot() throws {
        let s = try healthy()
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let log = root.appendingPathComponent("engine/log/dynjectd.log")
        try Data("[dynject_loader \(f.string(from: now.addingTimeInterval(-120)))] dynject_loader: ERROR amfid not found\n[dynjectd \(f.string(from: now.addingTimeInterval(-60)))] dynjectd: starting\n".utf8).write(to: log)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: log.path)
        let w = try XCTUnwrap(Doctor.run(s.context).checks.first { $0.check == "log errors" })
        XCTAssertEqual(w.status, .warning)
        XCTAssertTrue(w.detail.contains("amfid not found"))
        XCTAssertTrue(w.fix?.contains("MobileFileIntegrity") == true)
        // The same lines two hours ago are history.
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: log.path)
        XCTAssertEqual(Doctor.run(s.context).checks.first { $0.check == "log errors" }?.status, .ok)
    }

    func testApprovalCheckFollowsTheRunningDaemon() throws {
        let s = try healthy()
        let good = "/opt/dynject/lib/tweaks/libGood.dylib"
        let digest = try XCTUnwrap(DylibDigest.sha256Hex(ofFileAt: root.appendingPathComponent("lib/tweaks/libGood.dylib").path))
        let conf = root.appendingPathComponent("engine/etc/dynjectd.conf"), log = root.appendingPathComponent("engine/log/dynjectd.log")
        let base = "dylib:\(good):deny\ndylib-override:\(good):allow:com.apple.TextEdit\nallow:TextEdit\n"
        func approval() throws -> DoctorCheck {
            try XCTUnwrap(Doctor.run(s.context).checks.first { $0.section == "config" && $0.check == "approval" })
        }
        func daemon(_ mode: String?) throws {
            let line = mode.map { "[dynjectd 01:00:00] dynjectd: approval: \($0); 0 of 1 dylib(s) have a dylib-sha256 line\n" } ?? ""
            try Data("[dynjectd 01:00:00] dynjectd: starting\n\(line)".utf8).write(to: log)
        }

        // Stock dynjectd (no approval line in its log): reported, not a warning.
        var c = try approval()
        XCTAssertEqual(c.status, .ok)
        XCTAssertTrue(c.detail.contains("libGood.dylib: no dylib-sha256 approval (the running dynjectd doesn't check"), c.detail)
        try daemon("audit")
        c = try approval()
        XCTAssertEqual(c.status, .warning)
        XCTAssertEqual(c.fix, "dw tweak approve --all")
        try daemon("enforce")
        c = try approval()
        XCTAssertEqual(c.status, .problem)
        XCTAssertTrue(c.detail.contains("dynjectd skips them (enforce)"), c.detail)

        try Data((base + "dylib-sha256:\(good):\(digest)\n").utf8).write(to: conf)
        c = try approval()
        XCTAssertEqual(c.status, .ok)
        XCTAssertEqual(c.detail, "1 dylib(s) approved; dynjectd checks them (enforce)")

        // The file changed after it was approved.
        try Data((base + "dylib-sha256:\(good):\(String(repeating: "0", count: 64))\n").utf8).write(to: conf)
        c = try approval()
        XCTAssertEqual(c.status, .problem)
        XCTAssertTrue(c.detail.contains("the file isn't the approved build"), c.detail)
        try daemon("audit")
        XCTAssertEqual(try approval().status, .warning)
    }

    func testConfigTweakAndMenuFindings() throws {
        var s = try healthy()
        // A second declared dylib that doesn't exist and has no manifest, a validator error, a manifest for an
        // undeclared dylib, a bad signature, and a stale Apple-menu list.
        try Data("dylib:/opt/dynject/lib/tweaks/libGood.dylib:deny\ndylib-override:/opt/dynject/lib/tweaks/libGone.dylib:allow:x\ndylib:/opt/dynject/lib/tweaks/libGone.dylib:deny\n".utf8)
            .write(to: root.appendingPathComponent("engine/etc/dynjectd.conf"))
        try writeManifest("com.example.lonely", dylib: "libLonely.dylib",
                          extra: ["appleMenu": [["id": "a", "title": "A", "action": "notify:x"]]])
        s.context.codeSignatureProblem = { $0.hasSuffix("libGood.dylib") ? "invalid signature (code or signature have been modified)" : nil }
        let r = Doctor.run(s.context)
        let config = r.checks.filter { $0.section == "config" }
        XCTAssertTrue(config.contains { $0.status == .problem && $0.detail.contains("line 2: Override appears before its dylib line") })
        XCTAssertTrue(config.contains { $0.status == .problem && $0.detail.contains("libGone.dylib: missing") })
        XCTAssertTrue(config.contains { $0.status == .problem && $0.detail.contains("code signature invalid") })
        XCTAssertTrue(config.contains { $0.status == .warning && $0.detail.contains("libGone.dylib has no manifest") })
        XCTAssertTrue(config.contains { $0.status == .warning && $0.detail.contains("doesn't declare /opt/dynject/lib/tweaks/libLonely.dylib") })
        XCTAssertTrue(r.checks.contains { $0.section == "tweaks" && $0.status == .problem && $0.detail.contains("com.example.lonely") })
        let menu = try XCTUnwrap(r.checks.first { $0.section == "apple menu" })
        XCTAssertEqual(menu.status, .warning)
        XCTAssertEqual(menu.fix, "dw menu publish (or reload in workbench)")
        XCTAssertEqual(s.menuStore.writes, 1, "only the setup published; doctor never writes")
        XCTAssertEqual(s.menuStore.notifications, ["dynject.menuloader.changed"])
    }

    func testTweakThatIgnoresSafeModeIsAWarning() throws {
        let s = try healthy()
        try file("lib/tweaks/libGood.dylib", FakeMachO.universal)   // no DynjectHook markers
        let w = try XCTUnwrap(Doctor.run(s.context).checks.first { $0.check == "safe mode support" })
        XCTAssertEqual(w.status, .warning)
        XCTAssertTrue(w.detail.contains("not built on DynjectHook"))
    }

    /// One line per crash: the tweak it happened in apart from those only loaded; a deleted report isn't offered.
    func testCrashesAreOneLineEachWithTheCulpritNamed() throws {
        let s = try healthy()
        try file("Reports/App-1.ips", Data("{}".utf8))
        let kept = root.appendingPathComponent("Reports/App-1.ips").path
        let gone = root.appendingPathComponent("Reports/App-0.ips").path
        func crash(_ id: String, _ path: String, inTweak: Bool, ago: TimeInterval, culprits: [String]) -> SafeModeCrash {
            SafeModeCrash(tweakID: id, bundleID: "com.example.app", appName: "App", date: now.addingTimeInterval(-ago),
                          reportPath: path, inTweak: inTweak, frameSummary: "EXC_BREAKPOINT (SIGTRAP) in libBad.dylib: Boom",
                          incidentID: path, culpritIDs: culprits)
        }
        try SafeModeStateStore(directory: root.appendingPathComponent("SafeMode")).update { state in
            state.recentCrashes = [crash("com.example.quiet", gone, inTweak: false, ago: 600, culprits: []),
                                   crash("com.example.bad", kept, inTweak: true, ago: 60, culprits: ["com.example.bad"]),
                                   crash("com.example.good", kept, inTweak: false, ago: 60, culprits: ["com.example.bad"]),
                                   crash("com.example.other", kept, inTweak: false, ago: 60, culprits: ["com.example.bad"])]
        }
        let lines = Doctor.run(s.context).checks.filter { $0.check == "crash" }
        let text = DoctorReport(checks: lines).text()
        XCTAssertEqual(lines.count, 2, text)
        XCTAssertTrue(lines[0].detail.contains("App crashed in com.example.bad (also loaded: com.example.good, com.example.other): EXC_BREAKPOINT"), text)
        XCTAssertFalse(lines[0].detail.contains("crashed with"), text)
        XCTAssertEqual(lines[0].fix, "read the report: \(kept)")
        XCTAssertTrue(lines[1].detail.contains("App crashed with com.example.quiet loaded"), text)
        XCTAssertTrue(lines[1].fix?.contains("deleted") == true, text)
    }

    /// minimumSystemVersion and depends are problems; an untested macOS, a non-semantic version and an old SDK
    /// build are warnings. A pre-panic-switch DynjectHook build gets the Safe Mode warning, not a second SDK one.
    func testCompatibilityFindings() throws {
        var s = try healthy()
        s.context.systemVersion = try XCTUnwrap(SystemVersion("27.2"))
        var old = FakeMachO.universal
        old.append(SafeModeSupportChecker.marker)
        old.append(SafeModeSupportChecker.panicMarker)
        old.append(Data("\u{0}\(SDKVersionChecker.markerPrefix)0.0.1\u{0}".utf8))
        try file("lib/tweaks/libGood.dylib", old)
        try writeManifest("com.example.good", dylib: "libGood.dylib",
                          extra: ["version": "1.0", "testedSystemVersions": "27.0 - 27.1", "depends": ["com.example.gone >= 2.0.0"]])
        var perTweak = FakeMachO.universal
        perTweak.append(SafeModeSupportChecker.marker)
        try file("lib/tweaks/libNew.dylib", perTweak)
        try writeManifest("com.example.new", dylib: "libNew.dylib", extra: ["minimumSystemVersion": "99.0"])

        let checks = Doctor.run(s.context).checks.filter { $0.section == "tweaks" }
        func find(_ check: String, _ id: String) -> [DoctorCheck] { checks.filter { $0.check == check && $0.detail.contains("(\(id))") } }
        let text = DoctorReport(checks: checks).text()
        XCTAssertEqual(find("macos", "com.example.new").map(\.status), [.problem], text)
        XCTAssertTrue(find("macos", "com.example.new")[0].detail.contains("needs macOS 99.0 or later; this Mac runs 27.2"), text)
        XCTAssertEqual(find("macos", "com.example.good").map(\.status), [.warning], text)
        XCTAssertEqual(find("version", "com.example.good").map(\.status), [.warning], text)
        XCTAssertTrue(find("version", "com.example.good")[0].fix?.contains("\"1.0.0\"") == true, text)
        XCTAssertFalse(checks.contains { $0.check == "manifest" && $0.detail.contains("semantic version") }, "listed once: \(text)")
        XCTAssertEqual(find("depends", "com.example.good").map(\.status), [.problem], text)
        XCTAssertEqual(find("sdk", "com.example.good").map(\.status), [.warning], text)
        XCTAssertTrue(find("sdk", "com.example.good")[0].detail.contains("built with DynjectHook 0.0.1"), text)
        XCTAssertEqual(find("sdk", "com.example.new"), [], "the Safe Mode warning already says it: \(text)")
        XCTAssertEqual(find("safe mode support", "com.example.new").map(\.status), [.warning], text)
    }

    /// An agent whose copied dw isn't the app's is stale; one that matches is fine; missing agents and tokens.
    func testAgentsStaleBinaryAndToken() throws {
        var s = try healthy()
        try file("bin/dw", Data("dw build 0".utf8), executable: true)
        var r = Doctor.run(s.context)
        let stale = r.checks.filter { $0.section == "agents" && $0.detail.contains("stale") }
        XCTAssertEqual(stale.count, 1, r.text())
        XCTAssertTrue(stale[0].detail.hasPrefix("safe mode watcher"))
        XCTAssertEqual(stale[0].fix, Doctor.watcherHint)

        s.context.bridgeToken = { "abc;01;com.apple.app-sandbox.mach;local.other" }
        r = Doctor.run(s.context)
        XCTAssertEqual(r.checks.first { $0.check == "bridge token" }?.status, .problem)
        s.context.bridgeToken = { nil }
        XCTAssertEqual(Doctor.run(s.context).checks.first { $0.check == "bridge token" }?.status, .problem)

        // Not installed: the watcher is wanted, the broker only when a tweak declares bridge capabilities.
        try FileManager.default.removeItem(at: root.appendingPathComponent("LaunchAgents"))
        r = Doctor.run(s.context)
        XCTAssertEqual(r.checks.first { $0.check == "safe mode watcher" }?.status, .warning)
        XCTAssertEqual(r.checks.first { $0.check == "bridge broker" }?.status, .ok)
        XCTAssertNil(r.checks.first { $0.check == "bridge token" }, "no token check without a running broker")
    }

    func testAgentBinaryComparison() throws {
        try file("a", Data("one".utf8))
        try file("b", Data("one".utf8))
        try file("c", Data("two".utf8))
        func p(_ n: String) -> String { root.appendingPathComponent(n).path }
        XCTAssertEqual(AgentBinaryCheck.compare(installed: p("a"), reference: p("b")), .same)
        XCTAssertEqual(AgentBinaryCheck.compare(installed: p("a"), reference: p("c")), .differs)
        XCTAssertEqual(AgentBinaryCheck.compare(installed: p("a"), reference: p("missing")), .unknown)
    }

    func testAppsSafeModeAndWorkbenchFindings() throws {
        var s = try healthy()
        let app = RunningApp(pid: 7, bundleID: "com.apple.TextEdit", name: "TextEdit", bundlePath: "/System/Applications/TextEdit.app",
                             executablePath: "/x", launchDate: now)
        let finder = RunningApp(pid: 8, bundleID: "com.apple.finder", name: "Finder", bundlePath: "/System/Library/CoreServices/Finder.app",
                                executablePath: "/y", launchDate: now)
        let reason = RespringReason(.missing, dylib: "/opt/dynject/lib/tweaks/libGood.dylib", tweak: "com.example.good")
        let plan = RespringPlan(date: now, candidates: [
            RespringCandidate(app: app, service: "s", expected: [], loaded: [], reasons: [reason], exclusion: nil),
            RespringCandidate(app: finder, service: "f", expected: [], loaded: [], reasons: [reason], exclusion: .finder),
        ])
        s.context.respringPlan = { _, _, _ in plan }
        try s.context.safeMode.disable(tweakID: "com.example.good", bundleID: "com.apple.TextEdit", now: now)
        try s.context.safeMode.setPanic(true, now: now)
        try file("Apps/Dynject Workbench.app/Contents/Info.plist",
                 try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "9.9.9"], format: .xml, options: 0))
        let r = Doctor.run(s.context)
        let apps = r.checks.filter { $0.section == "apps" }
        XCTAssertEqual(apps.map(\.fix), ["dw respring", "dw respring --include com.apple.finder"])
        XCTAssertTrue(apps[1].detail.contains("Finder is relaunched only with --all"))
        let safe = r.checks.filter { $0.section == "safe mode" }
        XCTAssertEqual(safe.map(\.fix), ["dw safemode panic off", "dw safemode enable com.example.good com.apple.TextEdit"])
        let wb = try XCTUnwrap(r.checks.first { $0.section == "workbench" })
        XCTAssertEqual(wb.status, .warning)
        XCTAssertTrue(wb.detail.contains("is 9.9.9, this dw is \(WorkbenchInfo.version)"))
        XCTAssertEqual(r.exitCode, 0, "warnings only")
    }

    func testJSONShape() throws {
        var s = try healthy()
        s.context.sipStatus = { "System Integrity Protection status: enabled.\n" }
        let r = Doctor.run(s.context)
        let array = try XCTUnwrap(try JSONSerialization.jsonObject(with: r.json()) as? [[String: Any]])
        XCTAssertEqual(array.count, r.checks.count)
        for o in array {
            XCTAssertEqual(Set(o.keys), ["section", "check", "status", "detail", "fix"])
            XCTAssertTrue(["ok", "warning", "problem"].contains(o["status"] as? String))
            if o["status"] as? String == "ok" { XCTAssertTrue(o["fix"] is NSNull) }
        }
        let sip = try XCTUnwrap(array.first { $0["check"] as? String == "sip" })
        XCTAssertEqual(sip["status"] as? String, "problem")
        XCTAssertEqual(sip["section"] as? String, "engine")
        XCTAssertTrue((sip["fix"] as? String)?.contains("csrutil") == true)
    }

    func testReportTextAndExitCode() {
        let r = DoctorReport(checks: [
            .init(section: "a", check: "x", status: .ok, detail: "fine"),
            .init(section: "b", check: "y", status: .warning, detail: "meh", fix: "do this"),
            .init(section: "a", check: "z", status: .ok, detail: "also fine", fix: "never shown"),
        ])
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.text(header: "H"), "H\n\na\n  ✓ fine\n  ✓ also fine\n\nb\n  ! meh\n      → do this\n\n0 problems, 1 warning")
        XCTAssertEqual(r.text(quiet: true), "b\n  ! meh\n      → do this\n\n0 problems, 1 warning")
        XCTAssertEqual(DoctorReport(checks: [.init(section: "a", check: "x", status: .problem, detail: "bad")]).exitCode, 1)
    }

    // MARK: helpers

    func testSIPParsing() {
        let custom = SIPStatus.parse(Self.customSIP)
        XCTAssertEqual(custom.state, .custom)
        XCTAssertEqual(custom.blockingEngine, [])
        XCTAssertEqual(custom.alsoOff, ["Apple Internal"])
        XCTAssertEqual(SIPStatus.parse("System Integrity Protection status: enabled.").blockingEngine,
                       [SIPStatus.filesystem, SIPStatus.debugging])
        XCTAssertEqual(SIPStatus.parse("System Integrity Protection status: disabled.").state, .disabled)
        XCTAssertEqual(SIPStatus.parse("System Integrity Protection status: disabled.").blockingEngine, [])
        let fsOnly = SIPStatus.parse(Self.customSIP.replacingOccurrences(of: "Debugging Restrictions: disabled", with: "Debugging Restrictions: enabled"))
        XCTAssertEqual(fsOnly.blockingEngine, [SIPStatus.debugging])
        XCTAssertEqual(SIPStatus.parse("").state, .unknown)
    }

    func testLogClockWalksBackAcrossMidnight() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let modified = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 0, minute: 10)))
        let text = """
        [dynject_loader 23:00:00] dynject_loader: ERROR amfid not found
        [dynjectd 23:50:00] dynjectd: starting
        garbage without a stamp
        [dynjectd 00:05:00] dynjectd: ERROR something
        [dynjectd 00:10:00] dynjectd: x MATCH (1 dylib(s) injected)
        """
        let all = DynjectLogClock.lines(in: text, modified: modified, since: .distantPast, calendar: cal)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all[0].date, cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 23)))
        XCTAssertEqual(all[3].date, modified)
        let recent = DynjectLogClock.errors(in: text, modified: modified, since: modified.addingTimeInterval(-30 * 60), calendar: cal)
        XCTAssertEqual(recent.map(\.line), ["[dynjectd 00:05:00] dynjectd: ERROR something"])
    }

    func testBridgeTokenCheck() {
        let ok = "1f2e;01;00000000;00000000;00000000;000000000000001a;com.apple.app-sandbox.mach;local.dynject.bridge"
        XCTAssertNil(BridgeTokenCheck.problem(token: ok, service: "local.dynject.bridge"))
        XCTAssertEqual(BridgeTokenCheck.problem(token: ok, service: "local.other"), "the token opens local.dynject.bridge, not local.other")
        XCTAssertNotNil(BridgeTokenCheck.problem(token: "garbage", service: "local.dynject.bridge"))
        XCTAssertNotNil(BridgeTokenCheck.problem(token: "a;b;com.apple.app-sandbox.read;local.dynject.bridge", service: "local.dynject.bridge"))
    }

    func testCodeSignatureCheckOnRealFiles() throws {
        XCTAssertNil(CodeSignatureCheck.problem(path: "/bin/ls"))
        try file("unsigned", Data("not code".utf8))
        XCTAssertNotNil(CodeSignatureCheck.problem(path: root.appendingPathComponent("unsigned").path))
    }

    // MARK: apis

    func testAPICanaryJudgesEachTweak() throws {
        func manifest(_ id: String, _ extra: [String: Any]) throws -> TweakManifest {
            var d: [String: Any] = ["formatVersion": 1, "identifier": id, "name": id, "dylib": "/x/\(id).dylib", "sections": []]
            for (k, v) in extra { d[k] = v }
            return try XCTUnwrap(TweakManifestParser.parse(data: manifestData(d), path: "/\(id)", fileExists: { _ in true }).0)
        }
        let good = try manifest("good", ["requires": [["class": "NSObject", "image": "Foundation", "methods": ["-description", "+new"]]]])
        let bad = try manifest("bad", ["requires": [["class": "DWNoSuchClass", "image": "Foundation"],
                                                    ["symbol": "strlen", "image": "libSystem.B"]]])
        let optional = try manifest("opt", ["requires": [["symbol": "dw_no_such_function", "image": "libSystem.B", "optional": true]]])
        let none = try manifest("none", [:])
        let nothing = try manifest("nothing", ["requires": [Any]()])
        let bridged = try manifest("bridged", ["bridge": ["notify"]])
        let r = Doctor.apis(manifests: [good, bad, optional, none, nothing, bridged], bridgeInUse: true, system: "macOS 99.0 (Z1)")
        func check(_ id: String) -> DoctorCheck? { r.checks.first { $0.check == "\(id) (\(id))" } }
        XCTAssertEqual(r.checks.first?.detail, "macOS 99.0 (Z1)")
        XCTAssertEqual(check("good")?.status, .ok)
        XCTAssertEqual(check("bad")?.status, .problem)
        XCTAssertEqual(check("bad")?.detail, "bad (bad): missing class DWNoSuchClass: this tweak will probably misbehave on this macOS")
        XCTAssertEqual(check("opt")?.status, .warning)
        XCTAssertEqual(check("none")?.status, .warning)
        XCTAssertEqual(check("nothing")?.detail, "nothing (nothing): needs nothing private")
        XCTAssertEqual(check("bridged")?.status, .ok, "the bridge client's SPI is checked implicitly")
        XCTAssertTrue(check("bridged")?.detail.contains("sandbox_extension_consume") == true)
        XCTAssertEqual(r.checks.last?.check, "workbench bridge broker")
        XCTAssertEqual(r.checks.last?.status, .ok)
        XCTAssertEqual(r.exitCode, 1)
    }
}
