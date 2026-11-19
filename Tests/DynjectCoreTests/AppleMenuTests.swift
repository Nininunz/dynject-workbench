@testable import DynjectCore
import XCTest

/// Parses a manifest with the given Apple-menu items (and a switch "on" plus a text "t" setting).
private func menuManifest(_ appleMenu: Any?, id: String = "com.test.a", name: String? = nil,
                          sections: [[String: Any]]? = nil) -> (TweakManifest?, [ManifestIssue]) {
    var d: [String: Any] = [
        "formatVersion": 1, "identifier": id, "dylib": "/d",
        "sections": sections ?? [["items": [["type": "switch", "key": "on"], ["type": "text", "key": "t"]]]],
    ]
    if let name { d["name"] = name }
    if let appleMenu { d["appleMenu"] = appleMenu }
    return TweakManifestParser.parse(data: manifestData(d), path: "/\(id).workbench.plist", fileExists: { _ in true })
}

private func item(_ id: String, _ action: String = "notify:x.y", _ extra: [String: Any] = [:]) -> [String: Any] {
    ["id": id, "title": "Title \(id)", "action": action].merging(extra) { _, b in b }
}

final class AppleMenuManifestTests: XCTestCase {
    func testExampleManifestDeclaresAppleMenuItems() {
        let m = exampleManifest()
        XCTAssertEqual(m.appleMenu.map(\.id), ["toggle", "help"])
        let toggle = m.appleMenu[0]
        XCTAssertEqual(toggle.action, .notify("com.example.windowtweak.toggle"))
        XCTAssertEqual(toggle.checkedBy, "enabled")
        XCTAssertEqual(toggle.symbol, "macwindow")
        XCTAssertEqual(toggle.keyEquivalent, "k")
        XCTAssertEqual(toggle.modifiers, [.control, .option, .command])
        XCTAssertEqual(toggle.shortcutDisplay, "⌃⌥⌘K")
        XCTAssertNil(toggle.apps)
        XCTAssertEqual(m.appleMenu[1].action, .url("https://example.com/windowtweak"))
        XCTAssertEqual(m.appleMenu[1].apps, ["com.apple.finder"])
    }

    func testManifestWithoutAppleMenuIsUnchanged() {
        let (m, issues) = menuManifest(nil)
        XCTAssertEqual(m?.appleMenu, [])
        XCTAssertEqual(issues, [])
    }

    func testValidItemsParse() {
        let (m, issues) = menuManifest([
            item("n", "notify:com.test.ping", ["checkedBy": "on", "keyEquivalent": "k", "modifiers": ["command", "option", "command"]]),
            item("u", "url:https://example.com/a?b=c", ["symbol": "link"]),
            item("s", "shortcut:My Thing & Co"),
            item("p", "app:com.apple.TextEdit", ["apps": ["com.apple.finder", "com.apple.finder", "com.apple.Notes"]]),
            item("m", "url:mailto:someone@example.com"),
        ])
        XCTAssertEqual(issues.map(\.message), [])
        let items = m!.appleMenu
        XCTAssertEqual(items.map(\.id), ["n", "u", "s", "p", "m"])
        XCTAssertEqual(items[0].checkedBy, "on")
        XCTAssertEqual(items[0].modifiers, [.command, .option])
        XCTAssertEqual(items[1].symbol, "link")
        XCTAssertEqual(items[2].action, .shortcut("My Thing & Co"))
        XCTAssertEqual(items[2].action.openURL?.absoluteString, "shortcuts://run-shortcut?name=My%20Thing%20%26%20Co")
        XCTAssertEqual(items[3].action, .app("com.apple.TextEdit"))
        XCTAssertEqual(items[3].apps, ["com.apple.finder", "com.apple.Notes"])
        XCTAssertEqual(items[0].plistDictionary as NSDictionary, [
            "id": "n", "title": "Title n", "action": "notify:com.test.ping", "checkedBy": "on",
            "keyEquivalent": "k", "modifiers": ["command", "option"],
        ] as NSDictionary)
    }

    func testInvalidItemsAreSkippedWithDiagnostics() {
        let (m, issues) = menuManifest([
            "not a dict",
            ["title": "No id", "action": "notify:a"],
            ["id": "noTitle", "action": "notify:a"],
            ["id": "noAction", "title": "x"],
            item("ok"),
            item("ok", "notify:other"),
            item("scheme", "run:thing"),
            item("bare", "hello"),
            item("badURL", "url:not a url"),
            item("noHost", "url:https://"),
            item("emptyNotify", "notify:"),
            item("spaceNotify", "notify:a b"),
            item("emptyApp", "app:"),
            item("badApp", "app:not a bundle"),
            item("emptyShortcut", "shortcut:  "),
            item("emptyApps", "notify:a", ["apps": []]),
            item("badApps", "notify:a", ["apps": [""]]),
            item("appsString", "notify:a", ["apps": "com.apple.finder"]),
        ])
        XCTAssertEqual(m?.appleMenu.map(\.id), ["ok"])
        XCTAssertTrue(issues.allSatisfy { $0.severity == .error })
        let text = issues.map(\.message).joined(separator: "\n")
        for needle in ["appleMenu[0]: must be a dictionary", "appleMenu[1]: id is required", "\"noTitle\": title is required",
                       "\"noAction\": action is required", "\"ok\": duplicate id", "unknown action scheme \"run\"",
                       "\"hello\" needs a scheme", "\"not a url\" is not an absolute URL", "\"https://\" is not an absolute URL",
                       "nothing after \"notify:\"", "must not contain spaces", "nothing after \"app:\"",
                       "\"not a bundle\" is not a bundle ID", "nothing after \"shortcut:\"",
                       "\"emptyApps\": apps must be", "\"badApps\": apps must be", "\"appsString\": apps must be"] {
            XCTAssertTrue(text.contains(needle), "missing: \(needle)\n\(text)")
        }
        XCTAssertEqual(issues.count, 17)
    }

    func testBadOptionalFieldsAreIgnoredButItemKept() {
        let (m, issues) = menuManifest([
            item("textCheck", "notify:a", ["checkedBy": "t"]),
            item("missingCheck", "notify:a", ["checkedBy": "missing"]),
            item("longKey", "notify:a", ["keyEquivalent": "ab"]),
            item("spaceKey", "notify:a", ["keyEquivalent": " "]),
            item("badMods", "notify:a", ["keyEquivalent": "k", "modifiers": ["command", "hyper"]]),
            item("modsOnly", "notify:a", ["modifiers": ["command"]]),
            item("badSymbol", "notify:a", ["symbol": 3]),
        ])
        let items = m!.appleMenu
        XCTAssertEqual(items.map(\.id), ["textCheck", "missingCheck", "longKey", "spaceKey", "badMods", "modsOnly", "badSymbol"])
        XCTAssertTrue(items.allSatisfy { $0.checkedBy == nil && $0.keyEquivalent == nil && $0.modifiers == nil && $0.symbol == nil })
        let errors = issues.filter { $0.severity == .error }.map(\.message).joined(separator: "\n")
        for needle in ["\"textCheck\": checkedBy \"t\" is not a switch", "\"missingCheck\": checkedBy \"missing\" is not a switch",
                       "\"longKey\": keyEquivalent must be a single", "\"spaceKey\": keyEquivalent must be a single",
                       "\"badMods\": modifiers must be", "keyEquivalent and modifiers ignored", "\"badSymbol\": symbol must be"] {
            XCTAssertTrue(errors.contains(needle), "missing: \(needle)\n\(errors)")
        }
        XCTAssertEqual(issues.filter { $0.severity == .warning }.map(\.message), ["appleMenu[5] \"modsOnly\": modifiers without keyEquivalent; ignored."])
    }

    func testShortcutsWithoutCommandAreRejected() {
        // The Apple menu is checked for key equivalents in every app before the focused view gets the key, so these
        // would take a plain key, an Option character ('@' on a German layout), a Shift letter or a Control key
        // that text views and terminals use (⌃A, ⌃E, ⌃K) from typing.
        let (m, issues) = menuManifest([
            item("none", "notify:a", ["keyEquivalent": "e", "modifiers": []]),
            item("option", "notify:a", ["keyEquivalent": "l", "modifiers": ["option"]]),
            item("shift", "notify:a", ["keyEquivalent": "9", "modifiers": ["shift"]]),
            item("optShift", "notify:a", ["keyEquivalent": "k", "modifiers": ["option", "shift"]]),
            item("upperOption", "notify:a", ["keyEquivalent": "K", "modifiers": ["option"]]),
            item("control", "notify:a", ["keyEquivalent": "k", "modifiers": ["control"]]),
            item("ctrlOpt", "notify:a", ["keyEquivalent": "k", "modifiers": ["control", "option"]]),
            item("default", "notify:a", ["keyEquivalent": "y"]),
            item("ctrlCmd", "notify:a", ["keyEquivalent": "k", "modifiers": ["control", "command"]]),
        ])
        let items = Dictionary(uniqueKeysWithValues: m!.appleMenu.map { ($0.id, $0) })
        XCTAssertEqual(items.count, 9, "items are kept, only the shortcut is dropped")
        for id in ["none", "option", "shift", "optShift", "upperOption", "control", "ctrlOpt"] {
            XCTAssertNil(items[id]?.keyEquivalent, id)
            XCTAssertNil(items[id]?.modifiers, id)
            XCTAssertNil(items[id]?.plistDictionary["keyEquivalent"], id)
        }
        XCTAssertEqual(items["default"]?.shortcutDisplay, "⌘Y")
        XCTAssertEqual(items["ctrlCmd"]?.shortcutDisplay, "⌃⌘K")
        let errors = issues.filter { $0.severity == .error }.map(\.message)
        XCTAssertEqual(errors.count, 7, errors.joined(separator: "\n"))
        for needle in ["\"none\": shortcut E needs command", "\"option\": shortcut ⌥L needs command",
                       "\"shift\": shortcut ⇧9 needs", "\"optShift\": shortcut ⌥⇧K needs", "\"upperOption\": shortcut ⌥⇧K needs",
                       "\"control\": shortcut ⌃K needs command", "\"ctrlOpt\": shortcut ⌃⌥K needs command"] {
            XCTAssertTrue(errors.contains { $0.contains(needle) }, "missing: \(needle)\n\(errors)")
        }
    }

    func testFunctionKeysAndInvisibleCharactersAreNotKeyEquivalents() {
        let bad = ["\u{F700}", "\u{F704}", "\u{F728}", "\u{E000}", "\u{F0000}", "\u{7F}", "\u{1B}", "\u{200B}", "\u{00A0}", "\u{2028}", "\t"]
        let good = [",", "1", "é", "ß", "/"]
        let (m, issues) = menuManifest((bad + good).enumerated().map { i, k in item("k\(i)", "notify:a", ["keyEquivalent": k]) })
        let keys = m!.appleMenu.map(\.keyEquivalent)
        XCTAssertEqual(keys, bad.map { _ in nil } + good.map { Optional($0) })
        XCTAssertEqual(issues.filter { $0.severity == .error }.count, bad.count)
        XCTAssertTrue(issues.allSatisfy { $0.severity == .warning || $0.message.contains("keyEquivalent must be a single visible character") })
    }

    func testShiftLettersArePublishedUppercaseWithShift() {
        // AppKit: "J" is ⇧⌘J; "j" with a Shift mask is matched as plain ⌘J. Both sides use "J" + shift.
        let (m, issues) = menuManifest([
            item("cmd", "notify:a", ["keyEquivalent": "J", "modifiers": ["command"]]),
            item("implicit", "notify:a", ["keyEquivalent": "K"]),
            item("upperShift", "notify:a", ["keyEquivalent": "L", "modifiers": ["shift", "command"]]),
            item("lowerShift", "notify:a", ["keyEquivalent": "m", "modifiers": ["shift", "control", "command"]]),
            item("digitShift", "notify:a", ["keyEquivalent": "1", "modifiers": ["shift", "command"]]),
            item("lower", "notify:a", ["keyEquivalent": "j", "modifiers": ["command"]]),
        ])
        let items = m!.appleMenu
        XCTAssertEqual(items.map(\.keyEquivalent), ["J", "K", "L", "M", "1", "j"])
        XCTAssertEqual(items.map(\.shortcutDisplay), ["⇧⌘J", "⇧⌘K", "⇧⌘L", "⌃⇧⌘M", "⇧⌘1", "⌘J"])
        XCTAssertEqual(items[0].modifiers, [.command, .shift])
        XCTAssertEqual(items[1].modifiers, [.command, .shift])
        XCTAssertEqual(items[2].modifiers, [.shift, .command])
        XCTAssertEqual(items[3].modifiers, [.shift, .control, .command])
        XCTAssertEqual(items[0].plistDictionary["modifiers"] as? [String], ["command", "shift"])
        XCTAssertEqual(items[3].plistDictionary["keyEquivalent"] as? String, "M")
        let warnings = issues.filter { $0.severity == .warning }.map(\.message)
        XCTAssertEqual(warnings.count, 2, warnings.joined(separator: "\n"))
        XCTAssertTrue(warnings[0].contains("\"cmd\": keyEquivalent \"J\" is uppercase, which AppKit treats as ⇧⌘J"), warnings[0])
        XCTAssertTrue(warnings[0].contains("For ⌘J use \"j\""), warnings[0])
        XCTAssertTrue(warnings[1].contains("\"implicit\""), warnings[1])
        XCTAssertFalse(issues.contains { $0.severity == .error })
        // An item made in code (or read from an old list) shows the Shift AppKit adds for an uppercase letter.
        XCTAssertEqual(AppleMenuItem(id: "x", title: "x", action: .notify("x"), keyEquivalent: "J", modifiers: [.command]).shortcutDisplay, "⇧⌘J")
    }

    func testCommonAppShortcutsWarnAndKeepTheShortcut() {
        let (m, issues) = menuManifest([
            item("close", "notify:a", ["keyEquivalent": "w"]),
            item("settings", "notify:a", ["keyEquivalent": ",", "modifiers": ["command"]]),
            item("lock", "notify:a", ["keyEquivalent": "q", "modifiers": ["control", "command"]]),
            item("free", "notify:a", ["keyEquivalent": "k", "modifiers": ["option", "command"]]),
        ])
        let items = m!.appleMenu
        XCTAssertEqual(items.map(\.shortcutDisplay), ["⌘W", "⌘,", "⌃⌘Q", "⌥⌘K"])
        XCTAssertEqual(items[0].shortcutCaveat, "⌘W is the standard Close shortcut; apps that have it keep it.")
        XCTAssertEqual(items[2].shortcutCaveat, "⌃⌘Q is the Apple menu's own Lock Screen; apps that have it keep it.")
        XCTAssertNil(items[3].shortcutCaveat)
        let warnings = issues.filter { $0.severity == .warning }.map(\.message)
        XCTAssertEqual(warnings.count, 3, warnings.joined(separator: "\n"))
        XCTAssertTrue(warnings[0].contains("\"close\": ⌘W is the standard Close shortcut"), warnings[0])
        XCTAssertTrue(warnings[1].contains("\"settings\": ⌘, is the standard Settings shortcut"), warnings[1])
        XCTAssertFalse(issues.contains { $0.severity == .error })
    }

    func testAppleMenuMustBeAnArray() {
        let (m, issues) = menuManifest(["id": "x"])
        XCTAssertEqual(m?.appleMenu, [])
        XCTAssertEqual(issues.map(\.message), ["appleMenu must be an array of items; ignored."])
    }

    func testMenuOnlyManifestIsNotReportedAsEmpty() {
        let (m, issues) = menuManifest([item("a")], sections: [])
        XCTAssertEqual(m?.appleMenu.count, 1)
        XCTAssertEqual(issues, [])
        // Still warned when there is neither.
        XCTAssertEqual(menuManifest(nil, sections: []).1.map(\.message), ["No usable settings items."])
    }
}

final class MenuLoaderPublisherTests: XCTestCase {
    func manifests() -> [TweakManifest] {
        [
            menuManifest([item("z1"), item("z2", "url:https://example.com")], id: "com.test.zeta", name: "Zeta").0!,
            menuManifest(nil, id: "com.test.none", name: "No Menu").0!,
            // Invalid items are dropped by the parser and so never published.
            menuManifest([item("a1", "bogus:1"), item("a2", "app:com.apple.Notes", ["apps": ["com.apple.finder"]])], id: "com.test.alpha", name: "alpha").0!,
            menuManifest([item("b1")], id: "com.test.alpha2", name: "Alpha").0!,
        ]
    }

    func testPayloadSortsByTweakNameThenManifestOrder() {
        let p = MenuLoaderPublisher.payload(for: manifests(), settings: MenuLoaderSettings())!
        XCTAssertEqual(p["formatVersion"] as? Int, 1)
        XCTAssertEqual(p["placement"] as? String, "submenu")
        XCTAssertEqual(p["submenuTitle"] as? String, "Dynject")
        let items = p["items"] as! [[String: Any]]
        // "alpha" and "Alpha" compare equal ignoring case; the identifier breaks the tie.
        XCTAssertEqual(items.map { $0["id"] as! String }, ["a2", "b1", "z1", "z2"])
        XCTAssertEqual(items.map { $0["tweakID"] as! String }, ["com.test.alpha", "com.test.alpha2", "com.test.zeta", "com.test.zeta"])
        XCTAssertEqual(items.map { $0["tweakName"] as! String }, ["alpha", "Alpha", "Zeta", "Zeta"])
        XCTAssertEqual(items[0] as NSDictionary, [
            "id": "a2", "title": "Title a2", "action": "app:com.apple.Notes", "apps": ["com.apple.finder"],
            "tweakID": "com.test.alpha", "tweakName": "alpha",
        ] as NSDictionary)
        XCTAssertTrue(PropertyListSerialization.propertyList(p, isValidFor: .binary))
    }

    func testCheckedByPublishesTheSwitchDefault() {
        let sections: [[String: Any]] = [["items": [["type": "switch", "key": "on", "default": true], ["type": "switch", "key": "off"]]]]
        let m = menuManifest([item("c1", "notify:x.y", ["checkedBy": "on"]), item("c2", "notify:x.y", ["checkedBy": "off"]), item("c3")],
                             sections: sections).0!
        let items = MenuLoaderPublisher.payload(for: [m], settings: MenuLoaderSettings())!["items"] as! [[String: Any]]
        // MenuLoader's fallback while the tweak has no settings payload, matching Workbench's effective value.
        XCTAssertEqual(items.map { $0["checkedByDefault"] as? Bool }, [true, false, nil])
    }

    func testDuplicateShortcutsKeepTheFirstInPublishedOrder() {
        let all = [
            menuManifest([item("b1", "notify:a", ["keyEquivalent": "j"]),
                          item("b2", "notify:a", ["keyEquivalent": "j", "apps": ["com.x"]])], id: "com.test.beta", name: "Beta").0!,
            menuManifest([item("a1", "notify:a", ["keyEquivalent": "j", "modifiers": ["command"]]),
                          // a2 and a3 are both ⇧⌘K.
                          item("a2", "notify:a", ["keyEquivalent": "k", "modifiers": ["shift", "command"]]),
                          item("a3", "notify:a", ["keyEquivalent": "K"])], id: "com.test.alpha", name: "Alpha").0!,
            menuManifest([item("g1", "notify:a", ["keyEquivalent": "j", "modifiers": ["option", "command"], "apps": ["com.y"]]),
                          item("g2", "notify:a", ["keyEquivalent": "j", "modifiers": ["option", "command"], "apps": ["com.z"]]),
                          item("g3", "notify:a", ["keyEquivalent": "j", "modifiers": ["option", "command"], "apps": ["com.w", "com.y"]])],
                         id: "com.test.gamma", name: "Gamma").0!,
        ]
        let items = MenuLoaderPublisher.payload(for: all, settings: MenuLoaderSettings())!["items"] as! [[String: Any]]
        XCTAssertEqual(items.map { $0["id"] as! String }, ["a1", "a2", "a3", "b1", "b2", "g1", "g2", "g3"])
        XCTAssertEqual(items.map { $0["keyEquivalent"] as? String }, ["j", "K", nil, nil, nil, "j", "j", nil])
        XCTAssertTrue(items.filter { $0["keyEquivalent"] == nil }.allSatisfy { $0["modifiers"] == nil })
        let conflicts = MenuLoaderPublisher.shortcutConflicts(for: all, settings: MenuLoaderSettings())
        XCTAssertEqual(conflicts.map(\.itemID), ["a3", "b1", "b2", "g3"])
        XCTAssertEqual(conflicts[1].message, "Shortcut ⌘J not published: \"Title a1\" (Alpha) already uses it.")
        XCTAssertEqual(conflicts[0].shortcut, "⇧⌘K")
        // Turning off the tweak that had it gives the shortcut to the next one.
        var s = MenuLoaderSettings()
        s.included["com.test.alpha"] = false
        XCTAssertEqual(MenuLoaderPublisher.items(for: all, settings: s).map(\.1.keyEquivalent), ["j", nil, "j", "j", nil])
    }

    func testIncludeFlagPlacementAndTitle() {
        var s = MenuLoaderSettings()
        s.included["com.test.zeta"] = false
        s.placement = .section
        s.submenuTitle = "   "
        let p = MenuLoaderPublisher.payload(for: manifests(), settings: s)!
        XCTAssertEqual((p["items"] as! [[String: Any]]).map { $0["id"] as! String }, ["a2", "b1"])
        XCTAssertEqual(p["placement"] as? String, "section")
        XCTAssertEqual(p["submenuTitle"] as? String, "Dynject")
        s.submenuTitle = "Tweaks"
        XCTAssertEqual(MenuLoaderPublisher.payload(for: manifests(), settings: s)!["submenuTitle"] as? String, "Tweaks")

        s.included = ["com.test.zeta": false, "com.test.alpha": false, "com.test.alpha2": false]
        XCTAssertNil(MenuLoaderPublisher.payload(for: manifests(), settings: s))
        XCTAssertNil(MenuLoaderPublisher.payload(for: [], settings: MenuLoaderSettings()))
    }

    func testPublishWritesAndNotifiesOnlyOnChange() throws {
        let backend = MemoryTweakBackend()
        let publisher = MenuLoaderPublisher(store: backend, names: .test)
        var s = MenuLoaderSettings()

        XCTAssertTrue(try publisher.publish(manifests(), settings: s))
        XCTAssertEqual(backend.writes, 1)
        XCTAssertEqual(backend.notifications, ["dynject.menuloader.test.changed"])
        XCTAssertEqual(Array(backend.keyed.keys), ["dynject.menuloader.test"])
        XCTAssertEqual(backend.store.count, 0)   // tweak payloads untouched
        XCTAssertEqual(backend.posted, [])

        XCTAssertFalse(try publisher.publish(manifests(), settings: s))
        XCTAssertEqual(backend.writes, 1)
        XCTAssertEqual(backend.notifications.count, 1)

        s.placement = .section
        XCTAssertTrue(try publisher.publish(manifests(), settings: s))
        XCTAssertEqual(backend.keyed["dynject.menuloader.test"]?["placement"] as? String, "section")

        s.included["com.test.zeta"] = false
        XCTAssertTrue(try publisher.publish(manifests(), settings: s))
        XCTAssertEqual((backend.keyed["dynject.menuloader.test"]?["items"] as? [Any])?.count, 2)

        // Nothing left to show: the key is removed (once).
        XCTAssertTrue(try publisher.publish([], settings: s))
        XCTAssertNil(backend.keyed["dynject.menuloader.test"])
        XCTAssertFalse(try publisher.publish([], settings: s))
        XCTAssertEqual(backend.writes, 4)
        XCTAssertEqual(backend.notifications.count, 4)
    }

    func testNoItemsAndNothingPublishedWritesNothing() throws {
        let backend = MemoryTweakBackend()
        XCTAssertFalse(try MenuLoaderPublisher(store: backend, names: .test).publish([menuManifest(nil).0!], settings: MenuLoaderSettings()))
        XCTAssertEqual(backend.writes, 0)
        XCTAssertEqual(backend.notifications, [])
    }

    func testFileBackendSharesTheFixtureFile() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = FileTweakBackend(path: dir.appendingPathComponent("prefs.plist").path)
        let m = exampleManifest()
        let settings = TweakSettings(manifest: m, backend: backend)
        settings.set(.number(3), for: m.item("radius")!)
        try settings.persist()
        let publisher = MenuLoaderPublisher(store: backend, names: .test)
        XCTAssertTrue(try publisher.publish([m], settings: MenuLoaderSettings()))
        XCTAssertFalse(try MenuLoaderPublisher(store: FileTweakBackend(path: backend.path), names: .test).publish([m], settings: MenuLoaderSettings()))
        XCTAssertEqual(backend.posted, ["dynject.tweak.com.example.windowtweak.changed", "dynject.menuloader.test.changed"])
        XCTAssertNotNil(backend.payload(for: m.id))
        XCTAssertEqual((publisher.currentPayload()?["items"] as? [[String: Any]])?.map { $0["id"] as? String }, ["toggle", "help"])
    }

    /// Unchanged detection must survive a real CFPreferences round trip (number and boolean bridging).
    func testUnchangedDetectionThroughCFPreferences() throws {
        // A private test domain, never the global one, and the test key, never the production key.
        let domain = "local.dynject.workbench.tests"
        let prefsFile = NSHomeDirectory() + "/Library/Preferences/\(domain).plist"
        let names = MenuLoaderNames.test
        defer {
            CFPreferencesSetValue(names.key as CFString, nil, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            try? FileManager.default.removeItem(atPath: prefsFile)
        }
        let backend = CFPreferencesTweakBackend(domain: domain as CFString)
        try backend.setDictionary(nil, forKey: names.key)
        let publisher = MenuLoaderPublisher(store: backend, names: names)
        XCTAssertTrue(try publisher.publish([exampleManifest()], settings: MenuLoaderSettings()))
        let fresh = MenuLoaderPublisher(store: CFPreferencesTweakBackend(domain: domain as CFString), names: names)
        XCTAssertFalse(try fresh.publish([exampleManifest()], settings: MenuLoaderSettings()))
        XCTAssertEqual(fresh.currentPayload()?["formatVersion"] as? Int, 1)
    }

    func testContractNamesAndSettingsDecoding() throws {
        XCTAssertEqual(MenuLoaderNames.production, MenuLoaderNames(key: "dynject.menuloader", notification: "dynject.menuloader.changed"))
        XCTAssertEqual(MenuLoaderNames.test, MenuLoaderNames(key: "dynject.menuloader.test", notification: "dynject.menuloader.test.changed"))
        let empty = try JSONDecoder().decode(MenuLoaderSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, MenuLoaderSettings())
        XCTAssertTrue(empty.isIncluded("anything"))
        let odd = try JSONDecoder().decode(MenuLoaderSettings.self, from: Data(#"{"placement":"sideways","included":{"a":false}}"#.utf8))
        XCTAssertEqual(odd.placement, .submenu)
        XCTAssertFalse(odd.isIncluded("a"))
        var s = MenuLoaderSettings()
        s.included["x"] = false
        s.placement = .section
        XCTAssertEqual(try JSONDecoder().decode(MenuLoaderSettings.self, from: JSONEncoder().encode(s)), s)
    }
}
