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
            Text(review.package != nil ? review.path : review.source?.manifestPath ?? review.path)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)

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
                InstallCompatibilityBox(model: model, review: review, plan: plan)
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
                    .disabled(review.plan == nil || review.plan?.changesNothing == true || review.plan?.isRefused == true
                              || model.isInstallingTweak || model.installBlocker != nil)
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
            let dependents = model.dependencyChecker.dependents(of: review.manifest.id)
            if !dependents.isEmpty {
                Toggle("Uninstall anyway: \(dependents.map(\.name).joined(separator: ", ")) depend\(dependents.count == 1 ? "s" : "") on it and will stop working",
                       isOn: Binding(get: { review.force }, set: { on in
                           model.uninstallReview?.force = on
                           model.replanUninstall()
                       }))
                    .accessibilityIdentifier("uninstall-force")
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
                Button("Cancel") { model.uninstallReview = nil }.keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive) { model.confirmUninstall() }
                    .disabled(review.plan == nil || model.isInstallingTweak || model.installBlocker != nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// The install sheet's version, macOS and dependency checks, with the explicit checkboxes that override a refusal.
struct InstallCompatibilityBox: View {
    var model: WorkbenchModel
    var review: TweakInstallReview
    var plan: TweakInstallPlan

    var check: TweakInstallCheck { plan.compatibility }
    var all: [TweakInstallRefusal] { check.refusals + check.overridden }

    var body: some View {
        GroupBox("Version and compatibility") {
            VStack(alignment: .leading, spacing: 6) {
                Label(check.change.summary, systemImage: symbol)
                    .foregroundStyle(check.change.isDowngrade ? .orange : .primary)
                    .accessibilityIdentifier("install-version-change")
                if let os = TweakCompatibilityInfo.systemText(plan.manifest) {
                    Text("macOS: \(os). This Mac runs \(SystemVersion.current.description).").font(.callout).foregroundStyle(.secondary)
                }
                let deps = plan.manifest.allDependencies
                if !deps.isEmpty {
                    TweakDependencyList(dependencies: deps,
                                        checker: DependencyChecker(installed: model.tweaks.filter { $0.id != plan.manifest.id },
                                                                   components: model.componentStatus))
                }
                ForEach(check.refusals) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        Label(r.message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        if let fix = r.fix { Text("Fix: \(fix)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if all.contains(where: { $0.kind == .downgrade }) {
                    Toggle("Install the older version (downgrade)", isOn: Binding(get: { review.allowDowngrade }, set: { on in
                        model.installReview?.allowDowngrade = on
                        model.replanInstall()
                    }))
                    .accessibilityIdentifier("install-allow-downgrade")
                }
                if all.contains(where: { $0.kind == .applyCommand }) {
                    Toggle("Allow the package's settings command (it runs as you, outside the apps you pick)",
                           isOn: Binding(get: { review.allowApplyCommand }, set: { on in
                               model.installReview?.allowApplyCommand = on
                               model.replanInstall()
                           }))
                    .accessibilityIdentifier("install-allow-apply-command")
                }
                if all.contains(where: { $0.kind == .signerChange }) {
                    Toggle("Install it although someone else signed it", isOn: Binding(get: { review.allowSignerChange }, set: { on in
                        model.installReview?.allowSignerChange = on
                        model.replanInstall()
                    }))
                    .accessibilityIdentifier("install-allow-signer-change")
                }
                if all.contains(where: { $0.kind == .systemTooOld || $0.kind == .unmetDependency }) {
                    Toggle("Install anyway (\(forceReasons)); it may not load or work", isOn: Binding(get: { review.force }, set: { on in
                        model.installReview?.force = on
                        model.replanInstall()
                    }))
                    .accessibilityIdentifier("install-force")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var symbol: String {
        switch check.change {
        case .fresh: return "plus.circle"
        case .upgrade: return "arrow.up.circle"
        case .downgrade: return "arrow.down.circle.fill"
        case .rebuilt: return "hammer"
        case .same: return "equal.circle"
        case .changed: return "arrow.left.arrow.right.circle"
        }
    }

    var forceReasons: String {
        var parts: [String] = []
        if all.contains(where: { $0.kind == .systemTooOld }) { parts.append("macOS older than it needs") }
        if all.contains(where: { $0.kind == .unmetDependency }) { parts.append("missing dependencies") }
        return parts.joined(separator: ", ")
    }
}

/// `depends` with ✓ (met) or ✗ (and how to fix it).
struct TweakDependencyList: View {
    var dependencies: [TweakDependency]
    var checker: DependencyChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Depends on").font(.caption).foregroundStyle(.secondary)
            ForEach(dependencies, id: \.self) { d in
                let problem = checker.problem(d)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(problem == nil ? "✓" : "✗").foregroundStyle(problem == nil ? .green : .red)
                    Text(d.description + (d.implicit ? " (it declares bridge capabilities)" : ""))
                    if let problem {
                        Text("— \(problem.message). Fix: \(problem.fix)").foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("tweak-depends-\(d.description)")
            }
        }
    }
}

/// The tweak page's version, SDK build, macOS range and dependencies, and what `dw doctor` would say about them.
struct TweakCompatibilityInfo: View {
    var model: WorkbenchModel
    var manifest: TweakManifest

    static func systemText(_ m: TweakManifest) -> String? {
        let parts = [m.minimumSystemVersion.map { "\($0) or later" }, m.testedSystemVersions.map { "tested on \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    var body: some View {
        let build = DylibBuildInfo.read(dylibAt: model.tweakFilePath(manifest.dylib))
        let env = TweakCompatibility.Environment(components: model.componentStatus, dylib: { _ in build })
        // The dependency list shows unmet dependencies itself.
        let issues = TweakCompatibility.issues(for: manifest, installed: model.tweaks, environment: env)
            .filter { $0.kind != .unmetDependency }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                if let v = manifest.version {
                    Text("Version \(v)\(manifest.semanticVersion == nil ? " (not semantic)" : "")")
                }
                if let build {
                    if let sdk = build.sdkVersion {
                        Text("Built with DynjectHook \(sdk)")
                    } else {
                        Text(build.usesDynjectHook ? "Built with DynjectHook before \(WorkbenchInfo.sdkVersion)" : "Not built with DynjectHook")
                    }
                }
                if let os = Self.systemText(manifest) { Text("macOS \(os)") }
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("tweak-compat-\(manifest.id)")
            if !manifest.allDependencies.isEmpty {
                TweakDependencyList(dependencies: manifest.allDependencies, checker: model.dependencyChecker)
            }
            ForEach(issues) { i in
                Label(i.message + (i.fix.map { ". \($0)." } ?? "."),
                      systemImage: i.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(i.severity == .error ? .red : .orange)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Approve All…: the approval lines `dw tweak approve --all` would write, before asking.
struct ApproveTweaksSheet: View {
    var model: WorkbenchModel
    var review: TweakApprovalReview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Approve installed tweak builds?").font(.title2.weight(.semibold))
            Text("Records each installed dylib's SHA-256 as its dylib-sha256 line, so an approval-aware dynjectd can tell "
                 + "when a file is replaced. Approve only builds you made or trust.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let plan = review.plan {
                GroupBox("Tweaks") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(plan.summaryLines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.callout, design: .monospaced))
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(plan.changesNothing ? "Every installed build is already approved."
                     : model.env.fixtureMode ? "Fixture mode: the config is under the isolation root; the restart is simulated."
                     : "macOS asks for your password once for the config and the dynjectd restart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = review.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                if model.isInstallingTweak { ProgressView().controlSize(.small) }
                Button("Cancel") { model.approvalReview = nil }.keyboardShortcut(.cancelAction)
                Button("Approve") { model.confirmApproveAll() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(review.plan?.changesNothing != false || model.isInstallingTweak || model.installBlocker != nil)
                    .accessibilityIdentifier("approve-confirm")
            }
        }
        .padding(20)
        .frame(width: 560)
        .accessibilityIdentifier("approve-sheet")
    }
}
