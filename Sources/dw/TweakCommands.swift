// `dw tweak install|uninstall|list` and `dw new`: one-step install of a built tweak folder, and a starter template.
// The planning and writing is DynjectCore's TweakInstaller, which Workbench's Tweaks page uses too.
import DynjectCore
import Foundation

let tweakUsage = """
usage:
  dw tweak install <folder|manifest.workbench.plist> [--for <bundleID>]... [--dylib <built.dylib>] [--dry-run]
  dw tweak uninstall <tweakID|manifest.workbench.plist> [--keep-file] [--dry-run]
  dw tweak list
  dw new <Name> [--id <reverse.dns.id>] [--app <bundleID>] [--dir <path>] [--sdk <dir>]

  install    copies the built dylib (build/<name> or next to the manifest) to the manifest's install path in
             /opt/dynject/lib/tweaks, declares it in dynjectd.conf (deny by default), enables it for each --for app
             (repeatable, or comma-separated), restarts dynjectd: one administrator prompt. Then copies the manifest
             to ~/Library/Application Support/Dynject Workbench/Tweaks/. Running it again after a rebuild replaces
             the dylib (backed up first).
  uninstall  removes the tweak's dylib: and dylib-override: lines, deletes the dylib (not with --keep-file),
             restarts dynjectd (one prompt), then deletes its manifest and Safe Mode entries. Its settings stay.
  list       installed manifests: dylib, whether the file exists, config policy, Safe Mode support.
  new        a ready-to-build tweak folder (default ./<Name>) with the SDK vendored in.

  --dry-run   print the plan; change nothing
  --root DIR  (testing) use DIR/etc/dynjectd.conf, DIR/lib/tweaks, DIR/Tweaks and a Safe Mode file in DIR;
              restarts are simulated and no administrator prompt can appear
"""

struct TweakArguments {
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    static let valued: Set<String> = ["--for", "--dylib", "--root", "--id", "--app", "--dir", "--sdk"]
    static let boolean: Set<String> = ["--dry-run", "--keep-file"]

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--help" || a == "-h" {
                print(tweakUsage)
                exit(0)
            } else if Self.valued.contains(a) {
                guard i + 1 < args.count else { fail("\(a) needs a value\n\n\(tweakUsage)", 2) }
                values[a, default: []].append(args[i + 1])
                i += 2
            } else if Self.boolean.contains(a) {
                flags.insert(a)
                i += 1
            } else if a.hasPrefix("--") {
                fail("unknown option \(a)\n\n\(tweakUsage)", 2)
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func value(_ key: String) -> String? { values[key]?.last }
    var dryRun: Bool { flags.contains("--dry-run") }

    var root: URL? {
        value("--root").map { p in
            let e = (p as NSString).expandingTildeInPath
            let abs = e.hasPrefix("/") ? e : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(e)
            return URL(fileURLWithPath: (abs as NSString).standardizingPath, isDirectory: true)
        }
    }
}

/// Live paths, or everything under --root with simulated restarts and no privileges.
struct TweakContext {
    var locations: TweakLocations
    var writer: ProtectedFileWriter
    var restarter: DaemonRestarter
    var safeMode: SafeMode
    var logPath: String
    var simulated: Bool

    init(_ a: TweakArguments, what: String) {
        if let root = a.root {
            locations = .sandbox(root: root)
            writer = ProtectedFileWriter(backups: BackupStore(root: root.appendingPathComponent("Backups")),
                                         executor: NoPrivilegesExecutor(), removableDirectory: locations.dylibFileDirectory)
            restarter = SimulatedRestarter()
            safeMode = SafeMode(keys: SafeModeKeyStore(store: FileTweakBackend(path: root.appendingPathComponent("safemode-prefs.plist").path),
                                                       names: .forDomain(SafeModeNames.testDomain)),
                                stateStore: SafeModeStateStore(directory: root.appendingPathComponent("SafeMode")))
            let rootLog = root.appendingPathComponent("log/dynjectd.log").path
            logPath = FileManager.default.fileExists(atPath: rootLog) ? rootLog : "/opt/dynject/log/dynjectd.log"
            simulated = true
        } else {
            locations = .live()
            let exec = PromptedExecutor(what: what)
            writer = ProtectedFileWriter(backups: BackupStore(root: BackupStore.defaultRoot), executor: exec)
            restarter = PrivilegedRestarter(executor: exec)
            safeMode = .live()
            logPath = "/opt/dynject/log/dynjectd.log"
            simulated = false
        }
    }
}

/// --root: files under the root are writable, so nothing should need privileges; refuse if something does.
struct NoPrivilegesExecutor: PrivilegedExecutor {
    func run(_ arguments: [String], prompt: String) throws -> String {
        throw WriteError.helperFailed("--root never asks for administrator rights, but a file under the root isn't writable.")
    }
}

func tweakCommand(_ args: [String]) {
    let a = TweakArguments(args)
    let p = a.positional
    switch (p.first, p.count) {
    case ("install", 2): tweakInstall(p[1], a)
    case ("uninstall", 2): tweakUninstall(p[1], a)
    case ("list", 1): tweakList(a)
    default:
        print(tweakUsage)
        exit(p.isEmpty ? 0 : 2)
    }
}

func printLines(_ lines: [String], prefix: String = "  ") {
    for l in lines { print(prefix + l) }
}

func tweakInstall(_ path: String, _ a: TweakArguments) {
    let bundleIDs = (a.values["--for"] ?? []).flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        .filter { !$0.isEmpty }
    do {
        let source = try TweakSource.locate(path, dylib: a.value("--dylib"))
        let ctx = TweakContext(a, what: "install \(source.manifest.name)")
        var targets: [InjectionTarget] = []
        if !bundleIDs.isEmpty {
            let log = DynjectLogParser.parse(DynjectLogParser.readTail(path: ctx.logPath) ?? "")
            targets = AppDiscovery.scan(roots: AppDiscovery.defaultRoots).map {
                InjectionTarget(app: $0, service: ServiceNameResolver.resolve($0, log: log).value)
            }
        }
        let plan = try TweakInstaller.plan(source: source, enableFor: bundleIDs, targets: targets, locations: ctx.locations)
        print("\(plan.manifest.name) (\(plan.manifest.id)\(plan.manifest.version.map { " v\($0)" } ?? "")) from \(source.manifestPath)")
        printLines(plan.summary)
        printLines(plan.warnings, prefix: "  warning: ")
        printLines(plan.notes, prefix: "  note: ")
        if plan.changesNothing { print("Nothing to do: it is already installed like this."); return }
        if a.dryRun { print("Dry run: nothing was changed."); return }
        if plan.needsPrivilegedStep && !ctx.simulated { print("Asking for your password once for the steps above…") }

        let result = try TweakInstaller.execute(plan, writer: ctx.writer, restarter: ctx.restarter)
        if let o = result.outcome {
            for (path, url) in o.backups.sorted(by: { $0.key < $1.key }) { print("backed up \(path) to \(url.path)") }
            if let r = o.restart {
                print(r.simulated ? "dynjectd restart simulated (--root)" : "dynjectd restarted: now \(r.after.map(String.init).joined(separator: " "))")
            }
        }
        if result.manifestWritten { print("manifest installed: \(plan.manifestDestination)") }
        printLines(result.problems, prefix: "warning: ")
        if ctx.locations.isLive { republishAppleMenu(ctx.locations) }
        let apps = plan.enabledFor + plan.alreadyEnabledFor
        print("""
        Installed \(plan.manifest.name). Apps load tweaks only at launch: relaunch \(apps.isEmpty ? "the apps you enable it for" : apps.map(\.displayName).joined(separator: ", ")) \
        with `dw respring` (or Workbench → Respring…).
        """)
        if apps.isEmpty && plan.declares {
            print("It is declared but enabled nowhere yet: add --for <bundleID>, or use Workbench → Apps & Injection.")
        }
    } catch {
        fail(error.localizedDescription)
    }
}

func tweakUninstall(_ tweak: String, _ a: TweakArguments) {
    let ctx = TweakContext(a, what: "uninstall \(tweak)")
    do {
        let plan = try TweakInstaller.planUninstall(tweak, keepFile: a.flags.contains("--keep-file"), locations: ctx.locations,
                                                    safeMode: ctx.safeMode)
        print("\(plan.name) (\(plan.tweakID)), dylib \(plan.dylibInstallPath)")
        printLines(plan.summary)
        if a.dryRun { print("Dry run: nothing was changed."); return }
        if plan.needsPrivilegedStep && !ctx.simulated { print("Asking for your password once for the steps above…") }
        let result = try TweakInstaller.executeUninstall(plan, writer: ctx.writer, restarter: ctx.restarter, safeMode: ctx.safeMode)
        if let o = result.outcome {
            for (path, url) in o.backups.sorted(by: { $0.key < $1.key }) { print("backed up \(path) to \(url.path)") }
            if let r = o.restart {
                print(r.simulated ? "dynjectd restart simulated (--root)" : "dynjectd restarted: now \(r.after.map(String.init).joined(separator: " "))")
            }
        }
        printLines(result.problems, prefix: "warning: ")
        if ctx.locations.isLive { republishAppleMenu(ctx.locations) }
        print("Uninstalled \(plan.name). Apps that loaded it keep it until they quit: `dw respring` relaunches them. Its settings (dynject.tweak.\(plan.tweakID)) are kept.")
    } catch {
        fail(error.localizedDescription)
    }
}

func tweakList(_ a: TweakArguments) {
    let ctx = TweakContext(a, what: "list")
    let (tweaks, issues, unmanifested) = TweakInstaller.list(locations: ctx.locations)
    if tweaks.isEmpty { print("No tweak manifests in \(ctx.locations.manifestSearchDirectories.joined(separator: " or ")).") }
    for t in tweaks {
        let support: String
        switch t.safeMode {
        case nil: support = "unknown (dylib unreadable)"
        case .unsupported?: support = "no (not built on DynjectHook)"
        case .perTweak?: support = "per tweak only (older DynjectHook; ignores the panic switch)"
        case .perTweakAndPanic?: support = "yes"
        }
        print("\(t.manifest.name)  \(t.manifest.id)\(t.manifest.version.map { "  v\($0)" } ?? "")")
        print("  dylib      \(t.manifest.dylib)\(t.fileExists ? "" : "  (MISSING)")")
        print("  config     \(t.policy)")
        print("  Safe Mode  \(support)")
        print("  manifest   \(t.manifest.sourcePath)")
    }
    if !unmanifested.isEmpty {
        print("In the config without a manifest:")
        printLines(unmanifested)
    }
    for i in issues { print("\(i.severity == .error ? "error" : "warning"): \(i.file): \(i.message)") }
}

func newTweak(_ args: [String]) {
    let a = TweakArguments(args)
    guard a.positional.count == 1 else { print(tweakUsage); exit(a.positional.isEmpty ? 0 : 2) }
    do {
        let template = try TweakTemplate(name: a.positional[0], identifier: a.value("--id"), bundleID: a.value("--app"))
        let sdk: TweakSDKFiles?
        if let dir = a.value("--sdk") {
            sdk = TweakSDKFiles.at(URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
            if sdk == nil { fail("\(dir) doesn't hold DynjectHook.h, DynjectHook.m and DynjectTweak.h") }
        } else {
            sdk = TweakSDKFiles.locate(executable: URL(fileURLWithPath: CommandLine.arguments[0]))
            if sdk == nil {
                fail("can't find the tweak SDK next to this dw (Dynject Workbench.app/Contents/Resources/TweakSDK or the repository's TweakSDK/); pass --sdk <dir>")
            }
        }
        let dirPath = ((a.value("--dir") ?? template.name) as NSString).expandingTildeInPath
        let dir = URL(fileURLWithPath: dirPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            .standardizedFileURL
        let files = try template.write(to: dir, sdk: sdk!)
        print("Created \(dir.path):")
        printLines(files)
        let rel = a.value("--dir") ?? template.name
        print("""

        Next:
          cd \(shellQuote(rel)) && ./build.sh
          dw tweak install . --for \(template.bundleID ?? "<bundleID>")
          dw respring
        """)
    } catch {
        fail(error.localizedDescription)
    }
}


/// Republishes MenuLoader's list after an install or uninstall, as Workbench would on Reload: the same manifests,
/// the same publisher, and Workbench's saved Apple-menu preferences (per-tweak "Show in Apple menu", placement).
/// Without this a tweak installed from the terminal gets no Apple-menu items until Workbench next reloads.
func republishAppleMenu(_ locations: TweakLocations) {
    let settings = MenuLoaderSettings.savedByWorkbench()
    let (manifests, _) = TweakManifestLoader.load(directories: locations.manifestSearchDirectories)
    do {
        if try MenuLoaderPublisher(store: CFPreferencesTweakBackend(), names: .production).publish(manifests, settings: settings) {
            print("apple menu: published the updated list (apps with MenuLoader update live)")
        }
    } catch {
        print("warning: apple menu not republished: \(error.localizedDescription); press Reload in Workbench")
    }
}
