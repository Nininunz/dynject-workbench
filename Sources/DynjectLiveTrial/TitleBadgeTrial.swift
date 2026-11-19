import AppKit
import DynjectCore
import Foundation

/// Live trial for the Title Badge example tweak (`DynjectLiveTrial --titlebadge --dylib <built dylib>
/// --manifest <manifest>`). Installs it, enables it for Calculator only, and proves through the tweak's own
/// unified-log lines that sandboxed Calculator reads settings Workbench writes, including live changes and a
/// per-app override. Leaves it installed; the settings session is reverted at the end.
func runTitleBadgeTrial() -> Int32 {
    let args = CommandLine.arguments
    func arg(_ f: String) -> String? { args.firstIndex(of: f).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    guard let builtDylib = arg("--dylib"), let manifestSrc = arg("--manifest"),
          let dylibData = FileManager.default.contents(atPath: builtDylib) else {
        say("usage: --titlebadge --dylib <libTitleBadge.dylib> --manifest <TitleBadge.workbench.plist>")
        return 2
    }
    let installed = "/opt/dynject/lib/tweaks/libTitleBadge.dylib"
    let calcBundle = "com.apple.calculator"
    guard NSRunningApplication.runningApplications(withBundleIdentifier: calcBundle).isEmpty else {
        say("Calculator is running; quit it first.")
        return 1
    }
    let backups = BackupStore(root: BackupStore.defaultRoot)
    let startStamp: String = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date().addingTimeInterval(-1))
    }()

    func tweakLog() -> [String] {
        let out = try? ProcessRunner.run("/usr/bin/log", ["show", "--start", startStamp, "--style", "compact", "--predicate",
                                                          "subsystem == \"local.dynject.titlebadge\" AND process == \"Calculator\""])
        return (out?.stdout ?? "").split(separator: "\n").map(String.init).filter { $0.contains("[local.dynject.titlebadge") }
    }
    func waitForLog(_ needle: String, _ seconds: Double = 8) -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let line = tweakLog().last(where: { $0.contains(needle) }) { return line }
            Thread.sleep(forTimeInterval: 0.7)
        } while Date() < deadline
        return nil
    }

    // 1. Install the dylib (password prompt 1).
    say("Step 1/5: install \(installed) (enter your password)")
    do {
        let exec = LabelledExecutor(label: "Title Badge 1 of 2: install the dylib")
        let current = FileManager.default.contents(atPath: installed)
        let outcome = try ProtectedFileWriter(backups: backups, executor: exec)
            .write(dylibData, to: installed, expectedCurrent: current, category: "dylibs")
        check(outcome.usedAdministratorRights, "installed with administrator rights")
        check(FileManager.default.contents(atPath: installed) == dylibData, "installed bytes match the build")
        check(stat(installed) == "root:wheel 644", "owner/mode \(stat(installed))")
        let verify = try? ProcessRunner.run("/usr/bin/codesign", ["--verify", installed])
        check(verify?.status == 0, "ad-hoc signature still valid")
    } catch {
        check(false, "install failed: \(error.localizedDescription)")
        return 1
    }

    // 2. Manifest into the user's Tweaks folder (no privileges).
    let tweaksDir = BackupStore.defaultRoot.deletingLastPathComponent().appendingPathComponent("Tweaks")
    let manifestDest = tweaksDir.appendingPathComponent("TitleBadge.workbench.plist")
    try? FileManager.default.createDirectory(at: tweaksDir, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: manifestDest)
    do { try FileManager.default.copyItem(atPath: manifestSrc, toPath: manifestDest.path) } catch { check(false, "copy manifest: \(error)") }
    let (manifests, issues) = TweakManifestLoader.load(directories: [tweaksDir.path])
    guard let manifest = manifests.first(where: { $0.id == "local.dynject.titlebadge" }) else {
        check(false, "manifest loads: \(issues.map(\.message))")
        return 1
    }
    say("\nStep 2/5: manifest installed at \(manifestDest.path)")
    check(issues.filter { $0.file == manifestDest.path }.isEmpty, "manifest has no problems")

    // 3. Declare the dylib, enable for Calculator only, save and restart (password prompt 2).
    say("\nStep 3/5: add to the Dynject config for Calculator and restart (enter your password)")
    let original = read()
    let log = DynjectLogParser.parse(DynjectLogParser.readTail(path: logPath) ?? "")
    let apps = AppDiscovery.scan(roots: AppDiscovery.defaultRoots)
    let targets = apps.map { InjectionTarget(app: $0, service: ServiceNameResolver.resolve($0, log: log).value) }
    guard let calc = targets.first(where: { $0.app.bundleID == calcBundle }) else { say("Calculator not found"); return 1 }
    do {
        var doc = ConfigDocument(text: String(decoding: original, as: UTF8.self))
        if EffectiveConfig(document: doc).dylib(path: installed) == nil { doc = try ConfigEditor.addDylib(installed, to: doc) }
        let edit = try ConfigEditor.setInjection(true, dylib: installed, for: calc, in: doc, allTargets: targets)
        let diff = LineDiff.diff(String(decoding: original, as: UTF8.self), edit.document.text)
        for case let .added(l) in diff { say("  + \(l)") }
        for case let .removed(l) in diff { say("  - \(l)") }
        let affected = ConfigEditor.affectedApps(from: ConfigDocument(text: String(decoding: original, as: UTF8.self)),
                                                 to: edit.document, targets: targets)
        check(affected.map(\.app.bundleID) == [calcBundle], "only Calculator's injection changes (\(affected.map(\.app.displayName)))")
        guard affected.map(\.app.bundleID) == [calcBundle] else { return 1 }
        let exec = LabelledExecutor(label: "Title Badge 2 of 2: enable for Calculator + restart")
        _ = try ProtectedFileWriter(backups: backups, executor: exec)
            .write(Data(edit.document.text.utf8), to: configPath, expectedCurrent: original, category: "config",
                   restartWith: PrivilegedRestarter(executor: exec))
        check(read() == Data(edit.document.text.utf8), "config saved")
        check(daemons().count == 1, "exactly one dynjectd: \(daemons())")
        Thread.sleep(forTimeInterval: 1)
        say("  log: \(lastStartSummary())")
    } catch {
        check(false, "config step failed: \(error.localizedDescription)")
        return 1
    }

    // 4. Settings written exactly as Workbench writes them (global domain + Darwin notification).
    say("\nStep 4/5: settings → sandboxed Calculator")
    let settings = TweakSettings(manifest: manifest, backend: CFPreferencesTweakBackend())
    settings.set(.string("Live Trial"), for: manifest.item("text")!)
    settings.set(.string("#00AA00"), for: manifest.item("color")!)
    try? settings.persist()

    _ = try? ProcessRunner.run("/usr/bin/open", ["-g", "-a", calc.app.bundlePath])
    var pid: Int32?
    for _ in 0..<50 {
        if let p = NSRunningApplication.runningApplications(withBundleIdentifier: calcBundle).first?.processIdentifier { pid = p; break }
        Thread.sleep(forTimeInterval: 0.2)
    }
    guard let pid else { check(false, "Calculator launched"); return 1 }
    Thread.sleep(forTimeInterval: 2)
    let loaded = LoadedImageInspector.inspect(pids: [pid], dylibs: [installed])[pid]?.contains(installed) ?? false
    check(loaded, "libTitleBadge loaded into Calculator (pid \(pid))")
    if let l = waitForLog("loaded into com.apple.calculator") { say("  log: \(l)") } else { check(false, "tweak logged that it loaded") }
    if let l = waitForLog("text=\"Live Trial\"") {
        check(l.contains("enabled=1") && l.contains("#00AA00") && !l.contains("windows=0"), "read settings inside the sandbox and drew on a window")
        say("  log: \(l)")
    } else { check(false, "tweak read \"Live Trial\" inside sandboxed Calculator") }

    say("  live change: text \"Changed Live\", style outline")
    settings.set(.string("Changed Live"), for: manifest.item("text")!)
    settings.set(.string("outline"), for: manifest.item("style")!)
    try? settings.persist()
    if let l = waitForLog("settings-changed in com.apple.calculator: enabled=1 text=\"Changed Live\"") {
        check(l.contains("style=outline"), "live update arrived via the Darwin notification")
        say("  log: \(l)")
    } else { check(false, "live update reached Calculator") }

    say("  per-app override for Calculator: text \"Calc Only\"")
    settings.setOverride(.string("Calc Only"), for: manifest.item("text")!, bundleID: calcBundle)
    try? settings.persist()
    if let l = waitForLog("text=\"Calc Only\"") { check(true, "per-app override applied"); say("  log: \(l)") }
    else { check(false, "per-app override reached Calculator") }

    // 5. Leave a clean state: settings back to before the trial (defaults), Calculator quit.
    say("\nStep 5/5: revert the trial's settings and quit Calculator")
    try? settings.revertSession()
    if let l = waitForLog("text=\"Dynject\"") { check(true, "reverted to defaults, seen live"); say("  log: \(l)") }
    else { check(false, "revert reached Calculator") }
    kill(pid, SIGTERM)
    check(CFPreferencesCopyValue(TweakPrefsContract.payloadKey(manifest.id) as CFString, kCFPreferencesAnyApplication,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost) == nil, "no settings key left behind")

    say("\n\(failures == 0 ? "ALL STEPS PASSED" : "\(failures) CHECK(S) FAILED")")
    say("Title Badge stays installed and enabled for Calculator. Open Workbench → Tweaks → Title Badge, open Calculator, and change settings.")
    return failures == 0 ? 0 : 1
}
