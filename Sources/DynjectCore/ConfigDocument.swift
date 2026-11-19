import Foundation

/// Limits compiled into dynjectd (see dynjectd.c).
public enum DynjectLimits {
    public static let maxDylibs = 32
    public static let maxOverridesPerDylib = 64
    public static let maxRules = 128
    public static let pathMax = 1024
    /// `fgets(line, PATH_MAX + 64, file)` reads at most this many bytes per chunk.
    public static let maxLineBytes = pathMax + 64 - 1
    public static let maxPatternBytes = 255
}

/// One physical line of the config, kept verbatim so edits never disturb unrelated lines.
public struct ConfigLine: Equatable, Sendable {
    public var text: String
    /// "\n", "\r\n", or "" (last line without a newline).
    public var terminator: String

    public init(text: String, terminator: String) {
        self.text = text
        self.terminator = terminator
    }
}

/// How dynjectd's `config_load` interprets a single line.
public enum LineKind: Equatable, Sendable {
    case blank
    case comment
    /// `dylib:path[:policy]`. `policyToken == nil` is the shorthand form (allow).
    case dylib(path: String, policyToken: String?)
    case override(path: String, policyToken: String, pattern: String)
    case allow(String)
    case deny(String)
    case uiApps(String)
    case skipHelpers(String)
    case unknownKey(key: String, value: String)
    /// Non-comment line without a colon; dynjectd skips it.
    case noColon
    /// `dylib-override` missing a policy or pattern field; dynjectd skips it.
    case malformedOverride

    public var isDirective: Bool {
        switch self {
        case .blank, .comment, .noColon, .malformedOverride, .unknownKey: return false
        default: return true
        }
    }
}

public extension LineKind {
    /// dynjectd allows only when the token is exactly "allow"; anything else is deny.
    static func policyAllows(_ token: String?) -> Bool {
        guard let token else { return true }
        return token == "allow"
    }

    /// `ui_apps` / `skip_helpers`: enabled unless exactly "no" or "0".
    static func flagEnabled(_ value: String) -> Bool {
        value != "no" && value != "0"
    }
}

public enum ConfigParser {
    /// Classify one line exactly as dynjectd's `config_load` does.
    public static func classify(_ raw: String) -> LineKind {
        var s = Substring(raw)
        while let first = s.first, first == " " || first == "\t" { s = s.dropFirst() }
        while let last = s.last, last == "\n" || last == "\r" || last == " " { s = s.dropLast() }
        // Swift treats "\r\n" as one Character; strip it too.
        while s.hasSuffix("\r\n") { s = s.dropLast() }

        if s.isEmpty { return .blank }
        if s.first == "#" { return .comment }
        guard let colon = s.firstIndex(of: ":") else { return .noColon }

        let key = String(s[..<colon])
        var value = s[s.index(after: colon)...]
        while value.first == " " { value = value.dropFirst() }

        switch key {
        case "dylib":
            if let c = value.firstIndex(of: ":") {
                return .dylib(path: String(value[..<c]), policyToken: String(value[value.index(after: c)...]))
            }
            return .dylib(path: String(value), policyToken: nil)
        case "dylib-override":
            guard let p1 = value.firstIndex(of: ":") else { return .malformedOverride }
            let path = String(value[..<p1])
            let rest = value[value.index(after: p1)...]
            guard let p2 = rest.firstIndex(of: ":") else { return .malformedOverride }
            let policy = String(rest[..<p2])
            let pattern = String(rest[rest.index(after: p2)...])
            return .override(path: path, policyToken: policy, pattern: pattern)
        case "allow": return .allow(String(value))
        case "deny": return .deny(String(value))
        case "ui_apps": return .uiApps(String(value))
        case "skip_helpers": return .skipHelpers(String(value))
        default: return .unknownKey(key: key, value: String(value))
        }
    }
}

/// A Dynject config held as verbatim lines.
public struct ConfigDocument: Equatable, Sendable {
    public private(set) var lines: [ConfigLine]

    public init(text: String) {
        lines = ConfigDocument.split(text)
    }

    public var text: String {
        lines.map { $0.text + $0.terminator }.joined()
    }

    public func kind(at index: Int) -> LineKind {
        ConfigParser.classify(lines[index].text)
    }

    public var kinds: [LineKind] { lines.map { ConfigParser.classify($0.text) } }

    /// The newline style most used in this file ("\n" if none).
    public var preferredTerminator: String {
        let crlf = lines.filter { $0.terminator == "\r\n" }.count
        let lf = lines.filter { $0.terminator == "\n" }.count
        return crlf > lf ? "\r\n" : "\n"
    }

    public mutating func replaceLine(at index: Int, with text: String) {
        lines[index].text = text
    }

    public mutating func insertLine(_ text: String, at index: Int) {
        let term = preferredTerminator
        if index == lines.count {
            // Appending: make sure the previous last line ends with a newline.
            if let last = lines.indices.last, lines[last].terminator.isEmpty {
                lines[last].terminator = term
            }
            lines.append(ConfigLine(text: text, terminator: term))
        } else {
            lines.insert(ConfigLine(text: text, terminator: term), at: index)
        }
    }

    public mutating func removeLine(at index: Int) {
        let removed = lines.remove(at: index)
        // Keep "no trailing newline" files that way if we removed the final line.
        if index == lines.count, removed.terminator.isEmpty, let last = lines.indices.last {
            lines[last].terminator = ""
        }
    }

    static func split(_ text: String) -> [ConfigLine] {
        var result: [ConfigLine] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if current.hasSuffix("\r") {
                    current.removeLast()
                    result.append(ConfigLine(text: current, terminator: "\r\n"))
                } else {
                    result.append(ConfigLine(text: current, terminator: "\n"))
                }
                current = ""
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { result.append(ConfigLine(text: current, terminator: "")) }
        return result
    }
}
