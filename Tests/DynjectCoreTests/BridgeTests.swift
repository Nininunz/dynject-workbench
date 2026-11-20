import DynjectCore
import Foundation
import XCTest

/// DynjectBridge: manifest `bridge` key, authorization, each action's argument checks, rate limiting, the decision
/// log, the agent plist. Everything runs on fakes: identities, an in-memory config, parsed manifests, recorded
/// effects. Nothing reaches XPC, launchd or the global preferences.
enum BridgeFixtures {
    static let dylib = "/opt/dynject/lib/tweaks/libGlass.dylib"
    static let otherDylib = "/opt/dynject/lib/tweaks/libOther.dylib"
    static let tweakID = "com.example.glass"

    static func manifest(id: String = tweakID, dylib: String = dylib, bridge: Any? = ["settings.set", "notify", "open:https", "pasteboard.write"],
                         extra: [String: Any] = [:]) -> (TweakManifest?, [ManifestIssue]) {
        var root: [String: Any] = [
            "formatVersion": 1, "identifier": id, "dylib": dylib,
            "sections": [["items": [
                ["type": "switch", "key": "enabled", "default": true, "perApp": true],
                ["type": "slider", "key": "radius", "min": 0, "max": 20, "default": 8],
                ["type": "number", "key": "count", "min": 1, "max": 10, "integer": true, "default": 3],
                ["type": "color", "key": "tint", "default": "#112233"],
                ["type": "text", "key": "label", "default": ""],
                ["type": "number", "key": "big", "integer": true],
                ["type": "number", "key": "real"],
                ["type": "appList", "key": "apps"],
            ]]],
        ]
        if let bridge { root["bridge"] = bridge }
        for (k, v) in extra { root[k] = v }
        let data = try! PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        return TweakManifestParser.parse(data: data, path: "/fixture/\(id).workbench.plist", fileExists: { _ in true })
    }

    static let glass = manifest().0!
    static let quiet = manifest(id: "com.example.quiet", dylib: "/opt/dynject/lib/tweaks/libQuiet.dylib", bridge: nil).0!
    static let other = manifest(id: "com.example.other", dylib: otherDylib).0!
    static let reserved = manifest(id: "local.dynject.menuloader.extra").0!

    /// Glass goes into Notes and Pages (team-signed, /Applications); Other is declared but goes nowhere.
    static let configText = """
        dylib:\(dylib):deny
        dylib-override:\(dylib):allow:com.apple.Notes
        dylib-override:\(dylib):allow:com.example.pages
        dylib-override:\(dylib):allow:local.test.host
        dylib-override:\(dylib):allow:com.example.store
        dylib-override:\(dylib):allow:com.apple.Finder
        dylib:\(otherDylib):deny
        allow:TestHost
        dylib:/opt/dynject/lib/tweaks/libQuiet.dylib:allow
        """
    static var config: EffectiveConfig { EffectiveConfig(document: ConfigDocument(text: configText)) }

    static func identity(_ bundleID: String = "com.apple.Notes", exe: String? = nil, apple: Bool = true, team: String? = nil,
                         appStore: Bool = false, adHoc: Bool = false, valid: Bool = true) -> BridgeCallerIdentity {
        let name = bundleID.split(separator: ".").last.map(String.init) ?? "App"
        let path = exe ?? (apple ? "/System/Applications/\(name).app/Contents/MacOS/\(name)" : "/Applications/\(name).app/Contents/MacOS/\(name)")
        let bundle = (path as NSString).deletingLastPathComponent.replacingOccurrences(of: "/Contents/MacOS", with: "")
        return BridgeCallerIdentity(pid: 4242, signingIdentifier: bundleID, taskSigningIdentifier: bundleID, teamID: team,
                                    executablePath: path, signatureValid: valid, appleAnchored: apple, developerID: team != nil,
                                    appStore: appStore, adHoc: adHoc, sandboxed: true, bundleIdentifier: bundleID,
                                    bundleExecutablePath: path, bundlePath: bundle)
    }

    static let notes = identity()
    static let textEdit = identity("com.apple.TextEdit")
    static let pages = identity("com.example.pages", apple: false, team: "ABCDE12345")
    static let finder = identity("com.apple.finder", exe: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")

    /// What AppDiscovery would find in the app folders.
    static let installed: [InstalledApp] = [
        app("com.apple.Notes", "/System/Applications/Notes.app", "Notes"),
        app("com.apple.TextEdit", "/System/Applications/TextEdit.app", "TextEdit"),
        app("com.example.pages", "/Applications/pages.app", "pages"),
        app("com.example.store", "/Applications/store.app", "store"),
        app("local.test.host", "/tmp/t/TestHost.app", "TestHost"),
        app("com.apple.finder", "/System/Library/CoreServices/Finder.app", "Finder"),
        app("com.evil.com.apple.Notes", "/Applications/Notes.app", "Notes"),
    ]

    static func app(_ id: String, _ bundle: String, _ exe: String) -> InstalledApp {
        InstalledApp(displayName: exe, bundleID: id, executableName: exe, executablePath: "\(bundle)/Contents/MacOS/\(exe)", bundlePath: bundle)
    }

    static func sources(manifests: [TweakManifest] = [glass, quiet, other, reserved], config: EffectiveConfig? = BridgeFixtures.config,
                        missing: Set<String> = [], installed: [InstalledApp] = BridgeFixtures.installed) -> BridgePolicySources {
        BridgePolicySources(manifests: { manifests }, config: { config }, fileExists: { !missing.contains($0) },
                            installedApps: { id in installed.filter { $0.bundleID == id } })
    }

    static func grant(_ m: TweakManifest = glass, _ id: BridgeCallerIdentity = notes) -> BridgeGrant {
        try! BridgeAuthorizer.authorize(tweak: m.id, identity: id, sources: sources(), allowAdHoc: false).get()
    }
}

/// A clock tests move by hand.
final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

final class BridgeManifestTests: XCTestCase {
    func testParsesCapabilities() {
        let (m, issues) = BridgeFixtures.manifest()
        XCTAssertEqual(m?.bridge, [.settingsSet, .notify, .open(scheme: "https"), .pasteboardWrite])
        XCTAssertEqual(issues, [])
        XCTAssertEqual(m?.bridge.map(\.rawValue), ["settings.set", "notify", "open:https", "pasteboard.write"])
        XCTAssertEqual(BridgeFixtures.quiet.bridge, [])
    }

    func testRejectsBadEntriesKeepsTheRest() {
        let (m, issues) = BridgeFixtures.manifest(bridge: ["notify", "run.command", "open:file", "open:javascript", "open:x-apple.systempreferences",
                                                           "open:HTTPS", "open:", 42, "notify", "open:dynject-workbench", "open:spotify"])
        XCTAssertEqual(m?.bridge, [.notify, .open(scheme: "spotify")])
        let errors = issues.filter { $0.severity == .error }.map(\.message)
        XCTAssertEqual(errors.count, 8, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("\"open:dynject-workbench\"") }, "Workbench's own links are never opened (L5)")
        XCTAssertTrue(issues.contains { $0.severity == .warning && $0.message.contains("\"open:spotify\"") && $0.message.contains("may act on them") })
        XCTAssertTrue(errors.contains { $0.contains("\"run.command\" is not a capability") })
        XCTAssertTrue(errors.contains { $0.contains("\"open:file\"") && $0.contains("lowercase URL scheme") })
        XCTAssertTrue(errors.contains { $0.contains("bridge[7] is not a string") })
        XCTAssertTrue(issues.contains { $0.severity == .warning && $0.message.contains("listed twice") })
    }

    func testNotAnArray() {
        let (m, issues) = BridgeFixtures.manifest(bridge: "notify")
        XCTAssertEqual(m?.bridge, [])
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.contains("bridge must be an array") })
    }

    func testSettingsSetWithoutSettingsWarnsAndBridgeOnlyManifestIsUsable() {
        let root: [String: Any] = ["formatVersion": 1, "identifier": "com.example.b", "dylib": "/opt/x.dylib", "sections": [],
                                   "bridge": ["notify", "settings.set"]]
        let data = try! PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        let (m, issues) = TweakManifestParser.parse(data: data, path: "/f", fileExists: { _ in true })
        XCTAssertEqual(m?.bridge, [.notify, .settingsSet])
        XCTAssertEqual(issues.map(\.message), ["bridge declares settings.set, but the manifest has no settings to set."])
    }

    func testOpenableSchemes() {
        for ok in ["https", "http", "mailto", "spotify", "a+b.c-d"] {
            XCTAssertTrue(BridgeCapability.isOpenableScheme(ok), ok)
        }
        // L5: action-taking handlers too, and Workbench's own scheme.
        for bad in ["file", "javascript", "vbscript", "data", "blob", "about", "applescript", "help", "x-man-page", "smb", "afp",
                    "ssh", "x-apple.systempreferences", "x-apple-helpbasic", "Https", "1http", "", "ht tp",
                    "shortcuts", "vscode", "vscode-insiders", "cursor", "ms-word", "ms-excel", "ms-powerpoint", "ms-settings",
                    "facetime", "facetime-audio", "tel", "sms", "webcal", "zoommtg", "zoomus", "terminal", "x-github-client",
                    "github-mac", "itms-services", "dynject-workbench"] {
            XCTAssertFalse(BridgeCapability.isOpenableScheme(bad), bad)
            XCTAssertNil(BridgeCapability("open:" + bad), bad)
        }
        XCTAssertFalse(BridgeCapability.open(scheme: "https").isHighRisk)
        XCTAssertFalse(BridgeCapability.open(scheme: "mailto").isHighRisk)
        XCTAssertTrue(BridgeCapability.open(scheme: "spotify").isHighRisk)
        XCTAssertFalse(BridgeCapability.notify.isHighRisk)
    }
}

final class BridgeAuthorizationTests: XCTestCase {
    typealias F = BridgeFixtures

    func code(_ tweak: String, _ id: BridgeCallerIdentity, sources: BridgePolicySources = F.sources(), adHoc: Bool = false) -> BridgeErrorCode? {
        switch BridgeAuthorizer.authorize(tweak: tweak, identity: id, sources: sources, allowAdHoc: adHoc) {
        case .success: return nil
        case let .failure(d): return d.code
        }
    }

    func testTable() {
        var noID = F.notes; noID.signingIdentifier = nil
        var emptyID = F.notes; emptyID.signingIdentifier = ""
        var taskDiffers = F.notes; taskDiffers.taskSigningIdentifier = "com.apple.TextEdit"
        var taskMissing = F.notes; taskMissing.taskSigningIdentifier = nil
        var bundleDiffers = F.notes; bundleDiffers.bundleIdentifier = "com.apple.TextEdit"
        var exeDiffers = F.notes; exeDiffers.bundleExecutablePath = "/System/Applications/Notes.app/Contents/MacOS/Other"
        var noBundle = F.notes; noBundle.bundleIdentifier = nil; noBundle.bundleExecutablePath = nil
        var teamless = F.pages; teamless.developerID = false
        var teamClaimNoAnchor = F.pages; teamClaimNoAnchor.developerID = false; teamClaimNoAnchor.teamID = "ABCDE12345"
        var teamAnchorNoID = F.pages; teamAnchorNoID.teamID = nil
        let adHocHost = F.identity("local.test.host", exe: "/tmp/t/TestHost.app/Contents/MacOS/TestHost", apple: false, adHoc: true)
        let adHocNotes = F.identity("com.apple.Notes", apple: false, adHoc: true)

        let cases: [(String, String, BridgeCallerIdentity, Bool, BridgeErrorCode?)] = [
            ("apple app, tweak injected", F.tweakID, F.notes, false, nil),
            ("team-signed app, tweak injected", F.tweakID, F.pages, false, nil),
            ("no signing identifier", F.tweakID, noID, false, .unidentifiedCaller),
            ("empty signing identifier", F.tweakID, emptyID, false, .unidentifiedCaller),
            ("kernel disagrees", F.tweakID, taskDiffers, false, .identityMismatch),
            ("kernel has none", F.tweakID, taskMissing, false, .identityMismatch),
            ("invalid signature", F.tweakID, F.identity(valid: false), false, .untrustedCaller),
            ("invalid signature, test mode", F.tweakID, F.identity(valid: false), true, .untrustedCaller),
            ("ad hoc", F.tweakID, adHocHost, false, .untrustedCaller),
            ("ad hoc, test mode", F.tweakID, adHocHost, true, nil),
            ("ad hoc claiming an apple id, test mode", F.tweakID, adHocNotes, true, .untrustedCaller),
            ("ad hoc claiming an apple id", F.tweakID, adHocNotes, false, .untrustedCaller),
            ("neither apple nor team", F.tweakID, teamless, false, .untrustedCaller),
            ("team claimed but not anchored", F.tweakID, teamClaimNoAnchor, false, .untrustedCaller),
            ("anchored without team id", F.tweakID, teamAnchorNoID, false, .untrustedCaller),
            ("bundle id differs", F.tweakID, bundleDiffers, false, .identityMismatch),
            ("not the bundle's executable", F.tweakID, exeDiffers, false, .identityMismatch),
            ("not in a bundle", F.tweakID, noBundle, false, .identityMismatch),
            ("unknown tweak", "com.example.nope", F.notes, false, .unknownTweak),
            ("tweak not injected into this app", F.tweakID, F.textEdit, false, .notInjected),
            ("other tweak, declared nowhere", "com.example.other", F.notes, false, .notInjected),
            ("tweak allowed everywhere", "com.example.quiet", F.textEdit, false, nil),
        ]
        for (name, tweak, id, adHoc, expected) in cases {
            XCTAssertEqual(code(tweak, id, adHoc: adHoc), expected, name)
        }
    }

    func testLiveStateDecides() {
        XCTAssertEqual(code(F.tweakID, F.notes, sources: F.sources(config: nil)), .configUnavailable)
        XCTAssertEqual(code(F.tweakID, F.notes, sources: F.sources(missing: [F.dylib])), .notInjected, "dylib file missing")
        XCTAssertEqual(code(F.tweakID, F.notes, sources: F.sources(manifests: [F.quiet])), .unknownTweak, "manifest removed")
        let off = EffectiveConfig(document: ConfigDocument(text: "dylib:\(F.dylib):deny\n"))
        XCTAssertEqual(code(F.tweakID, F.notes, sources: F.sources(config: off)), .notInjected, "switched off in the config")
        let denied = EffectiveConfig(document: ConfigDocument(text: F.configText + "\ndeny:Notes\n"))
        XCTAssertEqual(code(F.tweakID, F.notes, sources: F.sources(config: denied)), .notInjected, "process gate")
    }

    func testRequestShape() {
        func parse(_ o: Any?) -> BridgeErrorCode? {
            switch BridgeRequest.parse(o) { case .success: return nil; case let .failure(d): return d.code }
        }
        XCTAssertNil(parse(["v": 1, "tweak": "a.b", "action": "ping"]))
        XCTAssertNil(parse(["v": 1, "tweak": "a.b", "action": "ping", "args": [:] as [String: Any]]))
        XCTAssertEqual(parse(nil), .badRequest)
        XCTAssertEqual(parse(["x"]), .badRequest)
        XCTAssertEqual(parse(["tweak": "a.b", "action": "ping"]), .badRequest)
        XCTAssertEqual(parse(["v": 2, "tweak": "a.b", "action": "ping"]), .unsupportedVersion)
        XCTAssertEqual(parse(["v": 1, "tweak": "../x", "action": "ping"]), .badRequest)
        XCTAssertEqual(parse(["v": 1, "tweak": "", "action": "ping"]), .badRequest)
        XCTAssertEqual(parse(["v": 1, "tweak": "a.b", "action": ""]), .badRequest)
        XCTAssertEqual(parse(["v": 1, "tweak": "a.b", "action": String(repeating: "a", count: 65)]), .badRequest)
        XCTAssertEqual(parse(["v": 1, "tweak": "a.b", "action": "ping", "args": ["x"]]), .badRequest)
    }
}

final class BridgeActionTests: XCTestCase {
    typealias F = BridgeFixtures

    func validate(_ action: BridgeAction, _ args: [String: Any], grant: BridgeGrant = F.grant()) -> Result<BridgeActions.Plan, BridgeDenial> {
        BridgeActions.validate(action, args: args, grant: grant)
    }

    func code(_ action: BridgeAction, _ args: [String: Any], grant: BridgeGrant = F.grant()) -> BridgeErrorCode? {
        switch validate(action, args, grant: grant) { case .success: return nil; case let .failure(d): return d.code }
    }

    func testCapabilityRequired() {
        let quiet = F.grant(F.quiet, F.textEdit)
        XCTAssertNil(code(.ping, [:], grant: quiet))
        XCTAssertEqual(code(.settingsSet, ["key": "enabled", "value": false], grant: quiet), .capabilityMissing)
        XCTAssertEqual(code(.notify, ["name": "com.example.quiet.x"], grant: quiet), .capabilityMissing)
        XCTAssertEqual(code(.open, ["url": "https://example.com"], grant: quiet), .capabilityMissing)
        XCTAssertEqual(code(.pasteboardWrite, ["string": "x"], grant: quiet), .capabilityMissing)
    }

    func testSettingsArguments() {
        XCTAssertNil(code(.settingsSet, ["key": "enabled", "value": false]))
        XCTAssertNil(code(.settingsSet, ["key": "radius", "value": 12.5]))
        XCTAssertNil(code(.settingsSet, ["key": "count", "value": 10]))
        XCTAssertNil(code(.settingsSet, ["key": "tint", "value": "#aabbcc"]))
        XCTAssertNil(code(.settingsSet, ["key": "label", "value": "hi"]))
        XCTAssertNil(code(.settingsSet, ["key": "enabled", "value": true, "app": "com.apple.Notes"]))
        let bad: [(String, [String: Any])] = [
            ("no key", ["value": true]),
            ("undeclared key", ["key": "bogus", "value": true]),
            ("no value", ["key": "enabled"]),
            ("wrong type", ["key": "enabled", "value": "yes"]),
            ("above max", ["key": "radius", "value": 21]),
            ("below min", ["key": "radius", "value": -1]),
            ("not whole", ["key": "count", "value": 2.5]),
            ("not finite", ["key": "radius", "value": Double.nan]),
            ("not a color", ["key": "tint", "value": "red"]),
            ("text too long", ["key": "label", "value": String(repeating: "x", count: 64 * 1024 + 1)]),
            ("another app's override", ["key": "enabled", "value": true, "app": "com.apple.TextEdit"]),
            ("override of a non-perApp item", ["key": "radius", "value": 3, "app": "com.apple.Notes"]),
            ("app not a string", ["key": "enabled", "value": true, "app": 3]),
        ]
        for (name, args) in bad { XCTAssertEqual(code(.settingsSet, args), .badArguments, name) }
    }

    func testSettingsWriteAndNotify() throws {
        let backend = MemoryTweakBackend()
        let effects = RecordingBridgeEffects(settingsBackend: backend)
        let g = F.grant()
        let plan = try validate(.settingsSet, ["key": "radius", "value": 4]).get()
        let r = BridgeActions.perform(plan, grant: g, effects: effects)
        XCTAssertEqual((try r.get() as? [String: Any])?["key"] as? String, "radius")
        XCTAssertEqual((backend.store[F.tweakID]?["values"] as? [String: Any])?["radius"] as? Double, 4)
        XCTAssertEqual((backend.store[F.tweakID]?["defaults"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual(backend.posted, [F.tweakID])

        let o = try validate(.settingsSet, ["key": "enabled", "value": false, "app": "com.apple.Notes"]).get()
        _ = try BridgeActions.perform(o, grant: g, effects: effects).get()
        let perApp = backend.store[F.tweakID]?["perApp"] as? [String: [String: Any]]
        XCTAssertEqual(perApp?["com.apple.Notes"]?["enabled"] as? Bool, false)
        XCTAssertEqual((backend.store[F.tweakID]?["values"] as? [String: Any])?["radius"] as? Double, 4, "kept")
    }

    func testNotifyArguments() {
        XCTAssertNil(code(.notify, ["name": "com.example.glass"]))
        XCTAssertNil(code(.notify, ["name": "com.example.glass.refresh"]))
        XCTAssertNil(code(.notify, ["name": "com.example.glass.a-b_c.1"]))
        for bad in ["com.example.glassy", "com.example.other.x", "dynject.safemode.changed", "com.apple.x", "", "com.example.glass x",
                    "com.example.glass.\u{e9}", "com.example.glass." + String(repeating: "a", count: 200)] {
            XCTAssertEqual(code(.notify, ["name": bad]), .badArguments, bad)
        }
        XCTAssertEqual(code(.notify, [:]), .badArguments)
        XCTAssertEqual(code(.notify, ["name": 3]), .badArguments)
        let reserved = BridgeGrant(identity: F.notes, bundleID: "com.apple.Notes", manifest: F.reserved)
        XCTAssertEqual(code(.notify, ["name": "local.dynject.thing.x"], grant: reserved), .badArguments, "reserved namespace")
    }

    func testOpenArguments() throws {
        XCTAssertNil(code(.open, ["url": "https://example.com/x?y=1"]))
        XCTAssertNil(code(.open, ["url": "HTTPS://example.com"]))
        let cases: [(String, BridgeErrorCode)] = [
            ("file:///etc/passwd", .badArguments),
            ("FILE:///etc/passwd", .badArguments),
            ("javascript:alert(1)", .badArguments),
            ("x-apple.systempreferences:com.apple.preference.security", .badArguments),
            ("data:text/html,hi", .badArguments),
            ("/etc/passwd", .badArguments),
            ("not a url", .badArguments),
            ("https:///nohost", .badArguments),
            ("http://example.com", .capabilityMissing),
            ("mailto:a@b.c", .capabilityMissing),
        ]
        for (url, expected) in cases { XCTAssertEqual(code(.open, ["url": url]), expected, url) }
        XCTAssertEqual(code(.open, ["url": "https://" + String(repeating: "a", count: 4100)]), .badArguments)
        XCTAssertEqual(code(.open, [:]), .badArguments)

        let effects = RecordingBridgeEffects()
        _ = try BridgeActions.perform(try validate(.open, ["url": "https://example.com"]).get(), grant: F.grant(), effects: effects).get()
        XCTAssertEqual(effects.opened, [URL(string: "https://example.com")!])
        effects.openSucceeds = false
        if case let .failure(d) = BridgeActions.perform(try validate(.open, ["url": "https://example.com"]).get(), grant: F.grant(), effects: effects) {
            XCTAssertEqual(d.code, .failed)
        } else { XCTFail("open failure must be reported") }
    }

    func testPasteboardArguments() throws {
        XCTAssertNil(code(.pasteboardWrite, ["string": "hello"]))
        XCTAssertEqual(code(.pasteboardWrite, [:]), .badArguments)
        XCTAssertEqual(code(.pasteboardWrite, ["string": 1]), .badArguments)
        XCTAssertEqual(code(.pasteboardWrite, ["string": String(repeating: "x", count: 512 * 1024 + 1)]), .badArguments)
        let effects = RecordingBridgeEffects()
        _ = try BridgeActions.perform(try validate(.pasteboardWrite, ["string": "hello"]).get(), grant: F.grant(), effects: effects).get()
        XCTAssertEqual(effects.pasteboard, ["hello"])
    }

    func testPingResult() throws {
        let r = try BridgeActions.perform(.ping, grant: F.grant(), effects: RecordingBridgeEffects()).get() as? [String: Any]
        XCTAssertEqual(r?["app"] as? String, "com.apple.Notes")
        XCTAssertEqual(r?["capabilities"] as? [String], ["settings.set", "notify", "open:https", "pasteboard.write"])
        XCTAssertEqual(r?["protocol"] as? Int, 1)
    }
}

final class BridgeServiceTests: XCTestCase {
    typealias F = BridgeFixtures

    func makeService(clock: TestClock, effects: RecordingBridgeEffects = RecordingBridgeEffects(), log: BridgeDecisionLog? = nil,
                     tweakBurst: Int = 20, processBurst: Int = 60) -> BridgeService {
        var s = BridgeService.Settings()
        s.tweakBurst = tweakBurst
        s.processBurst = processBurst
        return BridgeService(settings: s, sources: F.sources(), effects: effects, log: log ?? BridgeDecisionLog(fileURL: nil),
                             now: { clock.now })
    }

    func send(_ s: BridgeService, _ req: [String: Any], peer: BridgePeer = BridgePeer(pid: 4242, pidVersion: 1),
              id: BridgeCallerIdentity? = F.notes) -> (ok: Bool, error: String?) {
        let r = s.handle(object: req, peer: peer, identify: { id })
        return (r["ok"] as? Bool ?? false, r["error"] as? String)
    }

    func req(_ action: String, tweak: String = F.tweakID, _ args: [String: Any] = [:]) -> [String: Any] {
        ["v": 1, "tweak": tweak, "action": action, "args": args]
    }

    func testEndToEndDecisions() {
        let clock = TestClock()
        let effects = RecordingBridgeEffects()
        let s = makeService(clock: clock, effects: effects)
        XCTAssertEqual(send(s, req("ping")).ok, true)
        XCTAssertEqual(send(s, req("notify", ["name": "com.example.glass.go"])).ok, true)
        XCTAssertEqual(effects.notifications, ["com.example.glass.go"])
        XCTAssertEqual(send(s, req("notify", ["name": "com.example.other.go"])).error, "bad-arguments")
        XCTAssertEqual(send(s, req("launch")).error, "unknown-action")
        XCTAssertEqual(send(s, req("ping"), id: nil).error, "unidentified-caller")
        XCTAssertEqual(send(s, req("ping"), id: F.textEdit).error, "not-injected")
        XCTAssertEqual(send(s, req("ping", tweak: "com.example.nope")).error, "not-injected", "same reply as not-injected (L7)")
        XCTAssertEqual(send(s, ["v": 1]).error, "bad-request")
        XCTAssertEqual(effects.notifications.count, 1, "denials have no effect")
        // Pre-identity denials (unidentified, bad-request) stay out of the decision log (L1).
        XCTAssertEqual(s.log.entries.map(\.reason), ["ok", "ok", "bad-arguments", "unknown-action", "not-injected", "unknown-tweak"])
        XCTAssertEqual(s.log.entries[4].app, "com.apple.TextEdit")
    }

    func testWireFormat() throws {
        let clock = TestClock()
        let s = makeService(clock: clock)
        let peer = BridgePeer(pid: 1, pidVersion: 1)
        let data = try PropertyListSerialization.data(fromPropertyList: req("ping"), format: .binary, options: 0)
        let out = try PropertyListSerialization.propertyList(from: s.handle(data: data, peer: peer, identify: { F.notes }), format: nil) as? [String: Any]
        XCTAssertEqual(out?["ok"] as? Bool, true)
        XCTAssertEqual((out?["result"] as? [String: Any])?["app"] as? String, "com.apple.Notes")

        var calls = 0
        let junk = s.handle(data: Data("garbage".utf8), peer: peer, identify: { calls += 1; return F.notes })
        XCTAssertEqual((try PropertyListSerialization.propertyList(from: junk, format: nil) as? [String: Any])?["error"] as? String, "bad-request")
        XCTAssertEqual(calls, 0, "no identity lookup for a request that doesn't parse")
        let big = s.handle(data: Data(count: BridgeProtocol.maxMessageBytes + 1), peer: peer, identify: { F.notes })
        XCTAssertEqual((try PropertyListSerialization.propertyList(from: big, format: nil) as? [String: Any])?["error"] as? String, "too-large")
    }

    func testRateLimitPerProcessAndTweak() {
        let clock = TestClock()
        let s = makeService(clock: clock)
        let results = (0..<25).map { _ in send(s, req("ping")) }
        XCTAssertEqual(results.filter(\.ok).count, 20)
        XCTAssertEqual(results.last?.error, "rate-limited")
        XCTAssertEqual(send(s, req("ping", tweak: "com.example.quiet")).ok, true, "another tweak has its own bucket")
        XCTAssertEqual(send(s, req("ping"), peer: BridgePeer(pid: 4242, pidVersion: 2)).ok, true, "a new process (reused pid) too")
        clock.advance(1)
        XCTAssertEqual((0..<6).map { _ in send(s, req("ping")).ok }.filter { $0 }.count, 5, "5 per second")
        // Denied requests don't spend the tweak's tokens; a caller's rate-limited denials fold into one log entry.
        let limited = s.log.entries.filter { $0.reason == "rate-limited" }
        XCTAssertEqual(limited.map(\.count), [6])
    }

    func testProcessLimitComesFirst() {
        let clock = TestClock()
        let s = makeService(clock: clock, processBurst: 3)
        var lookups = 0
        let peer = BridgePeer(pid: 9, pidVersion: 9)
        let errors = (0..<5).map { _ in s.handle(object: ["junk": 1], peer: peer, identify: { lookups += 1; return F.notes })["error"] as? String }
        XCTAssertEqual(errors, ["bad-request", "bad-request", "bad-request", "rate-limited", "rate-limited"])
        XCTAssertEqual(s.log.entries, [], "an unidentified process can't fill the decision log")
        XCTAssertEqual(lookups, 0)

        // L2: on the wire too, and before the size check: an oversized payload is never copied or parsed, and is
        // rate-limited like anything else.
        let s2 = makeService(clock: clock, processBurst: 2)
        let wire = (0..<4).map { _ -> String? in
            let out = s2.handle(payload: .tooLarge(50_000_000), peer: peer, identify: { lookups += 1; return F.notes })
            return (try? PropertyListSerialization.propertyList(from: out, format: nil) as? [String: Any])?["error"] as? String
        }
        XCTAssertEqual(wire, ["too-large", "too-large", "rate-limited", "rate-limited"])
        let junk = s2.handle(data: Data("x".utf8), peer: BridgePeer(pid: 10, pidVersion: 1), identify: { F.notes })
        XCTAssertNotNil(junk)
        XCTAssertEqual(lookups, 0)
        XCTAssertEqual(s2.log.entries, [])
    }

    func testLimiter() {
        let clock = TestClock()
        let l = BridgeRateLimiter(burst: 3, perSecond: 2, now: { clock.now })
        XCTAssertEqual((0..<4).map { _ in l.allow("a") }, [true, true, true, false])
        clock.advance(0.5)
        XCTAssertEqual([l.allow("a"), l.allow("a")], [true, false])
        XCTAssertTrue(l.allow("b"))
        clock.advance(100)
        XCTAssertEqual((0..<4).map { _ in l.allow("a") }, [true, true, true, false], "never more than the burst")
    }
}

final class BridgeLogTests: XCTestCase {
    func entry(_ i: Int, allowed: Bool = true, reason: String = "ok") -> BridgeLogEntry {
        BridgeLogEntry(date: Date(timeIntervalSinceReferenceDate: Double(i)), pid: 1, app: "a", tweak: "t", action: "ping\(allowed ? "\(i)" : "")",
                       allowed: allowed, reason: reason)
    }

    func testRingAndPersistence() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Bridge/log.json")
        let log = BridgeDecisionLog(capacity: 5, fileURL: url)
        for i in 0..<8 { log.append(entry(i)) }
        XCTAssertEqual(log.entries.map(\.id), [4, 5, 6, 7, 8])
        XCTAssertTrue(log.isDirty)
        try log.save()
        XCTAssertFalse(log.isDirty)
        XCTAssertEqual(BridgeDecisionLog.load(url), log.entries)

        let reopened = BridgeDecisionLog(capacity: 3, fileURL: url)
        XCTAssertEqual(reopened.entries.map(\.id), [6, 7, 8])
        reopened.append(entry(9))
        XCTAssertEqual(reopened.entries.map(\.id), [7, 8, 9], "ids continue")
    }

    func testFoldsRepeatedDenials() {
        let log = BridgeDecisionLog(capacity: 10, fileURL: nil)
        log.append(entry(1, allowed: false, reason: "rate-limited"))
        log.append(entry(2, allowed: false, reason: "rate-limited"))
        log.append(entry(3, allowed: false, reason: "not-injected"))
        log.append(entry(4, allowed: false, reason: "not-injected"))
        log.append(entry(5))
        log.append(entry(6))
        XCTAssertEqual(log.entries.map(\.count), [2, 2, 1, 1])
        XCTAssertEqual(log.entries.first?.date, Date(timeIntervalSinceReferenceDate: 2), "latest time")
    }

    func testUnreadableFile() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("log.json")
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(BridgeDecisionLog.load(url), [])
        XCTAssertEqual(BridgeDecisionLog(fileURL: url).entries, [])
        XCTAssertEqual(BridgeDecisionLog.load(dir.appendingPathComponent("missing.json")), [])
    }
}

final class BridgeAgentTests: XCTestCase {
    func testNames() {
        XCTAssertFalse(BridgeNames.production.isDisjointFromProduction)
        let test = BridgeNames(service: "local.dynject.bridge.test", tokenKey: "t", versionKey: "v", notification: "n")
        XCTAssertTrue(test.isDisjointFromProduction)
        var mixed = test
        mixed.tokenKey = "dynject.bridge.token"
        XCTAssertFalse(mixed.isDisjointFromProduction)
    }

    func testPlistAndBinaryKeptApartFromSafeMode() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("dw-src")
        try Data("#!/bin/sh\n".utf8).write(to: src)
        let runner = RecordingLaunchctlRunner()
        let la = dir.appendingPathComponent("LaunchAgents"), bin = dir.appendingPathComponent("bin")
        let bridge = BridgeAgent(launchAgentsDirectory: la, binDirectory: bin, runner: runner, uid: 501)
        let safe = SafeModeAgent(launchAgentsDirectory: la, binDirectory: bin, runner: runner, uid: 501)

        let p = bridge.plist()
        XCTAssertEqual(p["Label"] as? String, "local.dynject.bridge")
        XCTAssertEqual(p["MachServices"] as? [String: Bool], ["local.dynject.bridge": true])
        XCTAssertEqual(p["ProgramArguments"] as? [String], [bin.appendingPathComponent("dw-bridge").path, "bridge", "serve"])
        XCTAssertEqual(p["ProcessType"] as? String, "Adaptive")
        XCTAssertEqual(p["KeepAlive"] as? Bool, true)

        try bridge.install(sourceBinary: src.path)
        try safe.install(sourceBinary: src.path)
        XCTAssertEqual(runner.calls.filter { $0.first == "bootstrap" }.map { $0.last! },
                       [la.appendingPathComponent("local.dynject.bridge.plist").path, la.appendingPathComponent("local.dynject.safemode.plist").path])
        try safe.uninstall()
        XCTAssertTrue(bridge.status().binaryInstalled, "removing the watcher leaves the bridge's binary")
        XCTAssertTrue(bridge.status().plistMatches)
        let lint = try ProcessRunner.run("/usr/bin/plutil", ["-lint", bridge.plistURL.path])
        XCTAssertEqual(lint.status, 0)
        try bridge.uninstall()
        XCTAssertFalse(bridge.status().plistInstalled)
        XCTAssertEqual(runner.calls.last, ["print", "gui/501/local.dynject.bridge"])
    }
}

/// One or more regression tests per finding of the security review (M1–M3, L1–L9, F1, F2).
final class BridgeReviewTests: XCTestCase {
    typealias F = BridgeFixtures

    func authorize(_ id: BridgeCallerIdentity, tweak: String = F.tweakID, sources: BridgePolicySources = F.sources(),
                   adHoc: Bool = false) -> BridgeDenial? {
        switch BridgeAuthorizer.authorize(tweak: tweak, identity: id, sources: sources, allowAdHoc: adHoc) {
        case .success: return nil
        case let .failure(d): return d
        }
    }

    func validate(_ action: BridgeAction, _ args: [String: Any], grant: BridgeGrant = F.grant()) -> BridgeErrorCode? {
        switch BridgeActions.validate(action, args: args, grant: grant) { case .success: return nil; case let .failure(d): return d.code }
    }

    // MARK: M1

    func testM1DeveloperIDAppCantBeFinder() {
        // Signing ID = CFBundleIdentifier = com.apple.finder, executable Finder, team-signed, installed in /Applications.
        let fake = F.identity("com.apple.finder", exe: "/Applications/Finder.app/Contents/MacOS/Finder", apple: false, team: "ABCDE12345")
        let sources = F.sources(installed: F.installed + [F.app("com.apple.finder", "/Applications/Finder.app", "Finder")])
        XCTAssertEqual(authorize(fake, sources: sources)?.code, .untrustedCaller)
        let dock = F.identity("com.apple.dock", exe: "/Applications/Dock.app/Contents/MacOS/Dock", apple: false, team: "ABCDE12345")
        XCTAssertEqual(authorize(dock)?.code, .untrustedCaller)
        let notesLike = F.identity("COM.APPLE.Notes", apple: false, team: "ABCDE12345")
        XCTAssertEqual(authorize(notesLike)?.code, .untrustedCaller, "case-insensitive")
        XCTAssertNil(authorize(F.finder), "the real Finder, Apple-signed, through its launchd label override")
    }

    func testM1SubstringPatternsDontGrant() {
        // dynjectd would inject com.evil.com.apple.Notes through "com.apple.Notes"; the bridge doesn't honour that.
        let evil = F.identity("com.evil.com.apple.Notes", apple: false, team: "ABCDE12345")
        let d = authorize(evil)
        XCTAssertEqual(d?.code, .notInjected)
        XCTAssertTrue(d?.message.contains("isn't specific") ?? false, d?.message ?? "")

        func config(_ pattern: String) -> EffectiveConfig {
            EffectiveConfig(document: ConfigDocument(text: "dylib:\(F.dylib):deny\ndylib-override:\(F.dylib):allow:\(pattern)\n"))
        }
        XCTAssertEqual(authorize(F.notes, sources: F.sources(config: config("Notes")))?.code, .notInjected)
        XCTAssertEqual(authorize(F.notes, sources: F.sources(config: config("com.apple.")))?.code, .notInjected)
        XCTAssertNil(authorize(F.notes, sources: F.sources(config: config("com.apple.Notes"))))
        XCTAssertNil(authorize(F.notes, sources: F.sources(config: config("application.com.apple.Notes."))))
        XCTAssertNil(authorize(F.textEdit, tweak: "com.example.quiet"), "a dylib allowed everywhere by default")
    }

    func testM1CallerMustBeTheInstalledApp() {
        let copy = F.identity(exe: "/Users/someone/Downloads/Notes.app/Contents/MacOS/Notes")
        XCTAssertEqual(authorize(copy)?.code, .notInjected)
        XCTAssertEqual(authorize(F.notes, sources: F.sources(installed: []))?.code, .notInjected)
        var noBundle = F.notes
        noBundle.bundlePath = nil
        XCTAssertEqual(authorize(noBundle)?.code, .notInjected)
    }

    // MARK: M3, F1

    func testM3LaunchContextAndHardening() {
        func with(_ base: BridgeCallerIdentity, _ change: (inout BridgeCallerIdentity) -> Void) -> BridgeCallerIdentity {
            var i = base
            change(&i)
            return i
        }
        let store = F.identity("com.example.store", apple: false, appStore: true)
        let host = F.identity("local.test.host", exe: "/tmp/t/TestHost.app/Contents/MacOS/TestHost", apple: false, adHoc: true)
        let cases: [(String, BridgeCallerIdentity, Bool, BridgeErrorCode?)] = [
            ("developer ID, hardened, launched by launchd", F.pages, false, nil),
            ("developer ID without hardened runtime", with(F.pages) { $0.hardenedRuntime = false }, false, .untrustedCaller),
            ("developer ID with DYLD/library-validation entitlements", with(F.pages) { $0.weakenedCodeLoading = true }, false, .untrustedCaller),
            ("parent isn't launchd", with(F.pages) { $0.parentIsLaunchd = false }, false, .untrustedCaller),
            ("another process is responsible (shell child, reparented)", with(F.pages) { $0.selfResponsible = false }, false, .untrustedCaller),
            ("responsibility lookup unavailable", with(F.pages) { $0.selfResponsible = nil }, false, nil),
            ("apple app needs no runtime flag", with(F.notes) { $0.hardenedRuntime = false }, false, nil),
            ("apple app started from a shell", with(F.notes) { $0.parentIsLaunchd = false }, false, .untrustedCaller),
            ("mac app store", store, false, nil),
            ("mac app store without hardened runtime", with(store) { $0.hardenedRuntime = false }, false, .untrustedCaller),
            ("ad hoc test host, test mode", with(host) { $0.hardenedRuntime = false; $0.parentIsLaunchd = false; $0.selfResponsible = false }, true, nil),
            ("ad hoc test host, live", host, false, .untrustedCaller),
        ]
        for (name, id, adHoc, expected) in cases {
            XCTAssertEqual(authorize(id, adHoc: adHoc)?.code, expected, name)
        }
    }

    func testF1Requirements() {
        XCTAssertEqual(BridgeRequirements.developerID(team: "ABCDE12345"),
                       "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"ABCDE12345\"")
        XCTAssertNil(BridgeRequirements.developerID(team: "ABC\" or anchor trusted"))
        XCTAssertNil(BridgeRequirements.developerID(team: ""))
        XCTAssertEqual(BridgeRequirements.appStore, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]")
    }

    /// The requirements against apps on this Mac, checked statically (signatures read from disk; nothing launched).
    func testF1StaticClassificationOfInstalledApps() throws {
        let fm = FileManager.default
        var checked: [String] = []
        if let c = SecurityIdentityProvider.classify(bundleAt: "/System/Applications/Calculator.app") {
            XCTAssertTrue(c.apple)
            XCTAssertFalse(c.developerID || c.appStore)
            checked.append("Calculator: apple")
        }
        let apps = ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? []).filter { $0.hasSuffix(".app") }.sorted()
        if let mas = apps.first(where: { fm.fileExists(atPath: "/Applications/\($0)/Contents/_MASReceipt") }),
           let c = SecurityIdentityProvider.classify(bundleAt: "/Applications/\(mas)") {
            XCTAssertTrue(c.appStore, mas)
            XCTAssertFalse(c.apple || c.developerID, mas)
            checked.append("\(mas): app store")
        }
        for name in apps.prefix(40) where !fm.fileExists(atPath: "/Applications/\(name)/Contents/_MASReceipt") {
            guard let c = SecurityIdentityProvider.classify(bundleAt: "/Applications/\(name)"), c.team != nil, !c.apple else { continue }
            if c.developerID {
                XCTAssertFalse(c.appStore, name)
                checked.append("\(name): developer ID")
                break
            }
        }
        if checked.isEmpty { throw XCTSkip("no Apple, App Store or Developer ID app found to check") }
        print("F1 static check: \(checked.joined(separator: "; "))")
    }

    // MARK: M2

    func testM2HugeIntegersAreRefusedNotTrapped() throws {
        XCTAssertEqual(validate(.settingsSet, ["key": "big", "value": 1e300]), .badArguments)
        XCTAssertEqual(validate(.settingsSet, ["key": "big", "value": -1e19]), .badArguments)
        XCTAssertEqual(validate(.settingsSet, ["key": "big", "value": 1.0e16]), .badArguments)
        XCTAssertNil(validate(.settingsSet, ["key": "big", "value": 9_007_199_254_740_992.0]))
        XCTAssertNil(validate(.settingsSet, ["key": "real", "value": 1e300]), "not an integer item: stored as a double")
        // The conversions that trapped.
        XCTAssertEqual(PrefValue.number(1e300).plistObject(integer: true) as? Double, 1e300)
        XCTAssertEqual(PrefValue.number(42).plistObject(integer: true) as? Int, 42)
        for n in [1e300, -1e300, Double.infinity, Double.nan, 1e15 + 0.5] { XCTAssertFalse(PrefValue.number(n).displayText.isEmpty) }
        let backend = MemoryTweakBackend()
        let plan = try BridgeActions.validate(.settingsSet, args: ["key": "real", "value": 1e300], grant: F.grant()).get()
        _ = try BridgeActions.perform(plan, grant: F.grant(), effects: RecordingBridgeEffects(settingsBackend: backend)).get()
    }

    // MARK: L1

    func testL1LogTextIsEscaped() {
        XCTAssertEqual(BridgeLogText.clean("a\u{1B}[31mb\u{07}\r\n\u{202E}x\u{2066}y\u{200F}"),
                       "a\\u{001B}[31mb\\u{0007}\\u{000D}\\u{000A}\\u{202E}x\\u{2066}y\\u{200F}")
        XCTAssertEqual(BridgeLogText.clean("plain café"), "plain café")
        let log = BridgeDecisionLog(fileURL: nil)
        log.append(BridgeLogEntry(date: Date(), pid: 1, app: "a\u{1B}", tweak: "t", action: "x\n", allowed: false, reason: "r", detail: "\u{202E}gnp.exe"))
        XCTAssertEqual(log.entries[0].app, "a\\u{001B}")
        XCTAssertEqual(log.entries[0].action, "x\\u{000A}")
        XCTAssertEqual(log.entries[0].detail, "\\u{202E}gnp.exe")

        let s = BridgeService(sources: F.sources(), effects: RecordingBridgeEffects(), log: BridgeDecisionLog(fileURL: nil))
        _ = s.handle(object: ["v": 1, "tweak": F.tweakID, "action": "\u{1B}]0;pwned\u{07}"], peer: BridgePeer(pid: 1, pidVersion: 1),
                     identify: { F.notes })
        XCTAssertEqual(s.log.entries.last?.action, "\\u{001B}]0;pwned\\u{0007}")
        XCTAssertFalse(s.log.entries.last?.detail?.unicodeScalars.contains { $0.properties.generalCategory == .control } ?? true)
    }

    func testL1UnidentifiedAndUntrustedStayOutAndFloodsFold() {
        let s = BridgeService(sources: F.sources(), effects: RecordingBridgeEffects(), log: BridgeDecisionLog(capacity: 50, fileURL: nil))
        let peer = BridgePeer(pid: 7, pidVersion: 7)
        _ = s.handle(object: ["v": 1, "tweak": F.tweakID, "action": "ping"], peer: peer, identify: { nil })
        _ = s.handle(object: ["v": 1, "tweak": F.tweakID, "action": "ping"], peer: peer, identify: { F.identity(valid: false) })
        var mismatched = F.pages
        mismatched.bundleIdentifier = "com.example.somethingelse"
        _ = s.handle(object: ["v": 1, "tweak": F.tweakID, "action": "ping"], peer: peer, identify: { mismatched })
        XCTAssertEqual(s.log.entries, [], "unidentified, untrusted and mismatched callers only reach os_log")

        _ = s.handle(object: ["v": 1, "tweak": F.tweakID, "action": "ping"], peer: peer, identify: { F.notes })
        for i in 0..<40 {   // a trusted app varying the tweak and action
            _ = s.handle(object: ["v": 1, "tweak": "com.example.junk\(i)", "action": "a\(i)"], peer: peer, identify: { F.notes })
        }
        XCTAssertEqual(s.log.entries.map(\.reason), ["ok", "unknown-tweak"])
        XCTAssertEqual(s.log.entries.last?.count, 40)
        XCTAssertEqual(s.log.entries.last?.tweak, "com.example.junk39", "the latest request's fields")
    }

    // MARK: L7

    func testL7UnknownAndNotInjectedLookTheSame() {
        let s = BridgeService(sources: F.sources(), effects: RecordingBridgeEffects(), log: BridgeDecisionLog(fileURL: nil))
        let peer = BridgePeer(pid: 2, pidVersion: 2)
        let unknown = s.handle(object: ["v": 1, "tweak": "com.example.zzz", "action": "ping"], peer: peer, identify: { F.textEdit })
        let notInjected = s.handle(object: ["v": 1, "tweak": "com.example.zzz", "action": "ping"],
                                   peer: peer, identify: { F.textEdit })
        let glass = s.handle(object: ["v": 1, "tweak": F.tweakID, "action": "ping"], peer: peer, identify: { F.textEdit })
        XCTAssertEqual(unknown["error"] as? String, "not-injected")
        XCTAssertEqual(unknown["message"] as? String, notInjected["message"] as? String)
        XCTAssertEqual(glass["error"] as? String, "not-injected")
        XCTAssertEqual(glass["message"] as? String, "\(F.tweakID) isn't available in this app")
        XCTAssertFalse((glass["message"] as? String ?? "").contains(".dylib"))
        XCTAssertEqual(Set(s.log.entries.map(\.reason)), ["unknown-tweak", "not-injected"], "the log keeps the real reasons")
        XCTAssertTrue(s.log.entries.contains { $0.detail?.contains("libGlass.dylib") ?? false })
    }

    // MARK: L8

    func testL8AppListEntriesAndPayloadCap() throws {
        XCTAssertNil(validate(.settingsSet, ["key": "apps", "value": ["com.apple.Notes", "org.example.app-2"]]))
        XCTAssertEqual(validate(.settingsSet, ["key": "apps", "value": ["not a bundle id"]]), .badArguments)
        XCTAssertEqual(validate(.settingsSet, ["key": "apps", "value": ["\u{1B}[2J"]]), .badArguments)
        XCTAssertEqual(validate(.settingsSet, ["key": "apps", "value": [String(repeating: "a", count: 256)]]), .badArguments)

        let backend = MemoryTweakBackend()
        backend.store[F.tweakID] = ["formatVersion": 1, "values": ["legacy": String(repeating: "x", count: 300_000)]]
        let before = backend.store[F.tweakID]?["values"] as? [String: Any]
        let plan = try BridgeActions.validate(.settingsSet, args: ["key": "enabled", "value": false], grant: F.grant()).get()
        guard case let .failure(d) = BridgeActions.perform(plan, grant: F.grant(), effects: RecordingBridgeEffects(settingsBackend: backend)) else {
            return XCTFail("a payload over 256 KB must be refused")
        }
        XCTAssertEqual(d.code, .badArguments)
        XCTAssertEqual((backend.store[F.tweakID]?["values"] as? [String: Any])?.count, before?.count, "nothing written")
        XCTAssertEqual(backend.posted, [])
    }

    // MARK: L9, F2

    func testL9NotifyStaysOutOfLongerTweakNamespaces() {
        let g = BridgeGrant(identity: F.notes, bundleID: "com.apple.Notes", manifest: F.glass,
                            installedTweakIDs: [F.tweakID, "com.example.glass.pro", "com.example.other"])
        XCTAssertEqual(validate(.notify, ["name": "com.example.glass.pro"], grant: g), .badArguments)
        XCTAssertEqual(validate(.notify, ["name": "com.example.glass.pro.refresh"], grant: g), .badArguments)
        XCTAssertNil(validate(.notify, ["name": "com.example.glass.prototype"], grant: g))
        XCTAssertNil(validate(.notify, ["name": "com.example.glass.refresh"], grant: g))
        XCTAssertNil(validate(.notify, ["name": "com.example.glass"], grant: g))
        XCTAssertEqual(F.grant().installedTweakIDs.sorted(), [F.glass, F.quiet, F.other, F.reserved].map(\.id).sorted(), "authorize fills it")
    }

    func testF2ExampleTweaksMayNotifyInfrastructureMayNot() {
        for (id, name, ok) in [("local.dynject.titlebadge", "local.dynject.titlebadge.refresh", true),
                               ("local.dynject.oledfinder", "local.dynject.oledfinder", true),
                               ("local.dynject.menuloader", "local.dynject.menuloader.changed", false),
                               ("local.dynject.safemode", "local.dynject.safemode.x", false),
                               ("local.dynject.bridge", "local.dynject.bridge.changed", false),
                               ("local.dynject.workbench", "local.dynject.workbench.x", false),
                               ("dynject", "dynject.safemode.changed", false),
                               ("com.apple", "com.apple.x", false)] {
            let r = BridgeActions.validateNotification(name, tweak: id)
            XCTAssertEqual((try? r.get()) != nil, ok, "\(id): \(name)")
        }
    }

    // MARK: L6

    func testL6AgentDirectoriesNeedSimulatedLaunchctl() {
        XCTAssertNotNil(BridgeAgent.testingOptionsProblem(directoriesOverridden: true, simulatedLaunchctl: false))
        XCTAssertNil(BridgeAgent.testingOptionsProblem(directoriesOverridden: true, simulatedLaunchctl: true))
        XCTAssertNil(BridgeAgent.testingOptionsProblem(directoriesOverridden: false, simulatedLaunchctl: false))
    }
}
