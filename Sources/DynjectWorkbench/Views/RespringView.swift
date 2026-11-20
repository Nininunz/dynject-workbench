import AppKit
import DynjectCore
import SwiftUI

/// The sidebar footer's line: how many running apps still run with an old set of tweaks. Opens the sheet.
struct RespringFooterButton: View {
    var model: WorkbenchModel

    var body: some View {
        let r = model.respring
        Button { model.openRespring() } label: {
            if let plan = r.plan {
                let n = plan.pending.count
                if n > 0 {
                    Label("Respring: \(n) app\(n == 1 ? "" : "s") pending", systemImage: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("No respring needed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            } else {
                Label(r.fixtureError == nil ? "Checking running apps…" : "Respring unavailable", systemImage: "arrow.clockwise.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Running apps keep the tweaks they launched with. Click to see which ones need a relaunch.")
        .accessibilityIdentifier("respring-footer")
    }
}

struct RespringSheet: View {
    var model: WorkbenchModel
    var r: RespringModel { model.respring }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if r.runList.isEmpty { chooser } else { runView }
            Divider()
            footer
        }
        .frame(width: 700, height: 560)
        .interactiveDismissDisabled(r.isRunning)
        .axContainer("respring-sheet")
    }

    // MARK: Header

    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Respring").font(.title2.weight(.semibold))
                    Text("Tweaks are injected only when an app launches, so running apps keep the set they started with. "
                         + "Relaunch them to apply the current config. Each app is asked to quit; one that doesn't quit within "
                         + "the timeout (unsaved changes, a dialog) is skipped and left alone.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if r.simulated {
                Label("Simulated: these are fixture apps. No real app is quit, opened or inspected.", systemImage: "testtube.2")
                    .font(.caption).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("respring-simulated")
            }
            if let e = r.fixtureError {
                Label(e, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            }
            if r.daemonNeedsRestart {
                Label("dynjectd needs a restart first (Daemon page): relaunched apps would still get the old set.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("respring-daemon-warning")
            }
        }
        .padding(16)
    }

    // MARK: Choosing

    @ViewBuilder
    var chooser: some View {
        let rows = r.visibleCandidates
        if r.plan == nil {
            VStack { Spacer(); ProgressView("Checking running apps…"); Spacer() }.frame(maxWidth: .infinity)
        } else if rows.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "checkmark.circle").font(.system(size: 34)).foregroundStyle(.green)
                Text("Every running app has the tweaks the config gives it.").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("respring-empty")
        } else {
            // A plain stack, not a List: the smoke test's accessibility search doesn't descend into tables.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { c in
                        RespringRow(model: model, candidate: c).padding(.horizontal, 16).padding(.vertical, 6)
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .axContainer("respring-list")
        }
    }

    // MARK: Running

    var runView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = r.runSummary {
                Label(s, systemImage: "flag.checkered").font(.callout.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 8)
                    .accessibilityIdentifier("respring-summary")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(r.runList) { c in
                        RespringRunRow(model: model, candidate: c).padding(.horizontal, 16).padding(.vertical, 6)
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .axContainer("respring-run-list")
        }
    }

    // MARK: Footer

    var footer: some View {
        HStack(spacing: 10) {
            if r.runList.isEmpty {
                Button { r.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(r.isPlanning)
                    .accessibilityIdentifier("respring-refresh")
                Toggle("Show all running apps", isOn: Binding(get: { r.showAllApps }, set: { r.showAllApps = $0 }))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("respring-show-all")
                if r.isPlanning { ProgressView().controlSize(.small) }
                Spacer()
                Stepper(value: Binding(get: { r.quitTimeout }, set: { r.quitTimeout = $0 }), in: 5...120, step: 5) {
                    Text("Quit timeout \(Int(r.quitTimeout)) s").monospacedDigit()
                }
                .help("How long each app gets to quit before it is skipped")
                Button("Close") { r.close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("respring-close")
                let n = r.selectedCandidates.count
                Button("Respring Selected (\(n))") { r.run() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(n == 0 || r.plan == nil)
                    .accessibilityIdentifier("respring-run")
            } else if r.isRunning {
                ProgressView().controlSize(.small)
                Text(r.stopRequested ? "Stopping after this app…" : "Relaunching \(r.results.count + 1) of \(r.runList.count)…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop After This App") { r.stop() }
                    .disabled(r.stopRequested)
                    .accessibilityIdentifier("respring-stop")
            } else {
                Button("Back to List") { r.backToList() }
                    .accessibilityIdentifier("respring-back")
                Spacer()
                Button("Done") { r.close() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("respring-done")
            }
        }
        .padding(12)
    }
}

/// One running app in the chooser: checkbox, reasons, and why it is unchecked by default.
struct RespringRow: View {
    var model: WorkbenchModel
    var candidate: RespringCandidate

    var body: some View {
        let r = model.respring
        let c = candidate
        let id = c.app.bundleID
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { r.isSelected(c) }, set: { r.setSelected($0, c) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!r.canSelect(c) || r.isRunning)
                .accessibilityLabel("Relaunch \(c.app.name)")
                .accessibilityIdentifier("respring-check-\(id)")
            RespringAppIcon(model: model, app: c.app)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(c.app.name).fontWeight(.medium)
                    Text(id).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("pid \(c.app.pid)" + (c.app.launchDate.map { " · launched \(RespringFormat.time($0))" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if c.isPending {
                    ForEach(Array(c.reasons.enumerated()), id: \.offset) { _, reason in
                        Label(RespringFormat.line(reason), systemImage: RespringFormat.icon(reason.kind))
                            .font(.callout)
                            .foregroundStyle(RespringFormat.color(reason.kind))
                            .help(reason.detail)
                    }
                } else if !c.isInspected {
                    Label("Couldn't inspect it with lsof; its tweaks are unknown.", systemImage: "questionmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    let tweaks = c.expected.map { r.labels[$0] ?? $0.lastPathComponent }
                    Label(tweaks.isEmpty ? "Up to date (no tweaks)" : "Up to date: " + tweaks.joined(separator: ", "),
                          systemImage: "checkmark.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let note = r.note(for: c) {
                    Text(note).font(.caption).foregroundStyle(r.isSelected(c) ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("respring-note-\(id)")
                }
            }
        }
        .padding(.vertical, 3)
        .axContainer("respring-row-\(id)")
    }
}

/// One app during and after a run.
struct RespringRunRow: View {
    var model: WorkbenchModel
    var candidate: RespringCandidate

    var body: some View {
        let r = model.respring
        let c = candidate
        HStack(alignment: .top, spacing: 10) {
            RespringAppIcon(model: model, app: c.app)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.app.name).fontWeight(.medium)
                if let result = r.result(for: c) {
                    Label(r.summary(result), systemImage: RespringFormat.icon(result))
                        .font(.callout)
                        .foregroundStyle(RespringFormat.color(result))
                        .accessibilityIdentifier("respring-result-\(c.app.bundleID)")
                } else if let a = r.activity[c.id] {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(a).font(.callout)
                    }
                } else {
                    Text(r.isRunning ? "Waiting" : "Not started").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

struct RespringAppIcon: View {
    var model: WorkbenchModel
    var app: RunningApp

    var body: some View {
        Group {
            if let icon = model.appIcon(bundleID: app.bundleID) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
    }
}

enum RespringFormat {
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    static func time(_ d: Date) -> String { Calendar.current.isDateInToday(d) ? clock.string(from: d) : day.string(from: d) }

    static func line(_ r: RespringReason) -> String {
        if r.kind == .updated, let d = r.date { return "\(r.summary) (file changed \(time(d)))" }
        return r.summary
    }

    static func icon(_ k: RespringReason.Kind) -> String {
        switch k {
        case .missing: return "plus.circle"
        case .unwanted: return "minus.circle"
        case .updated: return "arrow.triangle.2.circlepath"
        case .safeModeOff, .safeModeOn: return "cross.case"
        }
    }

    static func color(_ k: RespringReason.Kind) -> Color {
        switch k {
        case .missing: return .blue
        case .unwanted: return .red
        case .updated: return .purple
        case .safeModeOff, .safeModeOn: return .orange
        }
    }

    static func icon(_ r: RespringResult) -> String {
        if r.succeeded { return "checkmark.circle.fill" }
        switch r.outcome {
        case .relaunched: return "exclamationmark.triangle.fill"
        case .openFailed: return "xmark.octagon.fill"
        default: return "minus.circle.fill"
        }
    }

    static func color(_ r: RespringResult) -> Color {
        if r.succeeded { return .green }
        switch r.outcome {
        case .openFailed: return .red
        default: return .orange
        }
    }
}
