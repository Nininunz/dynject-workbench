import AppKit
import DynjectCore
import SwiftUI

struct InjectionView: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search name, bundle ID, or executable", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("app-search")
                    Toggle("Injected only", isOn: $model.onlyInjected)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("only-injected")
                }
                .padding(8)
                Table(model.filteredApps, selection: $model.selectedAppID) {
                    TableColumn("Name") { app in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
                                .resizable().frame(width: 16, height: 16)
                            Text(app.displayName)
                        }
                    }
                    .width(min: 120, ideal: 170)
                    TableColumn("Bundle ID") { app in Text(app.bundleID).foregroundStyle(.secondary) }
                        .width(min: 120, ideal: 200)
                    TableColumn("Executable") { app in Text(app.executableName).foregroundStyle(.secondary) }
                        .width(min: 70, ideal: 110)
                    TableColumn("Injection") { app in InjectionSummary(model: model, app: app) }
                        .width(min: 90, ideal: 140)
                }
                .accessibilityIdentifier("apps-table")
                HStack {
                    Text(model.isScanning ? "Scanning…" : "\(model.filteredApps.count) of \(model.apps.count) apps")
                    Spacer()
                    if let t = model.runtimeCheckedAt {
                        Text("Loaded check \(t.formatted(date: .omitted, time: .standard))")
                    }
                    Button { model.refreshRuntime() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Recheck which dylibs are loaded in running apps (lsof)")
                        .disabled(model.isRefreshingRuntime)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
            }
            .frame(minWidth: 430, idealWidth: 560)

            Group {
                if let app = model.selectedApp {
                    AppDetailView(model: model, app: app)
                } else {
                    ContentUnavailableView("Select an app", systemImage: "app.dashed",
                                           description: Text("Pick an app to see and change how each configured dylib applies to it."))
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .axContainer("screen-injection")
    }
}

struct InjectionSummary: View {
    var model: WorkbenchModel
    var app: InstalledApp

    var body: some View {
        let configured = model.workingEvals[app.id]?.injectedDylibs ?? []
        let loaded = model.loaded[app.id] ?? []
        HStack(spacing: 4) {
            if !configured.isEmpty {
                Chip(text: "\(configured.count) configured", color: .blue)
            }
            if !loaded.isEmpty {
                Chip(text: "\(loaded.count) loaded", color: .green)
            }
            if configured.isEmpty && loaded.isEmpty {
                Text("—").foregroundStyle(.tertiary)
            }
        }
    }
}

struct AppDetailView: View {
    @Bindable var model: WorkbenchModel
    var app: InstalledApp

    var body: some View {
        let eval = model.workingEvals[app.id]
        let service = model.service(for: app)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(service)
                if let lastEdit = model.lastEdit, lastEdit.appName == app.displayName { editSummary(lastEdit) }

                GroupBox("dylibs configured in Dynject") {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.workingConfig.dylibPaths.isEmpty {
                            Text("The config declares no dylibs.").foregroundStyle(.secondary)
                        }
                        ForEach(model.workingConfig.dylibPaths, id: \.self) { dylib in
                            DylibRow(model: model, app: app, dylib: dylib, decision: eval?.decision(for: dylib))
                            Divider()
                        }
                        legend
                    }
                    .padding(6)
                }

                ForEach(model.tweaks.filter { !$0.perAppItems.isEmpty }) { m in
                    if let settings = model.tweakSettings[m.id] {
                        PerAppTweakPanel(model: model, settings: settings, app: app)
                    }
                }

                if let eval {
                    GroupBox("dynjectd filters (all must pass before any dylib is considered)") {
                        VStack(alignment: .leading, spacing: 6) {
                            GateRow(title: "1 · XPC service", outcome: eval.serviceGate)
                            GateRow(title: "2 · Process", outcome: eval.processGate)
                            Text("3 · Per-dylib policy: shown on each dylib above. The first matching dylib-override wins, otherwise the dylib's default applies.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .axContainer("gates")
                }

                guidanceBox

                if let match = model.log?.lastMatch(bundleID: app.bundleID, executable: app.executableName, service: service.value) {
                    GroupBox("Daemon log") {
                        Text("Last injection attempt at \(match.time): \(match.service) \(match.outcome). A log MATCH means dynjectd set DYLD_INSERT_LIBRARIES. Only the loaded check confirms dyld actually loaded it.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                }
            }
            .padding(16)
        }
        .axContainer("app-detail")
    }

    func header(_ service: ServiceName) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath)).resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName).font(.title2.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                    GridRow { Text("Bundle ID").foregroundStyle(.secondary); Text(app.bundleID).textSelection(.enabled) }
                    GridRow { Text("Executable").foregroundStyle(.secondary); Text(app.executableName).textSelection(.enabled) }
                    GridRow { Text("Path").foregroundStyle(.secondary); Text(app.bundlePath).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
                    GridRow {
                        Text("XPC service").foregroundStyle(.secondary)
                        HStack {
                            Text(service.value).textSelection(.enabled)
                            Chip(text: serviceSourceText(service.source), color: service.source == .observed ? .green : .gray)
                        }
                    }
                    if let pids = model.runningPIDs[app.id] {
                        GridRow { Text("Running").foregroundStyle(.secondary); Text("PID \(pids.map(String.init).joined(separator: ", "))") }
                    }
                }
                .font(.callout)
            }
        }
    }

    func serviceSourceText(_ s: ServiceName.Source) -> String {
        switch s {
        case .observed: return "seen in log"
        case .launchdLabel: return "launchd label"
        case .predicted: return "predicted"
        }
    }

    func editSummary(_ e: EditSummary) -> some View {
        GroupBox("Pending edit") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(e.changes.enumerated()), id: \.offset) { _, c in
                    Text(c.description).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                ForEach(e.notes, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                if !e.sideEffects.isEmpty {
                    Label("Also changes: " + e.sideEffects.map(\.app.displayName).joined(separator: ", "),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .axContainer("pending-edit")
    }

    var guidanceBox: some View {
        let steps = model.guidance(for: app)
        return Group {
            if !steps.isEmpty {
                GroupBox("What has to happen before this app sees the change") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                                Text(s)
                            }
                        }
                        HStack {
                            if model.runningPIDs[app.id] != nil {
                                Button("Quit & Relaunch \(app.displayName)…") { confirmRelaunch() }
                                    .disabled(model.env.fixtureMode || model.hasUnsavedConfig)
                                    .help(model.hasUnsavedConfig ? "Save the config (and restart Dynject) first" : "Asks the app to quit normally, then opens it again")
                            }
                            Button("Recheck loaded dylibs") { model.refreshRuntime() }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .axContainer("relaunch-guidance")
            }
        }
    }

    var legend: some View {
        Text("Configured: the policy in this window would inject it. Saved: the policy on disk. Loaded: lsof shows the dylib mapped in the running process, which is the only confirmation that it actually loaded.")
            .font(.caption).foregroundStyle(.secondary)
    }

    func confirmRelaunch() {
        let alert = NSAlert()
        alert.messageText = "Quit and relaunch \(app.displayName)?"
        alert.informativeText = "The app is asked to quit normally, so it may show save prompts. If dynjectd hasn't been restarted since the config was saved, the new launch still uses the old policy."
        alert.addButton(withTitle: "Quit & Relaunch")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.relaunch(app) }
    }
}

struct DylibRow: View {
    var model: WorkbenchModel
    var app: InstalledApp
    var dylib: String
    var decision: DylibDecision?

    var body: some View {
        let st = model.status(app, dylib)
        let eval = model.workingEvals[app.id]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                Text(dylib.lastPathComponent).fontWeight(.medium)
                Spacer()
                Toggle("Inject", isOn: Binding(
                    get: { st.configured },
                    set: { model.setInjection($0, dylib: dylib, app: app) }
                ))
                .toggleStyle(.switch)
                .accessibilityIdentifier("inject-toggle-\(dylib.lastPathComponent)")
                .accessibilityLabel("Inject \(dylib.lastPathComponent) into \(app.displayName)")
            }
            HStack(spacing: 4) {
                if st.configured {
                    Chip(text: st.pending ? "Configured (unsaved)" : "Configured", color: .blue, systemImage: "doc.badge.gearshape")
                } else {
                    Chip(text: st.pending ? "Not configured (unsaved)" : "Not configured", color: .gray)
                }
                if st.running && st.inspected {
                    Chip(text: st.loaded ? "Loaded" : "Not loaded", color: st.loaded ? .green : .gray,
                         systemImage: st.loaded ? "checkmark.seal.fill" : "circle.dashed")
                } else if st.running {
                    Chip(text: "Loaded: can't inspect", color: .orange)
                } else {
                    Chip(text: "Not running", color: .gray)
                }
                if decision?.fileMissing == true { Chip(text: "File missing", color: .red) }
            }
            if let decision {
                Text("Policy: \(decision.reasonText)" + ((eval?.gatesPass ?? false) ? "" : ". Blocked earlier by dynjectd's filters (see below)."))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .axContainer("dylib-row-\(dylib.lastPathComponent)")
    }
}
