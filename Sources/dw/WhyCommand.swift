// `dw why <tweak> <app>`: why a tweak does or doesn't load into an app. The checks are DynjectCore's Why; this
// file parses flags and prints.
import DynjectCore
import Foundation

let whyUsage = """
usage: dw why <tweak> <app> [--minutes N] [--no-log] [--json]

  every check between the app launching and the tweak running, in the order they happen, and the first
  one that stops it: dynjectd, dynjectd.conf's gates, dylib rule and approval, dyld's architecture and signature
  checks, the tweak's own target apps (DH_CTOR), safe mode, its macos minimum, then the running app and
  what the tweak logged about it. read-only: no password, no writes, no app launched or quit.
  ✓ lets it through, ✗ stops it, ! may stop it, ? couldn't check, - context.

  <tweak>   tweak id, name or dylib file name (libOLEDFinder.dylib, OLEDFinder)
  <app>     bundle id, app name, executable name, or a .app path

  --minutes N   how far back to search the tweak's log (default 60)
  --no-log      don't search the log (it can take a few seconds)
  --json        {tweak, app, loads, verdict, steps: [{section, check, status, detail, fix}]}

  exit status: 0 when nothing stops it, 1 when something does, 2 for a usage error or no such tweak or app.
"""

func whyCommand(_ args: [String]) {
    var json = false, searchLog = true, minutes = 60
    var positional: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        i += 1
        switch a {
        case "--json": json = true
        case "--no-log": searchLog = false
        case "--minutes":
            guard i < args.count, let n = Int(args[i]), n > 0 else { fail("--minutes needs a positive number\n\n\(whyUsage)", 2) }
            minutes = n
            i += 1
        case "--help", "-h", "help": print(whyUsage); exit(0)
        default:
            if a.hasPrefix("--") { fail("unknown option \(a)\n\n\(whyUsage)", 2) }
            positional.append(a)
        }
    }
    guard positional.count == 2 else { fail(whyUsage, 2) }
    let inputs: WhyInputs
    switch WhyInputs.live(tweak: positional[0], app: positional[1], searchLog: searchLog, logMinutes: minutes) {
    case let .success(x): inputs = x
    case let .failure(e): fail(e.description, 2)
    }
    let report = Why.explain(inputs)
    if json {
        FileHandle.standardOutput.write(report.json())
        print("")
    } else {
        print(report.text(header: "dw why: \(report.tweak) in \(report.app)\n  \(inputs.dylibPath) → \(inputs.app.bundlePath)"))
    }
    exit(report.exitCode)
}
