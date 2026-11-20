// `dw doctor`: a read-only health check of a Dynject + Workbench setup, and `dw doctor --apis`, the private-API
// canary to run after a macOS update. The checks are DynjectCore's Doctor; this file parses flags and prints.
import DynjectCore
import Foundation

let doctorUsage = """
usage: dw doctor [--apis [--tweaks-dir D]...] [--json] [--quiet]

  checks the engine, the config, installed tweaks, the agents, the apple-menu list, running apps, safe mode
  and the workbench app. read-only: no password, no writes, no app launched or quit.
  ✓ ok, ! warning, ✗ problem; each warning and problem is followed by what to do.

  --apis     instead: check that the private classes, methods and functions every installed tweak declares
             (manifest key requires) and workbench's bridge broker use still exist on this macOS. loads the
             frameworks they name into dw. run it after a macOS update.
  --tweaks-dir D   with --apis: the manifests in D (repeatable) instead of the installed ones, e.g. to check a
             tweak folder before installing it
  --json     a json array of {section, check, status, detail, fix}
  --quiet    only warnings and problems

  exit status: 0 without problems (warnings allowed), 1 with problems.
"""

func doctorCommand(_ args: [String]) {
    var json = false, quiet = false, apis = false
    var tweakDirs: [String] = []
    var i = 0
    while i < args.count {
        let a = args[i]
        i += 1
        switch a {
        case "--tweaks-dir":
            guard i < args.count else { fail("--tweaks-dir needs a value\n\n\(doctorUsage)", 2) }
            tweakDirs.append((args[i] as NSString).expandingTildeInPath)
            i += 1
        case "--json": json = true
        case "--quiet", "-q": quiet = true
        case "--apis": apis = true
        case "--help", "-h", "help": print(doctorUsage); exit(0)
        default: fail("unknown argument \(a)\n\n\(doctorUsage)", 2)
        }
    }
    if !tweakDirs.isEmpty && !apis { fail("--tweaks-dir only goes with --apis", 2) }
    let report: DoctorReport
    let header: String
    if apis {
        let dirs = tweakDirs.isEmpty ? TweakLocations.live().manifestSearchDirectories : tweakDirs
        let manifests = TweakManifestLoader.load(directories: dirs).manifests
        let bridgeInUse = manifests.contains { !$0.bridge.isEmpty } || BridgeAgent().status().plistInstalled
        report = Doctor.apis(manifests: manifests, bridgeInUse: bridgeInUse)
        header = "dw doctor --apis: \(Doctor.macOSDescription), dw \(WorkbenchInfo.version)"
            + (tweakDirs.isEmpty ? "" : "; manifests in \(tweakDirs.joined(separator: ", "))")
    } else {
        report = Doctor.run(.live())
        header = "dw doctor: \(Doctor.macOSDescription), dw \(WorkbenchInfo.version)"
    }
    if json {
        FileHandle.standardOutput.write(report.json())
        print("")
    } else {
        let text = report.text(quiet: quiet, header: header)
        if !text.isEmpty { print(text) }
    }
    exit(report.exitCode)
}
