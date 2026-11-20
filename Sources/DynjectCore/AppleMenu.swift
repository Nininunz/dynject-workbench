import Foundation

// MenuLoader: tweaks declare Apple-menu items in their manifest ("appleMenu"); Workbench publishes the
// combined list to the global preferences domain; one small injected tweak (Tweaks/MenuLoader) reads it and
// adds the items to the Apple menu. Contract: docs/tweak-format.md, "Apple menu items (MenuLoader)".

/// One item a tweak declares for the Apple menu.
public struct AppleMenuItem: Identifiable, Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Posts a Darwin notification (allowed from sandboxed apps).
        case notify(String)
        /// Opens an absolute URL with NSWorkspace.
        case url(String)
        /// Runs a Shortcut by name (shortcuts://run-shortcut?name=…).
        case shortcut(String)
        /// Launches or activates an app by bundle ID.
        case app(String)

        public static let schemes = ["notify", "url", "shortcut", "app"]

        /// The published form, `<scheme>:<value>`.
        public var rawValue: String {
            switch self {
            case let .notify(v): return "notify:\(v)"
            case let .url(v): return "url:\(v)"
            case let .shortcut(v): return "shortcut:\(v)"
            case let .app(v): return "app:\(v)"
            }
        }

        /// The URL MenuLoader opens for `url:` and `shortcut:` actions.
        public var openURL: URL? {
            switch self {
            case let .url(v): return URL(string: v)
            case let .shortcut(name):
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "&=+?#/")
                let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
                return URL(string: "shortcuts://run-shortcut?name=\(encoded)")
            case .notify, .app: return nil
            }
        }

        public var summary: String {
            switch self {
            case let .notify(v): return "Posts notification \(v)"
            case let .url(v): return "Opens \(v)"
            case let .shortcut(v): return "Runs the Shortcut \"\(v)\""
            case let .app(v): return "Opens \(v)"
            }
        }
    }

    public enum Modifier: String, Sendable, CaseIterable {
        case command, option, shift, control

        public var symbol: String {
            switch self {
            case .control: return "⌃"
            case .option: return "⌥"
            case .shift: return "⇧"
            case .command: return "⌘"
            }
        }
    }

    public var id: String
    public var title: String
    public var action: Action
    public var symbol: String?
    /// Show only inside these apps (bundle IDs). nil = every app.
    public var apps: [String]?
    /// Key of a switch setting of this tweak; the item shows a checkmark while it is on.
    public var checkedBy: String?
    public var keyEquivalent: String?
    /// nil = not given (MenuLoader decides); [] = explicitly no modifiers.
    public var modifiers: [Modifier]?

    /// The modifiers the shortcut really uses: the declared ones (command when none are given), plus shift for an
    /// uppercase letter, which AppKit reads as shift+letter. nil without a keyEquivalent.
    public var effectiveModifiers: Set<Modifier>? {
        guard let k = keyEquivalent else { return nil }
        var mods = Set(modifiers ?? [.command])
        if k.lowercased() != k, k.uppercased() == k { mods.insert(.shift) }
        return mods
    }

    /// "⌥⌘K", for display.
    public var shortcutDisplay: String? {
        guard let k = keyEquivalent, let mods = effectiveModifiers else { return nil }
        return Self.display(key: k, modifiers: mods)
    }

    /// Identifies a shortcut as AppKit matches it: lowercase key and modifier set.
    public var shortcutIdentity: String? {
        guard let k = keyEquivalent, let mods = effectiveModifiers else { return nil }
        return Self.display(key: k.lowercased(), modifiers: mods)
    }

    static func display<S: Sequence>(key: String, modifiers: S) -> String where S.Element == Modifier {
        let order: [Modifier] = [.control, .option, .shift, .command]
        let mods = Set(modifiers)
        return order.filter(mods.contains).map(\.symbol).joined() + key.uppercased()
    }

    /// Shortcuts that most apps (or the Apple menu itself) already use. In an app that has one, AppKit keeps the
    /// app's and clears the Apple-menu item's, so such a shortcut only works in apps without it.
    static let commonShortcuts: [String: String] = [
        "⌘Q": "Quit", "⌘W": "Close", "⌥⌘W": "Close All", "⌘H": "Hide", "⌥⌘H": "Hide Others", "⌘M": "Minimize",
        "⌘,": "Settings", "⌘N": "New", "⌘O": "Open", "⌘S": "Save", "⇧⌘S": "Save As/Duplicate", "⌘P": "Print",
        "⇧⌘P": "Page Setup", "⌘Z": "Undo", "⇧⌘Z": "Redo", "⌘X": "Cut", "⌘C": "Copy", "⌘V": "Paste",
        "⌥⇧⌘V": "Paste and Match Style", "⌘A": "Select All", "⌘F": "Find", "⌘G": "Find Next", "⇧⌘G": "Find Previous",
        "⌘E": "Use Selection for Find", "⌘T": "Show Fonts/New Tab", "⌘B": "Bold", "⌘I": "Italic", "⌘U": "Underline",
        "⌃⌘F": "Enter Full Screen", "⇧⌘/": "Help", "⇧⌘?": "Help", "⌘`": "Cycle Windows",
        "⌃⌘Q": "the Apple menu's own Lock Screen", "⇧⌘Q": "the Apple menu's own Log Out", "⌥⇧⌘Q": "the Apple menu's own Log Out",
    ]

    /// For display next to the shortcut: why it may not work everywhere, nil when nothing is known against it.
    public var shortcutCaveat: String? {
        guard let k = keyEquivalent, let mods = effectiveModifiers, let use = Self.commonShortcutUse(key: k, modifiers: mods) else { return nil }
        return "\(Self.display(key: k, modifiers: mods)) is \(use); apps that have it keep it."
    }

    /// "the standard Close shortcut" for ⌘W, nil for a shortcut apps don't commonly use.
    static func commonShortcutUse<S: Sequence>(key: String, modifiers: S) -> String? where S.Element == Modifier {
        guard let use = commonShortcuts[display(key: key.lowercased(), modifiers: modifiers)] else { return nil }
        return use.hasPrefix("the ") ? use : "the standard \(use) shortcut"
    }

    /// The item as published, without the tweak fields.
    public var plistDictionary: [String: Any] {
        var d: [String: Any] = ["id": id, "title": title, "action": action.rawValue]
        if let symbol { d["symbol"] = symbol }
        if let apps { d["apps"] = apps }
        if let checkedBy { d["checkedBy"] = checkedBy }
        if let keyEquivalent { d["keyEquivalent"] = keyEquivalent }
        if let modifiers { d["modifiers"] = modifiers.map(\.rawValue) }
        return d
    }
}

/// Where MenuLoader puts a tweak's items (manifest key `appleMenuPlacement`).
public enum AppleMenuPlacement: String, Sendable, CaseIterable {
    /// The tweak's own entry, "<title> ▸", after the App Store section.
    case submenu
    /// One section of the shared entry ("Tweaks" unless the user renamed it). The default.
    case shared
}

enum AppleMenuParser {
    static let bundleIDPattern = "^[A-Za-z0-9][A-Za-z0-9.-]*$"

    /// The manifest's top-level `appleMenuPlacement`, `appleMenuTitle` and `appleMenuSymbol`. Bad values are
    /// ignored with an error (the defaults apply); without `appleMenu` items they mean nothing and get a warning.
    static func parseGroup(_ root: [String: Any], hasItems: Bool, error: (String) -> Void, warning: (String) -> Void)
        -> (placement: AppleMenuPlacement, title: String?, symbol: String?) {
        let keys = ["appleMenuPlacement", "appleMenuTitle", "appleMenuSymbol"].filter { root[$0] != nil }
        guard hasItems else {
            if !keys.isEmpty { warning("\(keys.joined(separator: ", ")) without appleMenu items; ignored.") }
            return (.shared, nil, nil)
        }
        var placement = AppleMenuPlacement.shared
        if let raw = root["appleMenuPlacement"] {
            if let v = (raw as? String).flatMap(AppleMenuPlacement.init(rawValue:)) { placement = v } else {
                error("appleMenuPlacement must be \(AppleMenuPlacement.allCases.map(\.rawValue).joined(separator: " or ")); using shared.")
            }
        }
        var title: String?
        if let raw = root["appleMenuTitle"] {
            let t = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if t.isEmpty { error("appleMenuTitle must be a non-empty string; ignored.") } else { title = t }
        }
        var symbol: String?
        if let raw = root["appleMenuSymbol"] {
            if let v = raw as? String, !v.isEmpty { symbol = v } else { error("appleMenuSymbol must be an SF Symbol name; ignored.") }
        }
        return (placement, title, symbol)
    }

    /// Parses the manifest's `appleMenu` array. Broken items are skipped and broken optional fields ignored,
    /// each with an error, so the rest of the manifest keeps working.
    static func parse(_ raw: Any?, switchKeys: Set<String>, error: (String) -> Void, warning: (String) -> Void) -> [AppleMenuItem] {
        guard let raw else { return [] }
        guard let array = raw as? [Any] else {
            error("appleMenu must be an array of items; ignored.")
            return []
        }
        var items: [AppleMenuItem] = []
        var seen = Set<String>()
        for (i, element) in array.enumerated() {
            let at = "appleMenu[\(i)]"
            guard let d = element as? [String: Any] else { error("\(at): must be a dictionary; skipped."); continue }
            guard let id = d["id"] as? String, !id.trimmingCharacters(in: .whitespaces).isEmpty else {
                error("\(at): id is required; skipped.")
                continue
            }
            let label = "\(at) \"\(id)\""
            guard let title = d["title"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
                error("\(label): title is required; skipped.")
                continue
            }
            guard let rawAction = d["action"] as? String else {
                error("\(label): action is required (\(AppleMenuItem.Action.schemes.map { "\($0):…" }.joined(separator: ", "))); skipped.")
                continue
            }
            guard let action = parseAction(rawAction, at: label, error: error) else { continue }
            guard seen.insert(id).inserted else { error("\(label): duplicate id; skipped."); continue }

            var item = AppleMenuItem(id: id, title: title, action: action)

            if let s = d["symbol"] {
                if let s = s as? String, !s.isEmpty { item.symbol = s } else { error("\(label): symbol must be an SF Symbol name; ignored.") }
            }

            if let a = d["apps"] {
                guard let ids = a as? [String], !ids.isEmpty,
                      ids.allSatisfy({ $0.range(of: bundleIDPattern, options: .regularExpression) != nil }) else {
                    // Showing an app-specific item everywhere would be wrong, so skip the whole item.
                    error("\(label): apps must be a non-empty array of bundle IDs; skipped.")
                    continue
                }
                var unique = Set<String>()
                item.apps = ids.filter { unique.insert($0).inserted }
            }

            if let c = d["checkedBy"] {
                if let key = c as? String, switchKeys.contains(key) {
                    item.checkedBy = key
                } else {
                    error("\(label): checkedBy \"\(c)\" is not a switch setting in this manifest; ignored.")
                }
            }

            parseShortcut(key: d["keyEquivalent"], modifiers: d["modifiers"], into: &item, label: label, error: error, warning: warning)
            items.append(item)
        }
        return items
    }

    /// Characters that never make a key equivalent: whitespace, control and format characters, surrogates and
    /// private-use characters, which include AppKit's function keys (arrows, F-keys, Delete: U+F700–U+F8FF).
    static func isKeyEquivalentCharacter(_ k: String) -> Bool {
        guard k.count == 1 else { return false }
        return k.unicodeScalars.allSatisfy { s in
            if CharacterSet.whitespacesAndNewlines.contains(s) || CharacterSet.controlCharacters.contains(s) { return false }
            switch s.properties.generalCategory {
            case .control, .format, .privateUse, .surrogate, .spaceSeparator, .lineSeparator, .paragraphSeparator: return false
            default: return true
            }
        }
    }

    /// keyEquivalent and modifiers. MenuLoader puts the items in the Apple menu, which AppKit checks for key
    /// equivalents in every app before the key reaches the focused view, so a shortcut must use command or
    /// control: a bare key, shift+key or option+key (how accented characters are typed) would be taken from typing
    /// in every app. A shift letter is published as the uppercase letter with shift, the form AppKit matches.
    /// MenuLoader applies the same rules to the published list.
    static func parseShortcut(key rawKey: Any?, modifiers rawMods: Any?, into item: inout AppleMenuItem, label: String,
                              error: (String) -> Void, warning: (String) -> Void) {
        var key: String?
        var keyOK = true
        if let k = rawKey {
            if let k = k as? String, isKeyEquivalentCharacter(k) {
                key = k
            } else {
                error("\(label): keyEquivalent must be a single visible character (not a space, control or function key); ignored.")
                keyOK = false
            }
        }
        var mods: [AppleMenuItem.Modifier]?
        if let m = rawMods {
            let names = m as? [String]
            let parsed = names?.compactMap(AppleMenuItem.Modifier.init(rawValue:))
            if let names, let parsed, parsed.count == names.count {
                var unique: [AppleMenuItem.Modifier] = []
                for mod in parsed where !unique.contains(mod) { unique.append(mod) }
                if key == nil {
                    if keyOK { warning("\(label): modifiers without keyEquivalent; ignored.") }
                    return
                }
                mods = unique
            } else {
                // Wrong modifiers could turn the shortcut into one the app already uses.
                error("\(label): modifiers must be an array of \(AppleMenuItem.Modifier.allCases.map(\.rawValue).joined(separator: ", "))"
                      + (key != nil ? "; keyEquivalent and modifiers ignored." : "; ignored."))
                return
            }
        }
        guard var k = key else { return }
        // AppKit matches a letter key equivalent by its case: "J" is ⇧⌘J (Shift implied), while "j" with a Shift
        // modifier is matched as plain ⌘J. So a Shift letter is published as the uppercase letter plus shift.
        let lower = k.lowercased(), upper = k.uppercased()
        if lower != k, upper == k, lower.count == 1 {
            var withShift = mods ?? [.command]
            if !withShift.contains(.shift) {
                withShift.append(.shift)
                warning("\(label): keyEquivalent \"\(k)\" is uppercase, which AppKit treats as \(AppleMenuItem.display(key: k, modifiers: withShift)); "
                        + "shift added. For \(AppleMenuItem.display(key: k, modifiers: mods ?? [.command])) use \"\(lower)\".")
            }
            mods = withShift
        } else if upper != k, lower == k, upper.count == 1, mods?.contains(.shift) == true {
            k = upper
        }
        let effective = mods ?? [.command]
        // Command is required. Without it the Apple menu, which sees key equivalents before the focused view in every
        // app, would take the key from typing: a bare key, Option characters, and Control keys that text views and
        // terminals use (⌃A, ⌃E, ⌃K…).
        guard effective.contains(.command) else {
            error("\(label): shortcut \(AppleMenuItem.display(key: k, modifiers: effective)) needs command "
                  + "(without it the Apple menu would take that key from typing in every app); keyEquivalent and modifiers ignored.")
            return
        }
        item.keyEquivalent = k
        item.modifiers = mods
        if let use = AppleMenuItem.commonShortcutUse(key: k, modifiers: effective) {
            warning("\(label): \(AppleMenuItem.display(key: k, modifiers: effective)) is \(use). Apps that have it keep it, and this item "
                    + "shows no shortcut there.")
        }
    }

    static func parseAction(_ raw: String, at label: String, error: (String) -> Void) -> AppleMenuItem.Action? {
        guard let colon = raw.firstIndex(of: ":") else {
            error("\(label): action \"\(raw)\" needs a scheme (\(AppleMenuItem.Action.schemes.joined(separator: ", "))); skipped.")
            return nil
        }
        let scheme = String(raw[..<colon])
        let value = String(raw[raw.index(after: colon)...])
        func empty() -> AppleMenuItem.Action? { error("\(label): action \"\(raw)\" has nothing after \"\(scheme):\"; skipped."); return nil }
        switch scheme {
        case "notify":
            guard !value.isEmpty else { return empty() }
            guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                error("\(label): notification name must not contain spaces; skipped.")
                return nil
            }
            return .notify(value)
        case "url":
            guard !value.isEmpty else { return empty() }
            guard let url = URL(string: value), let s = url.scheme, !s.isEmpty,
                  s.range(of: "^[A-Za-z][A-Za-z0-9+.-]*$", options: .regularExpression) != nil,
                  !["http", "https"].contains(s.lowercased()) || !(url.host ?? "").isEmpty else {
                error("\(label): \"\(value)\" is not an absolute URL; skipped.")
                return nil
            }
            return .url(value)
        case "shortcut":
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return empty() }
            return .shortcut(value)
        case "app":
            guard !value.isEmpty else { return empty() }
            guard value.range(of: bundleIDPattern, options: .regularExpression) != nil else {
                error("\(label): \"\(value)\" is not a bundle ID; skipped.")
                return nil
            }
            return .app(value)
        default:
            error("\(label): unknown action scheme \"\(scheme)\" (use \(AppleMenuItem.Action.schemes.joined(separator: ", "))); skipped.")
            return nil
        }
    }
}

// MARK: - Published list

/// The style of the shared entry, which holds the items of every tweak whose placement is `shared`.
public enum MenuLoaderPlacement: String, Sendable, CaseIterable, Codable {
    /// One submenu ("Tweaks" unless renamed), one section per tweak.
    case submenu
    /// The items directly in the Apple menu, one section per tweak.
    case section
}

/// One tweak's share of the Apple menu: a manifest with `appleMenu` items, or Workbench's own "Dynject" group.
public struct MenuLoaderContributor: Identifiable, Sendable {
    /// The tweak identifier (`tweakID` in the published list).
    public var id: String
    public var name: String
    public var title: String
    public var placement: AppleMenuPlacement
    public var symbol: String?
    public var items: [AppleMenuItem]
    /// Manifest defaults of the switches `checkedBy` refers to (published as `checkedByDefault`).
    public var checkedDefaults: [String: Bool] = [:]

    public init(id: String, name: String, title: String, placement: AppleMenuPlacement, symbol: String?, items: [AppleMenuItem],
                checkedDefaults: [String: Bool] = [:]) {
        self.id = id
        self.name = name
        self.title = title
        self.placement = placement
        self.symbol = symbol
        self.items = items
        self.checkedDefaults = checkedDefaults
    }

    public init(manifest m: TweakManifest) {
        var defaults: [String: Bool] = [:]
        for key in Set(m.appleMenu.compactMap(\.checkedBy)) { defaults[key] = m.item(key)?.defaultValue.bool ?? false }
        self.init(id: m.id, name: m.name, title: m.effectiveAppleMenuTitle, placement: m.appleMenuPlacement,
                  symbol: m.appleMenuSymbol, items: m.appleMenu, checkedDefaults: defaults)
    }

    /// Identifier of Workbench's built-in group (Workbench's bundle ID). A manifest using it is ignored.
    public static let dynjectID = "local.dynject.workbench"

    /// Workbench's own group, "Dynject ▸": Respring…, Safe Mode…, Open Dynject Workbench. Hidden with the
    /// per-tweak include flag of `dynjectID` (MenuLoaderSettings).
    public static let dynject = MenuLoaderContributor(
        id: dynjectID, name: "Dynject", title: "Dynject", placement: .submenu, symbol: "puzzlepiece.extension",
        items: [
            AppleMenuItem(id: "respring", title: "Respring…", action: .url("dynject-workbench://respring"), symbol: "arrow.clockwise"),
            AppleMenuItem(id: "safemode", title: "Safe Mode…", action: .url("dynject-workbench://safemode"), symbol: "cross.case"),
            AppleMenuItem(id: "open", title: "Open Dynject Workbench", action: .app(dynjectID), symbol: "macwindow"),
        ])

    /// As published in the list's `contributors` array.
    public var plistDictionary: [String: Any] {
        var d: [String: Any] = ["tweakID": id, "title": title, "placement": placement.rawValue]
        if let symbol { d["symbol"] = symbol }
        return d
    }
}

/// Where Workbench publishes the Apple-menu list and how MenuLoader hears about changes.
public struct MenuLoaderNames: Sendable, Equatable {
    public var key: String
    public var notification: String

    public static let production = MenuLoaderNames(key: "dynject.menuloader", notification: "dynject.menuloader.changed")
    /// Test builds of MenuLoader (-DML_TEST) read this key; Workbench's fixture and smoke-test modes write it.
    public static let test = MenuLoaderNames(key: "dynject.menuloader.test", notification: "dynject.menuloader.test.changed")

    public init(key: String, notification: String) {
        self.key = key
        self.notification = notification
    }
}

/// Workbench's own MenuLoader preferences (stored by the app, not published as such).
public struct MenuLoaderSettings: Codable, Equatable, Sendable {
    /// Title of the shared entry.
    public static let defaultSubmenuTitle = "Tweaks"
    /// The shared entry's default title before Workbench's own group got that name; read as the new default.
    static let legacyDefaultSubmenuTitle = "Dynject"

    /// Per-tweak "Show in Apple menu" flag. Missing = on. `MenuLoaderContributor.dynjectID` hides Workbench's group.
    public var included: [String: Bool] = [:]
    /// Style and title of the shared entry.
    public var placement: MenuLoaderPlacement = .submenu
    public var submenuTitle: String = MenuLoaderSettings.defaultSubmenuTitle

    public init() {}

    public func isIncluded(_ tweakID: String) -> Bool { included[tweakID] ?? true }

    public var effectiveSubmenuTitle: String {
        let t = submenuTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? Self.defaultSubmenuTitle : t
    }

    public init(from decoder: Decoder) throws {
        // Tolerate missing fields so older or hand-edited files still load.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        included = try c.decodeIfPresent([String: Bool].self, forKey: .included) ?? [:]
        placement = (try? c.decodeIfPresent(MenuLoaderPlacement.self, forKey: .placement)) ?? .submenu
        submenuTitle = try c.decodeIfPresent(String.self, forKey: .submenuTitle) ?? Self.defaultSubmenuTitle
        // Saved by a Workbench whose one entry was "Dynject": that name now belongs to Workbench's own group.
        if submenuTitle == Self.legacyDefaultSubmenuTitle { submenuTitle = Self.defaultSubmenuTitle }
    }
}

/// A raw dictionary store in the global preferences domain (or a stand-in for fixtures and tests).
public protocol GlobalPrefsStore: AnyObject {
    func dictionary(forKey key: String) -> [String: Any]?
    /// nil removes the key.
    func setDictionary(_ value: [String: Any]?, forKey key: String) throws
    func postNotification(_ name: String)
}

/// An item whose shortcut was dropped from the published list because an earlier item already has it.
public struct ShortcutConflict: Sendable, Equatable {
    public var tweakID: String
    public var itemID: String
    public var shortcut: String
    public var keptByTweakName: String
    public var keptByTitle: String

    public var message: String {
        "Shortcut \(shortcut) not published: \"\(keptByTitle)\" (\(keptByTweakName)) already uses it."
    }
}

/// Builds the MenuLoader list from the loaded manifests (plus Workbench's own group) and publishes it when it changed.
public final class MenuLoaderPublisher {
    /// Still 1: `contributors` is an addition older MenuLoader builds ignore (they put every item in the shared entry).
    public static let formatVersion = 1

    public let store: GlobalPrefsStore
    public let names: MenuLoaderNames

    public init(store: GlobalPrefsStore, names: MenuLoaderNames) {
        self.store = store
        self.names = names
    }

    /// The included contributors with items, in Apple-menu order: own-entry contributors first (Workbench's group,
    /// then by title), then the shared ones by title; ties broken by identifier.
    public static func contributors(for manifests: [TweakManifest], settings: MenuLoaderSettings) -> [MenuLoaderContributor] {
        func rank(_ c: MenuLoaderContributor) -> Int { c.id == MenuLoaderContributor.dynjectID ? 0 : c.placement == .submenu ? 1 : 2 }
        let all = [MenuLoaderContributor.dynject]
            + manifests.filter { $0.id != MenuLoaderContributor.dynjectID }.map(MenuLoaderContributor.init(manifest:))
        return all
            .filter { !$0.items.isEmpty && settings.isIncluded($0.id) }
            .sorted {
                if rank($0) != rank($1) { return rank($0) < rank($1) }
                let c = $0.title.compare($1.title, options: [.caseInsensitive, .numeric])
                return c == .orderedSame ? $0.id < $1.id : c == .orderedAscending
            }
    }

    /// Every published item with its contributor, in published order (contributors in Apple-menu order, items in
    /// manifest order). An item whose shortcut an earlier item already has (in an app both can appear in) loses
    /// its shortcut; see `shortcutConflicts`.
    public static func items(for manifests: [TweakManifest], settings: MenuLoaderSettings) -> [(MenuLoaderContributor, AppleMenuItem)] {
        resolved(manifests, settings: settings).entries
    }

    /// Items that lost their shortcut to an earlier item with the same one, in published order.
    public static func shortcutConflicts(for manifests: [TweakManifest], settings: MenuLoaderSettings) -> [ShortcutConflict] {
        resolved(manifests, settings: settings).conflicts
    }

    static func resolved(_ manifests: [TweakManifest], settings: MenuLoaderSettings)
        -> (entries: [(MenuLoaderContributor, AppleMenuItem)], conflicts: [ShortcutConflict]) {
        let ordered = contributors(for: manifests, settings: settings).flatMap { c in c.items.map { (c, $0) } }
        // AppKit runs the first matching item, so a later item with the same shortcut would never run from the
        // keyboard; drop its shortcut so the menu (and Workbench) never shows a shortcut that does nothing.
        func overlap(_ a: [String]?, _ b: [String]?) -> Bool {
            guard let a, let b else { return true }
            return !Set(a).isDisjoint(with: b)
        }
        var kept: [(identity: String, contributor: MenuLoaderContributor, item: AppleMenuItem)] = []
        var conflicts: [ShortcutConflict] = []
        let entries = ordered.map { c, item -> (MenuLoaderContributor, AppleMenuItem) in
            guard let identity = item.shortcutIdentity else { return (c, item) }
            if let winner = kept.first(where: { $0.identity == identity && overlap($0.item.apps, item.apps) }) {
                conflicts.append(ShortcutConflict(tweakID: c.id, itemID: item.id, shortcut: item.shortcutDisplay ?? identity,
                                                  keptByTweakName: winner.contributor.name, keptByTitle: winner.item.title))
                var stripped = item
                stripped.keyEquivalent = nil
                stripped.modifiers = nil
                return (c, stripped)
            }
            kept.append((identity, c, item))
            return (c, item)
        }
        return (entries, conflicts)
    }

    /// The dictionary to publish, or nil when nothing contributes an item (the key is then removed).
    public static func payload(for manifests: [TweakManifest], settings: MenuLoaderSettings) -> [String: Any]? {
        let entries = items(for: manifests, settings: settings)
        guard !entries.isEmpty else { return nil }
        let list: [[String: Any]] = entries.map { c, item in
            var d = item.plistDictionary
            d["tweakID"] = c.id
            d["tweakName"] = c.name
            // The switch's manifest default: MenuLoader's fallback while the tweak has no settings payload yet,
            // so the checkmark matches what Workbench shows (DTPrefBool's `fallback`).
            if let key = item.checkedBy { d["checkedByDefault"] = c.checkedDefaults[key] ?? false }
            return d
        }
        var seen = Set<String>()
        let contributors = entries.map(\.0).filter { seen.insert($0.id).inserted }.map(\.plistDictionary)
        return [
            "formatVersion": formatVersion,
            "items": list,
            "contributors": contributors,
            "placement": settings.placement.rawValue,
            "submenuTitle": settings.effectiveSubmenuTitle,
        ]
    }

    public func currentPayload() -> [String: Any]? { store.dictionary(forKey: names.key) }

    /// Writes the list and posts the change notification, unless the published list is already identical.
    /// Returns whether anything was written.
    @discardableResult
    public func publish(_ manifests: [TweakManifest], settings: MenuLoaderSettings) throws -> Bool {
        let new = Self.payload(for: manifests, settings: settings)
        let old = currentPayload()
        switch (old, new) {
        case (nil, nil): return false
        case let (o?, n?) where NSDictionary(dictionary: o).isEqual(to: n): return false
        default: break
        }
        try store.setDictionary(new, forKey: names.key)
        store.postNotification(names.notification)
        return true
    }
}
