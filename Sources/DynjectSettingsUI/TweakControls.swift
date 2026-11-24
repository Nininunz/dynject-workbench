// The native control for each kind of manifest setting, shared by Workbench and SettingsLoader (Tweaks/SettingsLoader).
import AppKit
import DynjectCore
import SwiftUI

/// Renders one manifest item as a native control.
public struct TweakControl: View {
    var item: TweakItem
    @Binding var value: PrefValue
    var apps: [InstalledApp]
    var compact = false

    public init(item: TweakItem, value: Binding<PrefValue>, apps: [InstalledApp], compact: Bool = false) {
        self.item = item
        _value = value
        self.apps = apps
        self.compact = compact
    }

    public var body: some View {
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

public struct AppListEditor: View {
    var title: String
    @Binding var ids: [String]
    var apps: [InstalledApp]

    public init(title: String, ids: Binding<[String]>, apps: [InstalledApp]) {
        self.title = title
        _ids = ids
        self.apps = apps
    }
    @State private var showPicker = false
    @State private var query = ""

    public var body: some View {
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

extension NSColor {
    public convenience init?(hex: String) {
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

    public var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded()), a = Int((c.alphaComponent * 255).rounded())
        return a < 255 ? String(format: "#%02X%02X%02X%02X", r, g, b, a) : String(format: "#%02X%02X%02X", r, g, b)
    }
}
