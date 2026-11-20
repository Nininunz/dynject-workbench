@testable import DynjectCore
import XCTest

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func manifest(_ id: String, version: String? = nil, depends: [String]? = nil, bridge: [String]? = nil,
                      extra: [String: Any] = [:]) -> (TweakManifest?, [ManifestIssue]) {
    var d: [String: Any] = ["formatVersion": 1, "identifier": id, "dylib": "/opt/dynject/lib/tweaks/lib\(id).dylib",
                            "sections": [["items": [["type": "switch", "key": "enabled"]]]]]
    if let version { d["version"] = version }
    if let depends { d["depends"] = depends }
    if let bridge { d["bridge"] = bridge }
    for (k, v) in extra { d[k] = v }
    return TweakManifestParser.parse(data: manifestData(d), path: "/m/\(id).workbench.plist", fileExists: { _ in true })
}

private func m(_ id: String, version: String? = nil, depends: [String]? = nil, bridge: [String]? = nil,
               extra: [String: Any] = [:]) -> TweakManifest {
    manifest(id, version: version, depends: depends, bridge: bridge, extra: extra).0!
}

final class SemanticVersionTests: XCTestCase {
    func testParseAndDescription() {
        XCTAssertEqual(SemanticVersion("1.2.3"), SemanticVersion(1, 2, 3))
        XCTAssertEqual(SemanticVersion("1.0.0-beta.2")?.prerelease, ["beta", "2"])
        XCTAssertEqual(SemanticVersion("0.10.0-rc-1")?.description, "0.10.0-rc-1")
        XCTAssertEqual(SemanticVersion(1, 0, 0).description, "1.0.0")
        for bad in ["1.2", "1", "1.2.3.4", "01.2.3", "1.02.3", "v1.2.3", "1.2.3-", "1.2.3-beta..1", "1.2.3-01", "1.2.3+build",
                    "1.2.x", "", " 1.2.3", "1.2.3-bêta"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
    }

    func testPrecedence() {
        // semver.org's example order.
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
                       "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "1.10.0", "2.0.0"].map { SemanticVersion($0)! }
        XCTAssertEqual(ordered.shuffled().sorted(), ordered)
        for (a, b) in zip(ordered, ordered.dropFirst()) { XCTAssertLessThan(a, b, "\(a) < \(b)") }
        XCTAssertFalse(SemanticVersion("1.0.0")! < SemanticVersion("1.0.0")!)
    }
}

final class SystemVersionTests: XCTestCase {
    func testParseCompare() {
        XCTAssertEqual(SystemVersion("27"), SystemVersion("27.0.0"))
        XCTAssertEqual(SystemVersion("27.0")?.description, "27.0")
        XCTAssertEqual(SystemVersion([27, 2, 0]).description, "27.2")
        XCTAssertEqual(SystemVersion([27, 2, 1]).description, "27.2.1")
        XCTAssertLessThan(SystemVersion("26.4")!, SystemVersion("27")!)
        XCTAssertLessThan(SystemVersion("27.2")!, SystemVersion("27.10")!)
        for bad in ["", "27.", ".1", "27.0.0.1", "v27", "27,1", "27.a"] { XCTAssertNil(SystemVersion(bad), bad) }
        XCTAssertGreaterThanOrEqual(SystemVersion.current, SystemVersion("14.0")!)
    }

    func testRanges() {
        let r = SystemVersionRange("27.0 - 27.2")!
        XCTAssertEqual(r.description, "27.0 – 27.2")
        XCTAssertTrue(r.contains(SystemVersion("27.0")!))
        XCTAssertTrue(r.contains(SystemVersion("27.2.1")!), "the upper end counts at its precision")
        XCTAssertFalse(r.contains(SystemVersion("27.3")!))
        XCTAssertFalse(r.contains(SystemVersion("26.4")!))
        let one = SystemVersionRange("27.2")!
        XCTAssertEqual(one.description, "27.2")
        XCTAssertTrue(one.contains(SystemVersion("27.2.5")!))
        XCTAssertFalse(one.contains(SystemVersion("27.1")!))
        XCTAssertTrue(SystemVersionRange("27")!.contains(SystemVersion("27.9")!))
        XCTAssertEqual(SystemVersionRange("27.0-27.2"), r)
        for bad in ["27.2 - 27.0", "27 - ", "- 27", "27 - 28 - 29", "x"] { XCTAssertNil(SystemVersionRange(bad), bad) }
    }
}

final class SDKVersionTests: XCTestCase {
    /// DH_SDK_VERSION in DynjectHook.h is WorkbenchInfo.version, and DynjectHook.m embeds it behind "dynject.sdk:".
    func testSDKVersionHasOneSourceOfTruth() throws {
        let header = try String(contentsOf: repoRoot.appendingPathComponent("TweakSDK/include/DynjectHook.h"), encoding: .utf8)
        let source = try String(contentsOf: repoRoot.appendingPathComponent("TweakSDK/DynjectHook.m"), encoding: .utf8)
        XCTAssertTrue(header.contains("#define DH_SDK_VERSION \"\(WorkbenchInfo.version)\"\n"),
                      "DH_SDK_VERSION in DynjectHook.h must be WorkbenchInfo.version (\(WorkbenchInfo.version))")
        XCTAssertTrue(source.contains("\"\(SDKVersionChecker.markerPrefix)\" DH_SDK_VERSION;"), "the marker in DynjectHook.m")
        XCTAssertNotNil(SemanticVersion(WorkbenchInfo.version))
    }

    func testMarkerInData() throws {
        XCTAssertEqual(SDKVersionChecker.version(in: Data("\u{0}x\u{0}dynject.sdk:0.2.0\u{0}y".utf8)), "0.2.0")
        XCTAssertNil(SDKVersionChecker.version(in: Data("\u{0}dynject.safemode\u{0}".utf8)))
        XCTAssertNil(SDKVersionChecker.version(in: Data("xdynject.sdk:0.2.0\u{0}".utf8)), "a C string of its own")
        XCTAssertNil(SDKVersionChecker.version(in: Data("\u{0}dynject.sdk:0.2.0".utf8)), "unterminated")
        XCTAssertEqual(SDKVersionChecker.version(in: Data("\u{0}dynject.sdk:0.10.0\u{0}\u{0}dynject.sdk:0.9.0\u{0}".utf8)), "0.9.0",
                       "two copies: the older one")

        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("libX.dylib")
        try Data("\u{0}dynject.sdk:0.1.0\u{0}".utf8).write(to: file)
        let checker = SDKVersionChecker()
        XCTAssertEqual(checker.version(dylibAt: file.path), "0.1.0")
        try Data("\u{0}dynject.sdk:0.3.0\u{0}..".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        XCTAssertEqual(checker.version(dylibAt: file.path), "0.3.0", "rebuilt: read again")
        XCTAssertNil(checker.version(dylibAt: dir.appendingPathComponent("missing").path))
    }
}

final class ManifestCompatibilityKeysTests: XCTestCase {
    func testKeysParse() {
        let (parsed, issues) = manifest("a.b", version: "1.2.0", depends: ["c.d >= 1.0.0", "e.f", "bridge", " safemode "],
                                        extra: ["minimumSystemVersion": "27.0", "testedSystemVersions": "27.0 - 27.2"])
        XCTAssertEqual(issues, [])
        let x = parsed!
        XCTAssertEqual(x.semanticVersion, SemanticVersion(1, 2, 0))
        XCTAssertEqual(x.minimumSystemVersion, SystemVersion("27.0"))
        XCTAssertEqual(x.testedSystemVersions, SystemVersionRange("27.0 - 27.2"))
        XCTAssertEqual(x.depends.map(\.description), ["c.d >= 1.0.0", "e.f", "bridge", "safemode"])
        XCTAssertEqual(x.dependencyTweakIDs, ["c.d", "e.f"])
    }

    func testProblemsAreReported() {
        func messages(_ version: Any? = nil, depends: Any? = nil, extra: [String: Any] = [:]) -> [String] {
            var e = extra
            if let version { e["version"] = version }
            if let depends { e["depends"] = depends }
            return manifest("a.b", extra: e).1.map { "\($0.severity == .error ? "E" : "W") \($0.message)" }
        }
        XCTAssertTrue(messages("1.2").first?.hasPrefix("W version \"1.2\" is not a semantic version") == true)
        XCTAssertTrue(messages(3).first?.hasPrefix("W version must be a string") == true)
        XCTAssertTrue(messages(extra: ["minimumSystemVersion": 27.0]).first?.hasPrefix("E minimumSystemVersion must be a string") == true)
        XCTAssertTrue(messages(extra: ["testedSystemVersions": "27.2 - 27.0"]).first?.hasPrefix("E testedSystemVersions") == true)
        XCTAssertTrue(messages(extra: ["minimumSystemVersion": "27.0", "testedSystemVersions": "26.0 - 26.4"])
            .first?.contains("entirely below minimumSystemVersion") == true)
        XCTAssertTrue(messages(depends: "c.d").first?.hasPrefix("E depends must be an array") == true)
        let deps = messages(depends: ["c.d >= 1.0", "a.b", "bad id!", 4, "bridge >= 1.0.0", "c.d", "c.d"])
        XCTAssertEqual(deps.count, 6, "\(deps)")
        XCTAssertTrue(deps[0].contains("1.0 is not a semantic version"))
        XCTAssertTrue(deps[1].contains("can't depend on itself"))
        XCTAssertTrue(deps[2].contains("is not \"<tweak id>\""))
        XCTAssertTrue(deps[3].contains("not a string"))
        XCTAssertTrue(deps[4].contains("bridge has no version"))
        XCTAssertTrue(deps[5].hasPrefix("W") && deps[5].contains("listed twice"))
    }

    func testBridgeCapabilitiesImplyTheBridge() {
        let x = m("a.b", bridge: ["notify"])
        XCTAssertEqual(x.depends, [])
        XCTAssertEqual(x.allDependencies, [TweakDependency(.component(.bridge), implicit: true)])
        let y = m("a.b", depends: ["bridge"], bridge: ["notify"])
        XCTAssertEqual(y.allDependencies, [TweakDependency(.component(.bridge))])
    }

    /// The bundled tweaks declare macOS 27.0 (with DH_REQUIRE_SYSTEM in their constructors) and semantic versions.
    func testBundledTweaksDeclareTheirSystem() throws {
        for (manifestPath, sourcePath) in [("Tweaks/MenuLoader/MenuLoader.workbench.plist", "Tweaks/MenuLoader/MenuLoader.m"),
                                           ("Tweaks/Inspector/Inspector.workbench.plist", "Tweaks/Inspector/Inspector.m"),
                                           ("Examples/OLEDFinder/OLEDFinder.workbench.plist", "Examples/OLEDFinder/OLEDFinder.m")] {
            let path = repoRoot.appendingPathComponent(manifestPath).path
            let (parsed, issues) = TweakManifestParser.parse(data: try XCTUnwrap(FileManager.default.contents(atPath: path)), path: path,
                                                             fileExists: { _ in true })
            XCTAssertEqual(issues.filter { $0.message.contains("ersion") }, [], manifestPath)
            let x = try XCTUnwrap(parsed)
            XCTAssertNotNil(x.semanticVersion, manifestPath)
            XCTAssertEqual(x.minimumSystemVersion, SystemVersion("27.0"), manifestPath)
            XCTAssertEqual(x.testedSystemVersions, SystemVersionRange("27.2"), manifestPath)
            let source = try String(contentsOf: repoRoot.appendingPathComponent(sourcePath), encoding: .utf8)
            XCTAssertTrue(source.contains("DH_REQUIRE_SYSTEM(\"27.0\");"), sourcePath)
        }
    }
}

final class DependencyCheckerTests: XCTestCase {
    func testUnmetAndDependents() {
        let lib = m("x.lib", version: "1.2.0"), old = m("x.old", version: "1.0"), plain = m("x.plain")
        let user = m("x.user", depends: ["x.lib >= 1.3.0", "x.lib2", "x.old >= 1.0.0", "x.plain", "safemode"], bridge: ["notify"])
        let checker = DependencyChecker(installed: [lib, old, plain, user], components: [.bridge: false, .safemode: true])
        let unmet = checker.unmet(for: user)
        XCTAssertEqual(unmet.map(\.dependency.description), ["x.lib >= 1.3.0", "x.lib2", "x.old >= 1.0.0", "bridge"])
        XCTAssertEqual(unmet[0].message, "needs x.lib (x.lib) 1.3.0 or later; 1.2.0 is installed")
        XCTAssertEqual(unmet[1].message, "needs x.lib2, which isn't installed")
        XCTAssertEqual(unmet[1].fix, "dw tweak install <x.lib2's folder>")
        XCTAssertTrue(unmet[2].message.contains("can't be compared"))
        XCTAssertTrue(unmet[3].message.contains("the bridge, which isn't installed (it declares bridge capabilities)"))
        XCTAssertTrue(unmet[3].fix.hasPrefix("dw bridge agent install"))

        XCTAssertEqual(DependencyChecker(installed: [], components: [:]).unmet(for: m("y", depends: ["bridge", "safemode"])), [],
                       "unknown components are never unmet")
        XCTAssertEqual(DependencyChecker(installed: [], components: [.safemode: false]).unmet(for: m("y", depends: ["safemode"]))
            .first?.fix, BuiltInComponent.safemode.fix)

        XCTAssertEqual(checker.dependents(of: "x.lib").map(\.id), ["x.user"])
        XCTAssertEqual(checker.dependents(of: "x.user").map(\.id), [])
    }

    func testComponentStatusReadsThePlists() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(BuiltInComponent.installedStatus(launchAgentsDirectory: dir), [.bridge: false, .safemode: false])
        try Data().write(to: dir.appendingPathComponent("\(BridgeAgent.label).plist"))
        XCTAssertEqual(BuiltInComponent.installedStatus(launchAgentsDirectory: dir), [.bridge: true, .safemode: false])
    }
}

final class TweakCompatibilityReportTests: XCTestCase {
    func env(_ system: String = "27.2", sdk: String = "0.2.0", components: [BuiltInComponent: Bool] = [:],
             builds: [String: DylibBuildInfo] = [:]) -> TweakCompatibility.Environment {
        TweakCompatibility.Environment(systemVersion: SystemVersion(system)!, sdkVersion: sdk, components: components,
                                       dylib: { builds[$0.id] })
    }

    func testEachKindOfIssue() {
        let os = ["minimumSystemVersion": "27.0", "testedSystemVersions": "27.0 - 27.2"]
        let fine = m("t.fine", version: "1.0.0", extra: os)
        let tooOld = m("t.old", version: "1.0.0", extra: os)
        let looseVersion = m("t.loose", version: "1.2")
        let oldSDK = m("t.oldsdk", version: "1.0.0"), noMarker = m("t.nomarker", version: "1.0.0"), notHook = m("t.nothook")
        let needy = m("t.needy", version: "1.0.0", depends: ["t.fine >= 2.0.0", "t.gone"], bridge: ["notify"])
        let installed = [fine, tooOld, looseVersion, oldSDK, noMarker, notHook, needy]
        let builds: [String: DylibBuildInfo] = [
            "t.fine": .init(sdkVersion: "0.2.0", usesDynjectHook: true),
            "t.oldsdk": .init(sdkVersion: "0.1.0", usesDynjectHook: true),
            "t.nomarker": .init(sdkVersion: nil, usesDynjectHook: true),
            "t.nothook": .init(sdkVersion: nil, usesDynjectHook: false),
        ]
        let e = env(components: [.bridge: false], builds: builds)
        let report = Dictionary(uniqueKeysWithValues: TweakCompatibility.check(installed, environment: e).map { ($0.manifest.id, $0.issues) })
        XCTAssertEqual(report["t.fine"], [])
        XCTAssertEqual(report["t.nothook"], [], "no DynjectHook: no SDK to rebuild with")

        let untested = TweakCompatibility.issues(for: fine, installed: installed, environment: env("27.3", builds: builds))
        XCTAssertEqual(untested.map(\.kind), [.untestedSystem])
        XCTAssertEqual(untested.first?.severity.symbol, "!")
        XCTAssertEqual(untested.first?.message, "tested on macOS 27.0 – 27.2; this Mac runs 27.3")

        let below = TweakCompatibility.issues(for: tooOld, installed: installed, environment: env("26.4"))
        XCTAssertEqual(below.map(\.kind), [.systemTooOld], "below the minimum: no separate tested-range warning")
        XCTAssertEqual(below.first?.severity, .error)
        XCTAssertEqual(below.first?.severity.symbol, "✗")
        XCTAssertEqual(below.first?.message, "needs macOS 27.0 or later; this Mac runs 26.4")

        XCTAssertEqual(report["t.loose"]?.map(\.kind), [.nonSemanticVersion])
        XCTAssertTrue(report["t.loose"]?.first?.fix?.contains("\"1.2.0\"") == true)
        XCTAssertEqual(report["t.oldsdk"]?.map(\.kind), [.oldSDK])
        XCTAssertEqual(report["t.oldsdk"]?.first?.message, "built with DynjectHook 0.1.0; the current SDK is 0.2.0")
        XCTAssertEqual(report["t.nomarker"]?.map(\.kind), [.missingSDKMarker])
        XCTAssertTrue(report["t.nomarker"]?.first?.fix?.contains("rebuild") == true)

        let needs = report["t.needy"] ?? []
        XCTAssertEqual(needs.map(\.kind), [.unmetDependency, .unmetDependency, .unmetDependency])
        XCTAssertEqual(needs.map(\.severity), [.error, .error, .error])
        XCTAssertEqual(needs.map(\.message), ["needs t.fine (t.fine) 2.0.0 or later; 1.0.0 is installed",
                                              "needs t.gone, which isn't installed",
                                              "needs the bridge, which isn't installed (it declares bridge capabilities)"])
        XCTAssertTrue(needs.allSatisfy { $0.fix != nil && $0.tweakID == "t.needy" })
    }

    func testSuggestedVersions() {
        XCTAssertEqual(TweakCompatibility.suggestedSemanticVersion("1.2"), "1.2.0")
        XCTAssertEqual(TweakCompatibility.suggestedSemanticVersion("3"), "3.0.0")
        XCTAssertEqual(TweakCompatibility.suggestedSemanticVersion("beta"), "1.0.0")
    }
}

/// Install and uninstall planning with versions, macOS limits and depends, in a temporary engine folder.
final class TweakInstallCompatibilityTests: XCTestCase {
    var root: URL!
    var src: URL!
    var loc: TweakLocations!
    let template = try! TweakTemplate(name: "MyTweak", identifier: "local.mytweak")

    override func setUpWithError() throws {
        let tmp = try temporaryDirectory()
        root = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)!))
        loc = .sandbox(root: root.appendingPathComponent("engine"))
        for d in [loc.dylibFileDirectory, (loc.configPath as NSString).deletingLastPathComponent] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        try Fixtures.text("live.conf").write(toFile: loc.configPath, atomically: true, encoding: .utf8)
        src = root.appendingPathComponent("MyTweak")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("build"), withIntermediateDirectories: true)
        try writeSource()
        try FakeMachO.universal.write(to: src.appendingPathComponent("build/libMyTweak.dylib"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func writeSource(_ change: (inout [String: Any]) -> Void = { _ in }) throws {
        var d = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(template.manifest.utf8), format: nil) as? [String: Any])
        change(&d)
        try manifestData(d).write(to: src.appendingPathComponent("MyTweak.workbench.plist"))
    }

    func plan(_ options: TweakInstallOptions = .init(systemVersion: SystemVersion("27.2")!)) throws -> TweakInstallPlan {
        try TweakInstaller.plan(source: try TweakSource.locate(src.path), enableFor: [], targets: Apps.targets(), locations: loc,
                                options: options)
    }

    func install(_ options: TweakInstallOptions = .init(systemVersion: SystemVersion("27.2")!)) throws {
        let w = ProtectedFileWriter(backups: BackupStore(root: root.appendingPathComponent("Backups")), executor: RecordingExecutor())
        _ = try TweakInstaller.execute(try plan(options), writer: w, restarter: SimulatedRestarter())
    }

    func testVersionChanges() throws {
        try writeSource { $0["version"] = "1.0.0" }
        var p = try plan()
        XCTAssertEqual(p.compatibility.change, .fresh("1.0.0"))
        XCTAssertEqual(p.summary.first, "New install: version 1.0.0")
        try install()

        try writeSource { $0["version"] = "1.1.0" }
        p = try plan()
        XCTAssertEqual(p.compatibility.change, .upgrade(from: SemanticVersion(1, 0, 0), to: SemanticVersion(1, 1, 0)))
        XCTAssertEqual(p.summary.first, "Installed 1.0.0 → new 1.1.0 (upgrade)")
        XCTAssertFalse(p.isRefused)

        try writeSource { $0["version"] = "1.0.0" }
        XCTAssertEqual(try plan().compatibility.change, .same("1.0.0"))
        try FakeMachO.make([FakeMachO.x86_64, FakeMachO.arm64, FakeMachO.arm64e], tag: "rebuilt").write(to: src.appendingPathComponent("build/libMyTweak.dylib"))
        p = try plan()
        XCTAssertEqual(p.compatibility.change, .rebuilt("1.0.0"))
        XCTAssertTrue(p.summary.first?.contains("rebuilt") == true)
        XCTAssertFalse(p.isRefused)

        try writeSource { $0["version"] = "0.9.0-beta.1" }
        p = try plan()
        XCTAssertEqual(p.summary.first, "Installed 1.0.0 → new 0.9.0-beta.1 (downgrade)")
        XCTAssertEqual(p.compatibility.refusals.map(\.kind), [.downgrade])
        XCTAssertEqual(p.compatibility.refusals.first?.override, "--allow-downgrade")
        XCTAssertThrowsError(try TweakInstaller.execute(p, writer: ProtectedFileWriter(backups: BackupStore(root: root), executor: RecordingExecutor()),
                                                        restarter: SimulatedRestarter())) { error in
            XCTAssertTrue(error.localizedDescription.contains("older than the installed 1.0.0"), error.localizedDescription)
        }
        XCTAssertEqual(TweakManifestLoader.load(directories: [loc.manifestsDirectory]).manifests.first?.version, "1.0.0", "nothing written")
        p = try plan(.init(allowDowngrade: true, systemVersion: SystemVersion("27.2")!))
        XCTAssertFalse(p.isRefused)
        XCTAssertTrue(p.warnings.contains { $0.hasPrefix("Installing anyway (--allow-downgrade)") }, "\(p.warnings)")

        try writeSource { $0["version"] = "2" }
        p = try plan()
        XCTAssertEqual(p.compatibility.change, .changed(from: "1.0.0", to: "2"))
        XCTAssertFalse(p.isRefused)
        XCTAssertTrue(p.warnings.contains { $0.contains("not a semantic version") })
    }

    func testSystemLimits() throws {
        try writeSource { $0["minimumSystemVersion"] = "27.0"; $0["testedSystemVersions"] = "27.0 - 27.2" }
        XCTAssertEqual(try plan().compatibility.refusals, [])
        XCTAssertEqual(try plan().compatibility.warnings, [])

        var p = try plan(.init(systemVersion: SystemVersion("26.4")!))
        XCTAssertEqual(p.compatibility.refusals.map(\.kind), [.systemTooOld])
        XCTAssertEqual(p.compatibility.refusals.first?.message, "MyTweak needs macOS 27.0 or later; this Mac runs 26.4.")
        XCTAssertTrue(p.compatibility.refusalText.contains("--force installs anyway"))
        p = try plan(.init(force: true, systemVersion: SystemVersion("26.4")!))
        XCTAssertFalse(p.isRefused)

        p = try plan(.init(systemVersion: SystemVersion("27.3")!))
        XCTAssertFalse(p.isRefused)
        XCTAssertTrue(p.warnings.contains { $0.contains("tested on macOS 27.0 – 27.2; this Mac runs 27.3") }, "\(p.warnings)")
    }

    func testDependencies() throws {
        try writeSource { $0["depends"] = ["local.lib >= 1.1.0", "safemode"]; $0["bridge"] = ["notify"] }
        let none: [BuiltInComponent: Bool] = [.bridge: false, .safemode: false]
        var p = try plan(.init(systemVersion: SystemVersion("27.2")!, components: none))
        XCTAssertEqual(p.compatibility.refusals.map(\.kind), [.unmetDependency, .unmetDependency, .unmetDependency])
        XCTAssertEqual(p.compatibility.refusals.map(\.fix), ["dw tweak install <local.lib's folder>", BuiltInComponent.safemode.fix,
                                                            BuiltInComponent.bridge.fix])

        // Install the library at 1.0.0 (too old), and the agents.
        try FileManager.default.createDirectory(atPath: loc.manifestsDirectory, withIntermediateDirectories: true)
        let lib: [String: Any] = ["formatVersion": 1, "identifier": "local.lib", "name": "Lib", "version": "1.0.0",
                                  "dylib": "/opt/dynject/lib/tweaks/libLib.dylib", "sections": [["items": [["type": "switch", "key": "x"]]]]]
        try manifestData(lib).write(to: URL(fileURLWithPath: loc.manifestsDirectory + "/Lib.workbench.plist"))
        let all: [BuiltInComponent: Bool] = [.bridge: true, .safemode: true]
        p = try plan(.init(systemVersion: SystemVersion("27.2")!, components: all))
        XCTAssertEqual(p.compatibility.refusals.map(\.message), ["MyTweak needs Lib (local.lib) 1.1.0 or later; 1.0.0 is installed."])
        p = try plan(.init(force: true, systemVersion: SystemVersion("27.2")!, components: all))
        XCTAssertFalse(p.isRefused)

        var newer = lib
        newer["version"] = "1.1.0"
        try manifestData(newer).write(to: URL(fileURLWithPath: loc.manifestsDirectory + "/Lib.workbench.plist"))
        XCTAssertFalse(try plan(.init(systemVersion: SystemVersion("27.2")!, components: all)).isRefused)
        try install(.init(systemVersion: SystemVersion("27.2")!, components: all))

        // Uninstalling the library: MyTweak depends on it.
        XCTAssertThrowsError(try TweakInstaller.planUninstall("local.lib", keepFile: true, locations: loc, safeMode: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("MyTweak (local.mytweak) depends on Lib"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("--force"))
        }
        let forced = try TweakInstaller.planUninstall("local.lib", keepFile: true, locations: loc, safeMode: nil, force: true)
        XCTAssertTrue(forced.notes.contains { $0.contains("MyTweak (local.mytweak) depends on it") }, "\(forced.notes)")
        XCTAssertNoThrow(try TweakInstaller.planUninstall("local.mytweak", keepFile: true, locations: loc, safeMode: nil))
    }
}
