import DynjectCore
import SwiftUI

/// Bridge: the DynjectBridge broker's LaunchAgent, which tweaks may ask it for what, and its recent decisions.
/// A plain ScrollView + VStack like Safe Mode, so every row stays in the accessibility tree.
struct BridgeView: View {
    var model: WorkbenchModel
    var bridge: BridgeModel { model.bridge }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let m = bridge.message {
                    Label(m.text, systemImage: m.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(m.isError ? .orange : .secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("bridge-message")
                }
                agentBox
                tweaksBox
                decisionsBox
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .axContainer("screen-bridge")
        .task {
            // The broker writes its log about once a second while busy; re-read it while the panel is visible.
            while !Task.isCancelled {
                bridge.refresh()
                bridge.refreshAgentStatus()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bridge").font(.title2.weight(.semibold))
                Spacer()
                if bridge.deniedCount > 0 {
                    Chip(text: "\(bridge.deniedCount) denied recently", color: .orange)
                }
            }
            Text("Tweaks in sandboxed apps can't write their own settings, post most notifications or open other apps' links. The bridge is a small background agent, running as you without administrator rights, that does a few such things for them: only what a tweak's manifest declares, only inside apps the Dynject config injects that tweak into, and only within a rate limit. Every request is logged below.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if bridge.isolated {
                Label("Isolated: the agent is \(bridge.names.service) under \(bridge.agent.launchAgentsDirectory.path), launchctl is simulated, the token is kept in memory and the log is \(bridge.logURL.path). The real bridge is untouched.",
                      systemImage: "testtube.2")
                    .font(.caption).foregroundStyle(.purple)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("bridge-isolated")
            }
        }
    }

    var agentBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    statusLabel
                    Spacer()
                    let installed = bridge.agentStatus?.plistInstalled ?? false
                    Button(installed ? "Reinstall" : "Install Bridge") { bridge.installAgent() }
                        .disabled(!bridge.dwBinaryAvailable)
                        .help(bridge.dwBinaryAvailable ? "Copy dw to \(bridge.agent.binaryURL.path) and load \(bridge.agent.plistURL.path)"
                                                       : "No dw binary at \(bridge.dwBinaryPath)")
                        .accessibilityIdentifier("bridge-agent-install")
                    Button("Uninstall") { bridge.uninstallAgent() }
                        .disabled(!installed && !(bridge.agentStatus?.loaded ?? false))
                        .accessibilityIdentifier("bridge-agent-uninstall")
                }
                if !bridge.dwBinaryAvailable {
                    Label("No dw binary next to Workbench (\(bridge.dwBinaryPath)). scripts/build-app.sh bundles it.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Text("A LaunchAgent (\(bridge.agent.label)) runs `dw bridge serve` in your login session. It publishes a sandbox token in the global preferences (\(bridge.names.tokenKey)) so sandboxed apps may connect, then checks each request against the live config and the tweak's manifest.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(bridge.tokenPublished ? "Token published: sandboxed tweaks can reach the bridge."
                                            : "No token published: tweaks get \"not installed\".",
                      systemImage: bridge.tokenPublished ? "key.fill" : "key")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("bridge-token")
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Broker")
        }
        .axContainer("bridge-agent")
    }

    @ViewBuilder var statusLabel: some View {
        if let s = bridge.agentStatus {
            let (color, icon): (Color, String) = s.running ? (.green, "circle.fill")
                : s.plistInstalled ? (.orange, "exclamationmark.circle.fill") : (.secondary, "circle")
            HStack(spacing: 6) {
                Label("Bridge " + s.summary, systemImage: icon).foregroundStyle(color)
                if s.plistInstalled && !s.plistMatches { Chip(text: "plist differs from Workbench's", color: .orange) }
                if s.plistInstalled && !s.binaryInstalled { Chip(text: "dw binary missing", color: .red) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("bridge-agent-status")
            .accessibilityValue(s.summary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    var tweaksBox: some View {
        let declaring = model.tweaks.filter { !$0.bridge.isEmpty }
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if declaring.isEmpty {
                    Text("No installed tweak declares bridge capabilities.").foregroundStyle(.secondary)
                }
                ForEach(declaring) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(m.name).fontWeight(.medium)
                            Text(m.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        BridgeCapabilityList(capabilities: m.bridge)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("bridge-tweak-\(m.id)")
                }
                Text("The bridge knows the calling app, not the tweak: any code loaded in an app can claim to be any tweak injected there. So each capability is narrow, and a tweak should declare only what it uses.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("What tweaks may ask for")
        }
        .axContainer("bridge-tweaks")
    }

    var decisionsBox: some View {
        let shown = Array(bridge.entries.prefix(100))
        return GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if shown.isEmpty {
                    Text("No requests yet.").foregroundStyle(.secondary).padding(.vertical, 4)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, e in
                    if i > 0 { Divider().padding(.vertical, 4) }
                    BridgeDecisionRow(model: model, entry: e)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Recent decisions")
                Spacer()
                Text(bridge.logURL.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .axContainer("bridge-decisions")
    }
}

struct BridgeDecisionRow: View {
    var model: WorkbenchModel
    var entry: BridgeLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Chip(text: entry.allowed ? "allowed" : entry.reason, color: entry.allowed ? .green : .orange)
                Text(entry.action).font(.system(.callout, design: .monospaced))
                Text(model.tweaks.first { $0.id == entry.tweak }?.name ?? entry.tweak).lineLimit(1)
                Text("in \(entry.app == "?" ? "an unidentified process" : model.appDisplayName(bundleID: entry.app))")
                    .foregroundStyle(.secondary).lineLimit(1)
                if entry.count > 1 { Text("×\(entry.count)").foregroundStyle(.secondary) }
                Spacer()
                Text(entry.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
            }
            if let d = entry.detail, !entry.allowed {
                Text(d).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bridge-decision-\(entry.id)")
    }
}

/// A tweak's declared capabilities, one per line (tweak page, install review, Bridge panel).
struct BridgeCapabilityList: View {
    var capabilities: [BridgeCapability]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(capabilities, id: \.self) { c in
                HStack(spacing: 6) {
                    Image(systemName: icon(c)).frame(width: 16).foregroundStyle(.secondary)
                    Text(c.summary)
                    Text(c.rawValue).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if c.isHighRisk {
                        Chip(text: "hands links to another app", color: .orange, systemImage: "exclamationmark.triangle")
                            .help("Only http, https and mailto links just show something. An app that handles this scheme may act on the link.")
                    }
                }
                .font(.callout)
            }
        }
    }

    func icon(_ c: BridgeCapability) -> String {
        switch c {
        case .settingsSet: return "slider.horizontal.3"
        case .notify: return "bell"
        case .pasteboardWrite: return "doc.on.clipboard"
        case .open: return "link"
        }
    }
}
