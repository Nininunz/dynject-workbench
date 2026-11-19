import AppKit
import DynjectCore
import SwiftUI

struct ConfigView: View {
    @Bindable var model: WorkbenchModel
    @State private var highlight: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.env.configPath).font(.headline).textSelection(.enabled)
                Text(fileInfo).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reload from Disk") { model.reloadConfig() }
                    .disabled(model.hasUnsavedConfig)
                Button("Discard Edits") { model.discardConfigChanges() }
                    .disabled(!model.hasUnsavedConfig)
                Button("Review & Save…") { model.showApplySheet = true }
                    .disabled(!model.hasUnsavedConfig)
                    .buttonStyle(.borderedProminent)
            }
            .padding(10)
            if let err = model.configLoadError {
                Label(err, systemImage: "xmark.octagon.fill").foregroundStyle(.red).padding(.horizontal, 10)
            }
            VSplitView {
                CodeTextView(text: $model.workingText, identifier: "config-editor", highlightLine: highlight)
                    .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                DiagnosticsList(diagnostics: model.diagnostics) { highlight = $0 }
                    .frame(maxWidth: .infinity, minHeight: 90, idealHeight: 150)
            }
            Text("Edits here and the app toggles share one buffer. Nothing is written until you save, and dynjectd reads the file only when it starts.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .axContainer("screen-config")
    }

    var fileInfo: String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: model.env.configPath) else { return "" }
        let owner = a[.ownerAccountName] as? String ?? "?"
        let mode = (a[.posixPermissions] as? NSNumber).map { String($0.intValue, radix: 8) } ?? "?"
        let writable = AtomicFile.canWriteDirectly(model.env.configPath)
        return "owner \(owner), mode \(mode). \(writable ? "Writable without administrator rights." : "Saving needs administrator authorization.")"
    }
}

struct ApplySheet: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        let changes = model.pendingAppChanges
        let liveRestart = model.restarter.isLive
        VStack(alignment: .leading, spacing: 12) {
            Text("Review config changes").font(.title2.weight(.semibold))
            Text(model.env.configPath).font(.callout).foregroundStyle(.secondary)

            DiffView(old: model.diskText, new: model.workingText)
                .frame(minHeight: 160, maxHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))

            if !model.blockingErrors.isEmpty {
                ForEach(model.blockingErrors) { d in
                    Label((d.line.map { "Line \($0 + 1): " } ?? "") + d.message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
            let warnings = model.diagnostics.filter { $0.severity == .warning }
            if !warnings.isEmpty {
                Label("\(warnings.count) warning(s). See the Raw Config diagnostics.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            GroupBox("Effective injection changes (installed apps)") {
                VStack(alignment: .leading, spacing: 3) {
                    if changes.isEmpty {
                        Text("No installed app's injection changes (comments, formatting, or rules for apps not installed).")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(changes, id: \.app.id) { c in
                        let added = Set(c.after).subtracting(c.before).map(\.lastPathComponent).sorted()
                        let removed = Set(c.before).subtracting(c.after).map(\.lastPathComponent).sorted()
                        HStack(alignment: .firstTextBaseline) {
                            Text(c.app.displayName).fontWeight(.medium)
                            if !added.isEmpty { Text("+ " + added.joined(separator: ", ")).foregroundStyle(.green) }
                            if !removed.isEmpty { Text("− " + removed.joined(separator: ", ")).foregroundStyle(.red) }
                            if model.runningPIDs[c.app.id] != nil { Chip(text: "running: relaunch needed", color: .orange) }
                        }
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label(model.configNeedsAdmin
                      ? "The file is protected. macOS will ask for an administrator password. The helper backs up the file, refuses to write if it changed on disk since it was loaded, writes atomically, and keeps the file's owner and mode."
                      : "The file is writable, so it is replaced atomically without administrator rights. A backup is made first.",
                      systemImage: model.configNeedsAdmin ? "lock.shield" : "doc.on.doc")
                Label(liveRestart
                      ? "Save & Restart stops every running dynjectd (\(model.daemon?.processes.count ?? 0) now), confirms none are left, then starts exactly one with launchctl kickstart (never kickstart -k, which would leave the old detached daemon running). Avoid launching apps during the restart."
                      : "Fixture mode: the restart is simulated.",
                      systemImage: "arrow.triangle.2.circlepath")
                Label("Running apps keep their current dylibs until you quit and relaunch them.", systemImage: "app.badge")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                if model.isWriting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { model.showApplySheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save Only") { model.saveConfig(restart: false) }
                    .disabled(!model.blockingErrors.isEmpty || model.isWriting)
                    .accessibilityIdentifier("save-only")
                Button(liveRestart ? "Save & Restart Dynject" : "Save & Restart (simulated)") { model.saveConfig(restart: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.blockingErrors.isEmpty || model.isWriting)
                    .accessibilityIdentifier("save-restart")
            }
        }
        .padding(20)
        .frame(width: 720)
        .axContainer("apply-sheet")
    }
}

struct DylibsView: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Parsed from \(model.env.configPath), including unsaved edits. dynjectd honours at most \(DynjectLimits.maxDylibs) dylibs with \(DynjectLimits.maxOverridesPerDylib) overrides each.")
                    .font(.callout).foregroundStyle(.secondary)
                if model.workingConfig.dylibs.isEmpty {
                    ContentUnavailableView("No dylibs configured", systemImage: "shippingbox",
                                           description: Text("dynjectd refuses to start without at least one dylib: line."))
                }
                ForEach(Array(model.workingConfig.dylibs.enumerated()), id: \.offset) { _, d in
                    DylibCard(model: model, dylib: d)
                }
                GroupBox("Global rules") {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        GridRow { Text("ui_apps").foregroundStyle(.secondary); Text(model.workingConfig.uiApps ? "yes: apps in /Applications, /System/Applications, and CoreServices pass the process filter" : "no: only executables matching an allow: rule pass the process filter") }
                        GridRow { Text("skip_helpers").foregroundStyle(.secondary); Text(model.workingConfig.skipHelpers ? "yes: executables named \"… Helper\" are skipped" : "no") }
                        GridRow { Text("allow").foregroundStyle(.secondary); Text(model.workingConfig.allowRules.map { "\($0.value) (line \($0.line + 1))" }.joined(separator: ", ").ifEmpty("none")) }
                        GridRow { Text("deny").foregroundStyle(.secondary); Text(model.workingConfig.denyRules.map { "\($0.value) (line \($0.line + 1))" }.joined(separator: ", ").ifEmpty("none")) }
                    }
                    .font(.callout)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("allow/deny values are case-sensitive substring matches against the executable name, the executable path, and the XPC service name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .axContainer("screen-dylibs")
    }
}

struct DylibCard: View {
    var model: WorkbenchModel
    var dylib: EffectiveConfig.Dylib

    var body: some View {
        let injectedInto = model.apps.filter { model.workingEvals[$0.id]?.isInjected(dylib.path) ?? false }
        let plists = model.associations.filter { $0.dylibPath == dylib.path }
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                header
                Text(dylib.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if dylib.overrides.isEmpty {
                    Text("No overrides.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(dylib.overrides.enumerated()), id: \.offset) { _, o in
                        HStack {
                            Image(systemName: o.allow ? "plus.circle.fill" : "minus.circle.fill").foregroundStyle(o.allow ? .green : .red)
                            Text("\(o.allow ? "allow" : "deny") \"\(o.pattern)\"").font(.system(.callout, design: .monospaced))
                            Text("line \(o.line + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Injects into \(injectedInto.count) installed app(s): " + injectedInto.prefix(12).map(\.displayName).joined(separator: ", ") + (injectedInto.count > 12 ? ", …" : ""))
                    .font(.callout)
                Divider()
                HStack {
                    Text("Settings plists (associated manually)").font(.callout.weight(.medium))
                    Spacer()
                    Button("Associate Plist…") { associate() }
                }
                if plists.isEmpty {
                    Text("None. Workbench doesn't guess where a dylib keeps its settings. Associate a file you know it reads.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(plists) { a in
                    HStack {
                        Image(systemName: "doc.text")
                        Text(a.plistPath).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        if !FileManager.default.fileExists(atPath: a.plistPath) { Chip(text: "missing", color: .red) }
                        Spacer()
                        Button("Open") { model.openPlist(a.plistPath); model.section = .plists }
                        Button(role: .destructive) { model.removeAssociation(a) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .padding(6)
        }
        .axContainer("dylib-card-\(dylib.path.lastPathComponent)")
    }

    var header: some View {
        HStack {
            Text(dylib.path.lastPathComponent).font(.headline)
            Chip(text: dylib.defaultAllow ? "default allow" : "default deny", color: dylib.defaultAllow ? .orange : .blue)
            if !FileManager.default.fileExists(atPath: dylib.path) { Chip(text: "file missing", color: .red) }
            Spacer()
            if let t = model.tweaks(forDylib: dylib.path).first {
                Button("\(t.name) Settings…") { model.selectedTweakID = t.id; model.section = .tweaks }
            }
            Text("line \(dylib.line + 1)").font(.caption).foregroundStyle(.secondary)
        }
    }

    func associate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Preferences")
        panel.message = "Choose a plist that \(dylib.path.lastPathComponent) reads its settings from"
        if panel.runModal() == .OK, let url = panel.url {
            model.associate(plist: url.path, dylib: dylib.path)
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
