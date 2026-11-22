// `dw dev [folder]`: the tweak development loop. Builds and tests the tweak, installs it, relaunches the apps it is
// for and shows its log; then does it again every time a source file changes. The decisions are DynjectCore's
// DevLoop; this file runs the steps (build.sh, `dw tweak install`, `dw respring --only`, `log stream`).
import AppKit
import CoreServices
import CryptoKit
import DynjectCore
import Foundation

let devUsage = """
usage: dw dev [<tweak folder>] [--for <bundleID>]... [--no-test] [--no-install] [--no-relaunch] [--no-log] [--once]

  the loop for working on a tweak: builds it (./build.sh), runs its test host if it has one (./build.sh test or
  testhost/run.sh), installs it (dw tweak install: one password prompt each time the dylib changes), relaunches the
  apps it is for, and shows its log as it comes. then it watches the folder and does it all again when you save a
  source file, the manifest or a build script. a failed build or test stops that round before anything is installed.
  ctrl-c to stop.

  <tweak folder>   default: the current directory. it needs a build.sh and a manifest (*.workbench.plist).
  --for ID         the app to install it for and relaunch (repeatable). default: the apps its DH_CTOR lists
  --no-test        skip the test host
  --no-install     build and test only
  --no-relaunch    install, but leave running apps alone
  --no-log         don't show the tweak's log
  --once           one round, then exit with its status (0: everything passed)
  --root DIR       (testing) install under DIR like `dw tweak install --root`; implies --no-relaunch
"""

private struct DevOptions {
    var folder = "."
    var apps: [String] = []
    var test = true, install = true, relaunch = true, showLog = true, once = false
    var root: String?

    init(_ args: [String]) {
        var i = 0
        var positional: [String] = []
        func value(_ flag: String) -> String {
            guard i + 1 < args.count else { fail("\(flag) needs a value\n\n\(devUsage)", 2) }
            i += 1
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--for": apps.append(value("--for"))
            case "--no-test": test = false
            case "--no-install": install = false
            case "--no-relaunch": relaunch = false
            case "--no-log": showLog = false
            case "--once": once = true
            case "--root": root = (value("--root") as NSString).expandingTildeInPath; relaunch = false
            case "--help", "-h", "help": print(devUsage); exit(0)
            case let a where a.hasPrefix("--"): fail("unknown option \(a)\n\n\(devUsage)", 2)
            case let a: positional.append(a)
            }
            i += 1
        }
        guard positional.count <= 1 else { fail(devUsage, 2) }
        if let f = positional.first { folder = f }
    }
}

/// Runs a command, output captured (stdout and stderr together).
private func devRun(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (127, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func devClock() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

private func devSeconds(_ start: Date) -> String { String(format: "%.1f s", Date().timeIntervalSince(start)) }

private func sha256(_ path: String) -> String? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}

/// Indents the last `n` lines of `text` for a failed step.
private func devTail(_ text: String, _ n: Int = 25) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
    return lines.suffix(n).map { "      " + $0 }.joined(separator: "\n")
}

private final class DevSession {
    let o: DevOptions
    let folder: String
    let manifest: TweakManifest
    let dylibName: String
    let locations: TweakLocations
    let dw: String
    let testCommand: DevLoop.TestCommand
    var running = false
    var again = false
    var firstRound = true
    var pendingChanges: [String] = []
    var debounce: DispatchWorkItem?
    var logProcess: Process?
    var stream: FSEventStreamRef?

    init(_ o: DevOptions) {
        self.o = o
        var resolved = (o.folder as NSString).expandingTildeInPath
        if !resolved.hasPrefix("/") { resolved = FileManager.default.currentDirectoryPath + "/" + resolved }
        resolved = (resolved as NSString).standardizingPath
        if let real = realpath(resolved, nil) { resolved = String(cString: real); free(real) }
        folder = resolved
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: folder + "/build.sh") else { fail("\(folder) has no executable build.sh", 2) }
        let manifests = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(TweakManifest.fileSuffix) }.sorted()
        guard let name = manifests.first, let data = fm.contents(atPath: folder + "/" + name) else {
            fail("\(folder) has no manifest (*\(TweakManifest.fileSuffix))", 2)
        }
        let (m, issues) = TweakManifestParser.parse(data: data, path: folder + "/" + name, fileExists: { _ in true })
        guard let m else { fail("\(name): \(issues.map(\.message).joined(separator: "; "))", 2) }
        manifest = m
        dylibName = (m.dylib as NSString).lastPathComponent
        locations = o.root.map { TweakLocations.sandbox(root: URL(fileURLWithPath: $0)) } ?? .live()
        dw = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        let script = (try? String(contentsOfFile: folder + "/build.sh", encoding: .utf8))
        testCommand = o.test ? DevLoop.testCommand(folder: folder, buildScript: script) : .none
    }

    var builtDylib: String { folder + "/build/" + dylibName }

    // MARK: one round

    /// Build, test, install, relaunch. Returns whether every step that ran passed.
    @discardableResult
    func round(_ reason: String) -> Bool {
        print("\n── \(devClock()) \(reason)")
        // build (+ test when build.sh runs the host)
        var start = Date()
        let buildArgs = testCommand == .buildTest ? ["test"] : []
        let build = devRun(folder + "/build.sh", buildArgs)
        let result = DevLoop.testResult(build.output)
        if build.status != 0 && (testCommand != .buildTest || result.passed == nil) {
            print("  build     ✗ \(devSeconds(start))\n\(devTail(build.output))")
            return false
        }
        if testCommand == .buildTest {
            print("  build     ✓")
            if !reportTest(result, status: build.status, output: build.output, start: start) { return false }
        } else {
            print("  build     ✓ \(devSeconds(start))")
            if testCommand == .runScript {
                start = Date()
                let run = devRun(folder + "/testhost/run.sh", [])
                if !reportTest(DevLoop.testResult(run.output), status: run.status, output: run.output, start: start) { return false }
            } else if o.test {
                print("  test      - no test host (testhost/run.sh, or build.sh test)")
            }
        }
        guard o.install else { return true }

        // install, unless the dylib is what's installed already
        // (The first round with --for always installs: the config may not enable it for those apps yet.)
        let installed = locations.filePath(forDylib: manifest.dylib)
        let first = firstRound
        firstRound = false
        if let new = sha256(builtDylib), new == sha256(installed), installedManifestCurrent(), o.apps.isEmpty || !first {
            print("  install   - unchanged, skipped")
        } else {
            start = Date()
            var args = ["tweak", "install", folder]
            for a in o.apps { args += ["--for", a] }
            if let r = o.root { args += ["--root", r] }
            if o.root == nil { print("  install   … (a password prompt: it writes to /opt/dynject)") }
            let inst = devRun(dw, args)
            guard inst.status == 0 else {
                print("  install   ✗ \(devSeconds(start))\n\(devTail(inst.output, 12))")
                return false
            }
            let line = inst.output.split(separator: "\n").map(String.init).first { $0.hasPrefix("Installed ") } ?? "installed"
            print("  install   ✓ \(devSeconds(start))  \(line.components(separatedBy: ". ").first ?? line)")
        }
        guard o.relaunch else { return true }
        return relaunch()
    }

    /// Whether the installed manifest (same file name, in Workbench's Tweaks folder) has the folder's bytes.
    func installedManifestCurrent() -> Bool {
        let mine = (try? FileManager.default.contentsOfDirectory(atPath: folder))?.sorted().first { $0.hasSuffix(TweakManifest.fileSuffix) }
        guard let mine, let a = FileManager.default.contents(atPath: folder + "/" + mine) else { return false }
        return FileManager.default.contents(atPath: locations.manifestsDirectory + "/" + mine) == a
    }

    func reportTest(_ r: DevLoop.TestResult, status: Int32, output: String, start: Date) -> Bool {
        if status == 0 && r.passed != false {
            print("  test      ✓ \(devSeconds(start))  \(r.summary ?? "passed")")
            return true
        }
        print("  test      ✗ \(devSeconds(start))  \(r.summary ?? "exit status \(status)")")
        print(r.failures.isEmpty ? devTail(output, 15) : r.failures.prefix(15).map { "      " + $0 }.joined(separator: "\n"))
        print("      (nothing installed; --no-test skips the test host)")
        return false
    }

    func relaunch() -> Bool {
        let markers = FileManager.default.contents(atPath: builtDylib).map(CtorMarker.markers(in:)) ?? []
        let apps: [String]
        switch DevLoop.targets(explicit: o.apps, markers: markers, tweakID: manifest.id) {
        case let .apps(ids): apps = ids
        case .everyApp:
            print("  relaunch  - it loads in every app: pass --for <bundleID> to choose which to relaunch")
            return true
        case .unknown:
            print("  relaunch  - its DH_CTOR doesn't say which apps it's for: pass --for <bundleID>")
            return true
        }
        var ok = true
        for id in apps {
            let start = Date()
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
            if running {
                let r = devRun(dw, ["respring", "--only", id])
                let last = r.output.split(separator: "\n").last.map(String.init) ?? ""
                print("  relaunch  \(r.status == 0 ? "✓" : "✗") \(devSeconds(start))  \(id): \(last)")
                ok = ok && r.status == 0
            } else {
                let r = devRun("/usr/bin/open", ["-g", "-b", id])
                print("  relaunch  \(r.status == 0 ? "✓" : "✗") \(devSeconds(start))  \(id) wasn't running: opened in the background")
                ok = ok && r.status == 0
            }
        }
        return ok
    }

    // MARK: log

    func startLog() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--level", "debug", "--predicate", "subsystem == \"\(manifest.id)\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var partial = ""
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            partial += String(decoding: data, as: UTF8.self)
            var lines = partial.components(separatedBy: "\n")
            partial = lines.removeLast()
            let text = lines.compactMap { line -> String? in
                guard let l = WhyLogLine.parse(line).first else { return nil }
                return "  log │ \(l.process): \(l.message)"
            }
            if !text.isEmpty { DispatchQueue.main.async { print(text.joined(separator: "\n")) } }
        }
        do { try p.run(); logProcess = p } catch { print("  log: can't start log stream: \(error.localizedDescription)") }
    }

    // MARK: watching

    func watch() {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<DevSession>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            me.changed(Array(list.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &ctx, [folder] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.2, flags) else { fail("can't watch \(folder)") }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    func changed(_ paths: [String]) {
        let relevant = paths.filter { DevLoop.isRelevant($0, folder: folder) }
        guard !relevant.isEmpty else { return }
        pendingChanges += relevant.map { String($0.dropFirst(folder.count + 1)) }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runPending() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func runPending() {
        if running { again = true; return }
        var names: [String] = []
        for n in pendingChanges where !names.contains(n) { names.append(n) }
        pendingChanges.removeAll()
        guard !names.isEmpty else { return }
        running = true
        let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
        round("changed: \(shown)")
        running = false
        print("  watching… (ctrl-c to stop)")
        if again { again = false; runPending() }
    }

    func stop() {
        logProcess?.terminate()
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s) }
    }
}

func devCommand(_ args: [String]) {
    // Line by line, also into a pipe or a file: it runs for a long time and people watch it.
    setvbuf(stdout, nil, _IOLBF, 0)
    let o = DevOptions(args)
    let session = DevSession(o)
    let targets = o.apps.isEmpty ? "" : ", for \(o.apps.joined(separator: ", "))"
    print("dw dev: \(session.manifest.name) (\(session.manifest.id)) in \(session.folder)\(targets)")
    if o.showLog && !o.once { session.startLog() }
    let ok = session.round("start")
    if o.once {
        session.stop()
        exit(ok ? 0 : 1)
    }
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler {
        session.stop()
        print("\nstopped")
        exit(0)
    }
    sigint.resume()
    session.watch()
    print("  watching… (ctrl-c to stop)")
    withExtendedLifetime(sigint) { dispatchMain() }
}
