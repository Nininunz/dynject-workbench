import Foundation
import Observation

/// Where a tweak's settings live and how tweaks hear about changes (see docs/tweak-format.md):
///   key  "dynject.tweak.<id>"  in the user's global preferences domain (readable from sandboxed apps)
///   value { formatVersion: 1, values: {key: v}, perApp: {bundleID: {key: v}}, defaults: {key: v} }
///   Darwin notification "dynject.tweak.<id>.changed" after every write.
public enum TweakPrefsContract {
    public static func payloadKey(_ id: String) -> String { "dynject.tweak.\(id)" }
    public static func notificationName(_ id: String) -> String { "dynject.tweak.\(id).changed" }
}

public protocol TweakPrefsBackend: AnyObject {
    func payload(for id: String) -> [String: Any]?
    func setPayload(_ payload: [String: Any]?, for id: String) throws
    func postChange(for id: String)
}

/// The live backend: CFPreferences in the global domain (or another domain, for tests).
public final class CFPreferencesTweakBackend: TweakPrefsBackend {
    let domain: CFString

    public init(domain: CFString = kCFPreferencesAnyApplication) { self.domain = domain }

    public func payload(for id: String) -> [String: Any]? {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let v = CFPreferencesCopyValue(TweakPrefsContract.payloadKey(id) as CFString, domain,
                                       kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return v as? [String: Any]
    }

    public func setPayload(_ payload: [String: Any]?, for id: String) throws {
        CFPreferencesSetValue(TweakPrefsContract.payloadKey(id) as CFString, payload as CFPropertyList?, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw WriteError.io("Could not save preferences for \(id).")
        }
    }

    public func postChange(for id: String) {
        postNotification(TweakPrefsContract.notificationName(id))
    }
}

extension CFPreferencesTweakBackend: GlobalPrefsStore {
    public func dictionary(forKey key: String) -> [String: Any]? {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]
    }

    public func setDictionary(_ value: [String: Any]?, forKey key: String) throws {
        CFPreferencesSetValue(key as CFString, value as CFPropertyList?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw WriteError.io("Could not save preferences key \(key).")
        }
    }

    public func postNotification(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// Fixture backend: one plist file holding every payload; notifications are recorded, not posted.
public final class FileTweakBackend: TweakPrefsBackend {
    public let path: String
    public private(set) var posted: [String] = []

    public init(path: String) { self.path = path }

    func all() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return ((try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]) ?? [:]
    }

    public func payload(for id: String) -> [String: Any]? { dictionary(forKey: TweakPrefsContract.payloadKey(id)) }

    public func setPayload(_ payload: [String: Any]?, for id: String) throws {
        try setDictionary(payload, forKey: TweakPrefsContract.payloadKey(id))
    }

    public func postChange(for id: String) { postNotification(TweakPrefsContract.notificationName(id)) }
}

extension FileTweakBackend: GlobalPrefsStore {
    public func dictionary(forKey key: String) -> [String: Any]? { all()[key] as? [String: Any] }

    public func setDictionary(_ value: [String: Any]?, forKey key: String) throws {
        var a = all()
        a[key] = value
        let data = try PropertyListSerialization.data(fromPropertyList: a, format: .xml, options: 0)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public func postNotification(_ name: String) { posted.append(name) }
}

public final class MemoryTweakBackend: TweakPrefsBackend {
    public var store: [String: [String: Any]] = [:]
    public private(set) var posted: [String] = []
    /// Raw global keys written through `GlobalPrefsStore`, the number of those writes, and posted notification names.
    public var keyed: [String: [String: Any]] = [:]
    public fileprivate(set) var writes = 0
    public fileprivate(set) var notifications: [String] = []
    public init() {}
    public func payload(for id: String) -> [String: Any]? { store[id] }
    public func setPayload(_ payload: [String: Any]?, for id: String) throws { store[id] = payload }
    public func postChange(for id: String) { posted.append(id) }
}

/// Raw keys (MenuLoader) live apart from the per-tweak `store`, so tests of either stay independent.
extension MemoryTweakBackend: GlobalPrefsStore {
    public func dictionary(forKey key: String) -> [String: Any]? { keyed[key] }
    public func setDictionary(_ value: [String: Any]?, forKey key: String) throws {
        keyed[key] = value
        writes += 1
    }
    public func postNotification(_ name: String) { notifications.append(name) }
}

/// One tweak's settings: typed access for the UI over a raw payload. Keys the manifest doesn't know
/// (e.g. from an older or newer manifest) are preserved untouched.
@Observable
public final class TweakSettings {
    public let manifest: TweakManifest
    @ObservationIgnored let backend: TweakPrefsBackend

    public private(set) var values: [String: Any] = [:]
    public private(set) var perApp: [String: [String: Any]] = [:]
    /// The payload as it was before this session's first change (nil = no payload existed).
    @ObservationIgnored private var snapshot: [String: Any]??
    public private(set) var hasSessionChanges = false
    public private(set) var isDirty = false

    public init(manifest: TweakManifest, backend: TweakPrefsBackend) {
        self.manifest = manifest
        self.backend = backend
        reload()
    }

    public func reload() {
        let p = backend.payload(for: manifest.id)
        values = (p?["values"] as? [String: Any]) ?? [:]
        perApp = (p?["perApp"] as? [String: [String: Any]]) ?? [:]
        isDirty = false
    }

    // MARK: Reading

    /// Explicitly stored global value, if valid for the item.
    public func storedValue(_ item: TweakItem) -> PrefValue? {
        values[item.key].flatMap(PrefValue.init(plist:)).flatMap(item.normalized)
    }

    public func value(_ item: TweakItem) -> PrefValue { storedValue(item) ?? item.defaultValue }

    public func override(_ item: TweakItem, bundleID: String) -> PrefValue? {
        perApp[bundleID]?[item.key].flatMap(PrefValue.init(plist:)).flatMap(item.normalized)
    }

    /// What the tweak sees inside `bundleID`: per-app override, then global value, then default.
    public func effective(_ item: TweakItem, bundleID: String) -> PrefValue {
        override(item, bundleID: bundleID) ?? value(item)
    }

    public func isEnabled(_ item: TweakItem, bundleID: String? = nil) -> Bool {
        guard let dep = item.enabledIf, let sw = manifest.item(dep) else { return true }
        let v = bundleID.map { effective(sw, bundleID: $0) } ?? value(sw)
        return v.bool ?? true
    }

    public var appsWithOverrides: [String] { perApp.filter { !$0.value.isEmpty }.keys.sorted() }

    // MARK: Writing (in memory; call persist() to publish)

    @discardableResult
    public func set(_ v: PrefValue, for item: TweakItem) -> Bool {
        guard let n = item.normalized(v) else { return false }
        beginChange()
        values[item.key] = n.plistObject(integer: item.integer)
        return true
    }

    public func reset(_ item: TweakItem) {
        guard values[item.key] != nil else { return }
        beginChange()
        values[item.key] = nil
    }

    /// nil removes the override (the app inherits the global value again).
    @discardableResult
    public func setOverride(_ v: PrefValue?, for item: TweakItem, bundleID: String) -> Bool {
        guard item.perApp, !bundleID.isEmpty else { return false }
        var n: PrefValue?
        if let v { guard let ok = item.normalized(v) else { return false }; n = ok }
        beginChange()
        var entry = perApp[bundleID] ?? [:]
        entry[item.key] = n?.plistObject(integer: item.integer)
        perApp[bundleID] = entry.isEmpty ? nil : entry
        return true
    }

    private func beginChange() {
        if snapshot == nil { snapshot = .some(backend.payload(for: manifest.id)) }
        hasSessionChanges = true
        isDirty = true
    }

    /// The payload Workbench publishes.
    public var payload: [String: Any] {
        var defaults: [String: Any] = [:]
        for item in manifest.items { defaults[item.key] = item.defaultValue.plistObject(integer: item.integer) }
        return ["formatVersion": TweakManifest.formatVersion, "values": values, "perApp": perApp, "defaults": defaults]
    }

    /// Writes the payload and posts the change notification.
    public func persist() throws {
        try backend.setPayload(payload, for: manifest.id)
        backend.postChange(for: manifest.id)
        isDirty = false
    }

    /// The payload that existed before this session's first change; `.some(nil)` means there was none.
    public var sessionSnapshot: [String: Any]?? { snapshot }

    /// Restores the payload from before this session's first change.
    public func revertSession() throws {
        guard let snap = snapshot else { return }
        try backend.setPayload(snap, for: manifest.id)
        backend.postChange(for: manifest.id)
        snapshot = nil
        hasSessionChanges = false
        reload()
    }
}

public enum ApplyCommandRunner {
    public struct Result: Sendable { public var ok: Bool; public var message: String }

    /// Runs the manifest's apply command as the current user, without a shell, with a timeout.
    public static func run(_ argv: [String], timeout: TimeInterval = 10) -> Result {
        guard let exe = argv.first, FileManager.default.isExecutableFile(atPath: exe) else {
            return Result(ok: false, message: "\(argv.first ?? "?") is not executable")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = Array(argv.dropFirst())
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(ok: false, message: error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return Result(ok: false, message: String(format: "timed out after %.1f s", timeout)) }
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(ok: p.terminationStatus == 0,
                      message: p.terminationStatus == 0 ? "ok" : "exit \(p.terminationStatus)\(msg.isEmpty ? "" : ": \(msg)")")
    }
}
