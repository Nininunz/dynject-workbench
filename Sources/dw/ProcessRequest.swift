// Asking a running process something: a Darwin notification whose state carries the request, answered by the
// process in the unified log. Used by `dw hooks` (DynjectHook's reports) and `dw inspect` (Inspector's commands).
import AppKit
import DynjectCore
import Foundation
import notify

final class ProcessRequest {
    let pid: pid_t
    let request = UInt32.random(in: 1...UInt32.max)
    private let stream = Process()
    private let lock = NSLock()
    private var lines: [String] = []
    private var ready = false
    private var partial = ""
    private var asked = Date()
    private let predicate: String
    /// Whether the answer is in the log store too (default level); debug-level answers are only streamed.
    private let stored: Bool

    /// Starts listening to `subsystem` in `pid`'s log; returns once `log stream` is connected. `transient`: the
    /// process answers at debug level, which is never stored, so `finish` doesn't look in the store.
    init(pid: pid_t, subsystem: String, transient: Bool = false) {
        self.pid = pid
        stored = !transient
        predicate = "subsystem == \"\(subsystem)\" AND processID == \(pid)"
        stream.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        stream.arguments = ["stream", "--style", "compact", "--level", transient ? "debug" : "default", "--predicate", predicate]
        let pipe = Pipe()
        stream.standardOutput = pipe
        stream.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { h.readabilityHandler = nil; return }
            self.lock.lock()
            self.partial += String(decoding: data, as: UTF8.self)
            var chunk = self.partial.components(separatedBy: "\n")
            self.partial = chunk.removeLast()
            for line in chunk {
                if line.hasPrefix("Filtering the log data") { self.ready = true }
                if let l = WhyLogLine.parse(line).first { self.lines.append(l.message) }
            }
            self.lock.unlock()
        }
        do { try stream.run() } catch { fail("can't run log stream: \(error.localizedDescription)") }
        let readyBy = Date().addingTimeInterval(3)
        while Date() < readyBy {
            lock.lock(); let r = ready; lock.unlock()
            if r { break }
            usleep(50_000)
        }
        usleep(300_000)   // log stream prints its header before it is connected
    }

    /// The lines of this request so far (those starting with `prefix`, e.g. "A 123 ").
    func messages() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    /// Posts `name` with `state` (which should carry `request`).
    func post(_ name: String, state: UInt64) {
        asked = Date().addingTimeInterval(-1)
        var token: Int32 = 0
        guard notify_register_check(name, &token) == UInt32(NOTIFY_STATUS_OK) else { stop(); fail("can't register \(name)") }
        notify_set_state(token, state)
        notify_post(name)
        notify_cancel(token)
    }

    /// Polls until `done` says the answer is complete and no new line with `prefix` came for `quiet` seconds, or the
    /// deadline passes.
    func wait(prefix: String, timeout: TimeInterval, quiet: TimeInterval = 0.4, done: ([String]) -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = 0
        var last = Date()
        while Date() < deadline {
            usleep(100_000)
            let mine = messages().filter { $0.hasPrefix(prefix) }
            if mine.count != seen { seen = mine.count; last = Date() }
            if done(mine) && Date().timeIntervalSince(last) >= quiet { return }
        }
    }

    /// Stops listening and returns the request's lines: from the stream, or from the log store when that has more
    /// (a stream can miss the first lines a process logs after it starts listening; they're stored all the same).
    func finish(prefix: String) -> [String] {
        stop()
        let streamed = messages().filter { $0.hasPrefix(prefix) }
        guard stored else { return streamed }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let shown = try? ProcessRunner.run("/usr/bin/log", ["show", "--style", "compact", "--start", f.string(from: asked),
                                                                  "--predicate", predicate]) else { return streamed }
        let stored = WhyLogLine.parse(shown.stdout).map(\.message).filter { $0.hasPrefix(prefix) }
        return stored.count > streamed.count ? stored : streamed
    }

    func stop() {
        if stream.isRunning { stream.terminate() }
    }
}

/// A running app named on the command line (bundle ID, name, executable name or .app path), or --pid.
func runningApp(_ arg: String?, pid: pid_t?, usage: String) -> (pid: pid_t, name: String, bundleID: String) {
    if let p = pid {
        if let app = NSRunningApplication(processIdentifier: p) { return (p, app.localizedName ?? "pid \(p)", app.bundleIdentifier ?? "?") }
        if kill(p, 0) != 0 { fail("no process \(p)", 2) }
        return (p, "pid \(p)", "?")
    }
    guard let arg else { fail(usage, 2) }
    var id = arg
    if case let .success(app) = WhyLookup.app(arg, apps: AppDiscovery.scan(roots: AppDiscovery.defaultRoots)) { id = app.bundleID }
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
    guard let app = running.first else { fail("\(arg) isn't running (\(id))", 2) }
    if running.count > 1 { print("note: \(running.count) copies are running; using pid \(app.processIdentifier)") }
    return (app.processIdentifier, app.localizedName ?? id, id)
}
