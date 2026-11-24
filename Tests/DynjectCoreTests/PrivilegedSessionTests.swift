@testable import DynjectCore
import CryptoKit
import XCTest

/// The approval window's server, run as the current user in a temporary folder (its test hooks, like the helper's,
/// work only when it isn't root): one start for several steps, steps it doesn't do go to the fallback, end, idle.
final class PrivilegedSessionTests: XCTestCase {
    var root: URL!
    var tweaks: String { root.appendingPathComponent("tweaks").path }
    var config: String { root.appendingPathComponent("etc/dynjectd.conf").path }
    var sessionDir: String { root.appendingPathComponent("session").path }

    final class Fallback: PrivilegedExecutor, @unchecked Sendable {
        var calls: [[String]] = []
        func run(_ arguments: [String], prompt: String) throws -> String { calls.append(arguments); return "fallback\n" }
    }

    final class Counter: @unchecked Sendable { var starts = 0 }

    override func setUpWithError() throws {
        let tmp = try temporaryDirectory()
        root = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)!))
        try FileManager.default.createDirectory(atPath: tweaks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (config as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // The server and its idle timer both have the test's folder in their arguments.
        _ = try? ProcessRunner.run("/usr/bin/pkill", ["-9", "-f", sessionDir])
        try? FileManager.default.removeItem(at: root)
    }

    func session(idle: TimeInterval = 60, fallback: Fallback, counter: Counter) -> SessionExecutor {
        let env = ["DW_TEST_TWEAKS_DIR": tweaks, "DW_TEST_CONFIG": config]
        return SessionExecutor(fallback: fallback, directory: sessionDir, lockPath: root.appendingPathComponent("lock").path,
                               idle: idle, maximum: 600, tweaksDirectory: tweaks, configPath: config,
                               starter: { command, _ in
            counter.starts += 1
            var e = ProcessInfo.processInfo.environment
            e.merge(env) { _, new in new }
            let out = try ProcessRunner.run("/bin/sh", ["-c", command], environment: e)
            XCTAssertEqual(out.status, 0, out.stderr)
        })
    }

    func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The helper's arguments to create `target` with `data` (staged in the test folder).
    func install(_ target: String, _ data: Data, old: Data? = nil) throws -> [String] {
        let staged = root.appendingPathComponent("staged-\(UUID().uuidString)").path
        try data.write(to: URL(fileURLWithPath: staged))
        return ["install", target, staged, sha(data), old.map(sha) ?? "-"]
    }

    func testOneStartForSeveralStepsAndOthersGoToTheFallback() throws {
        let fallback = Fallback(), counter = Counter()
        let s = session(fallback: fallback, counter: counter)
        XCTAssertFalse(s.isAlive)

        let a = Data("dylib a".utf8), b = Data("dylib b".utf8), conf = Data("dylib:x:deny\n".utf8)
        let out = try s.run(try install(tweaks + "/libA.dylib", a), prompt: "test")
        XCTAssertTrue(out.contains("DW "), out)
        XCTAssertTrue(s.isAlive)
        _ = try s.run(try install(tweaks + "/libB.dylib", b) + install(config, conf), prompt: "test")
        _ = try s.run(["remove", tweaks + "/libA.dylib", sha(a)], prompt: "test")
        XCTAssertEqual(counter.starts, 1, "one password for all of them")
        XCTAssertEqual(fallback.calls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tweaks + "/libA.dylib"))
        XCTAssertEqual(FileManager.default.contents(atPath: tweaks + "/libB.dylib"), b)
        XCTAssertEqual(FileManager.default.contents(atPath: config), conf)

        // Not something the window does: asked for with a password (the fallback), not run.
        let elsewhere = root.appendingPathComponent("other.plist").path
        XCTAssertEqual(try s.run(try install(elsewhere, Data("x".utf8)), prompt: "test"), "fallback\n")
        XCTAssertEqual(try s.run(try install(tweaks + "/sub/libC.dylib", Data("x".utf8)), prompt: "test"), "fallback\n")
        XCTAssertEqual(fallback.calls.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere))

        // A failing step reports the helper's error.
        XCTAssertThrowsError(try s.run(try install(tweaks + "/libB.dylib", Data("new".utf8), old: Data("wrong".utf8)), prompt: "test")) {
            XCTAssertTrue("\($0.localizedDescription)".contains("changed on disk"), "\($0)")
        }

        try s.end()
        XCTAssertFalse(s.isAlive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir))
        _ = try s.run(try install(tweaks + "/libD.dylib", Data("d".utf8)), prompt: "test")
        XCTAssertEqual(counter.starts, 2, "a new window after end")
    }

    func testTheWindowClosesWhenIdle() throws {
        let s = session(idle: 2, fallback: Fallback(), counter: Counter())
        _ = try s.run(try install(tweaks + "/libA.dylib", Data("a".utf8)), prompt: "test")
        XCTAssertTrue(s.isAlive)
        Thread.sleep(forTimeInterval: 3.5)
        XCTAssertFalse(s.isAlive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir))
    }

    func testAllowedMatchesTheServer() {
        let t = "/opt/dynject/lib/tweaks", c = "/opt/dynject/etc/dynjectd.conf"
        XCTAssertTrue(SessionExecutor.allowed(["install", t + "/libX.dylib", "s", "n", "-", "restart"]))
        XCTAssertTrue(SessionExecutor.allowed(["install", c, "s", "n", "o", "remove", t + "/libY.dylib", "o"]))
        XCTAssertTrue(SessionExecutor.allowed(["restart"]))
        XCTAssertFalse(SessionExecutor.allowed([]))
        XCTAssertFalse(SessionExecutor.allowed(["install", "/etc/sudoers", "s", "n", "-"]))
        XCTAssertFalse(SessionExecutor.allowed(["install", t + "/../x.dylib", "s", "n", "-"]))
        XCTAssertFalse(SessionExecutor.allowed(["install", t + "/.hidden.dylib", "s", "n", "-"]))
        XCTAssertFalse(SessionExecutor.allowed(["install", t + "/libX.dylib", "s"]))
        XCTAssertFalse(SessionExecutor.allowed(["quit"]))
        XCTAssertFalse(SessionExecutor.allowed(["install", t + "/libX.dylib", "s\nrestart", "n", "-"]))
    }
}
