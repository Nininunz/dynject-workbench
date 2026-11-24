// SettingsLoader, Swift part: the sidebar entry, the pages, and System Settings' navigation. See SettingsLoader.m.
//
// System Settings internals this relies on (macOS 27.2, all private, found with Mirror and the ObjC runtime):
//
// - Sidebar: SettingsApp.SystemSettingsExtensionCoordinator._delegate (the coordination manager)
//   ._settingsAppState.navigationSplitViewState.$__lazy_storage_$_sidebarListState
//   .settingsSidebarListContextProvider.systemSettingsExtensionsStateProvider, which has the extension `monitor`
//   (its _state._identities include ours) and `snapshotsContinuation`, an AsyncStream continuation of snapshots
//   whose first two fields are [String: AppExtensionIdentity]: known extensions, then other extensions. Ours is
//   filtered out before it gets there, so SettingsLoader yields a copy of the current snapshot with ours added to
//   "other", and does it again whenever a new snapshot drops it.
// - Navigation: each extension has a coordinator implementing Settings.SettingsPrivateHostProtocol. A page tells it
//   about a push with navigationStackDidChange:(Settings.NavigationToken), which goes into the window's history;
//   back/forward come to the page as setNavigationWithPath:(Settings.SettingsNavigationPath) on the coordinator's
//   _extensionUIProxy (Settings.SettingsPrivateProtocol), where SettingsLoader puts its own object. Tokens are built
//   the way Apple's pages build them: keyed archives of title, isRoot, hasPushedContent, ... and a path whose data
//   is {"navigationPath":{"data":base64(NavigationPath's codable form)}}.
import AppKit
import DynjectCore
import DynjectSettingsUI
import ExtensionFoundation
import os
import SwiftUI

private let log = Logger(subsystem: "local.dynject.settingsloader", category: "pages")
private let extensionID = "local.dynject.settingsloader.extension"
private let rootTitle = "Tweaks"   // = the extension's sidebar-name

// MARK: - Mirror helpers

/// The child called `label`, looking through an Optional first.
private func child(_ value: Any, _ label: String) -> Any? {
    var mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
        guard let inner = mirror.children.first?.value else { return nil }
        mirror = Mirror(reflecting: inner)
    }
    return mirror.children.first(where: { $0.label == label })?.value
}

private func unwrap(_ value: Any) -> Any? {
    let mirror = Mirror(reflecting: value)
    return mirror.displayStyle == .optional ? mirror.children.first?.value : value
}

/// The coordination manager every coordinator points to.
private func manager(of coordinator: AnyObject) -> Any? {
    child(coordinator, "_delegate").flatMap(unwrap)
}

// MARK: - Sidebar

private enum Sidebar {
    static weak var anyCoordinator: NSObject?
    static var lastInjection = Date.distantPast
    static var reportedMissing = false
    static var reportedLayout = false

    /// Makes sure our extension is in the sidebar's current snapshot of extensions.
    static func ensure() {
        guard Date().timeIntervalSince(lastInjection) > 2,   // the last one may not have arrived yet
              let coordinator = anyCoordinator, let manager = manager(of: coordinator),
              let state = child(manager, "_settingsAppState"),
              let split = child(state, "navigationSplitViewState"),
              let list = child(split, "$__lazy_storage_$_sidebarListState").flatMap(unwrap),
              let provider = child(list, "settingsSidebarListContextProvider")
                .flatMap({ child($0, "systemSettingsExtensionsStateProvider") }),
              let identities = child(provider, "monitor").flatMap({ child($0, "_state") })
                .flatMap({ child($0, "_identities") }) as? [Any],
              let continuation = child(provider, "snapshotsContinuation"),
              let snapshot = child(list, "_currentSettingsSidebarListContext")
                .flatMap({ child($0, "systemSettingsExtensionsSnapshot") })
        else {
            // Before the first page shows, the sidebar's state isn't there yet; after that, System Settings changed.
            if anyCoordinator != nil && !reportedLayout {
                reportedLayout = true
                log.error("sidebar: System Settings' sidebar state isn't where SettingsLoader looks for it")
            }
            return
        }
        guard let ours = identities.lazy.compactMap({ $0 as? AppExtensionIdentity })
            .first(where: { $0.bundleIdentifier == extensionID }) else {
            if !reportedMissing {
                reportedMissing = true
                log.error("the Tweaks extension isn't registered (\(extensionID, privacy: .public)): install SettingsLoader again with dw tweak install, which registers it")
            }
            return
        }
        func open<S>(_ s: S) { inject(s, continuation, ours) }
        _openExistential(snapshot, do: open)
    }

    /// The snapshot type can't be named here: open it as T, check its layout, add ours to "other extensions" in a
    /// copy, and yield the copy through the provider's own continuation.
    private static func inject<T>(_ snapshot: T, _ continuation: Any, _ ours: AppExtensionIdentity) {
        typealias Extensions = [String: AppExtensionIdentity]
        let dicts = Mirror(reflecting: snapshot).children.compactMap { $0.value as? Extensions }
        guard dicts.count == 2 else { log.error("sidebar: snapshot layout changed (\(dicts.count) extension lists)"); return }
        if dicts[0][extensionID] != nil || dicts[1][extensionID] != nil { return }
        var raw = snapshot
        let words: [UInt] = withUnsafeBytes(of: &raw) { b in (0..<min(2, b.count / 8)).map { b.load(fromByteOffset: $0 * 8, as: UInt.self) } }
        let bits = dicts.map { d -> UInt in var copy = d; return withUnsafeBytes(of: &copy) { $0.load(as: UInt.self) } }
        guard words.count == 2, words[0] == bits[0], words[1] == bits[1] else {
            log.error("sidebar: snapshot layout changed (lists aren't its first two fields)"); return
        }
        guard let stream = continuation as? AsyncStream<T>.Continuation else {
            log.error("sidebar: snapshots continuation is \(String(reflecting: type(of: continuation)), privacy: .public)"); return
        }
        var others = dicts[1]
        others[extensionID] = ours
        var copy = snapshot
        withUnsafeMutableBytes(of: &copy) { bytes in
            bytes.baseAddress!.advanced(by: 8).assumingMemoryBound(to: Extensions.self).pointee = others
        }
        lastInjection = Date()
        stream.yield(copy)
        log.info("sidebar: added Tweaks")
    }
}

// MARK: - Navigation tokens

// Stand-ins archived under Settings' class names, then unarchived as the real classes.
@objc(SLPathStandIn) private final class PathStandIn: NSObject, NSCoding {
    let data: Data
    init(_ data: Data) { self.data = data }
    func encode(with coder: NSCoder) { coder.encode(data as NSData, forKey: "SettingsNavigationPath_data") }
    required init?(coder: NSCoder) { nil }
}

@objc(SLTokenStandIn) private final class TokenStandIn: NSObject, NSCoding {
    let title: String?, path: PathStandIn, pushed: Bool
    init(title: String?, path: PathStandIn, pushed: Bool) { self.title = title; self.path = path; self.pushed = pushed }
    func encode(with coder: NSCoder) {
        coder.encode(title as NSString?, forKey: "title")
        coder.encode(nil as NSString?, forKey: "subtitle")
        coder.encode(path, forKey: "SettingsNavigationPath")
        coder.encode(nil as NSData?, forKey: "iconData")
        coder.encode(nil as NSString?, forKey: "iconUTType")
        coder.encode(NSNumber(value: pushed), forKey: "hasPushedContent")
        coder.encode(NSNumber(value: !pushed), forKey: "isRoot")
    }
    required init?(coder: NSCoder) { nil }
}

enum NavigationPathCoding {
    /// Path data as Apple's pages write it, from page IDs (outermost first).
    static func encode(_ ids: [String]) -> Data {
        var flat: [String] = []
        for id in ids.reversed() { flat += ["Swift.String", String(data: try! JSONEncoder().encode(id), encoding: .utf8)!] }
        let inner = try! JSONSerialization.data(withJSONObject: flat)
        return try! JSONSerialization.data(withJSONObject: ["navigationPath": ["data": inner.base64EncodedString()]])
    }

    static func decode(_ data: Data) -> [String]? {
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = (outer["navigationPath"] as? [String: Any])?["data"] as? String,
              let inner = Data(base64Encoded: b64),
              let flat = try? JSONSerialization.jsonObject(with: inner) as? [String], flat.count % 2 == 0 else { return nil }
        var ids: [String] = []
        for i in stride(from: 1, to: flat.count, by: 2) {
            guard let id = try? JSONDecoder().decode(String.self, from: Data(flat[i].utf8)) else { return nil }
            ids.insert(id, at: 0)
        }
        return ids
    }

    /// The page IDs in a Settings.SettingsNavigationPath.
    static func ids(in path: AnyObject?) -> [String]? {
        guard let path, let archive = try? NSKeyedArchiver.archivedData(withRootObject: path, requiringSecureCoding: false),
              let plist = try? PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any],
              let data = objects.lazy.compactMap({ $0 as? Data }).first else { return nil }
        return decode(data)
    }

    static func token(title: String?, ids: [String]) -> NSObject? {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("Settings.NavigationToken", for: TokenStandIn.self)
        archiver.setClassName("Settings.SettingsNavigationPath", for: PathStandIn.self)
        archiver.encode(TokenStandIn(title: title, path: PathStandIn(encode(ids)), pushed: !ids.isEmpty),
                        forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: archiver.encodedData) else { return nil }
        unarchiver.requiresSecureCoding = false
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject
    }
}

// MARK: - Navigation

final class Navigation: ObservableObject {
    static let shared = Navigation()
    /// Pushed pages, outermost first; empty at the root. A page ID is a tweak identifier.
    @Published var path: [String] = []
    private(set) weak var coordinator: NSObject?
    private let proxy = SettingsProxy()

    func push(_ id: String) {
        path.append(id)
        report()
    }

    /// Tells the coordinator where we are: a history entry, the header's title and its back button.
    func report() {
        guard let coordinator = coordinator ?? findCoordinator() else { return }
        let title = path.last.map(Store.shared.title(of:))
        coordinator.perform(NSSelectorFromString("navigationStackDidChange:"), with: NavigationPathCoding.token(title: title, ids: path))
        // The root's title too: the header otherwise keeps the last page's.
        coordinator.perform(NSSelectorFromString("navigationTitleDidChange:"), with: (title ?? rootTitle) as NSString)
    }

    /// Back/forward: show the entry and confirm it, as Apple's pages do. The history waits for that confirmation;
    /// without it, it takes the next push for the confirmation and drops that push.
    func show(_ ids: [String]) {
        path = ids
        report()
    }

    func beginHosting() {
        guard let coordinator = coordinator ?? findCoordinator() else { return }
        coordinator.perform(NSSelectorFromString("didBeginHosting"))
        // Back/forward from another pane re-hosts our page: show the entry it goes to. Selecting the sidebar entry
        // (or a URL) shows the root, as with Apple's pages.
        path = History.restoringPath() ?? []
        report()
    }

    func endHosting() {
        coordinator?.perform(NSSelectorFromString("didEndHosting:"), with: nil)
    }

    /// Our extension's coordinator, from the manager's _coordinators; puts our proxy into it.
    private func findCoordinator() -> NSObject? {
        guard let any = Sidebar.anyCoordinator, let manager = manager(of: any),
              let coordinators = child(manager, "_coordinators") else { return nil }
        for entry in Mirror(reflecting: coordinators).children {
            let pair = Mirror(reflecting: entry.value).children.map(\.value)
            guard pair.count == 2, let identity = pair[0] as? AppExtensionIdentity,
                  identity.bundleIdentifier == extensionID, let found = pair[1] as? NSObject else { continue }
            guard let ivar = class_getInstanceVariable(type(of: found), "_extensionUIProxy") else {
                log.error("navigation: the coordinator has no _extensionUIProxy"); return nil
            }
            object_setIvarWithStrongDefault(found, ivar, proxy)
            coordinator = found
            return found
        }
        log.error("navigation: no coordinator for \(extensionID, privacy: .public)")
        return nil
    }
}

/// System Settings' back/forward history (SettingsApp.SettingsNavigationHistoryManager). While it moves to an entry,
/// its _targetItem is that entry: the page it shows (presentedSystemSettingsExtensionRecipe) and its token.
private enum History {
    static var managers: [AnyObject] = []
    static var scanned = false

    /// The path of the entry the history is moving to, if that entry is one of our pages.
    static func restoringPath() -> [String]? {
        if !scanned {
            scanned = true
            findHistoryManagers()
            log.info("history: \(managers.count) manager(s)")
        }
        for manager in managers {
            guard let target = child(manager, "_targetItem").flatMap(unwrap),
                  let recipe = child(target, "presentedSystemSettingsExtensionRecipe").flatMap(unwrap),
                  child(recipe, "bundleIdentifier") as? String == extensionID else { continue }
            let token = child(target, "navigationToken").flatMap(unwrap)
            return NavigationPathCoding.ids(in: token.flatMap { child($0, "navigationPath") }.flatMap(unwrap) as AnyObject?)
        }
        return nil
    }
}

@_silgen_name("SLFindHistoryManagers") private func findHistoryManagers()

@_cdecl("SLSawHistoryManager")
public func slSawHistoryManager(_ manager: AnyObject) {
    History.managers.append(manager)
}

/// What the coordinator would send the extension (Settings.SettingsPrivateProtocol).
@objc(SLSettingsProxy) private final class SettingsProxy: NSObject {
    private var host: AnyObject?

    @objc func setNavigationWithPath(_ path: AnyObject?) {
        let ids = NavigationPathCoding.ids(in: path) ?? []
        DispatchQueue.main.async { Navigation.shared.show(ids) }
    }
    @objc func willSelectWithNavigationPath(_ path: AnyObject?) {
        guard let ids = NavigationPathCoding.ids(in: path) else { return }
        DispatchQueue.main.async { Navigation.shared.show(ids) }
    }
    @objc func popNavigationStack() {
        DispatchQueue.main.async {
            let nav = Navigation.shared
            guard !nav.path.isEmpty else { return }
            nav.path.removeLast()
            nav.report()
        }
    }
    @objc func setSettingsHost(_ host: AnyObject?) { self.host = host }
    @objc func settingsHost() -> AnyObject? { host }
    @objc func handshakeWithEndPoint(_ endpoint: AnyObject?) {}
}

// MARK: - Tweaks and their settings

final class Store: ObservableObject {
    static let shared = Store()
    @Published private(set) var manifests: [TweakManifest] = []
    @Published private(set) var apps: [InstalledApp] = []
    private(set) var settings: [String: TweakSettings] = [:]
    private var pendingSaves: [String: DispatchWorkItem] = [:]
    private var scannedApps = false

    /// Installed tweaks that have settings, from the manifests Workbench reads.
    func reload() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dynject Workbench", isDirectory: true)
        let loaded = TweakManifestLoader.load(directories: TweakManifestLoader.defaultDirectories(supportDirectory: support))
        manifests = loaded.manifests.filter { !$0.items.isEmpty }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let backend = CFPreferencesTweakBackend()
        settings = Dictionary(uniqueKeysWithValues: manifests.map { ($0.id, TweakSettings(manifest: $0, backend: backend)) })
        if !scannedApps {
            scannedApps = true
            DispatchQueue.global(qos: .utility).async {
                let found = AppDiscovery.scan(roots: AppDiscovery.defaultRoots)
                DispatchQueue.main.async { self.apps = found }
            }
        }
    }

    func title(of id: String) -> String { manifests.first { $0.id == id }?.name ?? id }

    /// Saves shortly after the last change, like Workbench: the payload, the change notification, the apply command.
    func changed(_ id: String) {
        pendingSaves[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let s = self?.settings[id] else { return }
            do { try s.persist() } catch { log.error("saving \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
            if let command = s.manifest.applyCommand { DispatchQueue.global().async { _ = ApplyCommandRunner.run(command) } }
        }
        pendingSaves[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

// MARK: - Pages

private struct TweakIcon: View {
    var manifest: TweakManifest
    var size: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(Color(nsColor: .systemPurple).gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: manifest.appleMenuSymbol ?? "puzzlepiece.extension.fill")
                .font(.system(size: size * 0.55, weight: .medium)).foregroundStyle(.white))
    }
}

private struct TweakList: View {
    @ObservedObject var store = Store.shared
    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(nsColor: .systemPurple).gradient)
                        .frame(width: 48, height: 48)
                        .overlay(Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.white))
                    Text("Tweaks").font(.title2.bold())
                    Text("Settings for the Dynject tweaks installed on this Mac.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            Section {
                if store.manifests.isEmpty {
                    Text("No installed tweak has settings.").foregroundStyle(.secondary)
                }
                ForEach(store.manifests) { manifest in
                    Button { Navigation.shared.push(manifest.id) } label: {
                        HStack(spacing: 8) {
                            TweakIcon(manifest: manifest)
                            Text(manifest.name)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Installing tweaks and per-app settings are in Dynject Workbench.")
            }
        }
    }
}

private struct TweakPage: View {
    var manifest: TweakManifest
    var settings: TweakSettings
    @ObservedObject var store = Store.shared

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    TweakIcon(manifest: manifest, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(manifest.name).font(.headline)
                        let byline = [manifest.version.map { "Version \($0)" }, manifest.author].compactMap { $0 }
                        if !byline.isEmpty { Text(byline.joined(separator: " · ")).foregroundStyle(.secondary) }
                        if let summary = manifest.summary { Text(summary).foregroundStyle(.secondary).padding(.top, 4) }
                    }
                }
            }
            ForEach(Array(manifest.sections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(section.items) { item in
                        TweakControl(item: item, value: binding(item), apps: store.apps)
                            .disabled(!settings.isEnabled(item))
                    }
                } header: {
                    if let title = section.title { Text(title) }
                } footer: {
                    if let footer = section.footer { Text(footer) }
                }
            }
            if !notes.isEmpty {
                Section {} footer: { Text(notes.joined(separator: " ")) }
            }
        }
    }

    private var notes: [String] {
        var notes: [String] = []
        if manifest.takesEffect == .relaunch { notes.append("Changes take effect when the apps \(manifest.name) is in are opened again.") }
        let overrides = settings.appsWithOverrides.count
        if overrides > 0 {
            notes.append("\(overrides) \(overrides == 1 ? "app has" : "apps have") its own values for some of these settings; change those in Dynject Workbench.")
        }
        return notes
    }

    private func binding(_ item: TweakItem) -> Binding<PrefValue> {
        Binding(get: { settings.value(item) },
                set: { if settings.set($0, for: item) { store.changed(manifest.id) } })
    }
}

private struct RootView: View {
    @ObservedObject var navigation = Navigation.shared
    @ObservedObject var store = Store.shared
    var body: some View {
        Group {
            if let id = navigation.path.last, let manifest = store.manifests.first(where: { $0.id == id }),
               let settings = store.settings[id] {
                TweakPage(manifest: manifest, settings: settings).id(id)
            } else {
                TweakList()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Entry points (SettingsLoader.m)

@_cdecl("SLStart")
public func slStart() {
    // Snapshots can be replaced (an extension installed or removed, ...); put ours back when that drops it.
    Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in Sidebar.ensure() }
}

@_cdecl("SLSawCoordinator")
public func slSawCoordinator(_ coordinator: NSObject) {
    if Sidebar.anyCoordinator == nil { Sidebar.anyCoordinator = coordinator }
    Sidebar.ensure()
}

@_cdecl("SLMakePageController")
public func slMakePageController() -> NSViewController {
    Store.shared.reload()   // before the first layout, so the page doesn't change size (and scroll) right after it
    Navigation.shared.path = []
    let controller = NSViewController()
    controller.view = NSHostingView(rootView: RootView())
    return controller
}

/// The host was just set to our page: selected in the sidebar, opened by URL, or reached by back/forward.
@_cdecl("SLPageAttached")
public func slPageAttached() {
    Navigation.shared.beginHosting()
}

@_cdecl("SLPageDetached")
public func slPageDetached() {
    Navigation.shared.endHosting()
}
