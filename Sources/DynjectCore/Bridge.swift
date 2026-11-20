import Foundation
import os

// DynjectBridge, part 1: everything that decides. A sandboxed tweak sends {v, tweak, action, args} over XPC to
// `dw bridge serve`; the broker identifies the calling app from its audit token, checks the request against the
// live config and the tweak's manifest, performs one narrow action and replies {ok, error?, message?, result?}.
// The transport, the code-signing lookups and the side effects live in BridgeSystem.swift; this file is pure
// so tests can drive it with fakes. Spec: docs/bridge.md.

/// Names the broker and the SDK agree on. Tests use their own set so nothing real is touched.
public struct BridgeNames: Equatable, Sendable {
    /// Mach service (and LaunchAgent label) the broker listens on.
    public var service: String
    /// Global preferences key holding the sandbox extension token.
    public var tokenKey: String
    /// Global preferences key holding the protocol version.
    public var versionKey: String
    /// Darwin notification posted after the token is (re)published.
    public var notification: String

    public init(service: String, tokenKey: String, versionKey: String, notification: String) {
        self.service = service
        self.tokenKey = tokenKey
        self.versionKey = versionKey
        self.notification = notification
    }

    public static let production = BridgeNames(service: "local.dynject.bridge", tokenKey: "dynject.bridge.token",
                                               versionKey: "dynject.bridge.version", notification: "dynject.bridge.changed")

    /// True when no name is one of the production ones (test mode requires this).
    public var isDisjointFromProduction: Bool {
        let p = Self.production
        let mine = [service, tokenKey, versionKey, notification]
        return !mine.contains(where: { [p.service, p.tokenKey, p.versionKey, p.notification].contains($0) })
    }
}

public enum BridgeProtocol {
    public static let version = 1
    /// os_log subsystem of the broker.
    public static let logSubsystem = "local.dynject.bridge"
    /// Requests and replies are a binary plist in this key of the XPC dictionary.
    public static let payloadKey = "plist"
    public static let maxMessageBytes = 1 << 20
}

// MARK: - Capabilities

/// What a tweak's manifest lets it ask the broker for (manifest key `bridge`).
public enum BridgeCapability: Hashable, Sendable, Comparable {
    case settingsSet
    case notify
    case pasteboardWrite
    case open(scheme: String)

    public init?(_ string: String) {
        switch string {
        case "settings.set": self = .settingsSet
        case "notify": self = .notify
        case "pasteboard.write": self = .pasteboardWrite
        default:
            guard string.hasPrefix("open:") else { return nil }
            let scheme = String(string.dropFirst(5))
            guard Self.isOpenableScheme(scheme) else { return nil }
            self = .open(scheme: scheme)
        }
    }

    public var rawValue: String {
        switch self {
        case .settingsSet: return "settings.set"
        case .notify: return "notify"
        case .pasteboardWrite: return "pasteboard.write"
        case let .open(scheme): return "open:\(scheme)"
        }
    }

    /// One line for the tweak page and the install review.
    public var summary: String {
        switch self {
        case .settingsSet: return "Change its own settings (only keys its manifest declares)"
        case .notify: return "Post Darwin notifications named after itself"
        case .pasteboardWrite: return "Put text on the clipboard"
        case let .open(scheme): return "Open \(scheme): links"
        }
    }

    /// Schemes whose links only show something (a page, a new mail). Any other declared scheme hands a URL to an
    /// app that may act on it, so the install review warns about it.
    public static let lowRiskSchemes: Set<String> = ["http", "https", "mailto"]

    /// An `open:` capability for a scheme outside `lowRiskSchemes`.
    public var isHighRisk: Bool {
        if case let .open(scheme) = self { return !Self.lowRiskSchemes.contains(scheme) }
        return false
    }

    public static func < (a: BridgeCapability, b: BridgeCapability) -> Bool { a.rawValue < b.rawValue }

    /// Schemes `open:` may never name: local files, script, data and browser-internal URLs, network file systems
    /// and remote shells, and handlers that act on the URL (run a shortcut or a command, open a repository, place a
    /// call, join a meeting, install an app, subscribe a calendar, or Workbench's own respring and safe mode links).
    public static let forbiddenSchemes: Set<String> = [
        "file", "javascript", "vbscript", "data", "blob", "about", "applescript", "help", "x-man-page",
        "afp", "smb", "nfs", "cifs", "ftp", "ftps", "vnc", "ssh", "telnet", "sftp", "rdp",
        "shortcuts", "workflow", "vscode", "vscode-insiders", "cursor", "windsurf", "zed", "idea", "jetbrains",
        "facetime", "facetime-audio", "facetime-group", "tel", "telprompt", "sms", "imessage", "callto", "skype",
        "webcal", "zoommtg", "zoomus", "msteams", "slack", "discord", "terminal", "iterm2", "warp", "x-github-client",
        "github-mac", "github-windows", "sourcetree", "itms", "itms-apps", "itms-services", "macappstore",
        "macappstores", "dynject-workbench",
    ]

    /// Prefixes of scheme families that are forbidden as a whole: Apple's private handlers and Office's.
    public static let forbiddenSchemePrefixes = ["x-apple", "ms-"]

    /// Lowercase RFC 3986 scheme that is neither forbidden nor in a forbidden family.
    public static func isOpenableScheme(_ s: String) -> Bool {
        guard s.range(of: "^[a-z][a-z0-9+.-]{0,63}$", options: .regularExpression) != nil else { return false }
        return !forbiddenSchemes.contains(s) && !forbiddenSchemePrefixes.contains(where: { s.hasPrefix($0) })
    }

    /// Parses the manifest's `bridge` value. Bad entries are skipped with an error.
    public static func parseManifestValue(_ raw: Any?, error: (String) -> Void, warning: (String) -> Void) -> [BridgeCapability] {
        guard let raw else { return [] }
        guard let list = raw as? [Any] else {
            error("bridge must be an array of capability strings; ignored.")
            return []
        }
        var out: [BridgeCapability] = []
        for (i, entry) in list.enumerated() {
            guard let s = entry as? String else { error("bridge[\(i)] is not a string; skipped."); continue }
            guard let c = BridgeCapability(s) else {
                if s.hasPrefix("open:") {
                    error("bridge[\(i)] \"\(s)\": open needs a lowercase URL scheme that isn't file, javascript, data, x-apple*, ms-*, dynject-workbench or another local, script or action-taking scheme; skipped.")
                } else {
                    error("bridge[\(i)] \"\(s)\" is not a capability (settings.set, notify, open:<scheme>, pasteboard.write); skipped.")
                }
                continue
            }
            if out.contains(c) { warning("bridge[\(i)] \"\(s)\" is listed twice."); continue }
            if c.isHighRisk {
                warning("bridge[\(i)] \"\(s)\": links of this scheme go to an app that may act on them; only http, https and mailto just show something.")
            }
            out.append(c)
        }
        return out
    }
}

// MARK: - Requests and replies

public enum BridgeErrorCode: String, Sendable, Codable, CaseIterable {
    case badRequest = "bad-request"
    case tooLarge = "too-large"
    case unsupportedVersion = "unsupported-version"
    case unidentifiedCaller = "unidentified-caller"
    case untrustedCaller = "untrusted-caller"
    case identityMismatch = "identity-mismatch"
    case unknownAction = "unknown-action"
    case unknownTweak = "unknown-tweak"
    case configUnavailable = "config-unavailable"
    case notInjected = "not-injected"
    case capabilityMissing = "capability-missing"
    case badArguments = "bad-arguments"
    case rateLimited = "rate-limited"
    case failed = "failed"
}

public struct BridgeDenial: Error, Equatable, Sendable {
    public var code: BridgeErrorCode
    public var message: String
    public init(_ code: BridgeErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

public enum BridgeAction: String, Sendable, CaseIterable {
    case ping
    case settingsSet = "settings.set"
    case notify
    case open
    case pasteboardWrite = "pasteboard.write"
}

public struct BridgeRequest {
    public var version: Int
    public var tweak: String
    public var action: String
    public var args: [String: Any]

    static let tweakIDPattern = "^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$"

    /// Shape checks only; nothing here depends on who is asking.
    public static func parse(_ object: Any?) -> Result<BridgeRequest, BridgeDenial> {
        guard let d = object as? [String: Any] else { return .failure(.init(.badRequest, "the request is not a dictionary")) }
        guard let v = d["v"] as? Int else { return .failure(.init(.badRequest, "v (protocol version) is missing")) }
        guard v == BridgeProtocol.version else {
            return .failure(.init(.unsupportedVersion, "protocol version \(v); this broker speaks \(BridgeProtocol.version)"))
        }
        guard let tweak = d["tweak"] as? String, tweak.range(of: tweakIDPattern, options: .regularExpression) != nil else {
            return .failure(.init(.badRequest, "tweak must be a tweak identifier"))
        }
        guard let action = d["action"] as? String, !action.isEmpty, action.utf8.count <= 64 else {
            return .failure(.init(.badRequest, "action must be a short string"))
        }
        var args: [String: Any] = [:]
        if let a = d["args"] {
            guard let dict = a as? [String: Any] else { return .failure(.init(.badRequest, "args must be a dictionary")) }
            args = dict
        }
        return .success(BridgeRequest(version: v, tweak: tweak, action: action, args: args))
    }
}

public enum BridgeReply {
    public static func ok(_ result: Any? = nil) -> [String: Any] {
        var r: [String: Any] = ["ok": true]
        if let result { r["result"] = result }
        return r
    }

    public static func error(_ d: BridgeDenial) -> [String: Any] {
        ["ok": false, "error": d.code.rawValue, "message": d.message]
    }
}

// MARK: - Caller identity

/// Who is on the other end of a connection, from its audit token (BridgeSystem's SecurityIdentityProvider) or
/// made up by tests. The caller is the host app: every dylib loaded in it shares this identity.
public struct BridgeCallerIdentity: Equatable, Sendable {
    public var pid: Int32
    /// From the code signature (SecCodeCopySigningInformation on the guest code for the audit token).
    public var signingIdentifier: String?
    /// The kernel's view of the same (SecTaskCopySigningIdentifier). Must match.
    public var taskSigningIdentifier: String?
    public var teamID: String?
    public var executablePath: String?
    /// SecCodeCheckValidity on the running process passed.
    public var signatureValid: Bool
    /// The code satisfies `anchor apple` (Apple's own software).
    public var appleAnchored: Bool
    /// The code satisfies the Developer ID requirement for its team (`BridgeRequirements.developerID`).
    public var developerID: Bool
    /// The code satisfies the Mac App Store requirement (`BridgeRequirements.appStore`).
    public var appStore: Bool
    public var adHoc: Bool
    /// The signature has the hardened runtime flag (CS_RUNTIME, 0x10000).
    public var hardenedRuntime: Bool
    /// One of com.apple.security.cs.allow-dyld-environment-variables, .disable-library-validation or
    /// com.apple.security.get-task-allow: other code can be put into the process from outside.
    public var weakenedCodeLoading: Bool
    /// Its parent is launchd (pid 1), read before the audit-token lookup so it describes the same process.
    public var parentIsLaunchd: Bool
    /// It is its own responsible process, as LaunchServices launches make it (a process a shell started stays
    /// attributed to the terminal, even after its parent exits). nil: the private lookup isn't available.
    public var selfResponsible: Bool?
    public var sandboxed: Bool
    /// CFBundleIdentifier and executable of the .app bundle that holds `executablePath`.
    public var bundleIdentifier: String?
    public var bundleExecutablePath: String?
    public var bundlePath: String?

    public init(pid: Int32, signingIdentifier: String?, taskSigningIdentifier: String?, teamID: String?,
                executablePath: String?, signatureValid: Bool, appleAnchored: Bool, developerID: Bool, appStore: Bool = false,
                adHoc: Bool, hardenedRuntime: Bool = true, weakenedCodeLoading: Bool = false, parentIsLaunchd: Bool = true,
                selfResponsible: Bool? = true, sandboxed: Bool, bundleIdentifier: String?, bundleExecutablePath: String?,
                bundlePath: String?) {
        self.pid = pid
        self.signingIdentifier = signingIdentifier
        self.taskSigningIdentifier = taskSigningIdentifier
        self.teamID = teamID
        self.executablePath = executablePath
        self.signatureValid = signatureValid
        self.appleAnchored = appleAnchored
        self.developerID = developerID
        self.appStore = appStore
        self.adHoc = adHoc
        self.hardenedRuntime = hardenedRuntime
        self.weakenedCodeLoading = weakenedCodeLoading
        self.parentIsLaunchd = parentIsLaunchd
        self.selfResponsible = selfResponsible
        self.sandboxed = sandboxed
        self.bundleIdentifier = bundleIdentifier
        self.bundleExecutablePath = bundleExecutablePath
        self.bundlePath = bundlePath
    }
}

/// Code requirements for the signing classes the bridge accepts.
public enum BridgeRequirements {
    public static let apple = "anchor apple"
    /// Developer ID Application: intermediate with the Developer ID CA marker, leaf with the Developer ID
    /// Application marker, and the team in the leaf.
    public static func developerID(team: String) -> String? {
        guard isTeamID(team) else { return nil }
        return "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and "
            + "certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(team)\""
    }
    /// Apple Mac OS Application Signing: how the Mac App Store re-signs apps.
    public static let appStore = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]"

    public static func isTeamID(_ s: String) -> Bool { s.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil }
}

/// A connected process as the transport sees it, before any code-signing lookup.
public struct BridgePeer: Hashable, Sendable {
    public var pid: Int32
    /// From the audit token; distinguishes a reused pid.
    public var pidVersion: Int32
    public init(pid: Int32, pidVersion: Int32) {
        self.pid = pid
        self.pidVersion = pidVersion
    }
    var key: String { "\(pid).\(pidVersion)" }
}

// MARK: - Policy

/// Where the authorizer gets the live state. The broker reads the config and the Tweaks folders on each request.
public struct BridgePolicySources {
    public var manifests: () -> [TweakManifest]
    /// nil: unreadable (every request is then denied).
    public var config: () -> EffectiveConfig?
    public var fileExists: (String) -> Bool
    /// Installed apps with this bundle ID in the app folders (AppDiscovery), as dynjectd's filters would see them.
    public var installedApps: (String) -> [InstalledApp]

    public init(manifests: @escaping () -> [TweakManifest], config: @escaping () -> EffectiveConfig?,
                fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                installedApps: @escaping (String) -> [InstalledApp]) {
        self.manifests = manifests
        self.config = config
        self.fileExists = fileExists
        self.installedApps = installedApps
    }
}

/// A request that passed rules (a) and (b): who asked, for which tweak.
public struct BridgeGrant {
    public var identity: BridgeCallerIdentity
    public var bundleID: String
    public var manifest: TweakManifest
    /// Identifiers of every installed manifest (notify keeps out of the others' namespaces).
    public var installedTweakIDs: [String]
    public var capabilities: [BridgeCapability] { manifest.bridge }

    public init(identity: BridgeCallerIdentity, bundleID: String, manifest: TweakManifest, installedTweakIDs: [String] = []) {
        self.identity = identity
        self.bundleID = bundleID
        self.manifest = manifest
        self.installedTweakIDs = installedTweakIDs
    }
}

public enum BridgeAuthorizer {
    /// Identifiers only Apple's own code may have: com.apple.*, and the apps dynjectd knows by launchd label
    /// (Finder, Dock).
    public static func isAppleOnlyIdentifier(_ id: String) -> Bool {
        let l = id.lowercased()
        return l.hasPrefix("com.apple.") || ServiceNameResolver.knownLaunchdLabels[l] != nil
    }

    /// Rule (a), first half: the caller is a signed app we can name.
    /// - Apple's code satisfies `anchor apple`; com.apple.* and Finder/Dock identifiers must.
    /// - Anyone else: Developer ID with a team ID, or Mac App Store; hardened runtime; none of the entitlements
    ///   that let other code be loaded or attached (`weakenedCodeLoading`).
    /// - Ad hoc only in test mode, which also waives the hardened-runtime and launch checks for it.
    /// - Launched as an app: parent is launchd and it is its own responsible process.
    /// - The signing identifier agrees with the kernel's and with the CFBundleIdentifier of the bundle holding the
    ///   executable. Returns the bundle ID.
    public static func trust(_ id: BridgeCallerIdentity, allowAdHoc: Bool) -> Result<String, BridgeDenial> {
        guard let sid = id.signingIdentifier, !sid.isEmpty else {
            return .failure(.init(.unidentifiedCaller, "the caller has no code signing identifier"))
        }
        guard id.taskSigningIdentifier == sid else {
            return .failure(.init(.identityMismatch, "the code signature says \(sid), the kernel says \(id.taskSigningIdentifier ?? "nothing")"))
        }
        guard id.signatureValid else { return .failure(.init(.untrustedCaller, "\(sid): the code signature is not valid")) }
        if isAppleOnlyIdentifier(sid) && !id.appleAnchored {
            return .failure(.init(.untrustedCaller, "\(sid) is an Apple identifier but the code isn't signed by Apple"))
        }
        let testAdHoc = id.adHoc && allowAdHoc && !id.appleAnchored
        let trusted = id.appleAnchored || (id.developerID && BridgeRequirements.isTeamID(id.teamID ?? "")) || id.appStore || testAdHoc
        guard trusted else {
            return .failure(.init(.untrustedCaller, id.adHoc ? "\(sid) is signed ad hoc" : "\(sid) is neither Apple's, Developer ID nor Mac App Store"))
        }
        if !id.appleAnchored && !testAdHoc {
            guard id.hardenedRuntime else { return .failure(.init(.untrustedCaller, "\(sid) doesn't use the hardened runtime")) }
            guard !id.weakenedCodeLoading else {
                return .failure(.init(.untrustedCaller, "\(sid) has an entitlement that lets other code into it (DYLD variables, library validation off, get-task-allow)"))
            }
        }
        if !testAdHoc {
            guard id.parentIsLaunchd, id.selfResponsible != false else {
                return .failure(.init(.untrustedCaller, "\(sid) wasn't launched as an app (its parent isn't launchd, or another process is responsible for it)"))
            }
        }
        guard let exe = id.executablePath, let bexe = id.bundleExecutablePath, let bid = id.bundleIdentifier else {
            return .failure(.init(.identityMismatch, "\(sid) is not the executable of an app bundle"))
        }
        guard bid == sid, samePath(exe, bexe) else {
            return .failure(.init(.identityMismatch, "\(sid) runs \(exe), whose bundle is \(bid) with executable \(bexe)"))
        }
        return .success(sid)
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        (a as NSString).resolvingSymlinksInPath == (b as NSString).resolvingSymlinksInPath
    }

    /// Override patterns that name exactly this app: the forms Workbench writes (ConfigEditor.specificPattern).
    public static func exactPatterns(for app: InstalledApp, service: String) -> Set<String> {
        var s: Set<String> = [app.bundleID, "application.\(app.bundleID)."]
        if !service.hasPrefix("application.") { s.insert(service) }
        return s
    }

    /// Rules (a) and (b) up to the capability: trusted caller, installed at a scanned location under its own bundle
    /// ID, known tweak, its dylib injected into exactly this app by the live config.
    public static func authorize(tweak: String, identity: BridgeCallerIdentity, sources: BridgePolicySources,
                                 allowAdHoc: Bool) -> Result<BridgeGrant, BridgeDenial> {
        let bundleID: String
        switch trust(identity, allowAdHoc: allowAdHoc) {
        case let .failure(d): return .failure(d)
        case let .success(b): bundleID = b
        }
        let manifests = sources.manifests()
        guard let manifest = manifests.first(where: { $0.id == tweak }) else {
            return .failure(.init(.unknownTweak, "no installed manifest has the identifier \(tweak)"))
        }
        guard let config = sources.config() else {
            return .failure(.init(.configUnavailable, "the Dynject config could not be read"))
        }
        // The app as the policy sees it: the installed bundle with this ID that the caller runs from. A copy
        // somewhere else (Downloads, a disk image) is not the app the user configured.
        guard let callerBundle = identity.bundlePath,
              let app = sources.installedApps(bundleID).first(where: { samePath($0.bundlePath, callerBundle) }) else {
            return .failure(.init(.notInjected, "\(bundleID) at \(identity.bundlePath ?? "?") is not an installed app in the app folders"))
        }
        let service = ServiceNameResolver.resolve(app, log: nil).value
        let eval = PolicyEvaluator.evaluate(app: app, service: service, config: config, fileExists: sources.fileExists)
        let dylibName = (manifest.dylib as NSString).lastPathComponent
        guard eval.isInjected(manifest.dylib), let decision = eval.decision(for: manifest.dylib) else {
            return .failure(.init(.notInjected, "the config doesn't inject \(dylibName) into \(bundleID)"))
        }
        // dynjectd matches override patterns as substrings, so "com.apple.Notes" also covers com.evil.com.apple.Notes.
        // The bridge only honours an override that names this app exactly (or the dylib's default allow).
        if case let .override(line, pattern) = decision.reason, !exactPatterns(for: app, service: service).contains(pattern) {
            return .failure(.init(.notInjected, "\(dylibName) reaches \(bundleID) only through the pattern \"\(pattern)\" (line \(line + 1)), which isn't specific to it"))
        }
        return .success(BridgeGrant(identity: identity, bundleID: bundleID, manifest: manifest, installedTweakIDs: manifests.map(\.id)))
    }
}

// MARK: - Actions

/// The broker's side effects. Tests record them.
public protocol BridgeEffects: AnyObject {
    /// Where `settings.set` writes (the global domain live; a file in test mode).
    var settingsBackend: TweakPrefsBackend { get }
    func postNotification(_ name: String)
    func open(_ url: URL) -> Bool
    func writePasteboard(_ string: String) -> Bool
}

public enum BridgeActions {
    public static let maxNotificationNameBytes = 200
    public static let maxURLBytes = 4096
    public static let maxPasteboardBytes = 512 * 1024
    public static let maxTextSettingBytes = 64 * 1024
    public static let maxAppListCount = 1000
    /// What one tweak's settings key may hold after a bridge write (binary plist).
    public static let maxSettingsPayloadBytes = 256 * 1024
    /// Integer settings are stored as Int; beyond 2^53 a Double can't say which Int it means.
    public static let maxIntegerMagnitude = 9_007_199_254_740_992.0
    /// Notification namespaces that belong to the system or to Dynject's infrastructure, whatever a tweak is called.
    /// Example tweaks under local.dynject.* (titlebadge, oledfinder) keep their own namespaces.
    public static let reservedNotificationPrefixes = ["com.apple.", "dynject.", "local.dynject.menuloader", "local.dynject.bridge",
                                                      "local.dynject.safemode", "local.dynject.workbench"]

    /// The capability an action needs (nil: none; `open` checks its scheme separately).
    public static func requiredCapability(_ a: BridgeAction) -> BridgeCapability? {
        switch a {
        case .ping, .open: return nil
        case .settingsSet: return .settingsSet
        case .notify: return .notify
        case .pasteboardWrite: return .pasteboardWrite
        }
    }

    /// Rules (b) and (c) for one action: the capability is declared and the arguments pass the action's checks.
    /// Returns what to do, without doing it.
    public static func validate(_ action: BridgeAction, args: [String: Any], grant: BridgeGrant) -> Result<Plan, BridgeDenial> {
        if let need = requiredCapability(action), !grant.capabilities.contains(need) {
            return .failure(.init(.capabilityMissing, "\(grant.manifest.id) doesn't declare \(need.rawValue) in its manifest"))
        }
        switch action {
        case .ping:
            return .success(.ping)
        case .settingsSet:
            return validateSetting(args, grant: grant)
        case .notify:
            guard let name = args["name"] as? String else { return .failure(.init(.badArguments, "notify needs name (a string)")) }
            return validateNotification(name, tweak: grant.manifest.id, installedTweakIDs: grant.installedTweakIDs).map { .notify($0) }
        case .open:
            let schemes = grant.capabilities.compactMap { c -> String? in if case let .open(s) = c { return s } else { return nil } }
            guard !schemes.isEmpty else {
                return .failure(.init(.capabilityMissing, "\(grant.manifest.id) doesn't declare any open:<scheme> in its manifest"))
            }
            guard let s = args["url"] as? String else { return .failure(.init(.badArguments, "open needs url (a string)")) }
            return validateURL(s, declared: schemes).map { .open($0) }
        case .pasteboardWrite:
            guard let s = args["string"] as? String else { return .failure(.init(.badArguments, "pasteboard.write needs string")) }
            guard s.utf8.count <= maxPasteboardBytes else {
                return .failure(.init(.badArguments, "the string is longer than \(maxPasteboardBytes) bytes"))
            }
            return .success(.pasteboard(s))
        }
    }

    public enum Plan {
        case ping
        case setting(item: TweakItem, value: PrefValue, app: String?)
        case notify(String)
        case open(URL)
        case pasteboard(String)
    }

    static func validateSetting(_ args: [String: Any], grant: BridgeGrant) -> Result<Plan, BridgeDenial> {
        let m = grant.manifest
        guard let key = args["key"] as? String, !key.isEmpty else { return .failure(.init(.badArguments, "settings.set needs key")) }
        guard let item = m.item(key) else {
            return .failure(.init(.badArguments, "\"\(key)\" is not a setting in \(m.id)'s manifest"))
        }
        guard let raw = args["value"] else { return .failure(.init(.badArguments, "settings.set needs value")) }
        guard let v = PrefValue(plist: raw), let n = strictlyNormalized(v, for: item) else {
            return .failure(.init(.badArguments, "the value doesn't fit \"\(key)\" (\(item.kind.rawValue)\(rangeText(item)))"))
        }
        var app: String?
        if let a = args["app"] {
            guard let s = a as? String else { return .failure(.init(.badArguments, "app must be a bundle ID")) }
            guard s == grant.bundleID else {
                return .failure(.init(.badArguments, "a tweak can only set an override for the app it runs in (\(grant.bundleID)), not \(s)"))
            }
            guard item.perApp else { return .failure(.init(.badArguments, "\"\(key)\" has no per-app overrides (perApp)")) }
            app = s
        }
        return .success(.setting(item: item, value: n, app: app))
    }

    static func rangeText(_ item: TweakItem) -> String {
        switch (item.min, item.max) {
        case let (lo?, hi?): return " \(PrefValue.number(lo).displayText)…\(PrefValue.number(hi).displayText)"
        case let (lo?, nil): return " ≥ \(PrefValue.number(lo).displayText)"
        case let (nil, hi?): return " ≤ \(PrefValue.number(hi).displayText)"
        default: return ""
        }
    }

    /// TweakItem.normalized clamps numbers into range; a request is refused instead. Step rounding is kept.
    public static func strictlyNormalized(_ v: PrefValue, for item: TweakItem) -> PrefValue? {
        switch (item.kind, v) {
        case (.slider, .number(let n)), (.number, .number(let n)):
            guard n.isFinite else { return nil }
            if let lo = item.min, n < lo { return nil }
            if let hi = item.max, n > hi { return nil }
            if item.integer, n != n.rounded() || abs(n) > maxIntegerMagnitude { return nil }
        case (.text, .string(let s)):
            guard s.utf8.count <= maxTextSettingBytes else { return nil }
        case (.appList, .list(let l)):
            guard l.count <= maxAppListCount,
                  l.allSatisfy({ $0.utf8.count <= 255 && $0.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil })
            else { return nil }
        default: break
        }
        // Step rounding can still push a huge value to infinity.
        guard let out = item.normalized(v) else { return nil }
        if case let .number(n) = out, !n.isFinite || (item.integer && abs(n) > maxIntegerMagnitude) { return nil }
        return out
    }

    public static func validateNotification(_ name: String, tweak: String, installedTweakIDs: [String] = []) -> Result<String, BridgeDenial> {
        guard name.utf8.count <= maxNotificationNameBytes,
              name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return .failure(.init(.badArguments, "notification names are letters, digits, '.', '_' and '-', at most \(maxNotificationNameBytes) bytes"))
        }
        guard name == tweak || name.hasPrefix(tweak + ".") else {
            return .failure(.init(.badArguments, "\(tweak) may only post notifications named \(tweak) or \(tweak).*"))
        }
        let lower = name.lowercased()
        if let p = reservedNotificationPrefixes.first(where: { lower.hasPrefix($0) }) {
            return .failure(.init(.badArguments, "names starting with \(p) are reserved"))
        }
        // com.you.glass may not post into com.you.glass.pro's namespace when that tweak is installed.
        if let other = installedTweakIDs.first(where: { $0 != tweak && $0.hasPrefix(tweak + ".") && (name == $0 || name.hasPrefix($0 + ".")) }) {
            return .failure(.init(.badArguments, "\(name) belongs to the installed tweak \(other)"))
        }
        return .success(name)
    }

    public static func validateURL(_ s: String, declared: [String]) -> Result<URL, BridgeDenial> {
        guard s.utf8.count <= maxURLBytes, let url = URL(string: s), let raw = url.scheme else {
            return .failure(.init(.badArguments, "not an absolute URL"))
        }
        let scheme = raw.lowercased()
        guard BridgeCapability.isOpenableScheme(scheme) else {
            return .failure(.init(.badArguments, "\(scheme): URLs are never opened"))
        }
        guard declared.contains(scheme) else {
            return .failure(.init(.capabilityMissing, "the manifest doesn't declare open:\(scheme)"))
        }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, !host.isEmpty else { return .failure(.init(.badArguments, "\(scheme) URL without a host")) }
        }
        return .success(url)
    }

    /// Does it. Returns the reply's result, or a `failed` denial.
    public static func perform(_ plan: Plan, grant: BridgeGrant, effects: BridgeEffects) -> Result<Any?, BridgeDenial> {
        switch plan {
        case .ping:
            return .success([
                "protocol": BridgeProtocol.version,
                "broker": WorkbenchInfo.version,
                "brokerPID": Int(getpid()),
                "app": grant.bundleID,
                "capabilities": grant.capabilities.map(\.rawValue),
            ] as [String: Any])
        case let .setting(item, value, app):
            let settings = TweakSettings(manifest: grant.manifest, backend: effects.settingsBackend)
            let ok = app.map { settings.setOverride(value, for: item, bundleID: $0) } ?? settings.set(value, for: item)
            guard ok else { return .failure(.init(.badArguments, "the value doesn't fit \"\(item.key)\"")) }
            let size = (try? PropertyListSerialization.data(fromPropertyList: settings.payload, format: .binary, options: 0))?.count ?? .max
            guard size <= maxSettingsPayloadBytes else {
                return .failure(.init(.badArguments, "\(grant.manifest.id)'s settings would be larger than \(maxSettingsPayloadBytes / 1024) KB"))
            }
            do { try settings.persist() } catch { return .failure(.init(.failed, error.localizedDescription)) }
            return .success(["key": item.key, "value": value.plistObject(integer: item.integer)] as [String: Any])
        case let .notify(name):
            effects.postNotification(name)
            return .success(nil)
        case let .open(url):
            return effects.open(url) ? .success(nil) : .failure(.init(.failed, "nothing opened \(url.scheme ?? "?"): URLs"))
        case let .pasteboard(s):
            return effects.writePasteboard(s) ? .success(nil) : .failure(.init(.failed, "the clipboard refused the string"))
        }
    }
}

// MARK: - Rate limiting

/// Token buckets keyed by string: `burst` requests at once, refilled at `perSecond`.
public final class BridgeRateLimiter {
    public let burst: Double
    public let perSecond: Double
    let now: () -> Date
    private var buckets: [String: (tokens: Double, at: Date)] = [:]

    public init(burst: Int, perSecond: Double, now: @escaping () -> Date = Date.init) {
        self.burst = Double(max(1, burst))
        self.perSecond = max(0.001, perSecond)
        self.now = now
    }

    /// Takes one token for `key` if there is one.
    public func allow(_ key: String) -> Bool {
        let t = now()
        var b = buckets[key] ?? (burst, t)
        b.tokens = min(burst, b.tokens + max(0, t.timeIntervalSince(b.at)) * perSecond)
        b.at = t
        let ok = b.tokens >= 1
        if ok { b.tokens -= 1 }
        buckets[key] = b
        if buckets.count > 4096 { prune(t) }
        return ok
    }

    /// Drops buckets that have refilled completely; they behave exactly like new ones.
    func prune(_ t: Date) {
        buckets = buckets.filter { min(burst, $0.value.tokens + t.timeIntervalSince($0.value.at) * perSecond) < burst }
    }

    public var count: Int { buckets.count }
}

// MARK: - Decision log

public struct BridgeLogEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var date: Date
    public var pid: Int32
    /// The caller's bundle ID, or "?" before it is known.
    public var app: String
    public var tweak: String
    public var action: String
    public var allowed: Bool
    /// "ok" or the error code.
    public var reason: String
    public var detail: String?
    /// Identical consecutive denials (a flood of rate-limited requests) are folded into one entry.
    public var count: Int

    public init(id: Int = 0, date: Date, pid: Int32, app: String, tweak: String, action: String, allowed: Bool,
                reason: String, detail: String? = nil, count: Int = 1) {
        self.id = id
        self.date = date
        self.pid = pid
        self.app = app
        self.tweak = tweak
        self.action = action
        self.allowed = allowed
        self.reason = reason
        self.detail = detail
        self.count = count
    }
}

/// Text that came from a caller, made safe to show: control characters (ESC, BEL, CR, LF, ...), format characters
/// (the bidi overrides U+202A–202E and isolates U+2066–2069, zero-width marks) and line/paragraph separators become
/// visible `\u{XXXX}` escapes. Applied when recording and again when printing, since the file can be edited.
public enum BridgeLogText {
    public static func clean(_ s: String) -> String {
        var out = ""
        out.unicodeScalars.reserveCapacity(s.unicodeScalars.count)
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                out += String(format: "\\u{%04X}", u.value)
            default:
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    public static func clean(_ e: BridgeLogEntry) -> BridgeLogEntry {
        var e = e
        e.app = clean(e.app)
        e.tweak = clean(e.tweak)
        e.action = clean(e.action)
        e.reason = clean(e.reason)
        e.detail = e.detail.map(clean)
        return e
    }
}

/// The last `capacity` decisions, newest last, persisted as JSON for Workbench
/// (~/Library/Application Support/Dynject Workbench/Bridge/log.json).
public final class BridgeDecisionLog {
    public static let formatVersion = 1
    public let capacity: Int
    public let fileURL: URL?
    public private(set) var entries: [BridgeLogEntry]
    public private(set) var isDirty = false
    private var nextID: Int

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dynject Workbench/Bridge/log.json")
    }

    public init(capacity: Int = 200, fileURL: URL?) {
        self.capacity = max(1, capacity)
        self.fileURL = fileURL
        let loaded = fileURL.map(Self.load) ?? []
        entries = Array(loaded.suffix(self.capacity))
        nextID = (entries.map(\.id).max() ?? 0) + 1
    }

    /// How far back a denial looks for an entry of the same caller and reason to fold into.
    public static let foldWindow = 20

    /// Adds a decision. A denial folds into a recent denial of the same caller (pid and app) with the same reason,
    /// whatever its tweak, action or detail, which then moves to the end with the latest of those and a higher
    /// count. So one app can't push everything else out by varying its requests.
    public func append(_ e: BridgeLogEntry) {
        let e = BridgeLogText.clean(e)
        let start = max(0, entries.count - Self.foldWindow)
        if !e.allowed, let i = entries[start...].lastIndex(where: { !$0.allowed && $0.pid == e.pid && $0.app == e.app && $0.reason == e.reason }) {
            var folded = entries.remove(at: i)
            folded.count += 1
            folded.date = e.date
            folded.tweak = e.tweak
            folded.action = e.action
            folded.detail = e.detail
            entries.append(folded)
        } else {
            var e = e
            e.id = nextID
            nextID += 1
            entries.append(e)
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }
        isDirty = true
    }

    struct File: Codable {
        var formatVersion: Int
        var entries: [BridgeLogEntry]
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public func save() throws {
        guard let fileURL else { isDirty = false; return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder().encode(File(formatVersion: Self.formatVersion, entries: entries))
        try AtomicFile.write(data, to: fileURL.path)
        isDirty = false
    }

    /// Entries in a log file, oldest first; [] when missing or unreadable.
    public static func load(_ url: URL) -> [BridgeLogEntry] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(File.self, from: data))?.entries ?? []
    }
}

// MARK: - The handler

/// One request in, one reply out. Not thread-safe: the broker calls it from one serial queue.
public final class BridgeService {
    public struct Settings: Sendable {
        /// Test mode only: accept ad-hoc signed callers.
        public var allowAdHocCallers = false
        public var maxMessageBytes = BridgeProtocol.maxMessageBytes
        /// Per (caller process, tweak): rule (d).
        public var tweakBurst = 20
        public var tweakPerSecond = 5.0
        /// Per caller process, before anything else, so a flood of junk can't make the broker work.
        public var processBurst = 60
        public var processPerSecond = 20.0
        public init() {}
    }

    public let settings: Settings
    public let sources: BridgePolicySources
    public let effects: BridgeEffects
    public let log: BridgeDecisionLog
    let tweakLimiter: BridgeRateLimiter
    let processLimiter: BridgeRateLimiter
    let logger = Logger(subsystem: BridgeProtocol.logSubsystem, category: "decision")
    /// Called after every decision (the broker schedules a save of the log).
    public var onDecision: ((BridgeLogEntry) -> Void)?

    public init(settings: Settings = Settings(), sources: BridgePolicySources, effects: BridgeEffects, log: BridgeDecisionLog,
                now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.sources = sources
        self.effects = effects
        self.log = log
        tweakLimiter = BridgeRateLimiter(burst: settings.tweakBurst, perSecond: settings.tweakPerSecond, now: now)
        quietLimiter = BridgeRateLimiter(burst: 20, perSecond: 5, now: now)
        processLimiter = BridgeRateLimiter(burst: settings.processBurst, perSecond: settings.processPerSecond, now: now)
        self.now = now
    }

    let now: () -> Date
    /// Bounds the os_log lines for denials that never reach the decision log.
    let quietLimiter: BridgeRateLimiter
    private var quietSuppressed = 0

    /// What the transport got: the request bytes, or only their length when it was over the limit (never copied).
    public enum Payload {
        case data(Data)
        case tooLarge(Int)
    }

    /// The wire form: a binary plist in, a binary plist out. The per-process rate limit comes first, then the size,
    /// then parsing. `identify` is called at most once, and only for a request that parsed.
    public func handle(payload: Payload, peer: BridgePeer, identify: () -> BridgeCallerIdentity?) -> Data {
        let reply: [String: Any]
        if !processLimiter.allow(peer.key) {
            reply = quietDenial(peer, .init(.rateLimited, "too many requests from this process"))
        } else {
            switch payload {
            case let .tooLarge(n):
                reply = quietDenial(peer, .init(.tooLarge, "the request is \(n) bytes; at most \(settings.maxMessageBytes)"))
            case let .data(d) where d.count > settings.maxMessageBytes:
                reply = quietDenial(peer, .init(.tooLarge, "the request is \(d.count) bytes; at most \(settings.maxMessageBytes)"))
            case let .data(d):
                reply = process(object: try? PropertyListSerialization.propertyList(from: d, format: nil), peer: peer, identify: identify)
            }
        }
        return (try? PropertyListSerialization.data(fromPropertyList: reply, format: .binary, options: 0))
            ?? (try! PropertyListSerialization.data(fromPropertyList: ["ok": false, "error": BridgeErrorCode.failed.rawValue],
                                                    format: .binary, options: 0))
    }

    public func handle(data: Data, peer: BridgePeer, identify: () -> BridgeCallerIdentity?) -> Data {
        handle(payload: .data(data), peer: peer, identify: identify)
    }

    /// handle(payload:) for an already parsed request (tests).
    public func handle(object: Any?, peer: BridgePeer, identify: () -> BridgeCallerIdentity?) -> [String: Any] {
        guard processLimiter.allow(peer.key) else { return quietDenial(peer, .init(.rateLimited, "too many requests from this process")) }
        return process(object: object, peer: peer, identify: identify)
    }

    /// Codes decided before the caller is a trusted app. They go to os_log (rate-limited) and never into the decision
    /// log, so an unknown process can't fill it.
    static let quietCodes: Set<BridgeErrorCode> = [.tooLarge, .badRequest, .unsupportedVersion, .unidentifiedCaller,
                                                   .untrustedCaller, .identityMismatch]

    /// What the caller is told when nothing of that tweak is injected into it: the same for an unknown tweak and one
    /// that isn't injected, without naming dylibs. The real reason is in the log.
    static func replyDenial(_ d: BridgeDenial, tweak: String?) -> BridgeDenial {
        switch d.code {
        case .unknownTweak, .notInjected: return .init(.notInjected, "\(tweak ?? "that tweak") isn't available in this app")
        default: return d
        }
    }

    /// Applies the rules after the rate limit and size; the first that fails decides. See docs/bridge.md#authorization.
    private func process(object: Any?, peer: BridgePeer, identify: () -> BridgeCallerIdentity?) -> [String: Any] {
        let request: BridgeRequest
        switch BridgeRequest.parse(object) {
        case let .failure(d): return decide(peer: peer, request: nil, identity: nil, denial: d)
        case let .success(r): request = r
        }
        guard let identity = identify() else {
            return decide(peer: peer, request: request, identity: nil,
                          denial: .init(.unidentifiedCaller, "the caller's code identity could not be read"))
        }
        let grant: BridgeGrant
        switch BridgeAuthorizer.authorize(tweak: request.tweak, identity: identity, sources: sources,
                                          allowAdHoc: settings.allowAdHocCallers) {
        case let .failure(d): return decide(peer: peer, request: request, identity: identity, denial: d)
        case let .success(g): grant = g
        }
        guard let action = BridgeAction(rawValue: request.action) else {
            return decide(peer: peer, request: request, identity: identity,
                          denial: .init(.unknownAction, "\(request.action) is not an action (\(BridgeAction.allCases.map(\.rawValue).joined(separator: ", ")))"))
        }
        let plan: BridgeActions.Plan
        switch BridgeActions.validate(action, args: request.args, grant: grant) {
        case let .failure(d): return decide(peer: peer, request: request, identity: identity, denial: d)
        case let .success(p): plan = p
        }
        guard tweakLimiter.allow("\(peer.key)|\(request.tweak)") else {
            return decide(peer: peer, request: request, identity: identity,
                          denial: .init(.rateLimited, "more than \(settings.tweakBurst) requests at once or \(settings.tweakPerSecond)/s for this tweak"))
        }
        switch BridgeActions.perform(plan, grant: grant, effects: effects) {
        case let .failure(d): return decide(peer: peer, request: request, identity: identity, denial: d)
        case let .success(result):
            record(peer: peer, request: request, identity: identity, allowed: true, reason: "ok", detail: nil)
            return BridgeReply.ok(result)
        }
    }

    private func decide(peer: BridgePeer, request: BridgeRequest?, identity: BridgeCallerIdentity?, denial: BridgeDenial) -> [String: Any] {
        if Self.quietCodes.contains(denial.code) {
            return quietDenial(peer, denial, request: request, identity: identity)
        }
        record(peer: peer, request: request, identity: identity, allowed: false, reason: denial.code.rawValue, detail: denial.message)
        return BridgeReply.error(Self.replyDenial(denial, tweak: request?.tweak))
    }

    private func quietDenial(_ peer: BridgePeer, _ denial: BridgeDenial, request: BridgeRequest? = nil,
                             identity: BridgeCallerIdentity? = nil) -> [String: Any] {
        if quietLimiter.allow("all") {
            let app = BridgeLogText.clean(identity?.signingIdentifier ?? "?")
            let what = BridgeLogText.clean(request.map { "\($0.action) for \($0.tweak)" } ?? "a request")
            let note = quietSuppressed > 0 ? " (\(quietSuppressed) more not logged)" : ""
            quietSuppressed = 0
            logger.log("denied \(what, privacy: .public) from \(app, privacy: .public) (pid \(peer.pid)): \(denial.code.rawValue, privacy: .public): \(BridgeLogText.clean(String(denial.message.prefix(300))), privacy: .public)\(note, privacy: .public)")
        } else {
            quietSuppressed += 1
        }
        return BridgeReply.error(denial)
    }

    private func record(peer: BridgePeer, request: BridgeRequest?, identity: BridgeCallerIdentity?, allowed: Bool,
                        reason: String, detail: String?) {
        let app = identity?.signingIdentifier ?? "?"
        // Some messages quote what the caller sent; keep the log small whatever it sent.
        let detail = detail.map { $0.count > 300 ? String($0.prefix(300)) + "…" : $0 }
        let entry = BridgeLogText.clean(BridgeLogEntry(date: now(), pid: peer.pid, app: app, tweak: request?.tweak ?? "?",
                                                       action: request.map { String($0.action.prefix(64)) } ?? "?", allowed: allowed,
                                                       reason: reason, detail: detail))
        log.append(entry)
        if allowed {
            logger.log("allowed \(entry.action, privacy: .public) for \(entry.tweak, privacy: .public) in \(entry.app, privacy: .public) (pid \(peer.pid))")
        } else {
            logger.log("denied \(entry.action, privacy: .public) for \(entry.tweak, privacy: .public) in \(entry.app, privacy: .public) (pid \(peer.pid)): \(reason, privacy: .public): \(entry.detail ?? "", privacy: .public)")
        }
        onDecision?(log.entries.last ?? entry)
    }
}
