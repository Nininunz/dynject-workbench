import Foundation

/// An installed application bundle.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: String { bundlePath }
    public var displayName: String
    public var bundleID: String
    public var executableName: String
    public var executablePath: String
    public var bundlePath: String

    public init(displayName: String, bundleID: String, executableName: String,
                executablePath: String, bundlePath: String) {
        self.displayName = displayName
        self.bundleID = bundleID
        self.executableName = executableName
        self.executablePath = executablePath
        self.bundlePath = bundlePath
    }
}

/// The XPC service name dynjectd sees for an app, and how we know it.
public struct ServiceName: Hashable, Sendable {
    public enum Source: String, Sendable {
        /// Seen in dynjectd's log.
        case observed
        /// A launchd-managed app with a known label (Finder, Dock).
        case launchdLabel
        /// Assumed LaunchServices form "application.<bundleID>.<n>.<n>".
        case predicted
    }

    public var value: String
    public var source: Source

    public init(_ value: String, source: Source) {
        self.value = value
        self.source = source
    }
}

public enum GateOutcome: Equatable, Sendable {
    case pass(String)
    case fail(String)

    public var passed: Bool { if case .pass = self { return true } else { return false } }
    public var reason: String {
        switch self { case let .pass(r), let .fail(r): return r }
    }
}

public struct DylibDecision: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case defaultPolicy(line: Int)
        case override(line: Int, pattern: String)
        /// The launchd label allows the dylib, but the app's own bundle identifier doesn't (revised engine): it gets
        /// the dylib's default (`pattern` nil) or a deny override, on `line`.
        indirect case appIdentifier(bundleID: String, line: Int, pattern: String?, label: Reason)
    }

    public var dylibPath: String
    public var allowed: Bool
    public var reason: Reason
    public var fileMissing: Bool

    public var reasonText: String {
        switch reason {
        case let .defaultPolicy(line):
            return "default \(allowed ? "allow" : "deny") (line \(line + 1))"
        case let .override(line, pattern):
            return "override \(allowed ? "allow" : "deny") \"\(pattern)\" (line \(line + 1))"
        case let .appIdentifier(bundleID, line, pattern, _):
            let own = pattern.map { "override deny \"\($0)\"" } ?? "default deny"
            return "the service name allows it, but the app's own identifier (\(bundleID.isEmpty ? "none readable" : bundleID)) gets \(own) (line \(line + 1)); dynjectd needs both"
        }
    }
}

public struct AppEvaluation: Equatable, Sendable {
    public var serviceName: String
    public var serviceGate: GateOutcome
    public var processGate: GateOutcome
    public var decisions: [DylibDecision]

    public var gatesPass: Bool { serviceGate.passed && processGate.passed }

    /// Dylib paths dynjectd would put in DYLD_INSERT_LIBRARIES, in order.
    public var injectedDylibs: [String] {
        guard gatesPass else { return [] }
        return decisions.filter { $0.allowed && !$0.fileMissing }.map(\.dylibPath)
    }

    public func isInjected(_ dylib: String) -> Bool { injectedDylibs.contains(dylib) }

    public func decision(for dylib: String) -> DylibDecision? {
        decisions.first { $0.dylibPath == dylib }
    }
}

public enum PolicyEvaluator {
    /// From `g_daemon_patterns` in dynjectd.c.
    public static let systemDaemonPatterns = [
        "mdworker", "mds_stores", "searchpartyd", "symptomsd", "symptomsd-diag", "corecaptured",
        "revisiond", "logd", "notifyd", "newsyslog", "nsurlsessiond", "rapportd", "cloudd", "bird",
        "appleevents", "itunescloudd", "cloudkeychainproxy", "cfprefsd", "usernoted", "contextstored",
        "knowledgegraphd", "coreduetd", "trustd", "AddressBook.", "audio.SandboxHelper",
        "filesystems.netfs", "distnoted", "BackgroundShortcutRunner", "intents-helper", "WebKit.GPU",
        "WebKit.Networking", "WebKit.WebContent", "MTLCompilerService", "security.authhost",
        "dock.external.extra", "IOUserBluetoothSerialDriver", "remotemanagement.",
        "extensionkitservice", "mdmclient.daemon", "siri.context.service",
    ]

    /// From `g_ui_bundle_patterns`.
    public static let uiBundlePatterns = [
        "application.", "com.apple.Finder", "com.apple.Dock.", "com.apple.controlcenter", "homebrew.",
    ]

    /// From `path_is_ui_app`.
    public static let uiPathPrefixes = ["/Applications/", "/System/Applications/", "/System/Library/CoreServices/"]

    /// The system-daemon pattern a service name matches, if any. Stock: anywhere in the name. Revised: as a whole
    /// word, which starts the name or follows a ".", and isn't followed by a lowercase letter (a pattern that ends
    /// in "." needs nothing after it).
    public static func systemDaemonPattern(in service: String, rules: EngineRules = .active) -> String? {
        switch rules {
        case .stock:
            return systemDaemonPatterns.first { service.contains($0) }
        case .revised:
            let name = Array(service.utf8)
            return systemDaemonPatterns.first { pattern in
                let p = Array(pattern.utf8)
                guard !p.isEmpty, name.count >= p.count else { return false }
                for at in 0...(name.count - p.count) {
                    if at > 0, name[at - 1] != UInt8(ascii: ".") { continue }
                    guard name[at..<(at + p.count)].elementsEqual(p) else { continue }
                    if p.last == UInt8(ascii: ".") || at + p.count == name.count { return true }
                    let next = name[at + p.count]
                    if next < UInt8(ascii: "a") || next > UInt8(ascii: "z") { return true }
                }
                return false
            }
        }
    }

    /// Stage 1: `handle_auth_exec` filters on the XPC service name.
    public static func serviceGate(_ service: String, config: EffectiveConfig, rules: EngineRules = .active)
        -> GateOutcome
    {
        if let p = systemDaemonPattern(in: service, rules: rules) {
            return .fail("XPC service matches system-daemon pattern \"\(p)\"")
        }
        if let r = config.allowRules.first(where: { service.contains($0.value) }) {
            return .pass("service name matches allow:\(r.value) (line \(r.line + 1))")
        }
        if let r = config.denyRules.first(where: { service.contains($0.value) }) {
            return .fail("service name matches deny:\(r.value) (line \(r.line + 1))")
        }
        if let p = uiBundlePatterns.first(where: { service.contains($0) }) {
            return .pass("service name matches built-in UI pattern \"\(p)\"")
        }
        return .fail("service name \"\(service)\" is not a UI bundle and matches no allow rule")
    }

    /// Stage 2: `check_match` filters on the executable name and path.
    public static func processGate(name: String, path: String, config: EffectiveConfig) -> GateOutcome {
        if config.skipHelpers, name.contains(" Helper") {
            return .fail("skip_helpers is on and the executable name contains \" Helper\"")
        }
        if let r = config.denyRules.first(where: { name.contains($0.value) || path.contains($0.value) }) {
            return .fail("executable matches deny:\(r.value) (line \(r.line + 1))")
        }
        if let r = config.allowRules.first(where: { name.contains($0.value) || path.contains($0.value) }) {
            return .pass("executable matches allow:\(r.value) (line \(r.line + 1))")
        }
        if config.uiApps, isUIAppPath(path) {
            return .pass("ui_apps is on and the app is in a standard Applications folder")
        }
        if config.uiApps {
            return .fail("not in a standard Applications folder and no allow rule matches (no_gui)")
        }
        return .fail("ui_apps is off and no allow rule matches the executable (no_gui)")
    }

    public static func isUIAppPath(_ path: String) -> Bool {
        for prefix in uiPathPrefixes where path.hasPrefix(prefix) {
            if path.dropFirst(prefix.count).contains(".app/") { return true }
        }
        return false
    }

    /// Stage 3: `build_dyld_for_bundle`. The first override whose pattern is in the service name decides, else the
    /// dylib's default. The revised engine asks the same of "application.<bundleID>." (without regard to case) for
    /// an app in a bundle, and injects only if both allow; pass the app's `bundleID` for that ("" when it has none
    /// that can be read). nil means a program outside a bundle: the service name alone decides.
    public static func decisions(service: String, bundleID: String? = nil, config: EffectiveConfig,
                                 rules: EngineRules = .active, fileExists: (String) -> Bool) -> [DylibDecision] {
        let verified = rules == .revised ? bundleID.map { "application.\($0)." } : nil
        return config.dylibs.map { dylib in
            var allowed = dylib.defaultAllow
            var reason = DylibDecision.Reason.defaultPolicy(line: dylib.line)
            if let o = dylib.overrides.first(where: { service.contains($0.pattern) }) {
                allowed = o.allow
                reason = .override(line: o.line, pattern: o.pattern)
            }
            if allowed, let verified, let bundleID {
                let own = dylib.overrides.first {
                    $0.pattern.isEmpty || verified.range(of: $0.pattern, options: .caseInsensitive) != nil
                }
                if !(own?.allow ?? dylib.defaultAllow) {
                    allowed = false
                    reason = .appIdentifier(bundleID: bundleID, line: own?.line ?? dylib.line, pattern: own?.pattern,
                                            label: reason)
                }
            }
            return DylibDecision(dylibPath: dylib.path, allowed: allowed, reason: reason,
                                 fileMissing: !fileExists(dylib.path))
        }
    }

    public static func evaluate(app: InstalledApp, service: String, config: EffectiveConfig,
                                rules: EngineRules = .active,
                                fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> AppEvaluation
    {
        AppEvaluation(
            serviceName: service,
            serviceGate: serviceGate(service, config: config, rules: rules),
            processGate: processGate(name: app.executableName, path: app.executablePath, config: config),
            decisions: decisions(service: service, bundleID: app.bundleID, config: config, rules: rules,
                                 fileExists: fileExists)
        )
    }
}
