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
