@testable import DynjectCore
import DynjectTweakSDK
import XCTest

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func exampleManifest() -> TweakManifest {
    let path = repoRoot.appendingPathComponent("Examples/ExampleTweak.workbench.plist").path
    let (m, issues) = TweakManifestParser.parse(data: FileManager.default.contents(atPath: path)!, path: path,
                                                fileExists: { _ in true })
    XCTAssertEqual(issues.filter { $0.severity == .error }, [])
    return m!
}

func manifestData(_ dict: [String: Any]) -> Data {
    try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
}

final class TweakManifestTests: XCTestCase {
    func testExampleManifestParses() {
        let m = exampleManifest()
        XCTAssertEqual(m.id, "com.example.windowtweak")
        XCTAssertEqual(m.takesEffect, .live)
        XCTAssertEqual(m.version, "0.1")
        XCTAssertEqual(Set(m.items.map(\.kind)), Set(TweakItem.Kind.allCases))
        XCTAssertEqual(m.perAppItems.map(\.key), ["enabled", "style", "radius", "accent"])
        XCTAssertEqual(m.item("radius")?.defaultValue, .number(8))
        XCTAssertEqual(m.item("accent")?.defaultValue, .string("auto"))
        XCTAssertEqual(m.item("style")?.enabledIf, "enabled")
    }

    func testTitleBadgeManifestParses() {
        let path = repoRoot.appendingPathComponent("Examples/TitleBadge/TitleBadge.workbench.plist").path
        let (m, issues) = TweakManifestParser.parse(data: FileManager.default.contents(atPath: path)!, path: path,
                                                    fileExists: { _ in true })
        XCTAssertEqual(issues.map(\.message), [])
        XCTAssertEqual(m?.id, "local.dynject.titlebadge")
        XCTAssertEqual(m?.perAppItems.map(\.key), ["enabled", "text", "showBundleID", "style", "color"])
    }

    func testRejectsUnusableManifests() {
        func errors(_ d: [String: Any]) -> [String] {
            TweakManifestParser.parse(data: manifestData(d), path: "/x", fileExists: { _ in true }).1.map(\.message)
        }
        XCTAssertNil(TweakManifestParser.parse(data: Data("nope".utf8), path: "/x").0)
        XCTAssertTrue(errors(["identifier": "a.b", "dylib": "/d"]).contains { $0.contains("formatVersion") })
        XCTAssertTrue(errors(["formatVersion": 1, "dylib": "/d"]).contains { $0.contains("identifier") })
        XCTAssertTrue(errors(["formatVersion": 1, "identifier": "a.b", "dylib": "rel.dylib"]).contains { $0.contains("absolute") })
    }

    func testBadItemsAreSkippedNotFatal() {
        let d: [String: Any] = [
            "formatVersion": 1, "identifier": "a.b", "dylib": "/d", "applyCommand": ["relative"],
            "sections": [["items": [
                ["type": "switch", "key": "on"],
                ["type": "dial", "key": "x"],
                ["type": "slider", "key": "s", "min": 5, "max": 1],
                ["type": "choice", "key": "c"],
                ["type": "switch", "key": "on"],
                ["type": "color", "key": "col", "default": "red"],
                ["type": "text", "key": "t", "enabledIf": "missing"],
            ]]],
        ]
        let (m, issues) = TweakManifestParser.parse(data: manifestData(d), path: "/x", fileExists: { _ in true })
        XCTAssertEqual(m?.items.map(\.key), ["on", "col", "t"])
        XCTAssertNil(m?.applyCommand)
        XCTAssertEqual(m?.item("col")?.defaultValue, .string("#000000"))
        XCTAssertNil(m?.item("t")?.enabledIf)
        let messages = issues.map(\.message).joined(separator: "\n")
        for needle in ["type must be one of", "min < max", "needs options", "duplicate key", "doesn't fit", "enabledIf", "applyCommand"] {
            XCTAssertTrue(messages.contains(needle), needle)
        }
    }

    func testNormalization() {
        let m = exampleManifest()
        let radius = m.item("radius")!
        XCTAssertEqual(radius.normalized(.number(30)), .number(24))
        XCTAssertEqual(radius.normalized(.number(3.4)), .number(3))
        XCTAssertNil(radius.normalized(.string("3")))
        XCTAssertEqual(m.item("accent")!.normalized(.string("#ff00aa")), .string("#FF00AA"))
        XCTAssertEqual(m.item("accent")!.normalized(.string("auto")), .string("auto"))
        XCTAssertNil(m.item("accent")!.normalized(.string("#ff00a")))
        XCTAssertNil(m.item("style")!.normalized(.string("neon")))
        XCTAssertEqual(m.item("exclude")!.normalized(.list(["a", "", "a", "b"])), .list(["a", "b"]))
    }

    func testLoaderFindsManifestsAndRejectsDuplicateIDs() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let example = repoRoot.appendingPathComponent("Examples/ExampleTweak.workbench.plist")
        try FileManager.default.copyItem(at: example, to: dir.appendingPathComponent("a.workbench.plist"))
        try FileManager.default.copyItem(at: example, to: dir.appendingPathComponent("b.workbench.plist"))
        try Data("ignored".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let (manifests, issues) = TweakManifestLoader.load(directories: [dir.path, "/nonexistent"])
        XCTAssertEqual(manifests.count, 1)
        XCTAssertTrue(issues.contains { $0.message.contains("already provided") })
    }
}

final class TweakSettingsTests: XCTestCase {
    func testDefaultsGlobalsAndOverridesResolveInOrder() throws {
        let m = exampleManifest()
        let backend = MemoryTweakBackend()
        let s = TweakSettings(manifest: m, backend: backend)
        let radius = m.item("radius")!
        XCTAssertEqual(s.effective(radius, bundleID: "com.apple.Notes"), .number(8))
        XCTAssertTrue(s.set(.number(12), for: radius))
        XCTAssertEqual(s.effective(radius, bundleID: "com.apple.Notes"), .number(12))
        XCTAssertTrue(s.setOverride(.number(2), for: radius, bundleID: "com.apple.Notes"))
        XCTAssertEqual(s.effective(radius, bundleID: "com.apple.Notes"), .number(2))
        XCTAssertEqual(s.effective(radius, bundleID: "com.apple.finder"), .number(12))
        // Non-perApp items can't be overridden.
        XCTAssertFalse(s.setOverride(.number(3), for: m.item("borderWidth")!, bundleID: "com.apple.Notes"))
        try s.persist()

        let p = backend.store[m.id]!
        XCTAssertEqual((p["values"] as? [String: Any])?["radius"] as? Int, 12)
        XCTAssertEqual(((p["perApp"] as? [String: Any])?["com.apple.Notes"] as? [String: Any])?["radius"] as? Int, 2)
        XCTAssertEqual((p["defaults"] as? [String: Any])?["style"] as? String, "flat")
        XCTAssertEqual(backend.posted, [m.id])

        s.setOverride(nil, for: radius, bundleID: "com.apple.Notes")
        XCTAssertEqual(s.appsWithOverrides, [])
    }

    func testEnabledIfFollowsTheSwitchPerApp() {
        let m = exampleManifest()
        let s = TweakSettings(manifest: m, backend: MemoryTweakBackend())
        let style = m.item("style")!, enabled = m.item("enabled")!
        XCTAssertTrue(s.isEnabled(style))
        s.setOverride(.bool(false), for: enabled, bundleID: "com.apple.Notes")
        XCTAssertFalse(s.isEnabled(style, bundleID: "com.apple.Notes"))
        XCTAssertTrue(s.isEnabled(style, bundleID: "com.apple.finder"))
    }

    func testUnknownKeysArePreservedAndRevertRestoresSnapshot() throws {
        let m = exampleManifest()
        let backend = MemoryTweakBackend()
        let original: [String: Any] = ["formatVersion": 1, "values": ["legacyKey": "keep me", "radius": 4], "perApp": [:]]
        backend.store[m.id] = original
        let s = TweakSettings(manifest: m, backend: backend)
        XCTAssertEqual(s.value(m.item("radius")!), .number(4))
        s.set(.number(20), for: m.item("radius")!)
        try s.persist()
        XCTAssertEqual((backend.store[m.id]?["values"] as? [String: Any])?["legacyKey"] as? String, "keep me")
        XCTAssertTrue(s.hasSessionChanges)
        try s.revertSession()
        XCTAssertEqual((backend.store[m.id]?["values"] as? [String: Any])?["radius"] as? Int, 4)
        XCTAssertNil(backend.store[m.id]?["defaults"])
        XCTAssertFalse(s.hasSessionChanges)
        XCTAssertEqual(s.value(m.item("radius")!), .number(4))
    }

    func testRevertRemovesPayloadThatDidNotExist() throws {
        let m = exampleManifest()
        let backend = MemoryTweakBackend()
        let s = TweakSettings(manifest: m, backend: backend)
        s.set(.bool(false), for: m.item("enabled")!)
        try s.persist()
        XCTAssertNotNil(backend.store[m.id])
        try s.revertSession()
        XCTAssertNil(backend.store[m.id])
    }

    func testInvalidStoredValuesFallBackToDefault() {
        let m = exampleManifest()
        let backend = MemoryTweakBackend()
        backend.store[m.id] = ["values": ["radius": "big", "style": "neon"]]
        let s = TweakSettings(manifest: m, backend: backend)
        XCTAssertEqual(s.value(m.item("radius")!), .number(8))
        XCTAssertEqual(s.value(m.item("style")!), .string("flat"))
    }

    func testFileBackendRoundTrip() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = FileTweakBackend(path: dir.appendingPathComponent("prefs.plist").path)
        let m = exampleManifest()
        let s = TweakSettings(manifest: m, backend: backend)
        s.set(.string("#112233"), for: m.item("accent")!)
        try s.persist()
        XCTAssertEqual(TweakSettings(manifest: m, backend: backend).value(m.item("accent")!), .string("#112233"))
        XCTAssertEqual(backend.posted, ["dynject.tweak.com.example.windowtweak.changed"])
    }

    func testApplyCommandRunner() {
        XCTAssertTrue(ApplyCommandRunner.run(["/usr/bin/true"]).ok)
        XCTAssertFalse(ApplyCommandRunner.run(["/usr/bin/false"]).ok)
        XCTAssertFalse(ApplyCommandRunner.run(["/nope"]).ok)
        XCTAssertEqual(ApplyCommandRunner.run(["/bin/sleep", "5"], timeout: 0.3).message, "timed out after 0.3 s")
    }

    /// The Swift writer and the C header must agree on the storage contract.
    func testSDKHeaderReadsWhatWorkbenchWrites() throws {
        // One fixed domain: cfprefsd may re-create an empty file after cleanup, so never use a unique name per run.
        let domain = "local.dynject.workbench.tests"
        let prefsFile = NSHomeDirectory() + "/Library/Preferences/\(domain).plist"
        defer {
            CFPreferencesSetValue(TweakPrefsContract.payloadKey("com.example.windowtweak") as CFString, nil, domain as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            try? FileManager.default.removeItem(atPath: prefsFile)
        }
        let m = exampleManifest()
        let s = TweakSettings(manifest: m, backend: CFPreferencesTweakBackend(domain: domain as CFString))
        s.set(.number(16), for: m.item("radius")!)
        s.setOverride(.number(4), for: m.item("radius")!, bundleID: "com.apple.Notes")
        s.set(.list(["com.apple.Safari"]), for: m.item("exclude")!)
        try s.persist()

        let payload = DTPayloadInDomain(m.id, domain as CFString)
        XCTAssertNotNil(payload)
        XCTAssertEqual(DTResolve(payload, "radius", "com.apple.Notes", nil) as? Int, 4)
        XCTAssertEqual(DTResolve(payload, "radius", "com.apple.finder", nil) as? Int, 16)
        XCTAssertEqual(DTResolve(payload, "style", "com.apple.finder", nil) as? String, "flat")   // manifest default
        XCTAssertEqual(DTResolve(payload, "exclude", nil, nil) as? [String], ["com.apple.Safari"])
        XCTAssertEqual(DTResolve(payload, "missing", nil, "fb") as? String, "fb")
    }
}

final class WorkbenchInfoTests: XCTestCase {
    func testVersionMatchesInfoPlist() throws {
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("Resources/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(plist?["CFBundleShortVersionString"] as? String, WorkbenchInfo.version)
        XCTAssertTrue(WorkbenchInfo.versionText.contains("PolyForm Noncommercial 1.0.0"))
    }
}
