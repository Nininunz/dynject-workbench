import Foundation

/// The configuration dynjectd would hold in memory after reading a document.
/// Line numbers are 0-based indexes into `ConfigDocument.lines`.
public struct EffectiveConfig: Equatable, Sendable {
    public struct Override: Equatable, Sendable {
        public var pattern: String
        public var allow: Bool
        public var line: Int
    }

    public struct Dylib: Equatable, Sendable {
        public var path: String
        public var defaultAllow: Bool
        public var line: Int
        public var overrides: [Override]
    }

    public struct Rule: Equatable, Sendable {
        public var value: String
        public var line: Int
    }

    public var dylibs: [Dylib] = []
    public var allowRules: [Rule] = []
    public var denyRules: [Rule] = []
    public var uiApps = true
    public var skipHelpers = true
    /// dylib path → approved SHA-256 (lower-case hex), from `dylib-sha256` lines in any order; a later line wins.
    public var approvals: [String: String] = [:]
    /// `dylib-approval:enforce`. Otherwise audit, which is also what a config without the line means.
    public var approvalEnforced = false

    public init() {}

    public init(document: ConfigDocument, rules: EngineRules = .active) {
        // The revised engine matches overrides to dylibs after it has read the whole file.
        var pending: [(path: String, override: Override)] = []
        func attach(_ path: String, _ override: Override) {
            // To the first declared dylib with this exact path.
            guard let d = dylibs.firstIndex(where: { $0.path == path }) else { return }
            guard dylibs[d].overrides.count < DynjectLimits.maxOverridesPerDylib else { return }
            dylibs[d].overrides.append(override)
        }
        defer { for p in pending { attach(p.path, p.override) } }

        for (index, kind) in document.kinds.enumerated() {
            switch kind {
            case let .dylib(path, token):
                guard dylibs.count < DynjectLimits.maxDylibs else { continue }
                dylibs.append(Dylib(path: path, defaultAllow: LineKind.policyAllows(token), line: index, overrides: []))
            case let .override(path, token, pattern):
                let override = Override(pattern: Self.truncatedPattern(pattern), allow: token == "allow", line: index)
                // Stock: only a dylib declared above the override gets it.
                if rules == .stock { attach(path, override) } else { pending.append((path, override)) }
            case let .allow(value):
                guard allowRules.count < DynjectLimits.maxRules else { continue }
                allowRules.append(Rule(value: value, line: index))
            case let .deny(value):
                guard denyRules.count < DynjectLimits.maxRules else { continue }
                denyRules.append(Rule(value: value, line: index))
            case let .uiApps(value):
                uiApps = LineKind.flagValue(value, current: uiApps, rules: rules)
            case let .skipHelpers(value):
                skipHelpers = LineKind.flagValue(value, current: skipHelpers, rules: rules)
            case let .approval(path, sha256):
                approvals[path] = sha256
            case let .approvalMode(value):
                approvalEnforced = value == "enforce"
            default:
                continue
            }
        }
    }

    /// dynjectd copies patterns into a 256-byte buffer.
    static func truncatedPattern(_ pattern: String) -> String {
        let bytes = Array(pattern.utf8)
        guard bytes.count > DynjectLimits.maxPatternBytes else { return pattern }
        return String(decoding: bytes.prefix(DynjectLimits.maxPatternBytes), as: UTF8.self)
    }

    public func dylib(path: String) -> Dylib? {
        dylibs.first { $0.path == path }
    }

    /// Distinct dylib paths in declaration order.
    public var dylibPaths: [String] {
        var seen = Set<String>()
        return dylibs.map(\.path).filter { seen.insert($0).inserted }
    }
}

public struct ConfigDiagnostic: Equatable, Sendable, Identifiable {
    public enum Severity: Int, Comparable, Sendable {
        case info, warning, error
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    public var id: String { "\(line ?? -1):\(message)" }
    public var severity: Severity
    /// 0-based line index, or nil for whole-file issues.
    public var line: Int?
    public var message: String

    public init(_ severity: Severity, line: Int?, _ message: String) {
        self.severity = severity
        self.line = line
        self.message = message
    }
}

public enum ConfigValidator {
    public static func diagnose(_ document: ConfigDocument, rules: EngineRules = .active,
                                fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> [ConfigDiagnostic]
    {
        var out: [ConfigDiagnostic] = []
        let kinds = document.kinds
        var declared: [String: Int] = [:]
        var allDylibLines: [String: Int] = [:]
        var dylibCount = 0, allowCount = 0, denyCount = 0
        var overrideCounts: [String: Int] = [:]

        for (i, kind) in kinds.enumerated() {
            if case let .dylib(path, _) = kind, allDylibLines[path] == nil { allDylibLines[path] = i }
        }

        for (i, line) in document.lines.enumerated() {
            let bytes = (line.text + line.terminator).utf8.count
            if bytes > DynjectLimits.maxLineBytes {
                out.append(.init(.error, line: i,
                    "Line is \(bytes) bytes; dynjectd reads at most \(DynjectLimits.maxLineBytes) per line and would split it into separate directives."))
            }
            if line.text.drop(while: { $0 == " " || $0 == "\t" }).contains("\t"), kinds[i].isDirective {
                out.append(.init(.info, line: i, "Contains a tab. dynjectd only trims leading tabs, so tabs inside a value are matched literally."))
            }

            switch kinds[i] {
            case .blank, .comment:
                break
            case .noColon:
                out.append(.init(.warning, line: i, "No ':' on this line; dynjectd ignores it."))
            case .malformedOverride:
                out.append(.init(.warning, line: i, "dylib-override needs path:policy:pattern; dynjectd ignores this line."))
            case let .unknownKey(key, _):
                out.append(.init(.warning, line: i, "Unknown key \"\(key)\"; dynjectd ignores it. Keys are case-sensitive and must not contain spaces."))
            case let .dylib(path, token):
                dylibCount += 1
                if dylibCount > DynjectLimits.maxDylibs {
                    out.append(.init(.error, line: i, "More than \(DynjectLimits.maxDylibs) dylib lines; dynjectd ignores this one."))
                }
                if path.isEmpty { out.append(.init(.error, line: i, "Empty dylib path.")) }
                if let first = declared[path] {
                    out.append(.init(.warning, line: i,
                        "Duplicate dylib (first declared on line \(first + 1)). dynjectd evaluates it separately, and overrides only attach to the first declaration."))
                } else {
                    declared[path] = i
                }
                if let token, token != "allow", token != "deny" {
                    out.append(.init(.warning, line: i, "Policy \"\(token)\" is treated as deny. Only lowercase \"allow\" allows."))
                }
                if !path.isEmpty, !fileExists(path) {
                    out.append(.init(.warning, line: i, "File not found: \(path). dynjectd logs and skips it at injection time."))
                }
                if path.utf8.count >= DynjectLimits.pathMax {
                    out.append(.init(.error, line: i, "Path exceeds PATH_MAX and would be truncated."))
                }
            case let .override(path, token, pattern):
                if declared[path] == nil, rules == .stock, let later = allDylibLines[path] {
                    out.append(.init(.error, line: i,
                        "Override appears before its dylib line (\(later + 1)); dynjectd ignores it. Move it below that line."))
                } else if allDylibLines[path] == nil {
                    out.append(.init(.error, line: i, "No dylib line declares \(path); dynjectd ignores this override."))
                } else {
                    overrideCounts[path, default: 0] += 1
                    if overrideCounts[path]! > DynjectLimits.maxOverridesPerDylib {
                        out.append(.init(.error, line: i, "More than \(DynjectLimits.maxOverridesPerDylib) overrides for this dylib; dynjectd ignores this one."))
                    }
                }
                if token != "allow", token != "deny" {
                    out.append(.init(.warning, line: i, "Override policy \"\(token)\" is treated as deny."))
                }
                if pattern.isEmpty {
                    out.append(.init(.warning, line: i, "Empty pattern matches every bundle."))
                }
                if pattern.utf8.count > DynjectLimits.maxPatternBytes {
                    out.append(.init(.warning, line: i, "Pattern is longer than \(DynjectLimits.maxPatternBytes) bytes and will be truncated."))
                }
            case let .allow(value):
                allowCount += 1
                if allowCount > DynjectLimits.maxRules { out.append(.init(.error, line: i, "Too many allow rules; ignored.")) }
                if value.isEmpty { out.append(.init(.warning, line: i, "Empty allow rule matches every process.")) }
            case let .deny(value):
                denyCount += 1
                if denyCount > DynjectLimits.maxRules { out.append(.init(.error, line: i, "Too many deny rules; ignored.")) }
                if value.isEmpty { out.append(.init(.warning, line: i, "Empty deny rule blocks every process.")) }
            case .malformedApproval:
                out.append(.init(.warning, line: i, "dylib-sha256 needs path:<64 hex digits>; dynjectd ignores this line."))
            case let .approval(path, _):
                if allDylibLines[path] == nil {
                    out.append(.init(.warning, line: i, "No dylib line declares \(path); this approval does nothing."))
                }
            case let .approvalMode(value):
                if value != "audit", value != "enforce" {
                    out.append(.init(.warning, line: i, "dylib-approval is \"audit\" or \"enforce\"; dynjectd reads \"\(value)\" as audit."))
                }
            case let .uiApps(value), let .skipHelpers(value):
                switch rules {
                case .stock:
                    if !["yes", "no", "1", "0"].contains(value) {
                        out.append(.init(.info, line: i, "Value \"\(value)\" is read as enabled (only \"no\" or \"0\" disable it)."))
                    }
                case .revised:
                    if LineKind.flagWord(value) == nil {
                        out.append(.init(.warning, line: i,
                            "Value \"\(value)\" is neither yes nor no; dynjectd keeps the setting as it was (use yes/no, true/false, on/off or 1/0)."))
                    }
                }
            }
        }

        if dylibCount == 0 {
            out.append(.init(.error, line: nil,
                "No dylib lines. dynjectd refuses to start (\"no dylibs configured\"), so all injection would stop."))
        }

        // Overrides that can never match because an earlier override's pattern is a substring.
        let effective = EffectiveConfig(document: document, rules: rules)
        for dylib in effective.dylibs {
            for (j, o) in dylib.overrides.enumerated() {
                if let earlier = dylib.overrides[..<j].first(where: { o.pattern.contains($0.pattern) }) {
                    out.append(.init(.warning, line: o.line,
                        "Never takes effect: line \(earlier.line + 1) (\"\(earlier.pattern)\") matches first for every bundle this pattern matches."))
                }
            }
        }

        return out.sorted { ($0.line ?? -1, -$0.severity.rawValue) < ($1.line ?? -1, -$1.severity.rawValue) }
    }
}
