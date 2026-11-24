// `dw hooks <app>`: asks the DynjectHook copies in a running app what they have hooked (TweakSDK/DynjectHook.m,
// "Hook reports") and shows it per tweak, with the methods two tweaks hook. The report is DynjectCore's HookReport;
// this file sends the request, reads the answers from the unified log and prints.
import DynjectCore
import Foundation

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
    let app = runningApp(positional.first, pid: pid, usage: hooksUsage)
    run(pid: app.pid, appName: app.name, bundleID: app.bundleID, scan: scan, json: json, timeout: timeout)
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
    let ask = ProcessRequest(pid: pid, subsystem: "dynject.hooks")
    let request = ask.request
    let prefix = "R \(request) "
    ask.post("dynject.hooks.report.\(pid)", state: UInt64(request) | (scan ? (UInt64(1) << 32) : 0))

    // Done when every copy that started an answer has ended it, at least as many as the loaded dylibs that can
    // answer (copies outside the tweaks folder may answer too), and the scan is in if asked for. No loaded dylib that
    // can answer: only a copy elsewhere might, so don't wait long.
    let timeoutSeconds = timeout ?? (canAnswer == 0 ? (scan ? 3 : 1.2) : (scan ? 10 : 3))
    ask.wait(prefix: prefix, timeout: timeoutSeconds) { lines in
        let r = HookReport.parse(lines, request: request)
        let ended = r.copies.filter(\.complete).count
        return ended == r.copies.count && ended >= max(canAnswer, 1) && (!scan || r.scanFinished)
    }
    let report = HookReport.parse(ask.finish(prefix: prefix), request: request)

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
                 "imports": c.imports.map { ["symbol": $0.symbol, "library": $0.library as Any, "sites": $0.sites, "active": $0.active] },
                 "functions": c.functions.map { ["address": $0.address, "name": $0.name, "active": $0.active, "stacked": $0.stacked,
                                                 "group": $0.group as Any] }]
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
