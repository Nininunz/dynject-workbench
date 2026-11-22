// `dw hooks <app>`: asks the DynjectHook copies in a running app what they have hooked (TweakSDK/DynjectHook.m,
// "Hook reports") and shows it per tweak, with the methods two tweaks hook. The report is DynjectCore's HookReport;
// this file sends the request, reads the answers from the unified log and prints.
import AppKit
import DynjectCore
import Foundation
import notify

let hooksUsage = """
usage: dw hooks <app> [--scan] [--timeout S] [--json]
       dw hooks --pid <pid> [--scan] [--timeout S] [--json]

  every method and function the tweaks in a running app have hooked, per tweak: its state (installed, buried
  beneath another hook, restored by a group, pending), whether it's on top, its group; import hooks with how many
  call sites they cover. warns when two tweaks hook the same method. lists the tweak dylibs loaded in the app that
  didn't answer, and why. read-only: it asks the app, through a darwin notification, to write the list to its log.

  <app>        bundle id, app name, executable name or .app path of a running app
  --pid N      that process
  --scan       also look for methods of other images' classes implemented in tweak dylibs, by any hooking code.
               it realizes every class in the app once: can take a second in a big app
  --timeout S  how long to wait for the answers (default 3, 10 with --scan)
  --json       {app, pid, request, copies: [...], conflicts: [...], foreign: [...], silent: [...]}

  tweaks answer when built with DynjectHook from TweakSDK 0.1.3 on.
"""

func hooksCommand(_ args: [String]) {
    var scan = false, json = false
    var timeout: Double?
    var pid: pid_t?
    var positional: [String] = []
    var i = 0
    func value(_ flag: String) -> String {
        guard i + 1 < args.count else { fail("\(flag) needs a value\n\n\(hooksUsage)", 2) }
        i += 1
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--scan": scan = true
        case "--json": json = true
        case "--timeout": timeout = Double(value("--timeout")) ?? 3
        case "--pid": pid = pid_t(value("--pid")) ?? 0
        case "--help", "-h", "help": print(hooksUsage); exit(0)
        case let a where a.hasPrefix("--"): fail("unknown option \(a)\n\n\(hooksUsage)", 2)
        case let a: positional.append(a)
        }
        i += 1
    }
    guard (pid != nil) != (positional.count == 1), positional.count <= 1 else { fail(hooksUsage, 2) }

    // The process.
    var appName = "", bundleID = ""
    if let p = pid {
        guard let app = NSRunningApplication(processIdentifier: p) else {
            if kill(p, 0) != 0 { fail("no process \(p)", 2) }
            bundleID = "?"; appName = "pid \(p)"
            return run(pid: p, appName: appName, bundleID: bundleID, scan: scan, json: json, timeout: timeout)
        }
        appName = app.localizedName ?? "pid \(p)"
        bundleID = app.bundleIdentifier ?? "?"
    } else {
        let arg = positional[0]
        var id = arg
        if case let .success(app) = WhyLookup.app(arg, apps: AppDiscovery.scan(roots: AppDiscovery.defaultRoots)) { id = app.bundleID }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        guard let app = running.first else { fail("\(arg) isn't running (\(id))", 2) }
        if running.count > 1 { print("note: \(running.count) copies are running; asking pid \(app.processIdentifier)") }
        pid = app.processIdentifier
        appName = app.localizedName ?? id
        bundleID = id
    }
    run(pid: pid!, appName: appName, bundleID: bundleID, scan: scan, json: json, timeout: timeout)
}

private func run(pid: pid_t, appName: String, bundleID: String, scan: Bool, json: Bool, timeout: Double?) {
    let locations = TweakLocations.live()
    let manifests = TweakManifestLoader.load(directories: locations.manifestSearchDirectories).manifests
    let configText = FileManager.default.contents(atPath: locations.configPath).map { String(decoding: $0, as: UTF8.self) } ?? ""
    var candidates = EffectiveConfig(document: ConfigDocument(text: configText)).dylibPaths
    let dir = locations.dylibFileDirectory
    for f in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() where f.hasSuffix(".dylib") {
        let p = dir + "/" + f
        if !candidates.contains(p) { candidates.append(p) }
    }
    let loaded = (LsofDylibInspector().loadedDylibs(pids: [pid], candidates: candidates)[pid] ?? []).sorted()
    let canAnswer = loaded.filter { HookReportSupport.supports(dylibAt: $0) == true }.count

    // Listen first, then ask.
    let stream = Process()
    stream.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    stream.arguments = ["stream", "--style", "compact", "--level", "default", "--predicate", "subsystem == \"dynject.hooks\" AND processID == \(pid)"]
    let pipe = Pipe()
    stream.standardOutput = pipe
    stream.standardError = FileHandle.nullDevice
    let lock = NSLock()
    var messages: [String] = []
    var ready = false
    var partial = ""
    pipe.fileHandleForReading.readabilityHandler = { h in
        let data = h.availableData
        guard !data.isEmpty else { h.readabilityHandler = nil; return }
        lock.lock()
        partial += String(decoding: data, as: UTF8.self)
        var lines = partial.components(separatedBy: "\n")
        partial = lines.removeLast()
        for line in lines {
            if line.hasPrefix("Filtering the log data") { ready = true }
            if let l = WhyLogLine.parse(line).first { messages.append(l.message) }
        }
        lock.unlock()
    }
    do { try stream.run() } catch { fail("can't run log stream: \(error.localizedDescription)") }
    let readyBy = Date().addingTimeInterval(3)
    while Date() < readyBy {
        lock.lock(); let r = ready; lock.unlock()
        if r { break }
        usleep(50_000)
    }
    usleep(300_000)   // log stream prints its header before it is connected

    let asked = Date().addingTimeInterval(-1)
    let request = UInt32.random(in: 1...UInt32.max)
    let name = "dynject.hooks.report.\(pid)"
    var token: Int32 = 0
    guard notify_register_check(name, &token) == UInt32(NOTIFY_STATUS_OK) else { stream.terminate(); fail("can't register \(name)") }
    notify_set_state(token, UInt64(request) | (scan ? (UInt64(1) << 32) : 0))
    notify_post(name)

    // Done when every copy that started an answer has ended it, at least as many as the loaded dylibs that can
    // answer (copies outside the tweaks folder may answer too), the scan is in if asked for, and no line has come
    // for a moment.
    // No loaded dylib that can answer: only a copy elsewhere might, so don't wait long.
    let deadline = Date().addingTimeInterval(timeout ?? (canAnswer == 0 ? (scan ? 3 : 1.2) : (scan ? 10 : 3)))
    var report = HookReport()
    var seen = 0
    var lastLine = Date()
    while Date() < deadline {
        usleep(100_000)
        lock.lock(); let snapshot = messages; lock.unlock()
        let mine = snapshot.filter { $0.hasPrefix("R \(request) ") }.count
        if mine != seen { seen = mine; lastLine = Date() }
        report = HookReport.parse(snapshot, request: request)
        let ended = report.copies.filter(\.complete).count
        let allEnded = ended == report.copies.count && ended >= max(canAnswer, 1)
        if allEnded && (!scan || report.scanFinished) && Date().timeIntervalSince(lastLine) >= 0.4 { break }
    }
    stream.terminate()
    notify_cancel(token)

    // `log stream` can miss the first lines a process logs after it starts listening (the process learns about the
    // stream asynchronously); they are in the log store all the same. Read that too and keep whichever has more.
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    if let shown = try? ProcessRunner.run("/usr/bin/log", ["show", "--style", "compact", "--start", f.string(from: asked),
                                                           "--predicate", "subsystem == \"dynject.hooks\" AND processID == \(pid)"]) {
        let stored = WhyLogLine.parse(shown.stdout).map(\.message)
        lock.lock(); let streamed = messages; lock.unlock()
        func count(_ m: [String]) -> Int { m.filter { $0.hasPrefix("R \(request) ") }.count }
        if count(stored) > count(streamed) { report = HookReport.parse(stored, request: request) }
    }

    var names: [String: String] = [:]
    var idForDylib: [String: String] = [:]
    for m in manifests {
        names[m.id] = m.name
        idForDylib[locations.filePath(forDylib: m.dylib)] = m.id
        idForDylib[m.dylib] = m.id
    }
    let answered = Set(report.copies.map(\.image))
    let silent = loaded.filter { !answered.contains($0) }.map { path -> (path: String, why: HookReport.Silence, tweakID: String?) in
        let support = SafeModeSupportChecker.shared.support(dylibAt: path)
        let why = HookReport.silence(supportsReports: HookReportSupport.supports(dylibAt: path),
                                     usesDynjectHook: support.map { $0 != .unsupported })
        return (path, why, idForDylib[path])
    }

    if json {
        func hook(_ h: HookReport.Hook) -> [String: Any] {
            ["method": h.method, "class": h.cls, "selector": h.sel, "classMethod": h.classMethod, "state": h.state, "top": h.top,
             "group": h.group as Any]
        }
        let obj: [String: Any] = [
            "app": appName, "bundleID": bundleID, "pid": pid, "request": request,
            "copies": report.copies.map { c in
                ["tweakID": c.tweakID, "image": c.image, "sdk": c.sdk as Any, "complete": c.complete, "hooks": c.hooks.map(hook),
                 "imports": c.imports.map { ["symbol": $0.symbol, "library": $0.library as Any, "sites": $0.sites, "active": $0.active] }]
            },
            "conflicts": report.conflicts.map { ["method": $0.method, "tweakIDs": $0.tweakIDs, "top": $0.top as Any] },
            "foreign": report.scanned ? report.foreignNotReported.map { ["method": $0.method, "image": $0.image, "classImage": $0.classImage] } : [],
            "silent": silent.map { ["dylib": $0.path, "why": "\($0.why)", "tweakID": $0.tweakID as Any] },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        FileHandle.standardOutput.write(data)
        print("")
    } else {
        let header = "dw hooks: \(appName) (\(bundleID), pid \(pid)): \(loaded.count) tweak dylib\(loaded.count == 1 ? "" : "s") loaded, \(report.copies.count) answered"
        print(report.text(header: header, names: names, silent: silent, bundleID: bundleID))
    }
    exit(0)
}
