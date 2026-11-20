// dw — command-line companion to Dynject Workbench for tweak development (think Theos `make do`).
//
//   dw tweak install <folder> [--for ID]   install a built tweak folder: dylib, config, restart in one admin prompt,
//                                          then its manifest (TweakCommands.swift); also uninstall, list
//   dw new <Name> [--app ID]               a ready-to-build tweak folder with the SDK vendored in
//   dw install <built.dylib>               copy into /opt/dynject/lib/tweaks/ (admin prompt, hash-checked)
//   dw enable  <installed.dylib> <bundleID>  declare if needed, enable for one app, restart dynjectd (admin prompt)
//   dw disable <installed.dylib> <bundleID>  the reverse
//   dw relaunch <bundleID>                 quit (if running) and open the app
//   dw respring [--dry-run] [--all] ...    relaunch running apps whose tweaks are out of date (RespringCommand.swift)
//   dw config apply <new.conf> [--yes]     replace the config (diff + validation; writes only with --yes)
//   dw log <subsystem> [minutes]           show a tweak's unified-log lines
//   dw safemode ...                        Safe Mode: status, disable/enable, panic, watch, agent (SafeModeCommands.swift)
//   dw bridge ...                          DynjectBridge broker: serve, agent, status, log (BridgeCommands.swift)
//
// Uses the same DynjectCore code as the app: backups, conflict checks, atomic writes, single-daemon restart.
import AppKit
import DynjectCore
import Foundation

let tweaksDir = "/opt/dynject/lib/tweaks"
let configPath = "/opt/dynject/etc/dynjectd.conf"
let logPath = "/opt/dynject/log/dynjectd.log"

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("dw: \(message)\n".utf8))
    exit(code)
}

struct PromptedExecutor: PrivilegedExecutor {
    let what: String
    func run(_ arguments: [String], prompt: String) throws -> String {
        try OsascriptExecutor().run(arguments, prompt: "dw: \(what)\n\n\(prompt)")
    }
}

func writer(_ what: String) -> (ProtectedFileWriter, PromptedExecutor) {
    let exec = PromptedExecutor(what: what)
    return (ProtectedFileWriter(backups: BackupStore(root: BackupStore.defaultRoot), executor: exec), exec)
}

func install(_ source: String) {
    guard let data = FileManager.default.contents(atPath: source) else { fail("can't read \(source)") }
    let name = (source as NSString).lastPathComponent
    guard name.hasSuffix(".dylib"), !name.contains(":") else { fail("expected a .dylib without ':' in its name") }
    let dest = (tweaksDir as NSString).appendingPathComponent(name)
    let current = FileManager.default.contents(atPath: dest)
    if current == data { print("\(dest) is already up to date"); return }
    let (w, _) = writer("install \(name)")
    do {
        let out = try w.write(data, to: dest, expectedCurrent: current, category: "dylibs")
        print("installed \(dest) (sha256 \(sha256Hex(data).prefix(12)))" + (out.backup.map { "; previous saved to \($0.path)" } ?? ""))
        print("Running apps keep the old copy until relaunched; dynjectd needs no restart for an updated file.")
    } catch {
        fail(error.localizedDescription)
    }
}

func setEnabled(_ enabled: Bool, dylib: String, bundleID: String) {
    guard let original = FileManager.default.contents(atPath: configPath) else { fail("can't read \(configPath)") }
    let text = String(decoding: original, as: UTF8.self)
    let log = DynjectLogParser.parse(DynjectLogParser.readTail(path: logPath) ?? "")
    let apps = AppDiscovery.scan(roots: AppDiscovery.defaultRoots)
    let targets = apps.map { InjectionTarget(app: $0, service: ServiceNameResolver.resolve($0, log: log).value) }
    guard let target = targets.first(where: { $0.app.bundleID == bundleID }) else { fail("no installed app has bundle ID \(bundleID)") }
    do {
        var doc = ConfigDocument(text: text)
        if EffectiveConfig(document: doc).dylib(path: dylib) == nil {
            guard enabled else { print("\(dylib) isn't in the config; nothing to disable"); return }
            guard FileManager.default.fileExists(atPath: dylib) else { fail("\(dylib) doesn't exist; run `dw install` first") }
            doc = try ConfigEditor.addDylib(dylib, to: doc)
        }
        let edit = try ConfigEditor.setInjection(enabled, dylib: dylib, for: target, in: doc, allTargets: targets)
        guard edit.document.text != text else { print("already \(enabled ? "enabled" : "disabled") for \(bundleID)"); return }
        for op in LineDiff.diff(text, edit.document.text) {
            if case let .added(l) = op { print("  + \(l)") }
            if case let .removed(l) = op { print("  - \(l)") }
        }
        let affected = ConfigEditor.affectedApps(from: ConfigDocument(text: text), to: edit.document, targets: targets)
        let others = affected.filter { $0.app.bundleID != bundleID }
        if !others.isEmpty { fail("this would also change \(others.map(\.app.displayName).joined(separator: ", ")); edit in Workbench instead") }
        let (w, exec) = writer("\(enabled ? "enable" : "disable") \((dylib as NSString).lastPathComponent) for \(target.app.displayName) + restart dynjectd")
        let out = try w.write(Data(edit.document.text.utf8), to: configPath, expectedCurrent: original, category: "config",
                              restartWith: PrivilegedRestarter(executor: exec))
        print("saved; dynjectd now: \(out.restart?.after.map(String.init).joined(separator: " ") ?? "?"). Relaunch \(target.app.displayName) to apply.")
    } catch {
        fail(error.localizedDescription)
    }
}

func relaunch(_ bundleID: String) {
    guard let app = AppDiscovery.scan(roots: AppDiscovery.defaultRoots).first(where: { $0.bundleID == bundleID }) else {
        fail("no installed app has bundle ID \(bundleID)")
    }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    let pids = running.map(\.processIdentifier)
    running.forEach { $0.terminate() }
    // A CLI has no run loop, so NSRunningApplication.isTerminated never updates; poll the pids instead.
    func alive() -> Bool { pids.contains { kill($0, 0) == 0 } }
    for _ in 0..<100 where alive() { Thread.sleep(forTimeInterval: 0.1) }
    if alive() { fail("\(app.displayName) didn't quit (unsaved changes?)") }
    _ = try? ProcessRunner.run("/usr/bin/open", ["-a", app.bundlePath])
    print(running.isEmpty ? "opened \(app.displayName)" : "relaunched \(app.displayName)")
}

func showLog(_ subsystem: String, minutes: Int) {
    let out = try? ProcessRunner.run("/usr/bin/log", ["show", "--last", "\(minutes)m", "--style", "compact", "--info",
                                                      "--predicate", "subsystem == \"\(subsystem)\""])
    print(out?.stdout ?? "")
}


/// Replaces the whole config with `newPath`'s text: shows the diff and the validator's findings, refuses errors,
/// and writes only with --yes (backup, conflict check against what was read, single-daemon restart).
func applyConfig(_ newPath: String, confirmed: Bool) {
    guard let original = FileManager.default.contents(atPath: configPath) else { fail("can't read \(configPath)") }
    guard let newData = FileManager.default.contents(atPath: newPath) else { fail("can't read \(newPath)") }
    let old = String(decoding: original, as: UTF8.self), new = String(decoding: newData, as: UTF8.self)
    guard old != new else { print("no change"); return }
    for op in LineDiff.diff(old, new) {
        if case let .added(l) = op { print("  + \(l)") }
        if case let .removed(l) = op { print("  - \(l)") }
    }
    let diagnostics = ConfigValidator.diagnose(ConfigDocument(text: new))
    for d in diagnostics { print("  \(d.severity) \(d.line.map { "line \($0 + 1): " } ?? "")\(d.message)") }
    if diagnostics.contains(where: { $0.severity == .error }) { fail("the new config has errors; not applied") }
    guard confirmed else { print("dry run; add --yes to write it and restart dynjectd"); return }
    let (w, exec) = writer("apply config from \((newPath as NSString).lastPathComponent) + restart dynjectd")
    do {
        let out = try w.write(newData, to: configPath, expectedCurrent: original, category: "config",
                              restartWith: PrivilegedRestarter(executor: exec))
        print("saved; dynjectd now: \(out.restart?.after.map(String.init).joined(separator: " ") ?? "?"). Relaunch apps to apply.")
    } catch {
        fail(error.localizedDescription)
    }
}

let a = Array(CommandLine.arguments.dropFirst())
switch (a.first, a.count) {
case ("--version", _), ("version", _): print(WorkbenchInfo.versionText)
case ("safemode", _): safeModeCommand(Array(a.dropFirst()))
case ("bridge", _): bridgeCommand(Array(a.dropFirst()))
case ("respring", _): respringCommand(Array(a.dropFirst()))
case ("tweak", _): tweakCommand(Array(a.dropFirst()))
case ("new", _): newTweak(Array(a.dropFirst()))
case ("install", 2): install(a[1])
case ("enable", 3): setEnabled(true, dylib: a[1], bundleID: a[2])
case ("disable", 3): setEnabled(false, dylib: a[1], bundleID: a[2])
case ("relaunch", 2): relaunch(a[1])
case ("menu", 2) where a[1] == "publish": republishAppleMenu(.live())
case ("config", 3) where a[1] == "apply": applyConfig(a[2], confirmed: false)
case ("config", 4) where a[1] == "apply" && a[3] == "--yes": applyConfig(a[2], confirmed: true)
case ("log", 2): showLog(a[1], minutes: 5)
case ("log", 3): showLog(a[1], minutes: Int(a[2]) ?? 5)
default:
    print("""
    usage:
      dw tweak install <folder|manifest> [--for <bundleID>]... [--dylib <path>] [--dry-run]   (dw tweak --help)
      dw tweak uninstall <tweakID|manifest> [--keep-file] [--dry-run]
      dw tweak list
      dw new <Name> [--id <reverse.dns.id>] [--app <bundleID>] [--dir <path>]
      dw install <built.dylib>
      dw enable  <installed.dylib> <bundleID>
      dw disable <installed.dylib> <bundleID>
      dw relaunch <bundleID>
      dw respring [--dry-run] [--all] [--include ID]... [--exclude ID]... [--timeout S]   (dw respring --help)
      dw config apply <new.conf> [--yes]
      dw menu publish                   republish MenuLoader's list from the installed manifests
      dw log <subsystem> [minutes]
      dw safemode ...   (dw safemode help)
      dw bridge ...     (dw bridge help)
      dw --version
    """)
    exit(a.isEmpty ? 0 : 2)
}
