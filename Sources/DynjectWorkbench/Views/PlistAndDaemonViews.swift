import AppKit
import DynjectCore
import SwiftUI

struct PlistView: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button("Open Plist…") { choose() }
                    .accessibilityIdentifier("open-plist")
                if !model.associations.isEmpty {
                    Menu("Associated") {
                        ForEach(model.associations) { a in
                            Button("\(a.plistPath.lastPathComponent)  (\(a.dylibPath.lastPathComponent))") { model.openPlist(a.plistPath) }
                        }
                    }
                    .fixedSize()
                }
                if let doc = model.plistDoc {
                    Text(doc.path).font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Chip(text: doc.format.rawValue, color: doc.format == .binary ? .purple : .blue)
                        .accessibilityIdentifier("plist-format")
                    if !model.workingConfig.dylibPaths.isEmpty {
                        Menu("Associate with Dylib") {
                            ForEach(model.workingConfig.dylibPaths, id: \.self) { d in
                                Button(d.lastPathComponent) { model.associate(plist: doc.path, dylib: d) }
                            }
                        }
                        .fixedSize()
                    }
                }
                Spacer()
                if model.plistDoc != nil {
                    Button("Revert") { model.revertPlist() }.disabled(!model.plistIsDirty)
                    Button("Save") { model.savePlist() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.plistIsDirty || model.plistError != nil || !(model.plistDoc?.canSave ?? false))
                        .accessibilityIdentifier("save-plist")
                }
            }
            .padding(10)

            if let err = model.plistLoadError {
                Label(err, systemImage: "xmark.octagon.fill").foregroundStyle(.red).padding(10)
            }

            if let doc = model.plistDoc {
                CodeTextView(text: $model.plistText, identifier: "plist-editor", isEditable: doc.canSave)
                status(doc)
            } else if model.plistLoadError == nil {
                ContentUnavailableView {
                    Label("No plist open", systemImage: "list.bullet.indent")
                } description: {
                    Text("Open any property list. It is shown as XML. Saving validates the XML, backs up the original, and writes it back in its original format (binary stays binary). Associate files with a dylib from here or from the Dylibs page.")
                } actions: {
                    Button("Open Plist…") { choose() }
                }
            }
        }
        .axContainer("screen-plists")
    }

    func status(_ doc: PlistDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let e = model.plistError {
                Label("Invalid: \(e)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    .accessibilityIdentifier("plist-validation")
            } else {
                Label(model.plistIsDirty ? "Valid XML property list, with unsaved changes." : "Valid. No changes.",
                      systemImage: "checkmark.seal").foregroundStyle(.green)
                    .accessibilityIdentifier("plist-validation")
            }
            if !doc.canSave {
                Label("OpenStep-format plist: shown read-only because Foundation can't write that format back.", systemImage: "lock")
            } else if doc.format == .binary {
                Text("Stored as binary. Saving converts your XML back to binary, and values you didn't touch keep their exact original form (for example sub-second dates).")
            } else {
                Text("Stored as XML. Saving writes your validated text exactly as shown.")
            }
            if !AtomicFile.canWriteDirectly(doc.path) {
                Label("This file is protected. Saving asks for administrator authorization and keeps the file's owner and mode.", systemImage: "lock.shield")
            }
            if let owner = model.runningOwner(ofPlist: doc.path) {
                Label("\(owner.localizedName ?? "Its app") is running and may overwrite this file or ignore your edit. Quit it before saving.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if model.isPreferencesFile(doc.path) {
                Text("macOS caches preferences in cfprefsd. An app may not see a direct file edit until it relaunches, and cfprefsd can overwrite the file from its cache. Quitting the app before saving is the reliable path. A tweak dylib inside the app reads the new value on the app's next launch.")
            }
            if let b = model.lastPlistBackup { Text("Last backup: \(b.path)").textSelection(.enabled) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList, .data]
        panel.allowsOtherFileTypes = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Preferences")
        panel.showsHiddenFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            model.openPlist(url.path)
        }
    }
}

struct DaemonView: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("dynjectd").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Refresh") { model.refreshRuntime() }
                    Button(model.restarter.isLive ? "Restart Dynject…" : "Restart (simulated)") { confirmRestart() }
                        .disabled(model.isWriting || model.hasUnsavedConfig)
                        .help(model.hasUnsavedConfig ? "Save or discard config edits first" : "Stop every dynjectd and start exactly one")
                        .accessibilityIdentifier("restart-daemon")
                }
                if let d = model.daemon { statusBox(d) } else { ProgressView() }
                startsBox
                eventsBox
                if !model.errorLogTail.isEmpty {
                    GroupBox("dynjectd.error.log") {
                        Text(model.errorLogTail).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
        }
        .axContainer("screen-daemon")
    }

    func statusBox(_ d: DaemonStatus) -> some View {
        GroupBox("Status") {
            VStack(alignment: .leading, spacing: 8) {
                if d.processes.isEmpty {
                    Label("No dynjectd process is running. Nothing is being injected.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
                if d.isDuplicated {
                    Label("\(d.processes.count) dynjectd processes are running. Each one intercepts launches independently with the config it started with, so an older one can keep injecting into apps you removed. Restart Dynject to stop all of them and start one.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityIdentifier("duplicate-warning")
                }
                if !d.staleProcesses.isEmpty {
                    Label("PID \(d.staleProcesses.map { String($0.pid) }.joined(separator: ", ")) started before the config was last saved, so it is running an older config.",
                          systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow { Text("PID").bold(); Text("Parent").bold(); Text("Started").bold(); Text("Command").bold() }
                    ForEach(d.processes) { p in
                        GridRow {
                            Text(String(p.pid)).monospacedDigit()
                            Text(String(p.parentPID)).monospacedDigit()
                            Text(p.startedText)
                            Text(p.command).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                }
                .font(.callout)
                Divider()
                if let job = d.job {
                    Text("launchd job \(job.label): \(job.loaded ? (job.state ?? "?") : "not loaded")" + (job.runs.map { ", runs \($0)" } ?? "") + (job.lastExitCode.map { ", last exit \($0)" } ?? ""))
                        .font(.callout)
                    Text("The job runs dynject_loader, which starts a detached dynjectd and exits. That's why launchd reports \"not running\" while dynjectd is up, and why `launchctl kickstart -k` can't stop the old daemon and leaves a duplicate.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let m = d.configModified {
                    Text("Config last written: \(m.formatted(date: .abbreviated, time: .standard))").font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .axContainer("daemon-status")
    }

    var startsBox: some View {
        GroupBox("Daemon starts in the log (newest last)") {
            VStack(alignment: .leading, spacing: 4) {
                let starts = model.log?.starts.suffix(6) ?? []
                if starts.isEmpty { Text("None found.").foregroundStyle(.secondary) }
                ForEach(Array(starts.enumerated()), id: \.offset) { _, s in
                    let alive = s.pid.map { pid in model.daemon?.processes.contains { $0.pid == pid } ?? false } ?? false
                    HStack(alignment: .firstTextBaseline) {
                        Text(s.time).monospacedDigit()
                        Text(s.pid.map { "pid \($0)" } ?? "pid ?")
                        if alive { Chip(text: "running", color: .green) }
                        Text(s.dylibSummaries.map(\.lastPathComponent).joined(separator: "; ")).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Text("The log records times only (no dates). The override counts show which config each daemon loaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    var eventsBox: some View {
        GroupBox("Recent injection decisions (system daemons hidden)") {
            VStack(alignment: .leading, spacing: 2) {
                let events = (model.log?.events ?? []).filter { !$0.outcome.contains("system_daemon") }.suffix(25)
                if events.isEmpty { Text("None.").foregroundStyle(.secondary) }
                ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .firstTextBaseline) {
                        Text(e.time).monospacedDigit().foregroundStyle(.secondary)
                        Text(e.service + (e.executable.map { "(\($0))" } ?? "")).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(e.outcome).foregroundStyle(e.isMatch ? .green : .secondary)
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    func confirmRestart() {
        let alert = NSAlert()
        let n = model.daemon?.processes.count ?? 0
        alert.messageText = model.restarter.isLive ? "Restart Dynject?" : "Simulate a restart?"
        alert.informativeText = """
        With administrator rights this will:
        1. Wait for any running dynject_loader to finish.
        2. Send SIGTERM to every dynjectd (\(n) running now), escalate to SIGKILL after 5 s, and abort if any survive.
        3. Start the launchd job once (kickstart without -k, or bootstrap if it isn't loaded).
        4. Confirm that exactly one dynjectd is running.

        Don't launch apps during the few seconds this takes. Apps already running keep their current dylibs until relaunched.
        """
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.restartDaemon() }
    }
}
