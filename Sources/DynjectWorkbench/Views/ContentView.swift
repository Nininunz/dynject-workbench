import DynjectCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) { s in
                Label(s.title, systemImage: s.icon).tag(s)
                    .accessibilityIdentifier("sidebar-\(s.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            VStack(spacing: 0) {
                if model.env.fixtureMode { fixtureStrip }
                if let b = model.banner {
                    BannerView(banner: b) { model.banner = nil }
                }
                Group {
                    switch model.section {
                    case .injection: InjectionView(model: model)
                    case .dylibs: DylibsView(model: model)
                    case .config: ConfigView(model: model)
                    case .plists: PlistView(model: model)
                    case .daemon: DaemonView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.hasUnsavedConfig { PendingBar(model: model) }
            }
        }
        .sheet(isPresented: $model.showApplySheet) { ApplySheet(model: model) }
        .toolbar {
            ToolbarItem {
                Button { model.reloadConfig(); model.scanApps(); model.refreshRuntime() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Re-read the config, rescan apps, and recheck loaded dylibs and dynjectd")
                .disabled(model.hasUnsavedConfig)
            }
        }
    }

    var fixtureStrip: some View {
        HStack {
            Image(systemName: "testtube.2")
            Text("Fixture mode: \(model.env.configPath). Restarts are simulated and no administrator prompt is ever shown.")
            Spacer()
        }
        .font(.caption)
        .padding(6)
        .background(.purple.opacity(0.12))
        .accessibilityIdentifier("fixture-strip")
    }

    var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let d = model.daemon {
                if d.processes.isEmpty {
                    Label("dynjectd not running", systemImage: "circle.fill").foregroundStyle(.red)
                } else if d.isDuplicated {
                    Label("\(d.processes.count) dynjectd running", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if d.needsRestart {
                    Label("Restart needed", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                } else {
                    Label("dynjectd running", systemImage: "circle.fill").foregroundStyle(.green)
                }
            }
            if model.hasUnsavedConfig {
                Label("Unsaved config", systemImage: "pencil.circle.fill").foregroundStyle(.blue)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}

struct PendingBar: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        let added = LineDiff.diff(model.diskText, model.workingText).filter { if case .same = $0 { return false } else { return true } }.count
        HStack {
            Image(systemName: "pencil.circle.fill").foregroundStyle(.blue)
            Text("Unsaved config changes (\(added) line\(added == 1 ? "" : "s")). dynjectd sees them only after you save and restart it.")
                .font(.callout)
            Spacer()
            Button("Discard") { model.discardConfigChanges() }
                .accessibilityIdentifier("discard-config")
            Button("Review & Save…") { model.showApplySheet = true }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("review-save")
        }
        .padding(10)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
        .axContainer("pending-bar")
    }
}
