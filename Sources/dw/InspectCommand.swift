// `dw inspect <app>`: drives Inspector inside a running app from the terminal, including background apps
// (ControlCenter, the Dock) that the hotkey can't reach. Commands go through a Darwin notification for the app's pid
// (Tweaks/Inspector/Inspector.m, "dw inspect"); Inspector answers in the log.
import DynjectCore
import Foundation

let inspectUsage = """
usage: dw inspect <app> [--pick | --tree | --props | --stop]
       dw inspect --pid <pid> [--pick | --tree | --props | --stop]

  drives Inspector in a running app it's loaded into, also background apps (ControlCenter, the Dock, menu bar
  apps) that the ⌃⌥⌘ hotkey and the apple-menu item can't reach because they're never frontmost.

  (nothing)   open Inspector's panel in the app, on the app itself: its windows (menu bar items, panels) and menu
              bar, each a link into its views
  --pick      pick mode in the app: point at one of its windows and click to inspect it. a background app doesn't
              get the keyboard, so esc doesn't reach it there: end it with --stop
  --tree      print the app's status items (menu bar items, by autosave name) and its windows and their views
              (class, frame, hidden, identifiers, accessibility labels, layer class, the status item a window
              shows), no UI
  --props     --tree, plus every property the windows' own classes declare (below NSWindow), read with their
              getters: what tells one private window from another
  --stop      end pick mode and close the panel

  Inspector must be loaded in the app: `dw why inspector <app>` says what stops it.
"""

private enum InspectCommand: UInt64 { case open = 1, pick = 2, stop = 3, tree = 4, treeWithProperties = 5 }

func inspectCommand(_ args: [String]) {
    var command = InspectCommand.open
    var pid: pid_t?
    var positional: [String] = []
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--pick": command = .pick
        case "--tree": command = .tree
        case "--stop": command = .stop
        case "--props": command = .treeWithProperties
        case "--pid":
            guard i + 1 < args.count, let p = pid_t(args[i + 1]) else { fail("--pid needs a number\n\n\(inspectUsage)", 2) }
            pid = p
            i += 1
        case "--help", "-h", "help": print(inspectUsage); exit(0)
        case let a where a.hasPrefix("--"): fail("unknown option \(a)\n\n\(inspectUsage)", 2)
        case let a: positional.append(a)
        }
        i += 1
    }
    guard (pid != nil) != (positional.count == 1), positional.count <= 1 else { fail(inspectUsage, 2) }
    let app = runningApp(positional.first, pid: pid, usage: inspectUsage)

    requireInspector(in: app, marker: "dynject.inspect:v1", feature: "dw inspect")

    let ask = ProcessRequest(pid: app.pid, subsystem: "dynject.inspect")
    let prefix = "A \(ask.request) "
    ask.post("local.dynject.inspector.command.\(app.pid)", state: command.rawValue | (UInt64(ask.request) << 8))
    let isTree = command == .tree || command == .treeWithProperties
    ask.wait(prefix: prefix, timeout: isTree ? 10 : 3, quiet: isTree ? 0.4 : 0.1) { lines in
        isTree ? lines.contains { $0.hasPrefix(prefix + "end ") || $0.hasPrefix(prefix + "refused") } : !lines.isEmpty
    }
    let answers = ask.finish(prefix: prefix).map { String($0.dropFirst(prefix.count)) }
    guard let first = answers.first else {
        fail("no answer from Inspector in \(app.name) (pid \(app.pid)): Safe Mode or Shift at launch may have kept it out (dw why inspector \(app.bundleID))", 1)
    }
    if first.hasPrefix("refused") { fail("Inspector in \(app.name): \(first)", 1) }

    switch command {
    case .open: print("\(app.name): panel open, \(first.replacingOccurrences(of: "opened ", with: "")): use it there")
    case .pick: print("\(app.name): picking. point at one of its windows and click; `dw inspect \(positional.first ?? "--pid \(app.pid)") --stop` ends it")
    case .stop: print("\(app.name): stopped")
    case .tree, .treeWithProperties: print(DevTree.text(answers, app: "\(app.name) (\(app.bundleID), pid \(app.pid))"))
    }
}

/// Fails unless Inspector is loaded in `app` and the installed build has `marker` (is new enough for `feature`).
func requireInspector(in app: (pid: pid_t, name: String, bundleID: String), marker: String, feature: String) {
    let locations = TweakLocations.live()
    let manifests = TweakManifestLoader.load(directories: locations.manifestSearchDirectories).manifests
    let dylib = manifests.first { $0.id == "local.dynject.inspector" }?.dylib ?? TweakLocations.liveTweaksDirectory + "/libInspector.dylib"
    let file = locations.filePath(forDylib: dylib)
    let loaded = LsofDylibInspector().loadedDylibs(pids: [app.pid], candidates: [file])[app.pid]
    if let loaded, !loaded.contains(file) {
        fail("""
        Inspector isn't loaded in \(app.name) (pid \(app.pid)).
          dw why inspector \(app.bundleID)    says what stops it
        if it's the config: dw enable \(dylib) \(app.bundleID), then relaunch the app (killall it for ControlCenter or the Dock)
        """, 1)
    }
    if let data = try? Data(contentsOf: URL(fileURLWithPath: file), options: .mappedIfSafe),
       data.range(of: Data(marker.utf8)) == nil {
        fail("the installed Inspector is older than \(feature): reinstall it (dw tweak install Tweaks/Inspector), then relaunch \(app.name)", 1)
    }
}

/// The --tree answer as an indented outline.
enum DevTree {
    static func text(_ answers: [String], app: String) -> String {
        var out = ["\(app)"]
        for a in answers {
            let f = a.split(separator: " ", maxSplits: 2).map(String.init)
            switch f.first {
            case "W":
                out.append("")
                out.append("window " + (f.count > 2 ? f[1] + "  " + f[2] : a))
            case "S":
                out.append("status item " + a.dropFirst(2))
            case "C":
                out.append("scene " + a.dropFirst(2))
            case "D":
                out.append("    " + a.dropFirst(2))
            case "P" where f.count == 3:
                out.append("  · " + f[1] + " " + f[2])
            case "V" where f.count == 3:
                let depth = Int(f[1]) ?? 1
                out.append(String(repeating: "  ", count: depth) + f[2])
            case "end":
                out.append("")
                out.append(a.replacingOccurrences(of: "end ", with: "").replacingOccurrences(of: "=", with: " ") +
                           (a.contains(" cut") ? " (the rest left out)" : ""))
            default:
                out.append(a)
            }
        }
        return out.joined(separator: "\n")
    }
}
