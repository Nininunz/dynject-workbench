import AppKit
import DynjectCore
import SwiftUI

struct TweaksView: View {
    @Bindable var model: WorkbenchModel
    @State private var showAppleMenuOptions = false

    var body: some View {
        HSplitView {
            List(model.tweaks, selection: $model.selectedTweakID) { m in
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).fontWeight(.medium)
                    HStack(spacing: 4) {
                        Text(m.dylib.lastPathComponent)
                        if let v = m.version { Text("v\(v)") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .tag(m.id)
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Install Tweak…") { chooseTweak() }
                        .disabled(!model.canInstallTweaks)
                        .help(model.canInstallTweaks ? "Install a built tweak folder: dylib, config and restart in one step"
                                                     : (model.installBlocker ?? ""))
                        .accessibilityIdentifier("tweak-install")
                    Button("Reload") { model.loadTweaks() }
                    Button("Open Tweaks Folder") { openFolder() }
                    Button { showAppleMenuOptions.toggle() } label: { Image(systemName: "apple.logo") }
                        .help("Apple-menu items (MenuLoader)")
                        .accessibilityIdentifier("applemenu-options")
                        .popover(isPresented: $showAppleMenuOptions, arrowEdge: .top) {
                            AppleMenuOptions(model: model).padding(14).frame(width: 340)
                        }
                }
                .padding(8)
            }

            Group {
                if let id = model.selectedTweakID, let s = model.tweakSettings[id] {
                    TweakDetail(model: model, settings: s)
                } else {
                    emptyState
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .axContainer("screen-tweaks")
        .sheet(item: Binding(get: { model.installReview }, set: { model.installReview = $0 })) { r in
            InstallTweakSheet(model: model, review: r)
        }
        .sheet(item: Binding(get: { model.uninstallReview }, set: { model.uninstallReview = $0 })) { r in
            UninstallTweakSheet(model: model, review: r)
        }
    }

    func chooseTweak() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a built tweak folder, or its *\(TweakManifest.fileSuffix) manifest"
        panel.prompt = "Review"
        if panel.runModal() == .OK, let url = panel.url { model.beginInstall(path: url.path) }
    }

    var emptyState: some View {
        ContentUnavailableView {
            Label("No tweak manifests", systemImage: "puzzlepiece.extension")
        } description: {
            Text("A tweak gets a settings page here by shipping a manifest (*\(TweakManifest.fileSuffix)). Put manifests in the Tweaks folder. Examples/ExampleTweak.workbench.plist and docs/tweak-format.md show the format.")
        } actions: {
            Button("Open Tweaks Folder") { openFolder() }
        }
        .overlay(alignment: .bottom) { issuesList.padding() }
    }

    @ViewBuilder var issuesList: some View {
        if !model.tweakIssues.isEmpty {
            GroupBox("Manifest problems") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.tweakIssues) { i in
                        Label("\(i.file.lastPathComponent): \(i.message)",
                              systemImage: i.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(i.severity == .error ? .red : .orange)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func openFolder() {
        let dir = model.tweaksFolder
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }
}

struct TweakDetail: View {
    var model: WorkbenchModel
    var settings: TweakSettings

    var m: TweakManifest { settings.manifest }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                ForEach(Array(m.sections.enumerated()), id: \.offset) { _, section in
                    Section {
                        ForEach(section.items) { item in
                            TweakItemRow(model: model, settings: settings, item: item)
                        }
                    } header: {
                        if let t = section.title { Text(t) }
                    } footer: {
                        if let f = section.footer { Text(f).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if !m.appleMenu.isEmpty {
                    AppleMenuSection(model: model, manifest: m)
                }
                if !m.bridge.isEmpty {
                    Section {
                        BridgeCapabilityList(capabilities: m.bridge)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("tweak-bridge-\(m.id)")
                        let recent = model.bridge.entries(forTweak: m.id).prefix(5)
                        ForEach(Array(recent)) { e in BridgeDecisionRow(model: model, entry: e) }
                    } header: {
                        Text("Bridge")
                    } footer: {
                        Text(model.bridge.agentStatus?.running == true
                             ? "The bridge does these for it, only inside apps the config injects it into."
                             : "The bridge isn't running, so these requests fail. Install it on the Bridge page.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                let overridden = settings.appsWithOverrides
                if !overridden.isEmpty {
                    Section("Per-app overrides") {
                        ForEach(overridden, id: \.self) { bid in
                            HStack {
                                Text(model.installedAppName(bid))
                                Text("\(settings.perApp[bid]?.count ?? 0) setting(s)").foregroundStyle(.secondary)
                                Spacer()
                                Button("Show") {
                                    if let app = model.apps.first(where: { $0.bundleID == bid }) {
                                        model.selectedAppID = app.id
                                        model.section = .injection
                                    }
                                }
                                .disabled(!model.apps.contains { $0.bundleID == bid })
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .axContainer("tweak-form-\(m.id)")
        }
    }

    var header: some View {
        let configured = model.workingConfig.dylibPaths.contains(m.dylib)
        let exists = FileManager.default.fileExists(atPath: model.tweakFilePath(m.dylib))
        let loadedIn = model.appsWithTweakLoaded(m)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.name).font(.title2.weight(.semibold))
                if let v = m.version { Text("v\(v)").foregroundStyle(.secondary) }
                if let a = m.author { Text("by \(a)").foregroundStyle(.secondary) }
                Spacer()
                Button("Revert Session") { model.revertTweak(m.id) }
                    .disabled(!settings.hasSessionChanges)
                    .help("Restore this tweak's settings to how they were when you opened Workbench")
                    .accessibilityIdentifier("tweak-revert")
                Button("Uninstall…") { model.beginUninstall(m) }
                    .disabled(!model.canInstallTweaks)
                    .help("Remove its config lines, the dylib and the manifest (reviewed first)")
                    .accessibilityIdentifier("tweak-uninstall")
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: m.sourcePath)]) } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .help("Show the manifest in Finder")
            }
            if let s = m.summary { Text(s).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                Chip(text: m.dylib.lastPathComponent, color: .gray, systemImage: "shippingbox")
                if !exists {
                    Chip(text: "dylib missing", color: .red)
                } else if configured {
                    Chip(text: "in Dynject config", color: .blue)
                } else {
                    Chip(text: "not in Dynject config", color: .orange)
                }
                Chip(text: m.takesEffect == .live ? "applies live" : "needs app relaunch",
                     color: m.takesEffect == .live ? .green : .orange)
            }
            if !loadedIn.isEmpty {
                HStack {
                    Text("Loaded in: " + loadedIn.map(\.displayName).joined(separator: ", "))
                    if m.takesEffect == .relaunch {
                        Text("Relaunch these to see changes.").foregroundStyle(.orange)
                        ForEach(loadedIn) { app in
                            Button("Relaunch \(app.displayName)") { model.relaunch(app) }
                                .disabled(model.env.fixtureMode)
                        }
                    }
                }
                .font(.callout)
            }
            if let status = model.tweakApplyStatus[m.id] {
                Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("tweak-status")
            }
            let issues = model.tweakIssues.filter { $0.file == m.sourcePath }
            ForEach(issues) { i in
                Label(i.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(i.severity == .error ? .red : .orange)
            }
            Text("Stored as \(TweakPrefsContract.payloadKey(m.id)) in your global preferences (\(model.env.fixtureMode ? "fixture file" : "readable from sandboxed apps")). Changes save as you make them.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// One global setting row.
struct TweakItemRow: View {
    var model: WorkbenchModel
    var settings: TweakSettings
    var item: TweakItem

    var body: some View {
        let isSet = settings.storedValue(item) != nil
        TweakControl(item: item, value: Binding(
            get: { settings.value(item) },
            set: { if settings.set($0, for: item) { model.tweakDidChange(settings.manifest.id) } }
        ), apps: model.apps)
        .disabled(!settings.isEnabled(item))
        .accessibilityIdentifier("tweak-item-\(item.key)")
        .contextMenu {
            Button("Reset to Default (\(item.defaultValue.displayText))") {
                settings.reset(item)
                model.tweakDidChange(settings.manifest.id)
            }
            .disabled(!isSet)
        }
        .badge(isSet ? Text("•") : nil)
    }
}

/// Renders one manifest item as a native control.
struct TweakControl: View {
    var item: TweakItem
    @Binding var value: PrefValue
    var apps: [InstalledApp]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            control
            if let f = item.footer, !compact { Text(f).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder var control: some View {
        switch item.kind {
        case .switch:
            Toggle(item.title, isOn: Binding(get: { value.bool ?? false }, set: { value = .bool($0) }))
        case .slider:
            LabeledContent(item.title) {
                HStack {
                    if let step = item.step, step > 0 {
                        Slider(value: number, in: item.min!...item.max!, step: step)
                    } else {
                        Slider(value: number, in: item.min!...item.max!)
                    }
                    Text(value.displayText).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
        case .number:
            LabeledContent(item.title) {
                TextField("", value: number, format: .number).multilineTextAlignment(.trailing).frame(maxWidth: 120)
            }
        case .color:
            LabeledContent(item.title) {
                HStack {
                    let isAuto = value.string == "auto"
                    if item.allowAuto {
                        Toggle("Auto", isOn: Binding(get: { isAuto },
                                                     set: { value = $0 ? .string("auto") : .string(lastColorHex) }))
                            .toggleStyle(.checkbox)
                    }
                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: NSColor(hex: value.string ?? "") ?? .black) },
                        set: { value = .string(NSColor($0).hexString) }), supportsOpacity: true)
                        .labelsHidden()
                        .disabled(isAuto)
                    Text(value.string ?? "").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        case .choice:
            if item.options.count <= 3 && !compact {
                Picker(item.title, selection: $value) {
                    ForEach(item.options, id: \.value) { o in Text(o.title).tag(o.value) }
                }
                .pickerStyle(.segmented)
            } else {
                Picker(item.title, selection: $value) {
                    ForEach(item.options, id: \.value) { o in Text(o.title).tag(o.value) }
                }
                .pickerStyle(.menu)
            }
        case .text:
            LabeledContent(item.title) {
                TextField(item.placeholder ?? "", text: Binding(get: { value.string ?? "" }, set: { value = .string($0) }))
                    .frame(maxWidth: 260)
            }
        case .appList:
            AppListEditor(title: item.title, ids: Binding(get: { value.list ?? [] }, set: { value = .list($0) }), apps: apps)
        }
    }

    var number: Binding<Double> {
        Binding(get: { value.number ?? item.defaultValue.number ?? 0 }, set: { value = .number($0) })
    }

    var lastColorHex: String {
        if let d = item.defaultValue.string, d != "auto" { return d }
        return "#808080"
    }
}

struct AppListEditor: View {
    var title: String
    @Binding var ids: [String]
    var apps: [InstalledApp]
    @State private var showPicker = false
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Add App…") { showPicker = true }
                    .popover(isPresented: $showPicker) { picker }
            }
            if ids.isEmpty {
                Text("No apps").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(ids, id: \.self) { bid in
                HStack {
                    if let app = apps.first(where: { $0.bundleID == bid }) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath)).resizable().frame(width: 16, height: 16)
                        Text(app.displayName)
                    }
                    Text(bid).foregroundStyle(.secondary).font(.caption)
                    Spacer()
                    Button { ids.removeAll { $0 == bid } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    var picker: some View {
        VStack(alignment: .leading) {
            TextField("Search apps", text: $query).textFieldStyle(.roundedBorder)
            List(apps.filter { !ids.contains($0.bundleID) && (query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query)) }.prefix(60)) { app in
                Button {
                    ids.append(app.bundleID)
                    showPicker = false
                } label: {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath)).resizable().frame(width: 16, height: 16)
                        Text(app.displayName)
                        Text(app.bundleID).foregroundStyle(.secondary).font(.caption)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 360, height: 360)
    }
}

/// "<Tweak> for <App>": per-app overrides, shown in the app's detail pane.
struct PerAppTweakPanel: View {
    var model: WorkbenchModel
    var settings: TweakSettings
    var app: InstalledApp

    var body: some View {
        let m = settings.manifest
        let injected = model.workingEvals[app.id]?.isInjected(m.dylib) ?? false
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if !injected {
                    Label("\(m.dylib.lastPathComponent) isn't injected into \(app.displayName), so these settings have no effect until it is.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(m.perAppItems) { item in
                    let override = settings.override(item, bundleID: app.bundleID)
                    HStack(alignment: .center, spacing: 10) {
                        Toggle("Override", isOn: Binding(
                            get: { override != nil },
                            set: { on in
                                let ok = settings.setOverride(on ? settings.effective(item, bundleID: app.bundleID) : nil,
                                                              for: item, bundleID: app.bundleID)
                                if ok { model.tweakDidChange(m.id) }
                            }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .help("Use a different value in \(app.displayName)")
                            .accessibilityIdentifier("tweak-override-\(m.id)-\(item.key)")
                        TweakControl(item: item, value: Binding(
                            get: { settings.effective(item, bundleID: app.bundleID) },
                            set: { if settings.setOverride($0, for: item, bundleID: app.bundleID) { model.tweakDidChange(m.id) } }
                        ), apps: model.apps, compact: true)
                        .disabled(override == nil || !settings.isEnabled(item, bundleID: app.bundleID))
                        if override == nil {
                            Text("global").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                Text(m.takesEffect == .live ? "Changes apply live." : "Relaunch \(app.displayName) to see changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("\(m.name) for \(app.displayName)")
                Spacer()
                Button("All Settings") { model.selectedTweakID = m.id; model.section = .tweaks }
                    .buttonStyle(.link)
            }
        }
        .axContainer("tweak-perapp-\(m.id)")
    }
}

extension NSColor {
    convenience init?(hex: String) {
        guard PrefValue.isHexColor(hex) else { return nil }
        var v: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
        let hasAlpha = hex.count == 9
        let r = Double((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(v & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded()), a = Int((c.alphaComponent * 255).rounded())
        return a < 255 ? String(format: "#%02X%02X%02X%02X", r, g, b, a) : String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// The tweak's declared Apple-menu items and its "Show in Apple menu" switch.
struct AppleMenuSection: View {
    var model: WorkbenchModel
    var manifest: TweakManifest

    var body: some View {
        let included = model.isInAppleMenu(manifest.id)
        let conflicts = model.appleMenuShortcutConflicts.filter { $0.tweakID == manifest.id }
        Section {
            Toggle("Show in Apple menu", isOn: Binding(get: { included },
                                                        set: { model.setInAppleMenu($0, tweakID: manifest.id) }))
                .accessibilityIdentifier("applemenu-include-\(manifest.id)")
            ForEach(manifest.appleMenu) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.symbol ?? "circle.dashed")
                        .frame(width: 18)
                        .foregroundStyle(item.symbol == nil ? .tertiary : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        let conflict = conflicts.first { $0.itemID == item.id }
                        HStack(spacing: 6) {
                            Text(item.title)
                            if let k = item.shortcutDisplay {
                                Text(k).foregroundStyle(.secondary).monospaced().strikethrough(conflict != nil)
                            }
                        }
                        Text(item.action.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text(details(item)).font(.caption).foregroundStyle(.tertiary)
                        if let note = conflict?.message ?? item.shortcutCaveat {
                            Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .opacity(included ? 1 : 0.5)
                .accessibilityIdentifier("applemenu-item-\(item.id)")
            }
            if let status = model.menuStatus {
                Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("applemenu-status")
            }
        } header: {
            Text("Apple menu")
        } footer: {
            Text("The MenuLoader tweak adds these to the Apple menu of apps it is injected into, \(placementText).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Where the items go, as the manifest's appleMenuPlacement and the shared entry's style decide.
    var placementText: String {
        let title = manifest.effectiveAppleMenuTitle
        if manifest.appleMenuPlacement == .submenu { return "in its own \"\(title)\" submenu" }
        return model.menuSettings.placement == .submenu
            ? "as the \"\(title)\" section of the shared \"\(model.menuSettings.effectiveSubmenuTitle)\" submenu"
            : "as their own section of the Apple menu"
    }

    func details(_ item: AppleMenuItem) -> String {
        var parts: [String] = []
        if let apps = item.apps {
            parts.append("Only in " + apps.map(model.installedAppName).joined(separator: ", "))
        } else {
            parts.append("In every app")
        }
        if let c = item.checkedBy { parts.append("checkmark follows \"\(manifest.item(c)?.title ?? c)\"") }
        return parts.joined(separator: " · ")
    }
}

/// Global MenuLoader options: Workbench's own "Dynject" group, and the style and title of the shared entry.
struct AppleMenuOptions: View {
    var model: WorkbenchModel

    var body: some View {
        let entries = model.appleMenuEntries
        let tweakCount = Set(entries.map(\.0.id)).count
        VStack(alignment: .leading, spacing: 10) {
            Text("Apple menu (MenuLoader)").font(.headline)
            Toggle("Show the Dynject menu", isOn: Binding(get: { model.showsDynjectAppleMenu },
                                                         set: { model.setShowsDynjectAppleMenu($0) }))
                .accessibilityIdentifier("applemenu-dynject")
            Text("Respring…, Safe Mode… and Open Dynject Workbench, in a \"Dynject\" submenu below App Store….")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Shared menu, for tweaks that don't ask for their own submenu:").font(.subheadline)
            Picker("Style", selection: Binding(get: { model.menuSettings.placement },
                                               set: { model.setAppleMenuPlacement($0) })) {
                Text("Submenu").tag(MenuLoaderPlacement.submenu)
                Text("Section").tag(MenuLoaderPlacement.section)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("applemenu-placement")
            if model.menuSettings.placement == .submenu {
                TextField("Submenu title", text: Binding(get: { model.menuSettings.submenuTitle },
                                                         set: { model.setAppleMenuSubmenuTitle($0) }),
                          prompt: Text(MenuLoaderSettings.defaultSubmenuTitle))
                    .accessibilityIdentifier("applemenu-title")
            }
            Text(entries.isEmpty ? "Nothing is added to the Apple menu."
                                 : "\(entries.count) item\(entries.count == 1 ? "" : "s") from \(tweakCount) group\(tweakCount == 1 ? "" : "s"), published as \(model.menuPublisher.names.key)\(model.env.isolatesMenuLoader ? " in the fixture file" : " in your global preferences").")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = model.menuStatus {
                Text(status).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}
