import Foundation

/// A tweak's settings manifest (`<name>.workbench.plist`). Workbench renders a settings UI for any tweak
/// that ships one; it never guesses settings for tweaks that don't. Format spec: docs/tweak-format.md.
public struct TweakManifest: Identifiable, Sendable {
    public static let formatVersion = 1
    public static let fileSuffix = ".workbench.plist"

    public enum TakesEffect: String, Sendable { case live, relaunch }

    public struct Section: Sendable {
        public var title: String?
        public var footer: String?
        public var items: [TweakItem]
    }

    public var id: String
    public var name: String
    public var dylib: String
    public var summary: String?
    public var version: String?
    public var author: String?
    public var takesEffect: TakesEffect
    /// Run as the user (no shell) after settings change. Optional.
    public var applyCommand: [String]?
    public var sections: [Section]
    public var sourcePath: String
    /// Items this tweak declares for the Apple menu (MenuLoader). Optional; see docs/tweak-format.md.
    public var appleMenu: [AppleMenuItem] = []
    /// Where MenuLoader puts those items: the tweak's own Apple-menu entry or the shared one ("Tweaks").
    public var appleMenuPlacement: AppleMenuPlacement = .shared
    /// The title of the tweak's own entry (or its section in the shared one). nil = `name`.
    public var appleMenuTitle: String?
    /// SF Symbol of the tweak's own entry.
    public var appleMenuSymbol: String?
    /// What the tweak may ask DynjectBridge for (manifest key `bridge`). Empty: nothing. See docs/bridge.md.
    public var bridge: [BridgeCapability] = []
    /// What the tweak needs from macOS (manifest key `requires`), checked by `dw doctor --apis`. nil: not declared.
    public var requires: [TweakRequirement]? = nil

    /// `requires` plus what the SDK needs for the tweak's declared features (the bridge client's SPI).
    public var effectiveRequirements: [TweakRequirement] {
        (requires ?? []) + (bridge.isEmpty ? [] : TweakRequirement.bridgeClient)
    }

    /// The title MenuLoader shows for this tweak's items.
    public var effectiveAppleMenuTitle: String { appleMenuTitle ?? name }

    public var items: [TweakItem] { sections.flatMap(\.items) }
    public var perAppItems: [TweakItem] { items.filter(\.perApp) }
    public func item(_ key: String) -> TweakItem? { items.first { $0.key == key } }
}

public struct TweakItem: Identifiable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case `switch`, slider, number, color, choice, text, appList
    }

    public struct Option: Sendable, Equatable {
        public var value: PrefValue
        public var title: String
    }

    public var id: String { key }
    public var kind: Kind
    public var key: String
    public var title: String
    public var footer: String?
    public var defaultValue: PrefValue
    public var min: Double?
    public var max: Double?
    public var step: Double?
    public var integer: Bool
    public var options: [Option]
    public var allowAuto: Bool
    public var placeholder: String?
    public var perApp: Bool
    /// Key of a switch item; this item is disabled while that switch is off.
    public var enabledIf: String?

    /// Coerces and validates a value for this item. Returns nil if it can't be made valid.
    public func normalized(_ value: PrefValue) -> PrefValue? {
        switch (kind, value) {
        case (.switch, .bool): return value
        case (.slider, .number(let n)), (.number, .number(let n)):
            guard n.isFinite else { return nil }
            var v = n
            if let step, step > 0 { v = ((v - (min ?? 0)) / step).rounded() * step + (min ?? 0) }
            if integer { v = v.rounded() }
            if let min { v = Swift.max(min, v) }
            if let max { v = Swift.min(max, v) }
            return .number(v)
        case (.color, .string(let s)):
            if allowAuto && s == "auto" { return value }
            return PrefValue.isHexColor(s) ? .string(s.uppercased()) : nil
        case (.choice, _):
            return options.contains { $0.value == value } ? value : nil
        case (.text, .string): return value
        case (.appList, .list(let ids)):
            var seen = Set<String>()
            return .list(ids.filter { !$0.isEmpty && seen.insert($0).inserted })
        default: return nil
        }
    }
}

/// A settings value as stored in property lists.
public enum PrefValue: Hashable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case list([String])

    public init?(plist: Any) {
        if let n = plist as? NSNumber {
            // Distinguish CFBoolean from numbers.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        } else if let s = plist as? String {
            self = .string(s)
        } else if let a = plist as? [Any], a.allSatisfy({ $0 is String }) {
            self = .list(a as! [String])
        } else {
            return nil
        }
    }

    public func plistObject(integer: Bool = false) -> Any {
        switch self {
        case let .bool(b): return NSNumber(value: b)
        case let .number(n):
            // Int(exactly:) never traps: a value outside Int's range, or not whole, stays a Double.
            if integer, let i = Int(exactly: n.rounded()) { return NSNumber(value: i) }
            return NSNumber(value: n)
        case let .string(s): return s
        case let .list(l): return l
        }
    }

    public var bool: Bool? { if case let .bool(b) = self { return b } else { return nil } }
    public var number: Double? { if case let .number(n) = self { return n } else { return nil } }
    public var string: String? { if case let .string(s) = self { return s } else { return nil } }
    public var list: [String]? { if case let .list(l) = self { return l } else { return nil } }

    public static func isHexColor(_ s: String) -> Bool {
        s.range(of: "^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$", options: .regularExpression) != nil
    }

    public var displayText: String {
        switch self {
        case let .bool(b): return b ? "On" : "Off"
        case let .number(n):
            if let i = Int(exactly: n) { return String(i) }
            return n.isFinite && abs(n) < 1e15 ? String(format: "%.2f", n) : "\(n)"
        case let .string(s): return s.isEmpty ? "(empty)" : s
        case let .list(l): return l.isEmpty ? "none" : l.joined(separator: ", ")
        }
    }
}

public struct ManifestIssue: Equatable, Sendable, Identifiable {
    public enum Severity: Sendable { case warning, error }
    public var id: String { "\(file):\(message)" }
    public var file: String
    public var severity: Severity
    public var message: String
}

public enum TweakManifestParser {
    /// Parses one manifest. Returns nil (with errors) if it is unusable; individual bad items are
    /// skipped with an error so the rest of the manifest still works.
    public static func parse(data: Data, path: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> (TweakManifest?, [ManifestIssue])
    {
        var issues: [ManifestIssue] = []
        func err(_ m: String) { issues.append(ManifestIssue(file: path, severity: .error, message: m)) }
        func warn(_ m: String) { issues.append(ManifestIssue(file: path, severity: .warning, message: m)) }

        guard let root = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            err("Not a property list with a dictionary at the top level.")
            return (nil, issues)
        }
        guard (root["formatVersion"] as? Int) == TweakManifest.formatVersion else {
            err("formatVersion must be \(TweakManifest.formatVersion).")
            return (nil, issues)
        }
        guard let id = root["identifier"] as? String,
              id.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil else {
            err("identifier is required (reverse-DNS: letters, digits, dots, hyphens).")
            return (nil, issues)
        }
        guard let dylib = root["dylib"] as? String, dylib.hasPrefix("/") else {
            err("dylib is required and must be an absolute path.")
            return (nil, issues)
        }
        let name = (root["name"] as? String) ?? id
        if !fileExists(dylib) { warn("dylib not found at \(dylib).") }

        var takesEffect = TweakManifest.TakesEffect.relaunch
        if let t = root["takesEffect"] as? String {
            if let v = TweakManifest.TakesEffect(rawValue: t) { takesEffect = v } else { err("takesEffect must be live or relaunch.") }
        }

        var apply: [String]?
        if let cmd = root["applyCommand"] {
            if let a = cmd as? [String], let first = a.first, first.hasPrefix("/") {
                apply = a
                if !FileManager.default.isExecutableFile(atPath: first) { warn("applyCommand \(first) is not an executable file.") }
            } else {
                err("applyCommand must be an array of strings starting with an absolute path; ignored.")
            }
        }

        var sections: [TweakManifest.Section] = []
        var seenKeys = Set<String>()
        var switchKeys = Set<String>()
        for (si, rawSection) in ((root["sections"] as? [[String: Any]]) ?? []).enumerated() {
            var items: [TweakItem] = []
            for (ii, rawItem) in ((rawSection["items"] as? [[String: Any]]) ?? []).enumerated() {
                let where_ = "sections[\(si)].items[\(ii)]"
                guard let item = parseItem(rawItem, at: where_, error: err) else { continue }
                guard seenKeys.insert(item.key).inserted else { err("\(where_): duplicate key \"\(item.key)\"; skipped."); continue }
                if item.kind == .switch { switchKeys.insert(item.key) }
                items.append(item)
            }
            sections.append(.init(title: rawSection["title"] as? String, footer: rawSection["footer"] as? String, items: items))
        }
        let appleMenu = AppleMenuParser.parse(root["appleMenu"], switchKeys: switchKeys, error: err, warning: warn)
        let menuGroup = AppleMenuParser.parseGroup(root, hasItems: !appleMenu.isEmpty, error: err, warning: warn)
        let bridge = BridgeCapability.parseManifestValue(root["bridge"], error: err, warning: warn)
        let requires = TweakRequirementParser.parse(root["requires"], error: err, warning: warn)
        if bridge.contains(.settingsSet) && sections.flatMap(\.items).isEmpty {
            warn("bridge declares settings.set, but the manifest has no settings to set.")
        }
        // A manifest may exist only to declare Apple-menu items or bridge capabilities.
        if sections.flatMap(\.items).isEmpty && appleMenu.isEmpty && bridge.isEmpty { warn("No usable settings items.") }
        for item in sections.flatMap(\.items) {
            if let dep = item.enabledIf, !switchKeys.contains(dep) {
                err("\"\(item.key)\": enabledIf \"\(dep)\" is not a switch in this manifest; ignored.")
            }
        }
        // Drop broken enabledIf references.
        sections = sections.map { s in
            var s = s
            s.items = s.items.map { var i = $0; if let d = i.enabledIf, !switchKeys.contains(d) { i.enabledIf = nil }; return i }
            return s
        }

        let manifest = TweakManifest(id: id, name: name, dylib: dylib, summary: root["summary"] as? String,
                                     version: root["version"] as? String, author: root["author"] as? String,
                                     takesEffect: takesEffect, applyCommand: apply, sections: sections, sourcePath: path,
                                     appleMenu: appleMenu, appleMenuPlacement: menuGroup.placement,
                                     appleMenuTitle: menuGroup.title, appleMenuSymbol: menuGroup.symbol, bridge: bridge,
                                     requires: requires)
        return (manifest, issues)
    }

    static func parseItem(_ raw: [String: Any], at path: String, error: (String) -> Void) -> TweakItem? {
        guard let typeName = raw["type"] as? String, let kind = TweakItem.Kind(rawValue: typeName) else {
            error("\(path): type must be one of \(TweakItem.Kind.allCases.map(\.rawValue).joined(separator: ", ")); skipped.")
            return nil
        }
        guard let key = raw["key"] as? String, !key.isEmpty else { error("\(path): key is required; skipped."); return nil }
        let options: [TweakItem.Option] = ((raw["options"] as? [[String: Any]]) ?? []).compactMap { o in
            guard let v = o["value"].flatMap(PrefValue.init(plist:)) else { return nil }
            return .init(value: v, title: (o["title"] as? String) ?? v.displayText)
        }
        var item = TweakItem(
            kind: kind, key: key, title: (raw["title"] as? String) ?? key, footer: raw["footer"] as? String,
            defaultValue: .bool(false),
            min: (raw["min"] as? NSNumber)?.doubleValue, max: (raw["max"] as? NSNumber)?.doubleValue,
            step: (raw["step"] as? NSNumber)?.doubleValue, integer: (raw["integer"] as? Bool) ?? false,
            options: options, allowAuto: (raw["allowAuto"] as? Bool) ?? false,
            placeholder: raw["placeholder"] as? String, perApp: (raw["perApp"] as? Bool) ?? false,
            enabledIf: raw["enabledIf"] as? String)

        if kind == .slider, item.min == nil || item.max == nil || item.min! >= item.max! {
            error("\(path) \"\(key)\": slider needs min < max; skipped.")
            return nil
        }
        if kind == .choice, options.isEmpty {
            error("\(path) \"\(key)\": choice needs options [{value, title}]; skipped.")
            return nil
        }
        let fallback: PrefValue
        switch kind {
        case .switch: fallback = .bool(false)
        case .slider: fallback = .number(item.min!)
        case .number: fallback = .number(item.min ?? 0)
        case .color: fallback = .string(item.allowAuto ? "auto" : "#000000")
        case .choice: fallback = options[0].value
        case .text: fallback = .string("")
        case .appList: fallback = .list([])
        }
        if let rawDefault = raw["default"] {
            if let v = PrefValue(plist: rawDefault), let n = item.normalized(v) {
                item.defaultValue = n
            } else {
                error("\(path) \"\(key)\": default doesn't fit type \(kind.rawValue); using \(fallback.displayText).")
                item.defaultValue = fallback
            }
        } else {
            item.defaultValue = fallback
        }
        return item
    }
}

public enum TweakManifestLoader {
    /// Default search locations: the user's Workbench Tweaks folder, then next to installed dylibs.
    public static func defaultDirectories(supportDirectory: URL) -> [String] {
        [supportDirectory.appendingPathComponent("Tweaks").path, "/opt/dynject/lib/tweaks"]
    }

    public static func load(directories: [String]) -> (manifests: [TweakManifest], issues: [ManifestIssue]) {
        var manifests: [TweakManifest] = []
        var issues: [ManifestIssue] = []
        for dir in directories {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            for name in names where name.hasSuffix(TweakManifest.fileSuffix) {
                let path = (dir as NSString).appendingPathComponent(name)
                guard let data = FileManager.default.contents(atPath: path) else {
                    issues.append(.init(file: path, severity: .error, message: "Unreadable."))
                    continue
                }
                let (m, i) = TweakManifestParser.parse(data: data, path: path)
                issues += i
                guard let m else { continue }
                if let existing = manifests.first(where: { $0.id == m.id }) {
                    issues.append(.init(file: path, severity: .error,
                                        message: "Identifier \(m.id) is already provided by \(existing.sourcePath); ignored."))
                    continue
                }
                manifests.append(m)
            }
        }
        return (manifests, issues)
    }
}
