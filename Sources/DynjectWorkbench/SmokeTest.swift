import AppKit
import ApplicationServices
import DynjectCore
import SwiftUI

/// UI smoke test, started with `-DWSmokeTest <report-dir>` (fixture mode only).
///
/// It acts as an accessibility client of its own process (AXUIElement, like XCUITest), so it needs no
/// Accessibility permission: it finds controls by identifier, reads their values, presses them, then
/// checks the results on disk. It saves screenshots, writes report.json, and exits 0 on success.
@MainActor
struct SmokeTest {
    let model: WorkbenchModel
    let reportDirectory: String

    struct Step: Codable { var name: String; var ok: Bool; var detail: String }
    final class Log { var steps: [Step] = [] }
    let log = Log()

    let brutalium = "/opt/dynject/lib/tweaks/libBrutalium.dylib"
    var toggleID: String { "inject-toggle-\(brutalium.lastPathComponent)" }

    func run() async {
        try? FileManager.default.createDirectory(atPath: reportDirectory, withIntermediateDirectories: true)
        guard model.env.fixtureMode, model.env.configPath != AppEnvironment.liveConfigPath else {
            record("fixture mode", false, "Refusing to run: the smoke test only works against a fixture config.")
            finish()
            return
        }
        await scenario()
        finish()
    }

    // MARK: Scenario

    func scenario() async {
        let originalText = model.diskText
        guard check("window", await wait { mainWindow != nil }, "main window visible") else { return }
        guard check("apps scanned", await wait(20) { !model.isScanning && model.apps.contains { $0.bundleID == "com.apple.TextEdit" } },
                    "\(model.apps.count) apps, TextEdit present") else { return }
        _ = check("runtime refreshed", await wait(20) { model.daemon != nil && !model.isRefreshingRuntime },
                  "ps/pgrep/launchctl/lsof read-only checks done")
        _ = check("config parsed", model.workingConfig.dylibPaths == [brutalium] && !model.workingConfig.uiApps,
                  "dylibs=\(model.workingConfig.dylibPaths)")
        let primed = await AXSelf.prime()
        record("accessibility client", true, primed)

        // Every section renders and is reachable through accessibility.
        for s in SidebarSection.allCases {
            model.section = s
            // Containers such as HSplitView don't keep identifiers, so probe a control on each screen.
            let probe = ["injection": "apps-table"][s.rawValue] ?? "screen-\(s.rawValue)"
            let ok = await wait { await AXSelf.exists(probe) }
            _ = check("section \(s.rawValue)", ok, ok ? "found \(probe)" : "\(probe) missing")
            await settle()
            snapshot("section-\(s.rawValue)")
        }

        // Finder: configured in the fixture.
        model.section = .injection
        let finder = model.apps.first { $0.bundleID == "com.apple.finder" }!
        model.selectedAppID = finder.id
        let finderOK = await wait { await AXSelf.value(toggleID) == "1" }
        if !finderOK { await AXSelf.dump(to: path("ax-finder.txt")) }
        _ = check("finder toggle on", finderOK, "value=\(await AXSelf.value(toggleID) ?? "nil")")

        // TextEdit: enable through the switch.
        let textEdit = model.apps.first { $0.bundleID == "com.apple.TextEdit" }!
        model.searchText = "TextEdit"
        model.selectedAppID = textEdit.id
        guard check("textedit toggle off", await wait { await AXSelf.value(toggleID) == "0" },
                    "value=\(await AXSelf.value(toggleID) ?? "nil")") else { return }
        _ = check("textedit gate explained", await AXSelf.exists("gates") && model.workingEvals[textEdit.id]?.processGate.passed == false,
                  model.workingEvals[textEdit.id]?.processGate.reason ?? "")
        guard check("press toggle", await pressWhenReady(toggleID), "AXPress on \(toggleID)") else { return }
        let added = await wait { model.hasUnsavedConfig }
        _ = check("edit applied", added
                  && model.workingText.contains("dylib-override:\(brutalium):allow:com.apple.TextEdit\n")
                  && model.workingText.contains("allow:TextEdit\n")
                  && changed(originalText, model.workingText).removed.isEmpty,
                  "only lines added: \(changed(originalText, model.workingText).added)")
        _ = check("pending bar + guidance", await wait { await AXSelf.exists("review-save") && model.guidance(for: textEdit).count >= 2 },
                  model.guidance(for: textEdit).joined(separator: " | "))
        await settle()
        snapshot("injection-textedit-pending")

        // Review & save through the sheet.
        _ = check("press review", await pressWhenReady("review-save"), "")
        guard check("apply sheet", await wait { await AXSelf.exists("save-restart") }, "sheet shown") else { return }
        await settle()
        snapshot("apply-sheet", window: NSApp.windows.first { $0.isSheet && $0.isVisible })
        let expected = model.workingText
        _ = check("press save & restart", await pressWhenReady("save-restart"), "")
        _ = check("saved", await wait { !model.hasUnsavedConfig && model.lastOutcome != nil }, model.banner?.detail ?? "")
        let onDisk = (try? String(contentsOfFile: model.env.configPath, encoding: .utf8)) ?? ""
        _ = check("disk matches", onDisk == expected, "config on disk equals reviewed text")
        let backup = model.lastOutcome?.backup.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        _ = check("backup", backup == originalText, model.lastOutcome?.backup?.path ?? "none")
        _ = check("no admin rights", model.lastOutcome?.usedAdministratorRights == false, "fixture file is writable")
        _ = check("restart simulated", model.lastOutcome?.restart?.simulated == true
                  && (model.restarter as? SimulatedRestarter)?.count == 1, model.lastOutcome?.restart?.transcript ?? "")
        _ = check("toggle shows saved", await wait { await AXSelf.value(toggleID) == "1" }, "")
        await settle()
        snapshot("injection-textedit-saved")

        // Toggling back restores the exact original bytes.
        _ = await pressWhenReady(toggleID)
        _ = check("disable restores original", await wait { model.workingText == originalText }, "byte-identical")
        model.discardConfigChanges()

        // Raw editor diagnostics.
        model.section = .config
        model.workingText += "this line has no colon\n"
        _ = check("diagnostics", await wait {
                      let editor = await AXSelf.exists("config-editor")
                      return editor && model.diagnostics.contains { $0.message.contains("No ':'") }
                  },
                  model.diagnostics.map(\.message).joined(separator: " | "))
        await settle()
        snapshot("config-diagnostics")
        model.workingText = model.workingText.replacingOccurrences(of: "dylib:", with: "#dylib:")
        _ = check("no-dylib error blocks save", model.blockingErrors.contains { $0.message.contains("refuses to start") }, "")
        model.discardConfigChanges()

        // Plist editor: binary stays binary, untouched date keeps sub-second precision.
        let plistPath = (model.env.supportDirectory.path as NSString).appendingPathComponent("smoke/com.example.tweak.plist")
        let stamp = Date(timeIntervalSinceReferenceDate: 760_000_000.375)
        let original: [String: Any] = ["Theme": "dark", "Opacity": 0.8, "Stamp": stamp]
        try? FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let originalData = try! PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
        try! originalData.write(to: URL(fileURLWithPath: plistPath))
        model.associate(plist: plistPath, dylib: brutalium)
        model.openPlist(plistPath)
        model.section = .plists
        _ = check("plist opened", await wait { await AXSelf.exists("plist-editor") && model.plistDoc?.format == .binary }, "binary shown as XML")
        model.plistText = model.plistText.replacingOccurrences(of: "<string>dark</string>", with: "<string>light</string>")
        _ = check("plist dirty+valid", await wait { model.plistIsDirty && model.plistError == nil }, "")
        await settle()
        snapshot("plist-edited")
        _ = check("press save plist", await pressWhenReady("save-plist"), "")
        _ = check("plist saved", await wait { !model.plistIsDirty && model.lastPlistBackup != nil }, model.banner?.title ?? "")
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        let saved = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: plistPath)), options: [], format: &fmt)) as? [String: Any]
        _ = check("plist format preserved", fmt == .binary && saved?["Theme"] as? String == "light"
                  && (saved?["Stamp"] as? Date) == stamp && saved?["Opacity"] as? Double == 0.8,
                  "format=\(fmt == .binary ? "binary" : "other"), sub-second date intact")
        let backupData = model.lastPlistBackup.flatMap { try? Data(contentsOf: $0) }
        _ = check("plist backup", backupData == originalData, model.lastPlistBackup?.path ?? "")
        model.plistText = "<?xml version=\"1.0\"?><plist><dict><key>x</key></plist>"
        _ = check("plist validation error", await wait { model.plistError != nil }, model.plistError ?? "")
        await settle()
        snapshot("plist-invalid")
        model.revertPlist()

        await tweakScenario(finder: finder)
        await safeModeScenario(finder: finder)
        await respringScenario()

        model.section = .dylibs
        _ = check("association shown", await wait { await AXSelf.exists("screen-dylibs") }
                  && model.associations.contains { $0.plistPath == plistPath }
                  && FileManager.default.fileExists(atPath: model.associationStore.url.path), "")
        await settle()
        snapshot("dylibs-associated")
        model.section = .daemon
        _ = await wait { await AXSelf.exists("screen-daemon") }
        await settle()
        snapshot("daemon")
    }

    /// PreferenceLoader-style settings: global switch, per-app override, apply command, revert.
    func tweakScenario(finder: InstalledApp) async {
        let id = "com.example.windowtweak"
        let marker = (model.env.supportDirectory.deletingLastPathComponent().path as NSString).appendingPathComponent("applied")
        let file = FileTweakBackend(path: model.env.tweakPrefsFile)
        func payload() -> [String: Any]? { file.payload(for: id) }
        func global(_ k: String) -> Any? { (payload()?["values"] as? [String: Any])?[k] }
        func perApp(_ b: String, _ k: String) -> Any? { ((payload()?["perApp"] as? [String: Any])?[b] as? [String: Any])?[k] }

        guard check("tweak manifest loaded", Set(model.tweaks.map(\.id)) == [id, safeTweakID] && !model.tweakIssues.contains { $0.severity == .error },
                    model.tweakIssues.map(\.message).joined(separator: " | ")) else { return }
        model.section = .tweaks
        model.selectedTweakID = id
        _ = check("tweak form", await wait { await AXSelf.exists("tweak-form-\(id)") }, "")
        await settle()
        snapshot("tweaks")
        _ = check("press tweak switch", await pressWhenReady("tweak-item-enabled"), "AXPress on the Enabled switch")
        _ = check("tweak value saved", await wait { global("enabled") as? Bool == false }, "values.enabled = false")
        _ = check("apply command ran", await wait { FileManager.default.fileExists(atPath: marker) }, marker)
        _ = check("change notification", (model.tweakBackend as? FileTweakBackend)?.posted.contains("dynject.tweak.\(id).changed") == true, "")
        _ = check("defaults published", (payload()?["defaults"] as? [String: Any])?["radius"] as? Int == 8, "")

        // MenuLoader: the example's Apple-menu items go to the fixture file under the test key, never the real one.
        let menuKey = model.menuPublisher.names.key
        /// Published item IDs of one contributor (the example tweak unless given).
        func menuItems(_ tweakID: String? = nil) -> [String] {
            ((file.dictionary(forKey: menuKey)?["items"] as? [[String: Any]]) ?? [])
                .filter { $0["tweakID"] as? String == tweakID ?? id }.compactMap { $0["id"] as? String }
        }
        func menuPosts() -> Int {
            (model.tweakBackend as? FileTweakBackend)?.posted.filter { $0 == model.menuPublisher.names.notification }.count ?? 0
        }
        _ = check("apple menu isolated", model.menuPublisher.names == .test && model.menuPublisher.store is FileTweakBackend,
                  "\(menuKey) in \(model.env.tweakPrefsFile)")
        _ = check("apple menu published", menuItems() == ["toggle", "help"] && menuPosts() == 1
                  && menuItems(MenuLoaderContributor.dynjectID) == ["respring", "safemode", "open"],
                  "items=\(menuItems()), Dynject group=\(menuItems(MenuLoaderContributor.dynjectID))")
        _ = check("apple menu section", await wait { await AXSelf.exists("applemenu-include-\(id)") }, "")
        _ = check("press apple menu switch", await pressWhenReady("applemenu-include-\(id)"), "AXPress on Show in Apple menu")
        _ = check("apple menu removed", await wait { menuItems().isEmpty && menuPosts() == 2 && !model.isInAppleMenu(id) }
                  && FileManager.default.fileExists(atPath: model.env.menuLoaderSettingsFile.path),
                  "its items removed (the Dynject group stays), notification recorded, flag saved")
        scrollFormsToBottom()
        await settle()
        snapshot("tweak-apple-menu-off")
        _ = await pressWhenReady("applemenu-include-\(id)")
        _ = check("apple menu restored", await wait { menuItems() == ["toggle", "help"] && menuPosts() == 3 }, "")

        model.section = .injection
        model.searchText = ""
        model.selectedAppID = finder.id
        _ = check("per-app panel", await wait { await AXSelf.exists("tweak-perapp-\(id)") }, "shown in Finder's detail pane")
        _ = check("press override", await pressWhenReady("tweak-override-\(id)-radius"), "")
        _ = check("override saved", await wait { perApp("com.apple.finder", "radius") as? Int == 8 }, "perApp[com.apple.finder].radius = 8")
        await settle()
        snapshot("tweak-perapp-finder")

        model.section = .tweaks
        _ = check("press revert", await pressWhenReady("tweak-revert"), "")
        _ = check("session reverted", await wait { payload() == nil }, "no payload existed before this session")
    }

    // MARK: Safe Mode

    /// The second fixture manifest (scripts/ui-smoke-test.sh): its dylib contains DynjectHook's key string.
    var safeTweakID: String { "com.example.safetweak" }

    /// Agent install (simulated launchctl), crash attribution from synthetic reports, Re-enable, panic switch,
    /// refresh on state.json changes and on the Darwin notification, "Disable in Config…" through the review
    /// sheet, uninstall. Everything stays in the fixture file, the support folder and the test names.
    func safeModeScenario(finder: InstalledApp) async {
        let sm = model.safeMode
        let support = model.env.supportDirectory.path
        let brutalID = "com.example.windowtweak"
        let host = "local.dynject.safemode.smokehost"
        let safeRow = "\(safeTweakID)|\(host)", brutalRow = "\(brutalID)|com.apple.finder"
        let keys = sm.safeMode.keys
        let runner = sm.agent.runner as? SimulatedLaunchctlRunner

        guard check("safemode isolated", sm.isolated && sm.names == .forDomain(SafeModeNames.testDomain)
                    && sm.keyFile == model.env.tweakPrefsFile && sm.stateFile.hasPrefix(support)
                    && sm.agent.plistURL.path.hasPrefix(support) && sm.agent.binaryURL.path.hasPrefix(support)
                    && runner != nil && sm.reportsDirectory == model.env.reportsDirectoryOverride && sm.notifier is RecordingNotifier,
                    "key \(sm.names.key) in \(sm.keyFile ?? "?"), notification \(sm.names.notification), state \(sm.stateFile), agent \(sm.agent.plistURL.path)")
        else { return }
        let loose = SafeModeTweak.unmanifestedID(fileName: "libLoose.dylib")
        _ = check("safemode support check", sm.supportLevel(safeTweakID) == .perTweakAndPanic && sm.supportsSafeMode(brutalID) == false
                  && sm.supportsSafeMode(loose) == false && sm.tweaksIgnoringSafeMode.map(\.tweakID).contains(brutalID),
                  sm.catalog.tweaks.map { "\($0.tweakID)=\(String(describing: sm.supportsSafeMode($0.tweakID)))" }.joined(separator: ", "))

        model.section = .safemode
        _ = check("safemode panel", await wait {
                      for id in ["safemode-support-\(safeTweakID)", "safemode-support-\(loose)", "safemode-shift-footer", "safemode-panic"] {
                          if !(await AXSelf.exists(id)) { return false }
                      }
                      return true
                  }, "support badges, panic switch, Shift footer")
        _ = check("agent not installed", await wait { sm.agentStatus?.plistInstalled == false && sm.agentStatus?.loaded == false },
                  sm.agentStatus?.summary ?? "nil")
        await settle()
        snapshot("safemode-empty")

        // Watcher agent: real files in the support folder, simulated launchctl.
        _ = check("press install watcher", await pressWhenReady("safemode-agent-install"), sm.dwBinaryPath)
        _ = check("agent running (simulated)", await wait { sm.agentStatus?.running == true && sm.agentStatus?.plistMatches == true },
                  sm.agentStatus?.summary ?? "nil")
        let plist = (try? Data(contentsOf: sm.agent.plistURL))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
        let args = plist?["ProgramArguments"] as? [String] ?? []
        _ = check("agent plist", plist?["Label"] as? String == SafeModeAgent.label && plist?["RunAtLoad"] as? Bool == true
                  && plist?["KeepAlive"] as? Bool == true && Array(args.prefix(3)) == [sm.agent.binaryURL.path, "safemode", "watch"]
                  && args.contains(SafeModeNames.testDomain) && args.contains(sm.reportsDirectory),
                  args.joined(separator: " "))
        _ = check("agent binary copied", FileManager.default.isExecutableFile(atPath: sm.agent.binaryURL.path)
                  && FileManager.default.contentsEqual(atPath: sm.agent.binaryURL.path, andPath: sm.dwBinaryPath), sm.agent.binaryURL.path)
        _ = check("launchctl simulated", runner?.calls.contains { $0.first == "bootstrap" && $0.last == sm.agent.plistURL.path } == true,
                  runner?.calls.map { $0.joined(separator: " ") }.joined(separator: " | ") ?? "")

        // Two synthetic crashes: one inside the DynjectHook tweak, one inside the tweak that ignores Safe Mode.
        let dylibDir = model.env.tweakDylibDirectory
        let reportA = writeCrashReport("SmokeHost", bundleID: host, procPath: "/Applications/SmokeHost.app/Contents/MacOS/SmokeHost",
                                       tweakPath: (dylibDir as NSString).appendingPathComponent("libSafeTweak.dylib"))
        let reportB = writeCrashReport("Finder", bundleID: "com.apple.finder", procPath: finder.executablePath, tweakPath: brutalium)
        _ = check("press check reports", await pressWhenReady("safemode-scan"), sm.reportsDirectory)
        _ = check("crashes attributed", await wait {
                      let ids = Set(sm.snapshot.disabled.map(\.id))
                      return ids.contains(safeRow) && ids.contains(brutalRow)
                  }, sm.message?.text ?? "")
        let entries = keys.entries()
        let a = sm.snapshot.disabled.first { $0.id == safeRow }, b = sm.snapshot.disabled.first { $0.id == brutalRow }
        _ = check("key written", entries[safeTweakID] == [host] && entries[brutalID] == ["com.apple.finder"],
                  "\(keys.names.key) = \(entries)")
        _ = check("reasons recorded", a?.reason == .crashInTweak && a?.reportPath == reportA && a?.supportsSafeMode == true
                  && b?.reason == .crashInTweak && b?.reportPath == reportB && b?.supportsSafeMode == false,
                  "\(a?.frameSummary ?? "") / \(b?.frameSummary ?? "")")
        _ = check("recent crashes", sm.snapshot.recentCrashes.filter(\.inTweak).count >= 2, "\(sm.snapshot.recentCrashes.count) records")
        _ = check("user notified (recorded)", (sm.notifier as? RecordingNotifier)?.posted.count == 2,
                  (sm.notifier as? RecordingNotifier)?.posted.map(\.title).joined(separator: " | ") ?? "")
        _ = check("test notification only", (keys.store as? FileTweakBackend)?.posted.contains(sm.names.notification) == true
                  && (keys.store as? FileTweakBackend)?.posted.contains(SafeModeNames.production.notification) == false, sm.names.notification)
        let rowsShown = await wait {
            let row = await AXSelf.exists("safemode-row-\(safeRow)")
            let config = await AXSelf.exists("safemode-config-\(brutalRow)")
            return row && config
        }
        let safeHasConfig = await AXSelf.exists("safemode-config-\(safeRow)")
        _ = check("rows shown", rowsShown && !safeHasConfig, "only the tweak that ignores Safe Mode offers Disable in Config")
        await settle()
        snapshot("safemode-disabled")
        model.banner = nil
        scrollFormsToBottom()
        await settle()
        snapshot("safemode-disabled-rows")

        _ = check("press show crash report", await pressWhenReady("safemode-report-\(safeRow)"), "")
        _ = check("crash report opened (recorded)", await wait { model.openedReports.last == reportA }, model.openedReports.last ?? "nil")

        // Re-enable through the row button.
        _ = check("press re-enable", await pressWhenReady("safemode-reenable-\(safeRow)"), "")
        _ = check("re-enabled", await wait {
                      keys.entries()[safeTweakID] == nil && !sm.snapshot.disabled.contains { $0.id == safeRow }
                  } && sm.safeMode.stateStore.load().reenabledAt(tweakID: safeTweakID, bundleID: host) != nil,
                  "key entry removed, re-enable time recorded")

        // Panic switch.
        _ = check("press panic", await pressWhenReady("safemode-panic"), "")
        _ = check("panic on", await wait {
                      let v = await AXSelf.value("safemode-panic")
                      return keys.isPanicOn && sm.snapshot.panic && v == "1"
                  },
                  "\(keys.names.key)[\"*\"] = \(keys.entries()["*"] ?? [])")
        await settle()
        snapshot("safemode-panic")
        _ = await pressWhenReady("safemode-panic")
        _ = check("panic off", await wait { !keys.isPanicOn && keys.entries()["*"] == nil && !sm.snapshot.panic },
                  "brutalium entry kept: \(keys.entries()[brutalID] ?? [])")

        // Changes made by someone else (the watcher, dw): state.json → directory watch; key → Darwin notification.
        let other = SafeModeStateStore(directory: sm.safeMode.stateStore.directory)
        _ = try? other.update { $0.settings.threshold = 3 }
        _ = check("refresh on state.json change", await wait { sm.snapshot.settings.threshold == 3 }, "threshold 3 written outside the panel")
        let elsewhere = "local.dynject.safemode.other"
        let outside = SafeModeKeyStore(store: FileTweakBackend(path: sm.keyFile ?? ""), names: sm.names)
        _ = try? outside.add(tweakID: safeTweakID, bundleID: elsewhere)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(sm.names.notification as CFString), nil, nil, true)
        let outsideRow = "\(safeTweakID)|\(elsewhere)"
        _ = check("refresh on Darwin notification", await wait {
                      sm.snapshot.disabled.first { $0.id == outsideRow }.map { $0.reason == nil } ?? false
                  }, "\(sm.names.notification) posted")
        _ = await pressWhenReady("safemode-reenable-\(outsideRow)")
        _ = check("outside entry re-enabled", await wait { keys.entries()[safeTweakID] == nil }, "")

        // A tweak that ignores Safe Mode: stop it through the config, with the usual review sheet.
        let restarts = (model.restarter as? SimulatedRestarter)?.count ?? -1
        _ = check("finder injected before", model.diskEvals[finder.id]?.isInjected(brutalium) == true, "")
        _ = check("press disable in config", await pressWhenReady("safemode-config-\(brutalRow)"), "")
        _ = check("config edit staged", await wait {
                      let sheet = await AXSelf.exists("save-restart")
                      return sheet && model.workingEvals[finder.id]?.isInjected(brutalium) == false
                  }, model.lastEdit.map { $0.changes.map(\.description).joined(separator: " | ") } ?? "no edit")
        await settle()
        snapshot("safemode-config-sheet", window: NSApp.windows.first { $0.isSheet && $0.isVisible })
        _ = check("press save & restart (safe mode)", await pressWhenReady("save-restart"), "")
        _ = check("config saved without Finder", await wait {
                      !model.hasUnsavedConfig && model.diskEvals[finder.id]?.isInjected(brutalium) == false
                  } && (model.restarter as? SimulatedRestarter)?.count == restarts + 1
                    && model.lastOutcome?.usedAdministratorRights == false,
                  model.banner?.title ?? "")
        // The row now reflects the config: no warning or Disable in Config, and Re-enable says the config keeps it out.
        _ = check("row reflects the config", await wait {
                      let off = await AXSelf.exists("safemode-configoff-\(brutalRow)")
                      let button = await AXSelf.exists("safemode-config-\(brutalRow)")
                      return off && !button
                  }, "safemode-configoff-\(brutalRow)")
        _ = check("press re-enable (config-only tweak)", await pressWhenReady("safemode-reenable-\(brutalRow)"), "")
        _ = check("re-enable explains the config", await wait {
                      keys.entries()[brutalID] == nil && (sm.message?.text.contains("config still keeps it out") ?? false)
                  }, sm.message?.text ?? "")

        _ = check("press uninstall watcher", await pressWhenReady("safemode-agent-uninstall"), "")
        _ = check("agent removed", await wait { sm.agentStatus?.plistInstalled == false && sm.agentStatus?.loaded == false }
                  && !FileManager.default.fileExists(atPath: sm.agent.plistURL.path)
                  && !FileManager.default.fileExists(atPath: sm.agent.binaryURL.path),
                  sm.agentStatus?.summary ?? "nil")
        await settle()
        snapshot("safemode-final")
    }

    // MARK: Respring

    /// The Respring sheet over the made-up running apps of scripts/ui-smoke-test.sh (`-DWRespringFixture`), opened
    /// through a dynject-workbench://respring Apple Event sent to this process. Relaunches go to
    /// SimulatedAppController only. By now the fixture config injects Brutalium into TextEdit and not into Finder.
    func respringScenario() async {
        let r = model.respring
        guard check("respring isolated", r.simulated && model.env.respringFixturePath != nil,
                    "fixture \(model.env.respringFixturePath ?? "none")") else { return }
        let before = r.planCount
        r.refresh()
        let planned = await wait(10) { r.planCount > before && !r.isPlanning }
        let plan = r.plan
        func cand(_ id: String) -> RespringCandidate? { plan?.candidate(bundleID: id) }
        let pendingIDs = Set(plan?.pending.map(\.app.bundleID) ?? [])
        _ = check("respring plan", planned && pendingIDs == ["com.apple.TextEdit", "com.apple.finder", "com.apple.Terminal",
                                                             "com.example.stubborn", "local.dynject.workbench"]
                  && cand("com.apple.TextEdit")?.reasons.map(\.kind) == [.missing]
                  && cand("com.apple.finder")?.reasons.map(\.kind) == [.unwanted]
                  && cand("com.apple.calculator")?.isPending == false,
                  plan?.pending.map { "\($0.app.bundleID): \($0.reasonSummary)" }.joined(separator: " | ") ?? "no plan")
        model.section = .injection
        _ = check("respring footer", await wait { await AXSelf.exists("respring-footer") } && r.pendingCount == 5,
                  "\(r.pendingCount) pending")

        // The link only opens the sheet.
        let sent = sendLinkToSelf("dynject-workbench://respring")
        _ = check("respring link opens sheet", await wait {
                      let sheet = await AXSelf.exists("respring-run")
                      return sent && sheet && r.showSheet
                  } && r.linkRequests == 1 && !r.isRunning && r.runList.isEmpty,
                  "Apple Event sent: \(sent), link requests \(r.linkRequests)")
        var values: [String: String] = [:]
        for id in ["com.apple.TextEdit", "com.example.stubborn", "com.apple.finder", "com.apple.Terminal", "local.dynject.workbench"] {
            values[id] = await AXSelf.value("respring-check-\(id)") ?? "nil"
        }
        _ = check("respring default checks", values == ["com.apple.TextEdit": "1", "com.example.stubborn": "1", "com.apple.finder": "0",
                                                        "com.apple.Terminal": "0", "local.dynject.workbench": "0"],
                  values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        var notes = true
        for id in ["com.apple.finder", "com.apple.Terminal", "local.dynject.workbench"] where !(await AXSelf.exists("respring-note-\(id)")) {
            notes = false
        }
        _ = check("respring exclusion notes", notes, r.visibleCandidates.compactMap { r.note(for: $0) }.joined(separator: " | "))
        await settle()
        snapshot("respring-sheet", window: NSApp.windows.first { $0.isSheet && $0.isVisible })

        // Check Finder too, then run.
        _ = check("press respring finder", await pressWhenReady("respring-check-com.apple.finder"), "")
        _ = check("finder checked", await wait { await AXSelf.value("respring-check-com.apple.finder") == "1" }
                  && r.selectedCandidates.count == 3, "\(r.selectedCandidates.map(\.app.name))")
        _ = check("press respring selected", await pressWhenReady("respring-run"), "")
        let finished = await wait(30) { !r.isRunning && r.results.count == 3 }
        func result(_ id: String) -> RespringResult? { cand(id).flatMap { r.results[$0.id] } }
        _ = check("respring results", finished
                  && result("com.apple.TextEdit")?.succeeded == true && result("com.apple.finder")?.succeeded == true
                  && result("com.example.stubborn")?.outcome == .didNotQuit(timeout: 15)
                  && r.runList.map(\.app.bundleID) == ["com.apple.finder", "com.example.stubborn", "com.apple.TextEdit"],
                  r.runList.map { "\($0.app.name): \(r.result(for: $0).map(r.summary) ?? "-")" }.joined(separator: " | "))
        let calls = r.simulatedCalls
        let untouched = ["com.apple.Terminal", "local.dynject.workbench", "com.apple.calculator"].compactMap { cand($0)?.app.pid }
        let touchedExcluded = calls.contains { call in
            switch call {
            case let .terminate(pid, _), let .scheduleReopen(_, pid): return untouched.contains(pid)
            case .open: return false
            }
        }
        _ = check("respring simulated calls", !touchedExcluded
                  && calls.contains(.terminate(cand("com.apple.finder")?.app.pid ?? -1, .appleEventQuit))
                  && calls.filter { if case .open = $0 { return true } else { return false } }.count == 2,
                  calls.map { "\($0)" }.joined(separator: " | "))
        _ = check("respring result rows", await wait {
                      let ok = await AXSelf.exists("respring-result-com.apple.TextEdit")
                      let skip = await AXSelf.exists("respring-result-com.example.stubborn")
                      let summary = await AXSelf.exists("respring-summary")
                      return ok && skip && summary
                  }, r.runSummary ?? "")
        await settle()
        snapshot("respring-results", window: NSApp.windows.first { $0.isSheet && $0.isVisible })

        let after = r.planCount
        _ = check("press respring done", await pressWhenReady("respring-done"), "")
        _ = check("respring replanned", await wait(10) { !r.showSheet && r.planCount > after && !r.isPlanning }
                  && Set(r.plan?.pending.map(\.app.bundleID) ?? []) == ["com.apple.Terminal", "com.example.stubborn", "local.dynject.workbench"],
                  "pending now: \(r.plan?.pending.map(\.app.name) ?? [])")
        await settle()
        snapshot("respring-footer")
    }

    /// Delivers a GetURL Apple Event to this process, as `open dynject-workbench://…` would (sent to the current
    /// process, so it never leaves it).
    func sendLinkToSelf(_ link: String) -> Bool {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                                           targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: link), forKeyword: AEKeyword(keyDirectObject))
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 5)
            return true
        } catch {
            record("send link", false, error.localizedDescription)
            return false
        }
    }

    /// A minimal macOS 27 style .ips (header line + JSON body) whose faulting thread is inside `tweakPath`,
    /// written to the isolated reports folder and back-dated so the scanner reads it at once.
    func writeCrashReport(_ appName: String, bundleID: String, procPath: String, tweakPath: String) -> String {
        let dir = model.safeMode.reportsDirectory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let date = Date().addingTimeInterval(-30)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        let time = f.string(from: date)
        let incident = UUID().uuidString
        let header: [String: Any] = ["app_name": appName, "timestamp": time, "bug_type": "309", "bundleID": bundleID,
                                     "name": appName, "incident_id": incident, "os_version": "macOS 27.2.1 (26B131)"]
        let images: [[String: Any]] = [
            ["source": "P", "arch": "arm64", "base": 4_328_767_488, "size": 16384, "path": procPath, "name": procPath.lastPathComponent],
            ["source": "P", "arch": "arm64e", "base": 7_121_608_704, "size": 23_873_264,
             "path": "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", "name": "AppKit"],
            ["source": "P", "arch": "arm64e", "base": 4_329_177_088, "size": 49152, "path": tweakPath, "name": tweakPath.lastPathComponent],
        ]
        let frames: [[String: Any]] = [
            ["imageIndex": 2, "imageOffset": 4000, "symbol": "-[SmokeHook crash]", "symbolLocation": 12],
            ["imageIndex": 1, "imageOffset": 4016, "symbol": "-[NSApplication run]", "symbolLocation": 12],
            ["imageIndex": 0, "imageOffset": 4032, "symbol": "main", "symbolLocation": 12],
        ]
        let body: [String: Any] = [
            "procName": appName, "procPath": procPath, "bundleInfo": ["CFBundleIdentifier": bundleID], "captureTime": time,
            "incident": incident, "pid": 4242, "faultingThread": 0, "bug_type": "309",
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "subtype": "KERN_INVALID_ADDRESS at 0x10"],
            "threads": [["triggered": true, "id": 1, "queue": "com.apple.main-thread", "frames": frames]],
            "usedImages": images,
        ]
        let h = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let b = try! JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        let path = (dir as NSString).appendingPathComponent("\(appName)-smoke-\(incident.prefix(8)).ips")
        try? (h + Data("\n".utf8) + b).write(to: URL(fileURLWithPath: path))
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        return path
    }

    // MARK: Helpers

    var mainWindow: NSWindow? { NSApp.windows.first { $0.isVisible && !$0.isSheet && $0.contentView != nil } }

    func path(_ name: String) -> String { (reportDirectory as NSString).appendingPathComponent(name) }

    func wait(_ seconds: Double = 8, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return await condition()
    }

    /// Retries a press for a few seconds: the AX window list is briefly empty while a sheet animates.
    func pressWhenReady(_ id: String) async -> Bool {
        await wait(5) { await AXSelf.press(id) }
    }

    /// Scrolls every scrollable form in the main window to its end, so a screenshot shows the last section.
    func scrollFormsToBottom() {
        func visit(_ v: NSView) {
            if let sv = v as? NSScrollView, let doc = sv.documentView, doc.frame.height > sv.contentView.bounds.height {
                let y = doc.isFlipped ? doc.frame.height - sv.contentView.bounds.height : 0
                sv.contentView.scroll(to: NSPoint(x: 0, y: y))
                sv.reflectScrolledClipView(sv.contentView)
            }
            v.subviews.forEach(visit)
        }
        mainWindow?.contentView.map(visit)
    }

    func settle() async { try? await Task.sleep(nanoseconds: 500_000_000) }

    func changed(_ a: String, _ b: String) -> (added: [String], removed: [String]) {
        var added: [String] = [], removed: [String] = []
        for op in LineDiff.diff(a, b) {
            if case let .added(l) = op { added.append(l) }
            if case let .removed(l) = op { removed.append(l) }
        }
        return (added, removed)
    }

    @discardableResult
    func check(_ name: String, _ ok: Bool, _ detail: String) -> Bool {
        record(name, ok, detail)
        if !ok { AXSelf.dumpNow(to: path("ax-fail-\(name.replacingOccurrences(of: " ", with: "-")).txt")) }
        return ok
    }

    func record(_ name: String, _ ok: Bool, _ detail: String) {
        log.steps.append(Step(name: name, ok: ok, detail: detail))
        FileHandle.standardError.write(Data("[smoke] \(ok ? "PASS" : "FAIL") \(name) \(detail)\n".utf8))
    }

    func snapshot(_ name: String, window: NSWindow? = nil) {
        guard let view = (window ?? mainWindow)?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // cacheDisplay leaves the window background transparent; in dark mode that turns labels into
        // white-on-white, so composite over the window's real background color.
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = rep.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: rep.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: rep.size))
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path("\(name).png")))
    }

    func finish() {
        let failed = log.steps.filter { !$0.ok }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        struct Report: Encodable { var passed: Bool; var steps: [Step] }
        try? enc.encode(Report(passed: failed.isEmpty, steps: log.steps)).write(to: URL(fileURLWithPath: path("report.json")))
        FileHandle.standardError.write(Data("[smoke] \(log.steps.count - failed.count)/\(log.steps.count) passed\n".utf8))
        exit(failed.isEmpty ? 0 : 1)
    }
}

/// Accessibility client pointed at this process. AX requests to one's own pid are answered
/// in-process on the calling thread (no IPC), so they MUST run on the main thread: AppKit and
/// SwiftUI build the tree while answering.
@MainActor
enum AXSelf {
    private static func run<T>(_ body: () -> T) async -> T {
        let value = body()
        await Task.yield()
        return value
    }

    private static func app() -> AXUIElement {
        let a = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(a, 3)
        return a
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    /// Roles whose children are never searched (large and irrelevant to the probes).
    private static let opaque: Set<String> = ["AXOutline", "AXTable", "AXScrollBar", "AXToolbar", "AXMenuBar"]

    /// While a sheet is up, the application's AXChildren omits its windows, so start from AXWindows
    /// (which includes sheets) as well.
    private static func roots() -> [AXUIElement] {
        let a = app()
        var out = (attr(a, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for w in out { out += (attr(w, "AXSheets") as? [AXUIElement]) ?? [] }
        return out + [a]
    }

    private static func find(_ id: String) -> AXUIElement? {
        var queue = roots()
        var visited = 0
        while !queue.isEmpty, visited < 8000 {
            let e = queue.removeFirst()
            visited += 1
            if attr(e, "AXIdentifier") as? String == id { return e }
            if let role = attr(e, kAXRoleAttribute) as? String, opaque.contains(role), visited > 1 { continue }
            if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids) }
        }
        return nil
    }

    /// Becomes an accessibility client so SwiftUI materializes its tree.
    static func prime() async -> String {
        await run {
            let a = app()
            let set = AXUIElementSetAttributeValue(a, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            var windows: CFTypeRef?
            let get = AXUIElementCopyAttributeValue(a, kAXWindowsAttribute as CFString, &windows)
            return "trusted=\(AXIsProcessTrusted()) copyWindows=\(get.rawValue) setEUI=\(set.rawValue)"
        }
    }

    static func exists(_ id: String) async -> Bool { await run { find(id) != nil } }

    static func value(_ id: String) async -> String? {
        await run {
            guard let e = find(id), let v = attr(e, kAXValueAttribute) else { return nil }
            if let n = v as? NSNumber { return n.stringValue }
            return "\(v)"
        }
    }

    static func press(_ id: String) async -> Bool {
        await run {
            guard let e = find(id) else { return false }
            return AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
        }
    }

    static func dump(to path: String) async {
        dumpNow(to: path)
        await Task.yield()
    }

    static func dumpNow(to path: String) {
        var lines: [String] = []
        for r in roots() { walk(r, 0, &lines) }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func walk(_ e: AXUIElement, _ depth: Int, _ lines: inout [String]) {
        guard depth < 40, lines.count < 3000 else { return }
        let role = attr(e, kAXRoleAttribute) as? String ?? "?"
        let id = attr(e, "AXIdentifier") as? String ?? ""
        let title = (attr(e, kAXTitleAttribute) as? String) ?? (attr(e, kAXDescriptionAttribute) as? String) ?? ""
        lines.append(String(repeating: "  ", count: depth) + "\(role) id=\(id) \(title.prefix(60))")
        if opaque.contains(role) { return }
        for k in attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(k, depth + 1, &lines) }
    }
}
