import AppKit
import DynjectCore
import SwiftUI

/// Safe Mode: the watcher agent, the panic switch, what is disabled where and why, recent tweak-related crashes,
/// and which tweaks honour Safe Mode at all.
///
/// A plain ScrollView + VStack rather than a Form: every row stays in the accessibility tree (the smoke test
/// presses buttons at the bottom of the page).
struct SafeModeView: View {
    var model: WorkbenchModel
    var sm: SafeModeModel { model.safeMode }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let m = sm.message {
                    Label(m.text, systemImage: m.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(m.isError ? .orange : .secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("safemode-message")
                }
                watcherBox
                panicBox
                disabledBox
                crashesBox
                tweaksBox
                shiftFooter
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .axContainer("screen-safemode")
        .task {
            // While the panel is visible: re-read the key and state (cheap) and launchd's view of the agent.
            sm.refresh()
            while !Task.isCancelled {
                sm.refreshAgentStatus()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: Header

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Safe Mode").font(.title2.weight(.semibold))
                Spacer()
                if sm.snapshot.panic {
                    Chip(text: "panic switch on", color: .red, systemImage: "exclamationmark.octagon.fill")
                }
                Chip(text: sm.disabledCount == 0 ? "nothing disabled" : "\(sm.disabledCount) disabled",
                     color: sm.disabledCount == 0 ? .green : .orange)
            }
            Text("When an app crashes with a tweak loaded, the watcher turns that tweak off for that app only: at once if the crash happened inside the tweak, otherwise after \(sm.snapshot.settings.threshold) tweak-loaded crashes within \(Int(sm.snapshot.settings.windowMinutes)) minutes. Tweaks built on DynjectHook honour it the next time the app launches. No administrator rights are needed and the Dynject config is never edited.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if sm.isolated {
                Label("Isolated: the key is \(sm.names.key) in \(sm.keyFile ?? "a fixture file"), state is in \(sm.stateFile), and launchctl is simulated. The real Safe Mode is untouched.",
                      systemImage: "testtube.2")
                    .font(.caption).foregroundStyle(.purple)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("safemode-isolated")
            }
        }
    }

    // MARK: Watcher

    var watcherBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    agentStatusLabel
                    Spacer()
                    let installed = sm.agentStatus?.plistInstalled ?? false
                    Button(installed ? "Reinstall" : "Install Watcher") { sm.installAgent() }
                        .disabled(!sm.dwBinaryAvailable)
                        .help(sm.dwBinaryAvailable ? "Copy dw to \(sm.agent.binaryURL.path) and load \(sm.agent.plistURL.path)"
                                                   : "No dw binary at \(sm.dwBinaryPath)")
                        .accessibilityIdentifier("safemode-agent-install")
                    Button("Uninstall") { sm.uninstallAgent() }
                        .disabled(!installed && !(sm.agentStatus?.loaded ?? false))
                        .accessibilityIdentifier("safemode-agent-uninstall")
                }
                if !sm.dwBinaryAvailable {
                    Label("No dw binary next to Workbench (\(sm.dwBinaryPath)). scripts/build-app.sh bundles it.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Text("A LaunchAgent (\(SafeModeAgent.label)) runs `dw safemode watch` in your login session, with no administrator rights. It reads new reports in \(sm.reportsDirectory).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack(spacing: 16) {
                    Stepper(value: Binding(get: { sm.snapshot.settings.threshold },
                                           set: { v in sm.updateSettings { $0.threshold = v } }), in: 1...20) {
                        Text("Disable after \(sm.snapshot.settings.threshold) crash\(sm.snapshot.settings.threshold == 1 ? "" : "es")")
                    }
                    .accessibilityIdentifier("safemode-threshold")
                    Stepper(value: Binding(get: { Int(sm.snapshot.settings.windowMinutes) },
                                           set: { v in sm.updateSettings { $0.windowMinutes = Double(v) } }), in: 1...240) {
                        Text("within \(Int(sm.snapshot.settings.windowMinutes)) min")
                    }
                    .accessibilityIdentifier("safemode-window")
                    Toggle("Notify me", isOn: Binding(get: { sm.snapshot.settings.notify },
                                                      set: { v in sm.updateSettings { $0.notify = v } }))
                        .accessibilityIdentifier("safemode-notify")
                    Spacer()
                    Button("Check Reports Now") { sm.scanNow() }
                        .help("Run one pass of the watcher over \(sm.reportsDirectory)")
                        .accessibilityIdentifier("safemode-scan")
                }
                .font(.callout)
                Text("A crash inside the tweak always disables it at once. Reports older than \(Int(sm.snapshot.settings.maxReportAgeMinutes)) minutes are listed but never acted on.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Crash watcher")
        }
        .axContainer("safemode-watcher")
    }

    @ViewBuilder var agentStatusLabel: some View {
        if let s = sm.agentStatus {
            let (color, icon): (Color, String) = s.running ? (.green, "circle.fill")
                : s.plistInstalled ? (.orange, "exclamationmark.circle.fill") : (.secondary, "circle")
            HStack(spacing: 6) {
                Label("Watcher " + s.summary, systemImage: icon).foregroundStyle(color)
                if s.plistInstalled && !s.plistMatches {
                    Chip(text: "plist differs from Workbench's", color: .orange)
                }
                if s.plistInstalled && !s.binaryInstalled {
                    Chip(text: "dw binary missing", color: .red)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("safemode-agent-status")
            .accessibilityValue(s.summary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: Panic

    var panicBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Turn off all DynjectHook tweaks everywhere", isOn: Binding(get: { sm.snapshot.panic },
                                                                                set: { sm.setPanic($0) }))
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("safemode-panic")
                Text(verbatim: "Sets \(sm.names.key) \"*\" = [\"*\"]. Apps launched from now on start without their DynjectHook tweaks; running apps keep what they loaded. Per-app entries below are kept.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let ignoring = sm.tweaksIgnoringSafeMode
                if !ignoring.isEmpty {
                    Label("Still loads, because it ignores Safe Mode: " + ignoring.map(\.name).joined(separator: ", ")
                          + ". Turn these off in the config (Apps & Injection).",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let old = sm.tweaksIgnoringPanic
                if !old.isEmpty {
                    Label("Still loads, because it was built with an older DynjectHook that predates the panic switch: "
                          + old.map(\.name).joined(separator: ", ")
                          + ". Their per-app entries below still work. Rebuild them with the current TweakSDK, or turn them off in the config.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("safemode-panic-old-builds")
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Panic switch")
        }
        .axContainer("safemode-panic-box")
    }

    // MARK: Disabled

    var disabledBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if sm.snapshot.disabled.isEmpty {
                    Text("No tweak is disabled in any app.").foregroundStyle(.secondary).padding(.vertical, 4)
                }
                ForEach(Array(sm.snapshot.disabled.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().padding(.vertical, 6) }
                    DisabledRow(model: model, item: item)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("Disabled")
                Spacer()
                Button("Re-enable All…") { confirmClear() }
                    .disabled(sm.snapshot.disabled.isEmpty && !sm.snapshot.panic)
                    .accessibilityIdentifier("safemode-clear")
            }
        }
        .axContainer("safemode-disabled")
    }

    func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Re-enable every tweak in every app?"
        alert.informativeText = "This empties \(sm.names.key) and turns the panic switch off. Crashes before now no longer count. Apps load their tweaks again at their next launch."
        alert.addButton(withTitle: "Re-enable All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { sm.clearAll() }
    }

    // MARK: Crashes

    var crashesBox: some View {
        let crashes = Array(sm.snapshot.recentCrashes.prefix(25))
        return GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if crashes.isEmpty {
                    Text(sm.lastScanAt == nil && !(sm.agentStatus?.running ?? false)
                         ? "No tweak-related crashes recorded. Install the watcher, or use Check Reports Now."
                         : "No tweak-related crashes recorded.")
                        .foregroundStyle(.secondary).padding(.vertical, 4)
                }
                ForEach(Array(crashes.enumerated()), id: \.element.id) { i, crash in
                    if i > 0 { Divider().padding(.vertical, 6) }
                    CrashRow(model: model, crash: crash)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Recent tweak-related crashes")
        }
        .axContainer("safemode-crashes")
    }

    // MARK: Tweaks

    var tweaksBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if sm.catalog.tweaks.isEmpty {
                    Text("No tweaks found (manifests or dylibs in \(sm.dylibDirectory)).").foregroundStyle(.secondary)
                }
                ForEach(sm.catalog.tweaks) { t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.name).fontWeight(.medium)
                            Text(t.hasManifest ? t.tweakID : t.dylibPath)
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        SupportBadge(tweak: t, support: sm.supportLevel(t.tweakID))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("safemode-support-\(t.tweakID)")
                }
                Text("A tweak supports Safe Mode when DynjectHook is compiled in (its dylib contains \"\(SafeModeNames.productionKey)\"); builds of DynjectHook from before the panic switch honour their own entries but not the panic switch. Others keep loading whatever Safe Mode says; only the Dynject config can stop them. Dylibs without a manifest have no tweak ID to disable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Tweaks")
        }
        .axContainer("safemode-tweaks")
    }

    var shiftFooter: some View {
        Label {
            Text("**Hold Shift while you open an app** to start it once without any DynjectHook tweak, whatever the settings here say. Each tweak checks the moment it loads, at the very start of the launch, so press Shift before you click and let go once the app is open. Nothing is recorded: the next normal launch loads the tweaks again. A crash report doesn't show that the tweaks stayed out, so if the app still crashes, the watcher counts that crash toward \"repeated crashes\" for the tweaks it loaded; they aren't the cause, so re-enable any it then turns off. Tweaks that ignore Safe Mode still load, and macOS also skips restoring the app's windows for a Shift launch.")
        } icon: {
            Image(systemName: "shift")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("safemode-shift-footer")
    }
}

struct SupportBadge: View {
    var tweak: SafeModeTweak
    var support: SafeModeSupport?

    var body: some View {
        if !tweak.hasManifest {
            Chip(text: "no manifest: config only", color: .gray, systemImage: "questionmark.circle")
                .help("No manifest names this dylib, so it has no tweak ID for Safe Mode. Disable it in the config.")
        } else if support == .perTweakAndPanic {
            Chip(text: "supports Safe Mode", color: .green, systemImage: "checkmark.shield")
        } else if support == .perTweak {
            Chip(text: "supports Safe Mode, not the panic switch", color: .yellow, systemImage: "checkmark.shield")
                .help("Built with an older DynjectHook: per-app entries stop it, the panic switch doesn't. Rebuild it with the current TweakSDK.")
        } else if support == .unsupported {
            Chip(text: "ignores Safe Mode", color: .orange, systemImage: "exclamationmark.triangle")
                .help("Not built on DynjectHook: it keeps loading until it is disabled in the config.")
        } else {
            Chip(text: "unknown (dylib unreadable)", color: .gray)
        }
    }
}

/// App icon and name for a bundle ID ("*": every app).
struct AppLabel: View {
    var model: WorkbenchModel
    var bundleID: String
    var fallbackName: String?

    var body: some View {
        HStack(spacing: 6) {
            if bundleID == SafeModeNames.all {
                Image(systemName: "square.grid.2x2").frame(width: 18, height: 18)
            } else if let icon = model.appIcon(bundleID: bundleID) {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed").frame(width: 18, height: 18)
            }
            Text(model.appDisplayName(bundleID: bundleID, fallback: fallbackName)).fontWeight(.medium)
            if bundleID != SafeModeNames.all {
                Text(bundleID).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }
}

struct DisabledRow: View {
    var model: WorkbenchModel
    var item: SafeModeDisabledItem
    var sm: SafeModeModel { model.safeMode }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                AppLabel(model: model, bundleID: item.bundleID)
                Image(systemName: "arrow.left").foregroundStyle(.tertiary).font(.caption)
                Text(sm.displayName(item.tweakID))
                reasonChip
                Spacer()
                if let path = item.reportPath {
                    Button("Show Crash Report") { model.openCrashReport(path) }
                        .help(path)
                        .fixedSize()
                        .accessibilityIdentifier("safemode-report-\(item.id)")
                }
                Button("Re-enable") {
                    sm.reenable(item, appName: item.bundleID == SafeModeNames.all ? nil : model.appDisplayName(bundleID: item.bundleID),
                                configInjects: item.tweak.flatMap { model.configInjection(dylib: $0.dylibPath, bundleID: item.bundleID)?.saved })
                }
                    .fixedSize()
                    .accessibilityIdentifier("safemode-reenable-\(item.id)")
            }
            HStack(spacing: 6) {
                Text(item.since.map { "Since \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Added outside Workbench")
                if let f = item.frameSummary { Text("· \(f)").lineLimit(2).textSelection(.enabled) }
            }
            .font(.caption).foregroundStyle(.secondary)
            let alsoOff = item.alsoOffBecause.filter { $0 != .panic }
            if !alsoOff.isEmpty {
                Text("Also off here because \(SafeModeStillOff.describe(alsoOff)): re-enabling this row alone won't bring it back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if item.supportsSafeMode == false, let t = item.tweak {
                let app = model.appDisplayName(bundleID: item.bundleID)
                let config = model.configInjection(dylib: t.dylibPath, bundleID: item.bundleID)
                if config?.saved == false {
                    // The config already keeps it out; the key entry never had any effect on it.
                    Label("\(t.name) ignores Safe Mode, but the Dynject config already keeps it out of \(app).",
                          systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("safemode-configoff-\(item.id)")
                } else {
                    let staged = config?.working == false
                    HStack(alignment: .firstTextBaseline) {
                        Label(staged ? "\(t.name) ignores Safe Mode. Turning it off for \(app) is staged in the config; review and save to apply."
                                     : "\(t.name) isn't built on DynjectHook and ignores Safe Mode: it still loads in \(app). Disable it in the Dynject config to stop it.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(staged ? "Review & Save…" : "Disable in Config…") {
                            model.disableInConfig(dylib: t.dylibPath, bundleID: item.bundleID, tweakName: t.name)
                        }
                        .help("Stop injecting \(t.fileName) into this app: review, save and restart Dynject (administrator rights)")
                        .fixedSize()
                        .accessibilityIdentifier("safemode-config-\(item.id)")
                    }
                    .font(.caption)
                }
            } else if item.tweak == nil && item.tweakID != SafeModeNames.all {
                Text("No installed tweak has this ID.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("safemode-row-\(item.id)")
    }

    @ViewBuilder var reasonChip: some View {
        switch item.reason {
        case .crashInTweak?: Chip(text: "crash in tweak", color: .red)
        case .repeatedCrashes?: Chip(text: "repeated crashes", color: .orange)
        case .manual?: Chip(text: "manual", color: .blue)
        case .panic?: Chip(text: "panic", color: .red)
        case nil: Chip(text: "set outside Workbench", color: .gray)
        }
    }
}

struct CrashRow: View {
    var model: WorkbenchModel
    var crash: SafeModeCrash
    var sm: SafeModeModel { model.safeMode }

    var body: some View {
        let tweak = sm.tweak(crash.tweakID)
        let supports = sm.supportsSafeMode(crash.tweakID)
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let b = crash.bundleID {
                        AppLabel(model: model, bundleID: b, fallbackName: crash.appName)
                    } else {
                        Text(crash.appName ?? "Unknown app").fontWeight(.medium)
                    }
                    Text("with \(tweak?.name ?? crash.tweakID)").lineLimit(1)
                    if crash.inTweak { Chip(text: "in the tweak", color: .red) }
                }
                Text(crash.date.formatted(date: .abbreviated, time: .shortened) + " · " + crash.frameSummary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("Show Report") { model.openCrashReport(crash.reportPath) }
                .help(crash.reportPath)
                .fixedSize()
                .accessibilityIdentifier("safemode-crash-report-\(crash.id)")
            if supports == false, let t = tweak, let b = crash.bundleID,
               model.configInjection(dylib: t.dylibPath, bundleID: b)?.saved != false {
                Button("Disable in Config…") { model.disableInConfig(dylib: t.dylibPath, bundleID: b, tweakName: t.name) }
                    .help("\(t.name) ignores Safe Mode: stop injecting it into this app in the Dynject config")
                    .fixedSize()
                    .accessibilityIdentifier("safemode-crash-config-\(crash.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("safemode-crash-\(crash.id)")
    }
}
