// The respring end-to-end test (run it with scripts/respring-e2e.sh). It drives the REAL engine
// (Respringer + WorkspaceAppController + lsof) against two test apps built under .build/respring/e2e/, with a planner
// fed a FAKE config that gives those apps a test dylib. dynjectd isn't involved: the test passes the dylib through
// DYLD_INSERT_LIBRARIES in the open call's environment (Respringer.Settings.environment), as dynjectd would at exec.
//
// Safety: the planner only sees apps whose bundle lives under the test root, and every quit/open goes through
// `TestAppsOnly`, which aborts the run before acting on anything else (it also re-checks the pid's executable path).
import AppKit
import Darwin
import DynjectCore

setvbuf(stdout, nil, _IOLBF, 0)

guard CommandLine.arguments.count == 2 else {
    fputs("usage: RespringE2E <test root (.build/respring/e2e)>\n", stderr)
    exit(2)
}
let root = RespringPaths.normalized(URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path)
let plainID = "local.dynject.respring.e2e.plain"
let stubbornID = "local.dynject.respring.e2e.stubborn"
let testIDs: Set<String> = [plainID, stubbornID]
let plainURL = URL(fileURLWithPath: "\(root)/apps/RespringE2E Plain.app")
let stubbornURL = URL(fileURLWithPath: "\(root)/apps/RespringE2E Stubborn.app")
let dylib = "\(root)/tweaks/libRespringE2ETweak.dylib"
let markerLog = "\(root)/loaded.log"
let label = "e2e.tweak"
let quitTimeout: TimeInterval = 3
let stubbornQuitDelay: TimeInterval = 8 // RespringE2EQuitDelay in the stubborn app's Info.plist
let injectEnv = ["DYLD_INSERT_LIBRARIES": dylib, "RESPRING_E2E_LOG": markerLog]

func isOurs(_ path: String) -> Bool { RespringPaths.normalized(path).hasPrefix(root + "/") }

func executablePath(_ pid: Int32) -> String? { SystemProcessAncestry().executablePath(of: pid) }

// MARK: - Checks

struct Check { var name: String; var pass: Bool; var evidence: String }
var checks: [Check] = []
func check(_ name: String, _ pass: Bool, _ evidence: String) {
    checks.append(Check(name: name, pass: pass, evidence: evidence))
    print("  [\(pass ? "PASS" : "FAIL")] \(name) — \(evidence)")
}

let t0 = Date()
func stamp() -> String { String(format: "%6.2fs", Date().timeIntervalSince(t0)) }
func log(_ s: String) { print("\(stamp()) \(s)") }
/// Lets NSWorkspace's runningApplications catch up (a CLI has no run loop of its own).
func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; spin(0.2) }
    return cond()
}

// MARK: - Restricted sources and controller

/// The real NSWorkspace source, limited to apps under the test root.
struct TestAppsSource: RunningAppSource {
    func runningApps() -> [RunningApp] {
        spin(0.3)
        return WorkspaceRunningApps().runningApps().filter { isOurs($0.bundlePath) && alive($0.pid) }
    }
}

/// The real controller, refusing (by aborting the whole run) anything outside the test root.
final class TestAppsOnly: AppController {
    let real = WorkspaceAppController()
    private(set) var calls: [String] = []

    private func refuse(_ what: String) -> Never {
        fputs("ABORT: refused to \(what): not a test app under \(root)\n", stderr)
        exit(3)
    }

    func terminate(_ app: RunningApp, method: RespringQuitMethod) -> Bool {
        guard isOurs(app.bundlePath), testIDs.contains(app.bundleID), method == .terminate,
              let exe = executablePath(app.pid), isOurs(exe)
        else { refuse("quit \(app.bundleID) pid \(app.pid)") }
        calls.append("terminate \(app.bundleID) \(app.pid)")
        return real.terminate(app, method: method)
    }

    func isRunning(pid: Int32) -> Bool { real.isRunning(pid: pid) }

    func runningPIDs(bundleID: String) -> [Int32] {
        guard testIDs.contains(bundleID) else { return [] }
        return real.runningPIDs(bundleID: bundleID).filter { executablePath($0).map(isOurs) ?? false }
    }

    func open(bundleURL: URL, options: RespringOpenOptions) throws -> Int32 {
        guard isOurs(bundleURL.path) else { refuse("open \(bundleURL.path)") }
        calls.append("open \(bundleURL.lastPathComponent) env=\(options.environment?.keys.sorted() ?? []) activates=\(options.activates)")
        return try real.open(bundleURL: bundleURL, options: options)
    }

    func loadedDylibs(pid: Int32, candidates: [String]) -> Set<String>? { real.loadedDylibs(pid: pid, candidates: candidates) }

    func scheduleReopen(bundleURL: URL, afterExitOf pid: Int32, timeout: TimeInterval) throws {
        refuse("hand off \(bundleURL.path)") // no test app hosts this process
    }
}

let controller = TestAppsOnly()

/// Ends every test app still running (only processes whose executable is under the test root).
func cleanup() {
    for id in testIDs {
        for pid in controller.runningPIDs(bundleID: id) {
            if let r = NSRunningApplication(processIdentifier: pid), let exe = r.executableURL?.path, isOurs(exe) {
                _ = r.forceTerminate()
            }
            _ = waitFor(3) { !alive(pid) }
        }
    }
}

func realApps() -> Set<String> {
    Set(NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && !isOurs($0.bundleURL?.path ?? "") }
        .map { "\($0.bundleIdentifier ?? "?")#\($0.processIdentifier)" })
}

func lsofHas(_ pid: Int32) -> Bool { LoadedImageInspector.inspect(pids: [pid], dylibs: [dylib])[pid]?.contains(dylib) ?? false }

func markerPIDs() -> Set<Int32> {
    let text = (try? String(contentsOfFile: markerLog, encoding: .utf8)) ?? ""
    return Set(text.split(separator: "\n").compactMap { $0.hasPrefix("loaded pid ") ? Int32($0.dropFirst(11)) : nil })
}

// MARK: - Fake config and planner

let configAllow = """
dylib:\(dylib):deny
dylib-override:\(dylib):allow:local.dynject.respring.e2e
allow:RespringE2E
"""
let configDeny = """
dylib:\(dylib):deny
allow:RespringE2E
"""

func planner(_ text: String, since: Date?) -> RespringPlanner {
    RespringPlanner(config: EffectiveConfig(document: ConfigDocument(text: text)),
                    runningApps: TestAppsSource(), inspector: LsofDylibInspector(),
                    tweakLabels: [dylib: label], configEffectiveSince: since,
                    exclusions: .forCurrentProcess())
}

func engine(_ p: RespringPlanner, env: [String: String]?, verifyTimeout: TimeInterval = 5) -> Respringer {
    Respringer(controller: controller,
               settings: .init(quitTimeout: quitTimeout, verifyTimeout: verifyTimeout, environment: env,
                               tweakDylibs: p.tweakDylibs))
}

struct Timed { var phases: [(String, String, Date)] = [] }
func runLogged(_ e: Respringer, _ apps: [RespringCandidate], dryRun: Bool = false) -> ([RespringResult], Timed) {
    var timed = Timed()
    let results = e.run(apps, dryRun: dryRun) { p in
        let name = p.candidate.app.name
        let phase: String
        switch p.phase {
        case .quitting: phase = "quitting"
        case .waitingToQuit: return
        case .opening: phase = "opening"
        case .verifying: phase = "verifying"
        case let .finished(r): phase = "finished: \(r.summary(labels: [dylib: label]))"
        }
        timed.phases.append((name, phase, Date()))
        log("[\(p.index + 1)/\(p.total)] \(name): \(phase)")
    }
    return (results, timed)
}

func describe(_ c: RespringCandidate) -> String {
    "\(c.app.name) pid \(c.app.pid): expected \(c.expected.map { _ in label }), loaded \(c.loaded.map { $0.map { _ in label }.sorted() } ?? ["?"]), reasons [\(c.reasonSummary)], exclusion \(c.exclusion?.rawValue ?? "none")"
}

// MARK: - Run

let realBefore = realApps()
log("test root \(root)")
log("host exclusions (this process's ancestry): \(RespringExclusions.forCurrentProcess().hostBundlePaths.sorted())")
cleanup()
try? FileManager.default.removeItem(atPath: markerLog)

// 1. Launch both test apps WITHOUT the tweak, like apps that were running before a config change.
print("\n== 1. launch the test apps without the tweak")
let plain0 = try controller.open(bundleURL: plainURL, options: .init())
let stubborn0 = try controller.open(bundleURL: stubbornURL, options: .init())
spin(1.5)
check("test apps launched without the tweak", alive(plain0) && alive(stubborn0) && !lsofHas(plain0) && !lsofHas(stubborn0),
      "plain pid \(plain0), stubborn pid \(stubborn0); lsof: neither maps \((dylib as NSString).lastPathComponent)")
spin(1.1)
let configSince = Date() // the fake config "takes effect" after they launched

// 2. Pending detection with the fake config.
print("\n== 2. plan (fake config: the tweak is allowed for local.dynject.respring.e2e.*)")
let pA = planner(configAllow, since: configSince)
let planA = pA.plan()
planA.candidates.forEach { log(describe($0)) }
let missingOK = planA.candidates.count == 2 && planA.candidates.allSatisfy {
    $0.expected == [dylib] && $0.loaded == [] && $0.reasons.map(\.kind) == [.missing] && $0.selectedByDefault
}
check("pending: both apps 'missing \(label)'", missingOK, planA.candidates.map { "\($0.app.name): \($0.reasonSummary)" }.joined(separator: "; "))
let selA = planA.selection(RespringOptions(only: testIDs))
check("selection order (by name)", selA.apps.map(\.app.bundleID) == [plainID, stubbornID], selA.apps.map(\.app.name).joined(separator: " → "))
check("default selection equals --only (only test apps are visible)", planA.selection(RespringOptions()).apps.map(\.app.pid) == selA.apps.map(\.app.pid),
      "\(planA.defaultSelection.count) selected by default")

// 3. Dry run: nothing is touched.
print("\n== 3. dry run")
let callsBeforeDry = controller.calls.count
let (dry, _) = runLogged(engine(pA, env: injectEnv), selA.apps, dryRun: true)
let dryCalls = controller.calls.count - callsBeforeDry
check("dry run touches nothing", dry.map(\.outcome) == [.wouldRelaunch, .wouldRelaunch] && dryCalls == 0 && alive(plain0) && alive(stubborn0),
      "outcomes \(dry.map { $0.summary() }); controller calls during the dry run: \(dryCalls); both pids still alive")
let callsBeforeRun = controller.calls.count

// 4. Real respring: plain relaunched with the tweak, stubborn skipped after the timeout.
print("\n== 4. respring (quit timeout \(Int(quitTimeout)) s; stubborn app quits only \(Int(stubbornQuitDelay)) s after being asked)")
let (resB, timedB) = runLogged(engine(pA, env: injectEnv), selA.apps)
let plainR = resB.first { $0.candidate.app.bundleID == plainID }
let stubR = resB.first { $0.candidate.app.bundleID == stubbornID }
let plain1 = plainR?.newPID ?? -1
spin(0.5)
check("plain: relaunched, verified", plainR?.outcome == .relaunched && plainR?.verification?.ok == true && plain1 != plain0 && !alive(plain0) && alive(plain1),
      "\(plainR?.summary(labels: [dylib: label]) ?? "no result"); old pid \(plain0) gone: \(!alive(plain0))")
check("plain: new process really has the tweak", lsofHas(plain1) && markerPIDs().contains(plain1),
      "lsof maps it in pid \(plain1); constructor logged pids \(markerPIDs().sorted())")
let stubPhases = timedB.phases.filter { $0.0 == stubR?.candidate.app.name }
let waited = (stubPhases.last?.2).flatMap { end in stubPhases.first.map { end.timeIntervalSince($0.2) } } ?? -1
check("stubborn: skipped after the timeout, not reopened", stubR?.outcome == .didNotQuit(timeout: quitTimeout) && alive(stubborn0) && waited >= quitTimeout && waited < quitTimeout + 1.5
      && !controller.calls[callsBeforeRun...].contains { $0.contains("Stubborn") && $0.hasPrefix("open") },
      "\(stubR?.summary() ?? "no result"); waited \(String(format: "%.2f", waited)) s; pid \(stubborn0) still running")
check("order: plain before stubborn", resB.map(\.candidate.app.bundleID) == [plainID, stubbornID], resB.map(\.candidate.app.name).joined(separator: " → "))
let runOpens = controller.calls[callsBeforeRun...].filter { $0.hasPrefix("open") }
check("only plain reopened, in the background, with the test environment",
      runOpens == ["open RespringE2E Plain.app env=[\"DYLD_INSERT_LIBRARIES\", \"RESPRING_E2E_LOG\"] activates=false"],
      runOpens.joined(separator: "; "))
let stubGone = waitFor(stubbornQuitDelay + 4) { !alive(stubborn0) }
spin(2)
check("stubborn quits later on its own and is not reopened", stubGone && controller.runningPIDs(bundleID: stubbornID).isEmpty,
      "pid \(stubborn0) exited \(stubGone ? "at \(stamp())" : "never"); running instances now: \(controller.runningPIDs(bundleID: stubbornID))")

// 5. Re-plan: the relaunched app is up to date.
print("\n== 5. plan again")
let planC = pA.plan()
planC.candidates.forEach { log(describe($0)) }
check("after the respring: nothing pending", planC.candidates.map(\.app.pid) == [plain1] && planC.pending.isEmpty,
      planC.candidates.map(describe).joined(separator: "; "))

// 6. Updated: replace the dylib on disk (new inode, like an install) while the app runs.
print("\n== 6. replace the tweak dylib on disk")
spin(1.1)
let tmp = dylib + ".new"
try? FileManager.default.removeItem(atPath: tmp)
try FileManager.default.copyItem(atPath: dylib, toPath: tmp)
guard rename(tmp, dylib) == 0 else { fatalError("rename failed") }
let planD = pA.plan()
planD.candidates.forEach { log(describe($0)) }
let dReason = planD.candidates.first?.reasons
check("pending: 'updated \(label)'", dReason?.map(\.kind) == [.updated] && (dReason?.first?.date ?? .distantPast) > (planD.candidates.first?.app.launchDate ?? .distantFuture),
      planD.candidates.map(describe).joined(separator: "; "))
let (resD, _) = runLogged(engine(pA, env: injectEnv), planD.selection(RespringOptions(only: testIDs)).apps)
let plain2 = resD.first?.newPID ?? -1
check("updated app relaunched, verified", resD.count == 1 && resD[0].succeeded && plain2 != plain1 && !alive(plain1) && lsofHas(plain2),
      resD.map { $0.summary(labels: [dylib: label]) }.joined())
check("after the update respring: nothing pending", pA.plan().pending.isEmpty, "re-planned")

// 7. Unwanted: the config no longer gives the tweak; relaunch without it (as dynjectd would).
print("\n== 7. config now denies the tweak")
let pE = planner(configDeny, since: Date())
let planE = pE.plan()
planE.candidates.forEach { log(describe($0)) }
check("pending: 'unwanted \(label)'", planE.candidates.first?.reasons.map(\.kind) == [.unwanted] && planE.candidates.first?.expected == [],
      planE.candidates.map(describe).joined(separator: "; "))
let (resE, _) = runLogged(engine(pE, env: nil), planE.selection(RespringOptions(only: testIDs)).apps)
let plain3 = resE.first?.newPID ?? -1
check("unwanted tweak gone after relaunch, verified", resE.count == 1 && resE[0].succeeded && !lsofHas(plain3),
      resE.map { $0.summary(labels: [dylib: label]) }.joined())
let planE2 = pE.plan()
check("after it: nothing pending, no Dynject involvement", planE2.pending.isEmpty && planE2.candidates.allSatisfy { !$0.isInvolved },
      planE2.candidates.map(describe).joined(separator: "; "))

// 8. Verification failure: the config wants the tweak, but the relaunch doesn't get it.
print("\n== 8. relaunch that doesn't get the tweak (verification must fail)")
let pF = planner(configAllow, since: Date())
let planF = pF.plan()
let (resF, _) = runLogged(engine(pF, env: nil, verifyTimeout: 2), planF.selection(RespringOptions(only: testIDs)).apps)
let plain4 = resF.first?.newPID ?? -1
check("verification failure reported", resF.count == 1 && resF[0].outcome == .relaunched && resF[0].verification?.missing == [dylib] && !resF[0].succeeded
      && resF[0].summary(labels: [dylib: label]).contains("still missing \(label)"),
      resF.map { $0.summary(labels: [dylib: label]) }.joined() + "; pid \(plain4)")

// 9. Clean up and make sure nothing else was touched.
print("\n== 9. clean up")
cleanup()
spin(1)
let leftovers = testIDs.flatMap { controller.runningPIDs(bundleID: $0) }
check("no test app left running", leftovers.isEmpty, "running test pids: \(leftovers)")
let quitCalls = controller.calls.filter { $0.hasPrefix("terminate") }
check("every quit went to a test app", quitCalls.allSatisfy { c in testIDs.contains { c.hasPrefix("terminate \($0) ") } },
      "\(quitCalls.count) quit requests: " + quitCalls.joined(separator: "; "))
let realAfter = realApps()
check("no real app quit during the test", realBefore.subtracting(realAfter).isEmpty,
      "regular apps before \(realBefore.count), after \(realAfter.count); gone: \(realBefore.subtracting(realAfter).sorted()); new: \(realAfter.subtracting(realBefore).sorted())")

let failed = checks.filter { !$0.pass }
print("\n\(checks.count - failed.count) of \(checks.count) checks passed (\(stamp()))")
exit(failed.isEmpty ? 0 : 1)
