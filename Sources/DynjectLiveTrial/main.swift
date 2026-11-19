// Live privileged trial for Dynject Workbench. NOT part of the app; run only with the owner's approval:
//   swift run DynjectLiveTrial
// Uses the same DynjectCore paths as the app (ConfigEditor, ProtectedFileWriter, PrivilegedRestarter
// via osascript) against /opt/dynject, verifying each step from the outside.
//
// Steps (each shows a labelled administrator prompt):
//   1. Cancel test: the user clicks Cancel; the config must be unchanged.
//   2. Restart only: every dynjectd stops, exactly one starts.
//   3. Enable libBrutalium for a test app (Calculator), Save & Restart, launch it, expect Loaded.
//   4. Disable it again, Save & Restart (config must return to the original bytes), launch, expect Not loaded.
import AppKit
import DynjectCore
import Foundation

let configPath = "/opt/dynject/etc/dynjectd.conf"
let logPath = "/opt/dynject/log/dynjectd.log"
let dylib = "/opt/dynject/lib/tweaks/libBrutalium.dylib"
var failures = 0

func say(_ s: String) { print(s); fflush(stdout) }
func check(_ ok: Bool, _ what: String) {
    say("  [\(ok ? "PASS" : "FAIL")] \(what)")
    if !ok { failures += 1 }
}

/// Prefixes the real prompt so the user knows which step a dialog belongs to.
struct LabelledExecutor: PrivilegedExecutor {
    let label: String
    func run(_ arguments: [String], prompt: String) throws -> String {
        try OsascriptExecutor().run(arguments, prompt: "LIVE TRIAL \(label)\n\n\(prompt)")
    }
}

func daemons() -> [Int32] {
    ((try? ProcessRunner.run("/usr/bin/pgrep", ["-x", "dynjectd"]))?.stdout ?? "")
        .split(separator: "\n").compactMap { Int32($0) }.sorted()
}

func stat(_ path: String) -> String {
    let a = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
    let mode = (a[.posixPermissions] as? NSNumber).map { String($0.intValue, radix: 8) } ?? "?"
    return "\(a[.ownerAccountName] ?? "?"):\(a[.groupOwnerAccountName] ?? "?") \(mode)"
}

func read() -> Data { FileManager.default.contents(atPath: configPath) ?? Data() }

func lastStartSummary() -> String {
    let snap = DynjectLogParser.parse(DynjectLogParser.readTail(path: logPath) ?? "")
    guard let s = snap.starts.last else { return "none" }
    return "pid \(s.pid.map(String.init) ?? "?") at \(s.time): \(s.dylibSummaries.joined(separator: "; "))"
}

/// Launches the app in the background, then reports whether `dylib` is mapped into it.
func launchAndCheckLoaded(_ app: InstalledApp) -> Bool? {
    _ = try? ProcessRunner.run("/usr/bin/open", ["-g", "-a", app.bundlePath])
    var pid: Int32?
    for _ in 0..<50 {
        if let p = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first?.processIdentifier {
            pid = p; break
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    guard let pid else { say("  could not launch \(app.displayName)"); return nil }
    Thread.sleep(forTimeInterval: 2)   // let dyld finish
    let loaded = LoadedImageInspector.inspect(pids: [pid], dylibs: [dylib])[pid]?.contains(dylib) ?? false
    say("  \(app.displayName) pid \(pid): libBrutalium \(loaded ? "LOADED" : "not loaded")")
    kill(pid, SIGTERM)
    for _ in 0..<50 where NSRunningApplication(processIdentifier: pid) != nil { Thread.sleep(forTimeInterval: 0.1) }
    return loaded
}

if CommandLine.arguments.contains("--titlebadge") { exit(runTitleBadgeTrial()) }

// --original <file>: the config to return to (e.g. a pre-trial copy). Defaults to the current file.
// --skip-restart: skip step 2.
let args = CommandLine.arguments
let originalArg = args.firstIndex(of: "--original").map { args[$0 + 1] }
let skipRestart = args.contains("--skip-restart")
let original = originalArg.flatMap { FileManager.default.contents(atPath: $0) } ?? read()
let originalText = String(decoding: original, as: UTF8.self)
let backups = BackupStore(root: BackupStore.defaultRoot)
say("Live config \(stat(configPath)) sha256 \(sha256Hex(original))")
say("dynjectd before: \(daemons())")

// MARK: 1. Cancel
say("\nStep 1/4: cancel test (click CANCEL in the dialog)")
let beforeCancel = read()
do {
    let writer = ProtectedFileWriter(backups: backups, executor: LabelledExecutor(label: "step 1 of 4: do NOT type your password. Click Cancel. (Cancel test)"))
    _ = try writer.write(beforeCancel + Data("# live-trial cancel test\n".utf8), to: configPath, expectedCurrent: beforeCancel, category: "config")
    check(false, "expected the prompt to be cancelled, but the write went through")
} catch WriteError.cancelled {
    check(true, "cancel reported as WriteError.cancelled")
} catch {
    check(false, "unexpected error: \(error.localizedDescription)")
}
check(read() == beforeCancel, "config unchanged after cancel")

// MARK: 2. Restart
say("\nStep 2/4: restart dynjectd (enter your password)")
let before = daemons()
if skipRestart { say("  skipped (--skip-restart)") } else { do {
    let report = try PrivilegedRestarter(executor: LabelledExecutor(label: "step 2 of 4 — restart dynjectd")).restart()
    say(report.transcript.split(separator: "\n").map { "  | \($0)" }.joined(separator: "\n"))
    let now = daemons()
    check(now.count == 1, "exactly one dynjectd running: \(now)")
    check(Set(now).isDisjoint(with: before), "all previous daemons \(before) are gone")
    check(report.after == now, "helper's report matches pgrep")
} catch {
    check(false, "restart failed: \(error.localizedDescription)")
}
Thread.sleep(forTimeInterval: 1)
say("  log: \(lastStartSummary())")
} // skipRestart

// MARK: 3. Enable for a test app
let log = DynjectLogParser.parse(DynjectLogParser.readTail(path: logPath) ?? "")
let apps = AppDiscovery.scan(roots: AppDiscovery.defaultRoots)
let targets = apps.map { InjectionTarget(app: $0, service: ServiceNameResolver.resolve($0, log: log).value) }
guard let test = apps.first(where: { $0.bundleID == "com.apple.calculator" }),
      NSRunningApplication.runningApplications(withBundleIdentifier: test.bundleID).isEmpty else {
    say("Calculator missing or running; stopping before any config change.")
    exit(1)
}
let target = targets.first { $0.app.id == test.id }!

say("\nStep 3/4: enable libBrutalium for \(test.displayName) and restart (enter your password)")
var enabledText = ""
do {
    let edit = try ConfigEditor.setInjection(true, dylib: dylib, for: target, in: ConfigDocument(text: originalText), allTargets: targets)
    edit.changes.forEach { say("  \($0)") }
    check(edit.sideEffects.isEmpty, "no other installed app affected (\(edit.sideEffects.map(\.app.displayName)))")
    guard edit.sideEffects.isEmpty else { exit(1) }
    enabledText = edit.document.text
    let exec = LabelledExecutor(label: "step 3 of 4 — enable for \(test.displayName) + restart")
    // The current file may differ from `original` (e.g. a stray comment); the guard compares against what is on disk now.
    let onDiskBefore = read()
    let outcome = try ProtectedFileWriter(backups: backups, executor: exec)
        .write(Data(enabledText.utf8), to: configPath, expectedCurrent: onDiskBefore, category: "config",
               restartWith: PrivilegedRestarter(executor: exec))
    check(outcome.usedAdministratorRights, "write used administrator rights (one prompt incl. restart)")
    check(read() == Data(enabledText.utf8), "config on disk is the edited text")
    check(stat(configPath) == "root:wheel 644", "owner/mode preserved: \(stat(configPath))")
    check(outcome.backup.flatMap { try? Data(contentsOf: $0) } == onDiskBefore, "backup holds the previous file: \(outcome.backup?.path ?? "none")")
    check(daemons().count == 1, "exactly one dynjectd: \(daemons())")
    Thread.sleep(forTimeInterval: 1)
    say("  log: \(lastStartSummary())")
    let loaded = launchAndCheckLoaded(test)
    check(loaded == true, "\(test.displayName) confirmed Loaded after launch")
    let snap = DynjectLogParser.parse(DynjectLogParser.readTail(path: logPath) ?? "")
    if let ev = snap.lastEvent(bundleID: test.bundleID, executable: test.executableName, service: target.service) {
        say("  log event: \(ev.time) \(ev.service) \(ev.outcome)")
    }
} catch {
    check(false, "step 3 failed: \(error.localizedDescription)")
}

// MARK: 4. Disable again
say("\nStep 4/4: disable it again and restart (enter your password)")
do {
    let current = read()
    let edit = try ConfigEditor.setInjection(false, dylib: dylib, for: target,
                                             in: ConfigDocument(text: String(decoding: current, as: UTF8.self)), allTargets: targets)
    edit.changes.forEach { say("  \($0)") }
    check(edit.document.text == originalText, "edited text equals the original config byte for byte")
    let exec = LabelledExecutor(label: "step 4 of 4 — disable for \(test.displayName) + restart")
    _ = try ProtectedFileWriter(backups: backups, executor: exec)
        .write(Data(edit.document.text.utf8), to: configPath, expectedCurrent: current, category: "config",
               restartWith: PrivilegedRestarter(executor: exec))
    check(read() == original, "live config restored to original (sha256 \(sha256Hex(read())))")
    check(stat(configPath) == "root:wheel 644", "owner/mode preserved: \(stat(configPath))")
    check(daemons().count == 1, "exactly one dynjectd: \(daemons())")
    Thread.sleep(forTimeInterval: 1)
    say("  log: \(lastStartSummary())")
    let loaded = launchAndCheckLoaded(test)
    check(loaded == false, "\(test.displayName) Not loaded after relaunch")
} catch {
    check(false, "step 4 failed: \(error.localizedDescription)")
}

say("\n\(failures == 0 ? "ALL STEPS PASSED" : "\(failures) CHECK(S) FAILED")")
say("dynjectd now: \(daemons()); config sha256 \(sha256Hex(read()))")
exit(failures == 0 ? 0 : 1)
