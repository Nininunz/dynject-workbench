import AppKit
import Darwin
import Darwin.libproc
import Foundation
import os
import Security
import XPC

// DynjectBridge, part 2: the real world. The XPC listener (transport), the caller's code identity from its audit
// token, the sandbox extension token, the live config and manifests, the side effects, and the LaunchAgent.
// Decisions are made in Bridge.swift.

// MARK: - Private SPI

/// libsystem_sandbox and libxpc functions without public headers, looked up at run time so a macOS that drops
/// them makes the broker report an error instead of failing to launch.
public enum BridgeSPI {
    private typealias IssueMach = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> UnsafeMutablePointer<CChar>?
    private typealias GetAuditToken = @convention(c) (xpc_connection_t, UnsafeMutablePointer<audit_token_t>) -> Void

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)   // RTLD_DEFAULT
    }

    /// `sandbox_extension_issue_mach("com.apple.app-sandbox.mach", service, 0)`: a token that lets any sandboxed
    /// process that consumes it look up `service`. Not secret; it names the service, nothing more.
    public static func issueMachExtension(service: String) -> String? {
        guard let sym = symbol("sandbox_extension_issue_mach") else { return nil }
        let fn = unsafeBitCast(sym, to: IssueMach.self)
        guard let p = fn("com.apple.app-sandbox.mach", service, 0) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    public static func auditToken(of connection: xpc_connection_t) -> audit_token_t? {
        guard let sym = symbol("xpc_connection_get_audit_token") else { return nil }
        let fn = unsafeBitCast(sym, to: GetAuditToken.self)
        var token = audit_token_t()
        fn(connection, &token)
        return token
    }
}

// MARK: - Code identity

public enum SecurityIdentityProvider {
    /// Entitlements that let other code into a process: DYLD_* variables, unsigned libraries, a debugger's task port.
    public static let weakeningEntitlements = ["com.apple.security.cs.allow-dyld-environment-variables",
                                               "com.apple.security.cs.disable-library-validation",
                                               "com.apple.security.get-task-allow"]
    static let runtimeFlag: UInt32 = 0x10000   // kSecCodeSignatureRuntime
    static let adHocFlag: UInt32 = 0x2         // kSecCodeSignatureAdhoc

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    /// The process's parent pid (public proc_pidinfo) and whether it is its own responsible process (private
    /// responsibility_get_pid_responsible_for_pid; nil when unavailable).
    static func launchContext(pid: pid_t) -> (ppid: pid_t?, selfResponsible: Bool?) {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        let ppid = n == Int32(MemoryLayout<proc_bsdinfo>.size) ? pid_t(info.pbi_ppid) : nil
        var responsible: Bool?
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
            let r = unsafeBitCast(sym, to: ResponsibleFn.self)(pid)
            responsible = r > 0 ? r == pid : nil
        }
        return (ppid, responsible)
    }

    /// What the system says about the process behind `token`. nil when it has no code object (it exited).
    public static func identity(auditToken token: audit_token_t) -> BridgeCallerIdentity? {
        var token = token
        let pid = Int32(bitPattern: token.val.5)
        // Read before the audit-token lookup: if that lookup then succeeds, the process with this pid version was
        // alive throughout, so the pid still named it here (pid versions never repeat).
        let context = launchContext(pid: pid)
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var codeRef: SecCode?
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &codeRef) == errSecSuccess, let code = codeRef else { return nil }

        var staticRef: SecStaticCode?
        var info: [String: Any] = [:]
        if SecCodeCopyStaticCode(code, [], &staticRef) == errSecSuccess, let st = staticRef {
            var cf: CFDictionary?
            if SecCodeCopySigningInformation(st, SecCSFlags(rawValue: kSecCSSigningInformation), &cf) == errSecSuccess {
                info = (cf as? [String: Any]) ?? [:]
            }
        }
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let exe = (info[kSecCodeInfoMainExecutable as String] as? URL)?.path

        let valid = SecCodeCheckValidity(code, [], nil) == errSecSuccess
        let classes = valid ? classify(team: team) { satisfies(code, $0) } : (apple: false, developerID: false, appStore: false)

        var taskID: String?
        var sandboxed = false
        var weakened = false
        if let task = SecTaskCreateWithAuditToken(nil, token) {
            taskID = SecTaskCopySigningIdentifier(task, nil) as String?
            func entitled(_ e: String) -> Bool { (SecTaskCopyValueForEntitlement(task, e as CFString, nil) as? Bool) ?? false }
            sandboxed = entitled("com.apple.security.app-sandbox")
            weakened = weakeningEntitlements.contains(where: entitled)
        }

        var bundleID: String?, bundleExe: String?, bundlePath: String?
        if let exe, let r = exe.range(of: ".app/Contents/MacOS/", options: .backwards) {
            let path = String(exe[..<r.lowerBound]) + ".app"
            if let app = AppDiscovery.read(bundleAt: path) {
                bundleID = app.bundleID
                bundleExe = app.executablePath
                bundlePath = path
            }
        }
        return BridgeCallerIdentity(pid: pid, signingIdentifier: identifier, taskSigningIdentifier: taskID, teamID: team,
                                    executablePath: exe, signatureValid: valid, appleAnchored: classes.apple,
                                    developerID: classes.developerID, appStore: classes.appStore, adHoc: flags & adHocFlag != 0,
                                    hardenedRuntime: flags & runtimeFlag != 0, weakenedCodeLoading: weakened,
                                    parentIsLaunchd: context.ppid == 1, selfResponsible: context.selfResponsible,
                                    sandboxed: sandboxed, bundleIdentifier: bundleID, bundleExecutablePath: bundleExe,
                                    bundlePath: bundlePath)
    }

    /// Which signing class the code is in, given a requirement check.
    static func classify(team: String?, _ check: (String) -> Bool) -> (apple: Bool, developerID: Bool, appStore: Bool) {
        (check(BridgeRequirements.apple),
         team.flatMap(BridgeRequirements.developerID(team:)).map(check) ?? false,
         check(BridgeRequirements.appStore))
    }

    static func satisfies(_ code: SecCode, _ requirement: String) -> Bool {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    /// The signing class of an app on disk (static check, resources not validated). For tests and diagnostics.
    public static func classify(bundleAt path: String) -> (apple: Bool, developerID: Bool, appStore: Bool, team: String?, hardenedRuntime: Bool)? {
        var st: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &st) == errSecSuccess, let st else { return nil }
        var cf: CFDictionary?
        guard SecCodeCopySigningInformation(st, SecCSFlags(rawValue: kSecCSSigningInformation), &cf) == errSecSuccess,
              let info = cf as? [String: Any] else { return nil }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let c = classify(team: team) { r in
            var req: SecRequirement?
            guard SecRequirementCreateWithString(r as CFString, [], &req) == errSecSuccess, let req else { return false }
            return SecStaticCodeCheckValidity(st, SecCSFlags(rawValue: kSecCSDoNotValidateResources), req) == errSecSuccess
        }
        return (c.apple, c.developerID, c.appStore, team, flags & runtimeFlag != 0)
    }
}

// MARK: - Transport

/// The broker's XPC listener (C API, mach service). Each message is a dictionary with the request as a binary plist
/// under `BridgeProtocol.payloadKey`; the reply has the same shape. Everything runs on `queue`.
public final class BridgeXPCListener {
    public typealias Handler = (BridgeService.Payload, BridgePeer, () -> BridgeCallerIdentity?) -> Data

    public let serviceName: String
    let queue: DispatchQueue
    let handler: Handler
    let identify: (audit_token_t) -> BridgeCallerIdentity?
    private var listener: xpc_connection_t?
    let logger = Logger(subsystem: BridgeProtocol.logSubsystem, category: "xpc")

    public init(serviceName: String, queue: DispatchQueue,
                identify: @escaping (audit_token_t) -> BridgeCallerIdentity? = SecurityIdentityProvider.identity(auditToken:),
                handler: @escaping Handler) {
        self.serviceName = serviceName
        self.queue = queue
        self.identify = identify
        self.handler = handler
    }

    public func start() {
        let l = xpc_connection_create_mach_service(serviceName, queue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        xpc_connection_set_event_handler(l) { [weak self] event in
            guard let self else { return }
            if xpc_get_type(event) == XPC_TYPE_CONNECTION {
                self.accept(event)
            } else if xpc_get_type(event) == XPC_TYPE_ERROR {
                self.logger.error("listener error: \(Self.describe(event), privacy: .public)")
            }
        }
        xpc_connection_resume(l)
        listener = l
    }

    public func cancel() {
        if let listener { xpc_connection_cancel(listener) }
        listener = nil
    }

    /// Identity is looked up when a connection's first request gets past the per-process rate limit, and again
    /// whenever the audit token of an incoming message differs from the one it was looked up for (libxpc keeps the
    /// token of the last message received; the pid version in it changes on exec).
    final class PeerState {
        var peer: BridgePeer
        var token: audit_token_t?
        var identity: BridgeCallerIdentity??
        init(conn: xpc_connection_t) {
            peer = BridgePeer(pid: 0, pidVersion: 0)
            update(conn)
        }

        func update(_ conn: xpc_connection_t) {
            let t = BridgeSPI.auditToken(of: conn)
            if let t, let old = token, Self.same(t, old) { return }
            token = t
            identity = nil
            peer = BridgePeer(pid: t.map { Int32(bitPattern: $0.val.5) } ?? xpc_connection_get_pid(conn),
                              pidVersion: t.map { Int32(bitPattern: $0.val.7) } ?? 0)
        }

        static func same(_ a: audit_token_t, _ b: audit_token_t) -> Bool {
            var a = a, b = b
            return memcmp(&a, &b, MemoryLayout<audit_token_t>.size) == 0
        }
    }

    private func accept(_ conn: xpc_connection_t) {
        let state = PeerState(conn: conn)
        xpc_connection_set_target_queue(conn, queue)
        xpc_connection_set_event_handler(conn) { [weak self] message in
            guard let self, xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
            self.receive(message, on: conn, state: state)
        }
        xpc_connection_resume(conn)
    }

    private func receive(_ message: xpc_object_t, on conn: xpc_connection_t, state: PeerState) {
        guard let reply = xpc_dictionary_create_reply(message) else { return }
        state.update(conn)
        var length = 0
        let payload: BridgeService.Payload
        if let p = xpc_dictionary_get_data(message, BridgeProtocol.payloadKey, &length) {
            // The length is checked before anything is copied.
            payload = length > BridgeProtocol.maxMessageBytes ? .tooLarge(length) : .data(Data(bytes: p, count: length))
        } else {
            payload = .data(Data())
        }
        let out = handler(payload, state.peer) { [identify] in
            if let cached = state.identity { return cached }
            let id = state.token.flatMap(identify)
            state.identity = .some(id)
            return id
        }
        out.withUnsafeBytes { buf in
            xpc_dictionary_set_data(reply, BridgeProtocol.payloadKey, buf.baseAddress!, buf.count)
        }
        xpc_connection_send_message(conn, reply)
    }

    static func describe(_ error: xpc_object_t) -> String {
        guard let s = xpc_dictionary_get_string(error, XPC_ERROR_KEY_DESCRIPTION) else { return "unknown" }
        return String(cString: s)
    }
}

/// A client for tests, `dw bridge ping` and the e2e driver: sends one request and waits for the reply.
public enum BridgeXPCClient {
    public static func send(_ request: [String: Any], service: String, timeout: TimeInterval = 5) -> [String: Any]? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: request, format: .binary, options: 0) else { return nil }
        let conn = xpc_connection_create_mach_service(service, nil, 0)
        xpc_connection_set_event_handler(conn) { _ in }
        xpc_connection_resume(conn)
        defer { xpc_connection_cancel(conn) }
        let msg = xpc_dictionary_create(nil, nil, 0)
        data.withUnsafeBytes { xpc_dictionary_set_data(msg, BridgeProtocol.payloadKey, $0.baseAddress!, $0.count) }
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        xpc_connection_send_message_with_reply(conn, msg, DispatchQueue.global()) { reply in
            if xpc_get_type(reply) == XPC_TYPE_DICTIONARY {
                var n = 0
                if let p = xpc_dictionary_get_data(reply, BridgeProtocol.payloadKey, &n) {
                    result = (try? PropertyListSerialization.propertyList(from: Data(bytes: p, count: n), format: nil)) as? [String: Any]
                }
            }
            sem.signal()
        }
        return sem.wait(timeout: .now() + timeout) == .success ? result : nil
    }
}

// MARK: - Token

/// Where the broker publishes the token: the global preferences domain (readable from sandboxed apps).
public protocol BridgeTokenStore: AnyObject {
    func token() -> String?
    func publish(token: String) throws
    func clear() throws
}

public final class CFPreferencesBridgeTokenStore: BridgeTokenStore {
    public let names: BridgeNames
    public init(names: BridgeNames) { self.names = names }

    private func sync() -> Bool {
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private func set(_ key: String, _ value: CFPropertyList?) {
        CFPreferencesSetValue(key as CFString, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    public func token() -> String? {
        _ = sync()
        return CFPreferencesCopyValue(names.tokenKey as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                      kCFPreferencesAnyHost) as? String
    }

    public func publish(token: String) throws {
        set(names.tokenKey, token as CFString)
        set(names.versionKey, BridgeProtocol.version as CFNumber)
        guard sync() else { throw WriteError.io("Could not save \(names.tokenKey) to the global preferences.") }
        post()
    }

    public func clear() throws {
        set(names.tokenKey, nil)
        set(names.versionKey, nil)
        guard sync() else { throw WriteError.io("Could not remove \(names.tokenKey) from the global preferences.") }
        post()
    }

    func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(names.notification as CFString), nil, nil, true)
    }
}

/// For isolated Workbench launches and tests.
public final class MemoryBridgeTokenStore: BridgeTokenStore {
    public var value: String?
    public init(_ value: String? = nil) { self.value = value }
    public func token() -> String? { value }
    public func publish(token: String) throws { value = token }
    public func clear() throws { value = nil }
}

// MARK: - Live sources and effects

/// The config file, re-parsed only when it changes (size, modification date, inode).
public final class BridgeConfigFile {
    public let path: String
    private var stamp: [String]?
    private var cached: EffectiveConfig?

    public init(path: String) { self.path = path }

    public func current() -> EffectiveConfig? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { stamp = nil; cached = nil; return nil }
        let s = ["\(a[.size] ?? "")", "\((a[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)",
                 "\(a[.systemFileNumber] ?? "")"]
        if s == stamp, let cached { return cached }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let c = EffectiveConfig(document: ConfigDocument(text: String(decoding: data, as: UTF8.self)))
        stamp = s
        cached = c
        return c
    }
}

public extension BridgePolicySources {
    /// The live config file and the manifests in `tweakDirectories`, read on each request.
    /// The live config file, the manifests in `tweakDirectories` (read on each request) and the apps in `appRoots`
    /// (rescanned at most every 30 s, and at once when an ID isn't found, so a newly installed app works).
    static func live(configPath: String, tweakDirectories: [String], appRoots: [String] = AppDiscovery.defaultRoots) -> BridgePolicySources {
        let config = BridgeConfigFile(path: configPath)
        let apps = BridgeInstalledApps(roots: appRoots)
        return BridgePolicySources(manifests: { TweakManifestLoader.load(directories: tweakDirectories).manifests },
                                   config: { config.current() }, installedApps: { apps.apps(bundleID: $0) })
    }
}

/// AppDiscovery's scan of the app folders, cached.
public final class BridgeInstalledApps {
    public let roots: [String]
    let maxAge: TimeInterval
    private var scanned: Date?
    private var byID: [String: [InstalledApp]] = [:]

    public init(roots: [String], maxAge: TimeInterval = 30) {
        self.roots = roots
        self.maxAge = maxAge
    }

    public func apps(bundleID: String) -> [InstalledApp] {
        if let found = byID[bundleID], let t = scanned, Date().timeIntervalSince(t) < maxAge { return found }
        // Unknown ID: rescan, but not more than once a second, so unknown callers can't make the broker scan nonstop.
        if let t = scanned, Date().timeIntervalSince(t) < 1 { return byID[bundleID] ?? [] }
        byID = Dictionary(grouping: AppDiscovery.scan(roots: roots), by: \.bundleID)
        scanned = Date()
        return byID[bundleID] ?? []
    }
}

/// A settings backend that stores payloads in a plist file (test mode) but still posts the real Darwin
/// notification, so a tweak under test sees `.changed`.
public final class PostingFileTweakBackend: TweakPrefsBackend {
    let file: FileTweakBackend
    public init(path: String) { file = FileTweakBackend(path: path) }
    public func payload(for id: String) -> [String: Any]? { file.payload(for: id) }
    public func setPayload(_ payload: [String: Any]?, for id: String) throws { try file.setPayload(payload, for: id) }
    public func postChange(for id: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(TweakPrefsContract.notificationName(id) as CFString), nil, nil, true)
    }
}

public final class SystemBridgeEffects: BridgeEffects {
    public let settingsBackend: TweakPrefsBackend
    public init(settingsBackend: TweakPrefsBackend) { self.settingsBackend = settingsBackend }

    public func postNotification(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString),
                                             nil, nil, true)
    }

    public func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }

    public func writePasteboard(_ string: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(string, forType: .string)
    }
}

/// Records instead of acting (tests, previews).
public final class RecordingBridgeEffects: BridgeEffects {
    public let settingsBackend: TweakPrefsBackend
    public private(set) var notifications: [String] = []
    public private(set) var opened: [URL] = []
    public private(set) var pasteboard: [String] = []
    public var openSucceeds = true
    public init(settingsBackend: TweakPrefsBackend = MemoryTweakBackend()) { self.settingsBackend = settingsBackend }
    public func postNotification(_ name: String) { notifications.append(name) }
    public func open(_ url: URL) -> Bool { opened.append(url); return openSucceeds }
    public func writePasteboard(_ string: String) -> Bool { pasteboard.append(string); return true }
}

// MARK: - LaunchAgent

/// The LaunchAgent that runs `dw bridge serve` and owns the mach service `local.dynject.bridge`.
public final class BridgeAgent: UserLaunchAgent {
    public static let label = BridgeNames.production.service

    public init(launchAgentsDirectory: URL = UserLaunchAgent.defaultLaunchAgentsDirectory,
                binDirectory: URL = UserLaunchAgent.defaultBinDirectory,
                runner: LaunchctlRunner = SystemLaunchctlRunner(), uid: uid_t = getuid(), label: String = BridgeAgent.label) {
        super.init(label: label, command: ["bridge", "serve"], binaryName: "dw-bridge",
                   extraPlistKeys: ["MachServices": [label: true], "ProcessType": "Adaptive", "ThrottleInterval": 10],
                   launchAgentsDirectory: launchAgentsDirectory, binDirectory: binDirectory, runner: runner, uid: uid)
    }

    /// `dw bridge agent` with other directories would still bootstrap and boot out the real label and remove the real
    /// token. So other directories need simulated launchctl, which also leaves the token alone.
    public static func testingOptionsProblem(directoriesOverridden: Bool, simulatedLaunchctl: Bool) -> String? {
        directoriesOverridden && !simulatedLaunchctl
            ? "--launch-agents-dir and --bin-dir need --no-launchctl: launchctl would act on the real \(label) and its token"
            : nil
    }
}
