import AppKit
import DynjectCore
import SwiftUI

/// Install Tweak…: shows what will change (dylib, config lines, restart, manifest) before the one administrator prompt.
struct InstallTweakSheet: View {
    var model: WorkbenchModel
    var review: TweakInstallReview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install Tweak").font(.title2.weight(.semibold))
            if let m = review.source?.manifest {
                HStack(alignment: .firstTextBaseline) {
                    Text(m.name).font(.headline)
                    Text(m.id).foregroundStyle(.secondary)
                    if let v = m.version { Text("v\(v)").foregroundStyle(.secondary) }
                }
            }
            Text(review.source?.manifestPath ?? review.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)

            if review.source != nil {
                GroupBox("Enable for") {
                    VStack(alignment: .leading, spacing: 4) {
                        if review.bundleIDs.isEmpty {
                            Text("No app yet: it is declared (deny by default) and loads nowhere until you enable it.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(review.bundleIDs, id: \.self) { id in
                            HStack {
                                Text(model.appDisplayName(bundleID: id))
                                Text(id).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button { model.setInstallApps(review.bundleIDs.filter { $0 != id }) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        Menu("Add App") {
                            ForEach(addableApps, id: \.id) { app in
                                Button("\(app.displayName) (\(app.bundleID))") { model.setInstallApps(review.bundleIDs + [app.bundleID]) }
                            }
                        }
                        .fixedSize()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let m = review.source?.manifest, !m.bridge.isEmpty {
                GroupBox("Asks the bridge for") {
                    VStack(alignment: .leading, spacing: 4) {
                        BridgeCapabilityList(capabilities: m.bridge)
                        let risky = m.bridge.filter(\.isHighRisk)
                        if !risky.isEmpty {
                            Label("It may open \(risky.map(\.rawValue).map { $0.dropFirst(5) + ":" }.joined(separator: ", ")) links. "
                                  + "Unlike http, https and mailto, the app that handles such a link may act on it. "
                                  + "Any code in an app this tweak is injected into can use this.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.callout).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("install-bridge-risky")
                        }
                        Text("Granted inside the apps the config injects it into, as long as the bridge is installed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("install-bridge-capabilities")
            }

            if let plan = review.plan {
                GroupBox("Changes") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(plan.summary.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(line.hasPrefix("  +") ? .green : line.hasPrefix("  -") ? .red : .primary)
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 80, maxHeight: 220)
                }
                ForEach(plan.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                }
                ForEach(plan.notes, id: \.self) { n in Text(n).font(.caption).foregroundStyle(.secondary) }
                Text(promptNote(plan)).font(.caption).foregroundStyle(.secondary)
            }
            if let error = review.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
            }
            if let blocker = model.installBlocker {
                Label(blocker, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                if model.isInstallingTweak { ProgressView().controlSize(.small) }
                Button("Cancel") { model.installReview = nil }.keyboardShortcut(.cancelAction)
                Button("Install") { model.confirmInstall() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(review.plan == nil || review.plan?.changesNothing == true || model.isInstallingTweak || model.installBlocker != nil)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    var addableApps: [InstalledApp] {
        var seen = Set(review.bundleIDs)
        return model.apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .filter { !$0.bundleID.isEmpty && seen.insert($0.bundleID).inserted }
    }

    func promptNote(_ plan: TweakInstallPlan) -> String {
        if plan.changesNothing { return "It is already installed like this." }
        if model.env.fixtureMode { return "Fixture mode: files go to \(plan.locations.dylibFileDirectory) and \(plan.locations.manifestsDirectory); the restart is simulated." }
        guard plan.needsPrivilegedStep else { return "No administrator rights needed." }
        return "macOS asks for your password once for the dylib, the config and the restart. Running apps keep their old tweaks until relaunched (Respring…)."
    }
}

/// Uninstall…: lists what will be removed before asking.
struct UninstallTweakSheet: View {
    var model: WorkbenchModel
    var review: TweakUninstallReview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uninstall \(review.manifest.name)?").font(.title2.weight(.semibold))
            Text(review.manifest.id).foregroundStyle(.secondary)
            if let plan = review.plan {
                GroupBox("This removes") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(plan.summary.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.callout, design: .monospaced))
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Its settings (\(TweakPrefsContract.payloadKey(plan.tweakID))) are kept. Apps that loaded it keep it until they quit."
                     + (plan.needsPrivilegedStep && !model.env.fixtureMode ? " macOS asks for your password once." : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Keep the dylib file", isOn: Binding(get: { review.keepFile }, set: { on in
                model.uninstallReview?.keepFile = on
                model.replanUninstall()
            }))
            if let error = review.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
            }
            if let blocker = model.installBlocker {
                Label(blocker, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                if model.isInstallingTweak { ProgressView().controlSize(.small) }
                Button("Cancel") { model.uninstallReview = nil }.keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive) { model.confirmUninstall() }
                    .disabled(review.plan == nil || model.isInstallingTweak || model.installBlocker != nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
