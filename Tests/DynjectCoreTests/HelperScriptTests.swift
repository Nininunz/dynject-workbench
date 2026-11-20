@testable import DynjectCore
import XCTest

/// Runs the real privileged helper script as the current user with stubbed pgrep/kill/launchctl/sleep.
/// The script only honours DW_TEST_BIN when it is NOT root, and these stubs never touch real processes.
final class HelperScriptTests: XCTestCase {
    var dir: URL!
    var bin: URL!
    var state: URL!

    override func setUpWithError() throws {
        dir = try temporaryDirectory()
        bin = dir.appendingPathComponent("bin")
        state = dir.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)

        stub("pgrep", #"""
        newest=0; name=""
        while [ $# -gt 0 ]; do case "$1" in -n) newest=1;; -x) shift; name=$1;; esac; shift; done
        f="$DW_STATE/$name.pids"
        [ -s "$f" ] || exit 1
        if [ $newest = 1 ]; then tail -n 1 "$f"; else cat "$f"; fi
        """#)
        stub("kill", #"""
        sig=$1; shift
        echo "kill $sig $*" >> "$DW_STATE/calls"
        for p in "$@"; do
          if [ "$sig" = "-TERM" ] && grep -qx "$p" "$DW_STATE/stubborn" 2>/dev/null; then continue; fi
          grep -vx "$p" "$DW_STATE/dynjectd.pids" > "$DW_STATE/tmp"; mv "$DW_STATE/tmp" "$DW_STATE/dynjectd.pids"
        done
        """#)
        stub("launchctl", #"""
        echo "launchctl $*" >> "$DW_STATE/calls"
        case "$1" in
          print) [ -f "$DW_STATE/job-loaded" ]; exit $? ;;
          kickstart|bootstrap)
            if [ "$2" = system/com.apple.MobileFileIntegrity ]; then
              [ -f "$DW_STATE/amfid-fails" ] || echo 900 > "$DW_STATE/amfid.pids"
              exit 0
            fi
            [ "$1" = bootstrap ] && touch "$DW_STATE/job-loaded"
            [ -f "$DW_STATE/start-fails" ] && exit 0
            n=$(cat "$DW_STATE/spawn-count" 2>/dev/null || echo 1)
            i=0
            while [ $i -lt $n ]; do
              p=$(cat "$DW_STATE/nextpid"); echo "$p" >> "$DW_STATE/dynjectd.pids"; echo $((p + 1)) > "$DW_STATE/nextpid"
              i=$((i + 1))
            done ;;
        esac
        exit 0
        """#)
        stub("sleep", "exit 0")
        write("nextpid", "50000\n")
        write("job-loaded", "")
        write("amfid.pids", "900\n")   // amfid awake unless a test says otherwise
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func stub(_ name: String, _ body: String) {
        let url = bin.appendingPathComponent(name)
        try! ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func write(_ name: String, _ text: String) {
        try! text.write(to: state.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func read(_ name: String) -> String {
        (try? String(contentsOf: state.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    var executor: LocalShellExecutor {
        LocalShellExecutor(environment: ["DW_TEST_BIN": bin.path, "DW_STATE": state.path,
                                         "DW_TEST_PLIST": dir.appendingPathComponent("job.plist").path])
    }

    var calls: [String] { read("calls").split(separator: "\n").map(String.init) }

    // MARK: restart

    func testRestartStartsAnIdleAmfidFirst() throws {
        // dynject_loader exits with "amfid not found" when launchd has stopped the idle amfid.
        write("amfid.pids", "")
        write("dynjectd.pids", "7237\n")
        let out = try executor.run(["restart"], prompt: "")
        XCTAssertTrue(out.contains("DW started amfid"), out)
        let c = calls
        let amfidStart = try XCTUnwrap(c.firstIndex(of: "launchctl kickstart system/com.apple.MobileFileIntegrity"))
        let stopOld = try XCTUnwrap(c.firstIndex { $0.hasPrefix("kill -TERM") })
        XCTAssertLessThan(amfidStart, stopOld, "amfid must be up before the old daemon is stopped")
        XCTAssertEqual(read("dynjectd.pids").split(separator: "\n").count, 1)
    }

    func testRestartLeavesTheDaemonRunningWhenAmfidWontStart() throws {
        write("amfid.pids", "")
        write("amfid-fails", "")
        write("dynjectd.pids", "7237\n")
        XCTAssertThrowsError(try executor.run(["restart"], prompt: "")) { error in
            XCTAssertTrue("\(error)".contains("amfid did not start"), "\(error)")
        }
        XCTAssertFalse(calls.contains { $0.hasPrefix("kill") }, "nothing may be stopped")
        XCTAssertEqual(read("dynjectd.pids"), "7237\n")
    }

    func testRestartStopsBothDetachedDaemonsAndStartsExactlyOne() throws {
        write("dynjectd.pids", "7237\n45044\n")      // the situation found on this machine
        let out = try executor.run(["restart"], prompt: "")
        let report = PrivilegedRestarter.report(from: out)
        XCTAssertEqual(report.before, [7237, 45044])
        XCTAssertEqual(report.after, [50000])
        XCTAssertEqual(read("dynjectd.pids"), "50000\n")
        XCTAssertEqual(calls, ["kill -TERM 7237 45044", "launchctl print system/com.dynject.dynjectd",
                               "launchctl kickstart system/com.dynject.dynjectd"])
        XCTAssertFalse(calls.contains { $0.contains("-k") }, "kickstart -k must never be used")
    }

    func testRestartEscalatesToSigkillForAStuckDaemon() throws {
        write("dynjectd.pids", "7237\n")
        write("stubborn", "7237\n")
        let out = try executor.run(["restart"], prompt: "")
        XCTAssertTrue(out.contains("DW sigkill 7237"))
        XCTAssertTrue(calls.contains("kill -KILL 7237"))
        XCTAssertEqual(PrivilegedRestarter.report(from: out).after, [50000])
    }

    func testRestartRefusesToStartWhileOldDaemonSurvives() throws {
        stub("kill", "echo \"kill $*\" >> \"$DW_STATE/calls\"")   // kill has no effect
        write("dynjectd.pids", "7237\n")
        XCTAssertThrowsError(try executor.run(["restart"], prompt: "")) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not stop dynjectd"))
        }
        XCTAssertFalse(calls.contains { $0.contains("kickstart") })
    }

    func testRestartRemovesDuplicatesThatAppearAfterStart() throws {
        write("spawn-count", "2\n")
        let out = try executor.run(["restart"], prompt: "")
        XCTAssertTrue(out.contains("duplicate-after-start keeping=50001"))
        XCTAssertEqual(read("dynjectd.pids"), "50001\n")
    }

    func testRestartReportsDaemonThatDoesNotStart() {
        write("start-fails", "")
        XCTAssertThrowsError(try executor.run(["restart"], prompt: "")) { error in
            XCTAssertTrue(error.localizedDescription.contains("did not start"))
        }
    }

    func testRestartBootstrapsAnUnloadedJob() throws {
        try FileManager.default.removeItem(at: state.appendingPathComponent("job-loaded"))
        try "plist".write(to: dir.appendingPathComponent("job.plist"), atomically: true, encoding: .utf8)
        _ = try executor.run(["restart"], prompt: "")
        XCTAssertTrue(calls.contains { $0.hasPrefix("launchctl bootstrap system ") })
        XCTAssertEqual(read("dynjectd.pids"), "50000\n")
    }

    func testRestartWaitsOutAnInFlightLoader() {
        write("dynject_loader.pids", "321\n")   // never exits
        XCTAssertThrowsError(try executor.run(["restart"], prompt: "")) { error in
            XCTAssertTrue(error.localizedDescription.contains("dynject_loader is still running"))
        }
        XCTAssertTrue(calls.isEmpty)
    }

    // MARK: install

    func testInstallReplacesAtomicallyAndKeepsMode() throws {
        let target = dir.appendingPathComponent("dynjectd.conf")
        try "old\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        let staged = dir.appendingPathComponent("staged")
        try "new\n".write(to: staged, atomically: true, encoding: .utf8)

        let out = try executor.run(["install", target.path, staged.path, sha256Hex(Data("new\n".utf8)),
                                    sha256Hex(Data("old\n".utf8))], prompt: "")
        XCTAssertTrue(out.contains("DW installed"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new\n")
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o640)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".dw.") }, [])
    }

    func testInstallRefusesWhenTargetChangedOnDisk() throws {
        let target = dir.appendingPathComponent("dynjectd.conf")
        try "someone else edited\n".write(to: target, atomically: true, encoding: .utf8)
        let staged = dir.appendingPathComponent("staged")
        try "new\n".write(to: staged, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try executor.run(["install", target.path, staged.path, sha256Hex(Data("new\n".utf8)),
                                               sha256Hex(Data("old\n".utf8))], prompt: ""))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "someone else edited\n")
    }

    func testInstallRefusesWhenStagedContentWasSwapped() throws {
        let target = dir.appendingPathComponent("dynjectd.conf")
        try "old\n".write(to: target, atomically: true, encoding: .utf8)
        let staged = dir.appendingPathComponent("staged")
        try "evil\n".write(to: staged, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try executor.run(["install", target.path, staged.path, sha256Hex(Data("new\n".utf8)), "-"],
                                              prompt: "")) { error in
            XCTAssertTrue(error.localizedDescription.contains("staged content changed"))
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "old\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".dw.") }, [])
    }

    func testInstallThenRestartInOneInvocation() throws {
        write("dynjectd.pids", "7237\n45044\n")
        let target = dir.appendingPathComponent("dynjectd.conf")
        try "old\n".write(to: target, atomically: true, encoding: .utf8)
        let staged = dir.appendingPathComponent("staged")
        try "new\n".write(to: staged, atomically: true, encoding: .utf8)
        let out = try executor.run(["install", target.path, staged.path, sha256Hex(Data("new\n".utf8)),
                                    sha256Hex(Data("old\n".utf8)), "restart"], prompt: "")
        XCTAssertTrue(out.contains("DW installed"))
        XCTAssertEqual(PrivilegedRestarter.report(from: out).after, [50000])
    }

    // MARK: transactions (tweak install / uninstall)

    /// A tweaks folder given by its real path (the helper refuses a folder reached through a symlink, and the
    /// temporary directory is under /var -> /private/var).
    func tweaksFolder() throws -> URL {
        let url = dir.appendingPathComponent("tweaks")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let real = realpath(url.path, nil)!
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real))
    }

    func executor(tweaks: URL) -> LocalShellExecutor {
        var env = executor.environment
        env["DW_TEST_TWEAKS_DIR"] = tweaks.path
        return LocalShellExecutor(environment: env)
    }

    func file(_ url: URL, _ text: String) throws { try text.write(to: url, atomically: true, encoding: .utf8) }
    func sha(_ text: String) -> String { sha256Hex(Data(text.utf8)) }
    func leftovers(_ dirs: URL...) -> [String] {
        dirs.flatMap { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? [] }.filter { $0.contains(".dw.") }
    }

    func testTwoInstallsAndRestartInOneInvocation() throws {
        write("dynjectd.pids", "7237\n")
        let tweaks = try tweaksFolder()
        let dylib = tweaks.appendingPathComponent("libNew.dylib")
        let conf = dir.appendingPathComponent("dynjectd.conf")
        try file(conf, "old\n")
        let s1 = dir.appendingPathComponent("s1"), s2 = dir.appendingPathComponent("s2")
        try file(s1, "DYLIB"); try file(s2, "new\n")
        let out = try executor(tweaks: tweaks).run(["install", dylib.path, s1.path, sha("DYLIB"), "-",
                                                    "install", conf.path, s2.path, sha("new\n"), sha("old\n"), "restart"], prompt: "")
        XCTAssertEqual(out.components(separatedBy: "DW installed ").count - 1, 2)
        XCTAssertEqual(try String(contentsOf: dylib, encoding: .utf8), "DYLIB")
        XCTAssertEqual(try String(contentsOf: conf, encoding: .utf8), "new\n")
        XCTAssertEqual(PrivilegedRestarter.report(from: out).after, [50000])
        XCTAssertEqual(leftovers(tweaks, dir), [])
        // Both files were in place before the restart began.
        let installedAt = out.range(of: "DW installed \(conf.path)")!.lowerBound
        XCTAssertLessThan(installedAt, out.range(of: "DW running-before")!.lowerBound)
    }

    func testConflictOnTheSecondFileWritesNeither() throws {
        let tweaks = try tweaksFolder()
        let dylib = tweaks.appendingPathComponent("libNew.dylib")
        let conf = dir.appendingPathComponent("dynjectd.conf")
        try file(conf, "edited meanwhile\n")
        let s1 = dir.appendingPathComponent("s1"), s2 = dir.appendingPathComponent("s2")
        try file(s1, "DYLIB"); try file(s2, "new\n")
        XCTAssertThrowsError(try executor(tweaks: tweaks).run(["install", dylib.path, s1.path, sha("DYLIB"), "-",
                                                               "install", conf.path, s2.path, sha("new\n"), sha("old\n"), "restart"],
                                                              prompt: "")) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed on disk"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dylib.path))
        XCTAssertEqual(try String(contentsOf: conf, encoding: .utf8), "edited meanwhile\n")
        XCTAssertTrue(calls.isEmpty, "no restart")
    }

    func testSwappedSecondStagedFileWritesNeitherAndLeavesNoTemporaries() throws {
        let tweaks = try tweaksFolder()
        let dylib = tweaks.appendingPathComponent("libNew.dylib")
        let conf = dir.appendingPathComponent("dynjectd.conf")
        try file(conf, "old\n")
        let s1 = dir.appendingPathComponent("s1"), s2 = dir.appendingPathComponent("s2")
        try file(s1, "DYLIB"); try file(s2, "evil\n")
        XCTAssertThrowsError(try executor(tweaks: tweaks).run(["install", dylib.path, s1.path, sha("DYLIB"), "-",
                                                               "install", conf.path, s2.path, sha("new\n"), sha("old\n")], prompt: "")) { error in
            XCTAssertTrue(error.localizedDescription.contains("staged content changed"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dylib.path))
        XCTAssertEqual(try String(contentsOf: conf, encoding: .utf8), "old\n")
        XCTAssertEqual(leftovers(tweaks, dir), [])
    }

    func testConfigEditRemoveAndRestartInOneInvocation() throws {
        write("dynjectd.pids", "7237\n")
        let tweaks = try tweaksFolder()
        let dylib = tweaks.appendingPathComponent("libOld.dylib")
        try file(dylib, "OLD")
        let conf = dir.appendingPathComponent("dynjectd.conf")
        try file(conf, "old\n")
        let s = dir.appendingPathComponent("s")
        try file(s, "new\n")
        let out = try executor(tweaks: tweaks).run(["install", conf.path, s.path, sha("new\n"), sha("old\n"),
                                                    "remove", dylib.path, sha("OLD"), "restart"], prompt: "")
        XCTAssertTrue(out.contains("DW removed \(dylib.path)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dylib.path))
        XCTAssertEqual(try String(contentsOf: conf, encoding: .utf8), "new\n")
        XCTAssertEqual(PrivilegedRestarter.report(from: out).after, [50000])
    }

    func testRemoveRefusesAnythingButAPlainDylibInTheTweaksFolder() throws {
        let tweaks = try tweaksFolder()
        let outside = dir.appendingPathComponent("libOutside.dylib")
        try file(outside, "X")
        let sub = tweaks.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try file(sub.appendingPathComponent("libSub.dylib"), "X")
        try file(tweaks.appendingPathComponent("notes.txt"), "X")
        try file(tweaks.appendingPathComponent(".libHidden.dylib"), "X")
        try FileManager.default.createSymbolicLink(atPath: tweaks.appendingPathComponent("libLink.dylib").path, withDestinationPath: outside.path)
        try FileManager.default.createDirectory(at: tweaks.appendingPathComponent("libDir.dylib"), withIntermediateDirectories: true)
        try file(tweaks.appendingPathComponent("libReal.dylib"), "REAL")

        let cases: [(String, String, String)] = [
            (outside.path, sha("X"), "only *.dylib files"),
            (tweaks.path + "/../libOutside.dylib", sha("X"), "not a plain file name"),
            (sub.appendingPathComponent("libSub.dylib").path, sha("X"), "not a plain file name"),
            (tweaks.appendingPathComponent("notes.txt").path, sha("X"), "only *.dylib files"),
            (tweaks.appendingPathComponent(".libHidden.dylib").path, sha("X"), "not a plain file name"),
            (tweaks.appendingPathComponent("libLink.dylib").path, sha("X"), "symbolic link"),
            (tweaks.appendingPathComponent("libDir.dylib").path, sha("X"), "not a regular file"),
            (tweaks.appendingPathComponent("libReal.dylib").path, sha("OTHER"), "changed on disk"),
            ("relative/libReal.dylib", sha("REAL"), "only *.dylib files"),
        ]
        for (target, hash, message) in cases {
            XCTAssertThrowsError(try executor(tweaks: tweaks).run(["remove", target, hash], prompt: ""), target) { error in
                XCTAssertTrue(error.localizedDescription.contains(message), "\(target): \(error.localizedDescription)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tweaks.appendingPathComponent("libReal.dylib").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tweaks.appendingPathComponent(".libHidden.dylib").path))

        // A tweaks folder reached through a symlink is refused as a whole.
        let link = dir.appendingPathComponent("tweaks-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: tweaks.path)
        XCTAssertThrowsError(try executor(tweaks: link).run(["remove", link.path + "/libReal.dylib", sha("REAL")], prompt: "")) { error in
            XCTAssertTrue(error.localizedDescription.contains("symbolic link"), error.localizedDescription)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tweaks.appendingPathComponent("libReal.dylib").path))
    }

    func testFailedInstallCheckKeepsTheFileARemovalWouldDelete() throws {
        let tweaks = try tweaksFolder()
        let dylib = tweaks.appendingPathComponent("libOld.dylib")
        try file(dylib, "OLD")
        let conf = dir.appendingPathComponent("dynjectd.conf")
        try file(conf, "edited meanwhile\n")
        let s = dir.appendingPathComponent("s")
        try file(s, "new\n")
        XCTAssertThrowsError(try executor(tweaks: tweaks).run(["install", conf.path, s.path, sha("new\n"), sha("old\n"),
                                                               "remove", dylib.path, sha("OLD"), "restart"], prompt: ""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dylib.path))
    }

    func testRestartMustComeLast() {
        XCTAssertThrowsError(try executor.run(["restart", "restart"], prompt: "")) { error in
            XCTAssertTrue(error.localizedDescription.contains("restart must come last"))
        }
        XCTAssertThrowsError(try executor.run(["frobnicate"], prompt: ""))
        XCTAssertTrue(calls.isEmpty)
    }

    func testOsascriptCommandQuoting() {
        let cmd = OsascriptExecutor.command(for: ["install", "/tmp/it's here", "x"])
        XCTAssertTrue(cmd.hasPrefix("'/bin/sh' '-c' '"))
        XCTAssertTrue(cmd.hasSuffix("'dw-helper' 'install' '/tmp/it'\\''s here' 'x'"))
        XCTAssertEqual(HelperOutput.errorMessage("0:1: execution error: DW-ERROR boom happened (12)\n"), "boom happened")
    }
}
