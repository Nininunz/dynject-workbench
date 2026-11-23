// `dw respring`: relaunch running apps whose tweaks are out of date (docs/respring.md). Reads the config, the log,
// the manifests and Safe Mode's state; never writes any of them and never needs admin rights.
import DynjectCore
import Foundation

let respringUsage = """
usage: dw respring [--dry-run] [--all] [--system] [--include <bundleID>]... [--exclude <bundleID>]... [--timeout <seconds>] [--verbose]
       dw respring --only <bundleID>... [--dry-run] [--timeout <seconds>]

  Relaunches running apps whose injected tweaks don't match the config: a dylib that should be loaded and isn't,
  one that is loaded and no longer allowed, one replaced on disk since the app launched, or a Safe Mode change
  since launch. Apps are quit politely (an app that doesn't quit within the timeout is skipped), reopened in the
  background, and checked with lsof.

  --dry-run          print the plan only; nothing is quit or opened
  --all              every running app (Finder too), not just pending ones
  --system           also macOS's UI agents that tweaks can be in: the Dock, Control Center, the menu bar
                     (MenuBarAgent), SystemUIServer, Notification Center. they're quit with SIGTERM, like killall,
                     and launchd starts them again (never opened by dw); the screen flickers while they restart.
                     naming one with --only or --include brings it in too
  --include ID       also relaunch this app (even a terminal, editor, Workbench, or one that is up to date)
  --exclude ID       never relaunch this app
  --only ID          relaunch just this app (repeatable), pending or not; nothing else is considered
  --timeout S        seconds an app gets to quit (default 15)
  --verbose          also list apps that are up to date

  Left out unless named with --include: the app running dw (and its terminal or editor), terminals and editors,
  Dynject Workbench (relaunched last), and Finder (also brought in by --all).
"""

struct RespringArguments {
    var dryRun = false
    var verbose = false
    var options = RespringOptions()
    var timeout: TimeInterval = 15

    init(_ args: [String]) {
        var i = 0
        func value(_ flag: String) -> String {
            guard i + 1 < args.count else { fail("\(flag) needs a value\n\n\(respringUsage)", 2) }
            i += 1
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--dry-run", "-n": dryRun = true
            case "--all": options.all = true
            case "--system": options.system = true
            case "--verbose", "-v": verbose = true
            case "--include": options.include.formUnion(value("--include").split(separator: ",").map(String.init))
            case "--exclude": options.exclude.formUnion(value("--exclude").split(separator: ",").map(String.init))
            case "--only": options.only = (options.only ?? []).union(value("--only").split(separator: ",").map(String.init))
            case "--timeout":
                let v = value("--timeout")
                guard let t = TimeInterval(v), t > 0 else { fail("--timeout needs a positive number of seconds", 2) }
                timeout = t
            case "--help", "-h", "help": print(respringUsage); exit(0)
            default: fail("unknown argument \(args[i])\n\n\(respringUsage)", 2)
            }
            i += 1
        }
        if options.only != nil, options.all || !options.include.isEmpty {
            fail("--only can't be combined with --all or --include", 2)
        }
    }
}

private let clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

private let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d HH:mm"
    return f
}()

func respringTime(_ d: Date?) -> String {
    guard let d else { return "?" }
    return Calendar.current.isDateInToday(d) ? clockFormatter.string(from: d) : dayFormatter.string(from: d)
}

func respringCommand(_ args: [String]) {
    let a = RespringArguments(args)
    guard let configData = FileManager.default.contents(atPath: configPath) else { fail("can't read \(configPath)") }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Dynject Workbench", isDirectory: true)
    let manifests = TweakManifestLoader.load(directories: TweakManifestLoader.defaultDirectories(supportDirectory: support)).manifests
    let daemon = DaemonInspector.status(configPath: configPath)
    let planner = RespringPlanner.live(
        configText: String(decoding: configData, as: UTF8.self), configPath: configPath,
        logText: DynjectLogParser.readTail(path: logPath), manifests: manifests,
        safeModeState: SafeModeStateStore().load(), daemon: daemon,
        runningApps: WorkspaceRunningApps(includeSystemAgents: a.options.listsSystemAgents))
    let plan = planner.plan()
    let selection = plan.selection(a.options)

    if let m = daemon.configModified { print("config written \(respringTime(m))", terminator: "") }
    if let s = planner.configEffectiveSince { print("; in effect since \(respringTime(s))", terminator: "") }
    print("; \(plan.candidates.count) apps running")
    if daemon.needsRestart {
        print("warning: dynjectd needs a restart (\(daemon.isDuplicated ? "more than one is running" : "it predates the config")); "
              + "relaunched apps would still get the old set")
    }

    func line(_ c: RespringCandidate) -> String {
        "\(c.app.name) (\(c.app.bundleID), pid \(c.app.pid), launched \(respringTime(c.app.launchDate)))"
    }
    func reasons(_ c: RespringCandidate) -> String {
        c.reasons.map { r in
            r.kind == .updated ? "\(r.summary) (file changed \(respringTime(r.date)))" : r.summary
        }.joined(separator: "; ")
    }

    print("")
    let pending = plan.pending
    print(pending.isEmpty ? "Pending: none" : "Pending (\(pending.count)):")
    for c in pending {
        print("  \(line(c))")
        print("      \(reasons(c))")
    }

    print("")
    if selection.apps.isEmpty {
        print("Relaunch: nothing")
    } else {
        print("Relaunch, in this order (\(selection.apps.count)):")
        for (i, c) in selection.apps.enumerated() {
            var why = c.isPending ? reasons(c) : "up to date"
            if c.hostsCaller { why += "; runs dw, so a detached helper reopens it" }
            print("  \(i + 1). \(c.app.name) (\(c.app.bundleID)) — \(why)")
        }
    }
    if !selection.skipped.isEmpty {
        print("")
        print("Not relaunched:")
        for s in selection.skipped {
            let c = s.candidate
            let state = c.isPending ? reasons(c) : "up to date"
            let hint = (c.exclusion?.canBeSelected ?? false) && s.why != "excluded with --exclude" ? " (--include \(c.app.bundleID))" : ""
            print("  \(c.app.name) (\(c.app.bundleID)): \(state) — \(s.why)\(hint)")
        }
    }
    for id in selection.notRunning { print("note: \(id) is not running") }
    let blind = plan.notInspected
    if !blind.isEmpty {
        print("")
        print("Couldn't inspect with lsof (state unknown): " + blind.map(\.app.name).joined(separator: ", "))
    }
    if a.verbose {
        let fine = plan.candidates.filter { !$0.isPending && $0.isInspected }
        print("")
        print("Up to date (\(fine.count)):")
        for c in fine {
            let tweaks = c.expected.map(planner.label).joined(separator: ", ")
            print("  \(c.app.name) (\(c.app.bundleID))" + (tweaks.isEmpty ? "" : " — \(tweaks)"))
        }
    }

    guard !a.dryRun else {
        print("")
        print("dry run: nothing was quit or opened")
        return
    }
    guard !selection.apps.isEmpty else { return }

    print("")
    let engine = Respringer(controller: WorkspaceAppController(),
                            settings: .init(quitTimeout: a.timeout, tweakDylibs: planner.tweakDylibs))
    var lastWait: [Int32: Int] = [:]
    let results = engine.run(selection.apps) { p in
        let name = p.candidate.app.name
        switch p.phase {
        case .quitting: print("[\(p.index + 1)/\(p.total)] \(name): quitting…")
        case let .waitingToQuit(elapsed):
            let s = Int(elapsed)
            if s > 0, s % 5 == 0, lastWait[p.candidate.app.pid] != s {
                lastWait[p.candidate.app.pid] = s
                print("    still running after \(s) s…")
            }
        case .opening: print("    opening in the background…")
        case .waitingForLaunchd: print("    waiting for launchd to start it again…")
        case .verifying: print("    checking its tweaks…")
        case let .finished(r): print("    \(r.summary(labels: planner.tweakLabels))")
        }
    }
    let failed = results.filter { !$0.succeeded }
    print("")
    print("done: \(results.count - failed.count) of \(results.count) relaunched as expected")
    if results.contains(where: { if case .didNotQuit = $0.outcome { return true } else { return false } }) {
        print("note: an app that didn't quit in time was left as it is; if it quits later, it isn't reopened")
    }
    if !failed.isEmpty { exit(1) }
}
