import Darwin
import Foundation

/// One password for several privileged steps: an approval window, like sudo's.
///
/// The first privileged step starts a small root server (through the usual administrator prompt) that runs
/// `HelperScript` for later requests without asking again, until it has been idle for `idle` seconds (5 minutes)
/// or has run for `maximum` (1 hour). It only does what dw and Workbench do to install tweaks: write
/// /opt/dynject/etc/dynjectd.conf, put or remove a plain *.dylib directly in /opt/dynject/lib/tweaks, restart
/// dynjectd. Anything else (a protected plist Workbench edits, a path elsewhere) is refused by the server and asked
/// for with a password as before. While it runs, any program running as this user could ask it for those steps too;
/// that is the trade for not typing the password each time. `dw auth end` closes it early.
///
/// Files: a root-owned folder /private/var/run/dynject-workbench.<uid> (so nothing running as the user can swap what
/// root opens), holding `req`, a FIFO only this user can write (one request: the helper's arguments, one per line,
/// then end of file), `resp`, a root-owned FIFO with the answer (exit status, stdout, "DW-STDERR", stderr), and
/// `pid`. Requests are serialized with a lock file in the user's Workbench folder.
public final class SessionExecutor: PrivilegedExecutor, @unchecked Sendable {
    public static let idle: TimeInterval = 300
    public static let maximum: TimeInterval = 3600
    static let refused: Int32 = 99

    /// Shared by everything in this process, so one prompt covers a whole command (or Workbench session).
    public static let shared = SessionExecutor()

    let fallback: PrivilegedExecutor
    let directory: String
    let lockPath: String
    let idle: TimeInterval
    let maximum: TimeInterval
    let tweaksDirectory: String
    let configPath: String
    let starter: (String, String) throws -> Void

    public init(fallback: PrivilegedExecutor = OsascriptExecutor(),
                directory: String = SessionExecutor.defaultDirectory,
                lockPath: String = SessionExecutor.defaultLockPath,
                idle: TimeInterval = SessionExecutor.idle, maximum: TimeInterval = SessionExecutor.maximum,
                tweaksDirectory: String = TweakLocations.liveTweaksDirectory, configPath: String = TweakLocations.liveConfigPath,
                starter: ((String, String) throws -> Void)? = nil) {
        self.tweaksDirectory = tweaksDirectory
        self.configPath = configPath
        self.fallback = fallback
        self.directory = directory
        self.lockPath = lockPath
        self.idle = idle
        self.maximum = maximum
        self.starter = starter ?? SessionExecutor.startWithPassword
    }

    public static var defaultDirectory: String { "/private/var/run/dynject-workbench.\(getuid())" }
    public static var defaultLockPath: String {
        TweakLocations.defaultSupportDirectory.appendingPathComponent("session.lock").path
    }

    // MARK: Running a step

    public func run(_ arguments: [String], prompt: String) throws -> String {
        guard Self.allowed(arguments, tweaksDirectory: tweaksDirectory, configPath: configPath) else {
            return try fallback.run(arguments, prompt: prompt)
        }
        return try withLock {
            var answer: Answer
            do {
                if !isAlive { try start(prompt) }
                answer = try send(arguments)
            } catch is SessionClosed {   // it ended between the check and the request: start a new one
                try start(prompt)
                answer = try send(arguments)
            }
            if answer.status == 0 { return answer.stdout }
            if answer.status == Self.refused { return try fallback.run(arguments, prompt: prompt) }
            throw WriteError.helperFailed(HelperOutput.errorMessage(answer.stderr))
        }
    }

    func start(_ prompt: String) throws {
        try starter(Self.serverCommand(directory: directory, idle: idle, maximum: maximum), Self.prompt(prompt))
        guard waitUntilAlive() else { throw WriteError.helperFailed("The approval window didn't start.") }
    }

    static func prompt(_ prompt: String) -> String {
        prompt + "\n\nYour password also lets dw and Workbench install tweak files and restart dynjectd for the next "
            + "5 minutes without asking again (`dw auth end` stops that)."
    }

    /// What the server does: only the steps that install tweaks (it checks again itself).
    public static func allowed(_ arguments: [String], tweaksDirectory: String = TweakLocations.liveTweaksDirectory,
                               configPath: String = TweakLocations.liveConfigPath) -> Bool {
        var rest = arguments[...]
        guard !rest.isEmpty else { return false }
        while let op = rest.first {
            switch op {
            case "install":
                guard rest.count >= 5 else { return false }
                let target = rest[rest.startIndex + 1]
                guard target == configPath || isPlainDylib(target, in: tweaksDirectory) else { return false }
                rest = rest.dropFirst(5)
            case "remove":
                guard rest.count >= 3, isPlainDylib(rest[rest.startIndex + 1], in: tweaksDirectory) else { return false }
                rest = rest.dropFirst(3)
            case "restart":
                rest = rest.dropFirst()
            default:
                return false
            }
        }
        return !arguments.contains { $0.contains("\n") }
    }

    static func isPlainDylib(_ path: String, in directory: String) -> Bool {
        guard path.hasPrefix(directory + "/"), path.hasSuffix(".dylib") else { return false }
        let name = path.dropFirst(directory.count + 1)
        return !name.contains("/") && !name.hasPrefix(".")
    }

    // MARK: State

    public struct Status: Equatable, Sendable {
        public var pid: Int32
        public var startedAt: Date
    }

    /// The running window, if any: a root-owned folder (when we aren't root ourselves, a test's own one) whose server
    /// process is alive.
    public var status: Status? {
        var st = stat()
        guard lstat(directory, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        if getuid() != 0 && st.st_uid != 0 && st.st_uid != getuid() { return nil }
        if st.st_uid != 0 && directory == Self.defaultDirectory { return nil }   // the live window is always root's
        guard let text = try? String(contentsOfFile: directory + "/pid", encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        guard kill(pid, 0) == 0 || errno == EPERM else { return nil }
        var req = stat()
        guard lstat(directory + "/req", &req) == 0, (req.st_mode & S_IFMT) == S_IFIFO else { return nil }
        return Status(pid: pid, startedAt: Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec)))
    }

    public var isAlive: Bool { status != nil }

    func waitUntilAlive() -> Bool {
        for _ in 0..<50 { if isAlive { return true }; usleep(100_000) }
        return false
    }

    /// Closes the window now.
    public func end() throws {
        guard isAlive else { return }
        _ = try withLock { try send(["quit"]) }
    }

    // MARK: Talking to the server

    struct Answer { var status: Int32; var stdout: String; var stderr: String }
    struct SessionClosed: Error {}

    func send(_ arguments: [String]) throws -> Answer {
        // Non-blocking open: fails (ENXIO) while no server is reading, e.g. for the moment between two requests.
        var w: Int32 = -1
        for _ in 0..<40 {
            w = open(directory + "/req", O_WRONLY | O_NONBLOCK)
            if w >= 0 || errno != ENXIO || !isAlive { break }
            usleep(50_000)
        }
        guard w >= 0 else { throw SessionClosed() }
        _ = fcntl(w, F_SETFL, fcntl(w, F_GETFL) & ~O_NONBLOCK)
        let body = Data((arguments.joined(separator: "\n") + "\n").utf8)
        let written = body.withUnsafeBytes { write(w, $0.baseAddress, body.count) }
        close(w)
        guard written == body.count else { throw WriteError.helperFailed("Couldn't send the request to the approval window.") }

        let r = open(directory + "/resp", O_RDONLY | O_NONBLOCK)
        guard r >= 0 else { throw WriteError.helperFailed("The approval window has no answer channel.") }
        defer { close(r) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(300)
        var gotWriter = false
        while Date() < deadline {
            var pfd = pollfd(fd: r, events: Int16(POLLIN), revents: 0)
            _ = poll(&pfd, 1, 200)
            let n = read(r, &buffer, buffer.count)
            if n > 0 { data.append(buffer, count: n); gotWriter = true; continue }
            if n == 0 && gotWriter { break }   // the server wrote and closed
            if n < 0 && errno != EAGAIN { break }
            if n == 0 { usleep(20_000) }       // no writer yet: poll() reports hang-up at once
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let nl = text.firstIndex(of: "\n"), let status = Int32(text[..<nl]) else {
            throw WriteError.helperFailed("The approval window didn't answer.")
        }
        let rest = String(text[text.index(after: nl)...])
        let parts = rest.components(separatedBy: "DW-STDERR\n")
        return Answer(status: status, stdout: parts.first ?? "", stderr: parts.dropFirst().joined(separator: "DW-STDERR\n"))
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        try? FileManager.default.createDirectory(atPath: (lockPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return try body() }
        defer { flock(fd, LOCK_UN); close(fd) }
        flock(fd, LOCK_EX)
        return try body()
    }

    // MARK: Starting it

    static func startWithPassword(_ command: String, _ prompt: String) throws {
        let out = try ProcessRunner.run("/usr/bin/osascript", [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
            "-e", "end run",
            command, prompt,
        ])
        if out.status == 0 { return }
        if out.stderr.contains("(-128)") { throw WriteError.cancelled }
        throw WriteError.helperFailed(HelperOutput.errorMessage(out.stderr))
    }

    /// The shell command that starts the server (as root, or as the user in tests).
    public static func serverCommand(directory: String, idle: TimeInterval, maximum: TimeInterval) -> String {
        (["/bin/sh", "-c", serverSource, "dw-session", directory, String(getuid()), String(Int(idle)), String(Int(maximum)),
          HelperScript.source]).map(shellQuote).joined(separator: " ")
    }

    /// The server. Arguments: folder, the user's uid, idle seconds, maximum seconds, the helper's source.
    static let serverSource = #"""
    set -u
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH
    DIR=$1; OWNER=$2; IDLE=$3; MAX=$4; HELPER=$5
    TWEAKS=/opt/dynject/lib/tweaks
    CONF=/opt/dynject/etc/dynjectd.conf
    # Test hooks, honoured only when NOT running as root (like the helper's).
    if [ "$(id -u)" != "0" ]; then
      TWEAKS="${DW_TEST_TWEAKS_DIR:-$TWEAKS}"; CONF="${DW_TEST_CONFIG:-$CONF}"
    else
      case "$DIR" in /private/var/run/dynject-workbench.[0-9]*) ;; *) echo "DW-ERROR bad session folder" >&2; exit 1 ;; esac
    fi
    case "$OWNER$IDLE$MAX" in *[!0-9]*) echo "DW-ERROR bad session arguments" >&2; exit 1 ;; esac
    umask 022
    rm -rf "$DIR" && mkdir -m 755 "$DIR" || { echo "DW-ERROR can't create $DIR" >&2; exit 1; }
    mkfifo -m 600 "$DIR/req" && mkfifo -m 644 "$DIR/resp" || { echo "DW-ERROR can't create the FIFOs" >&2; exit 1; }
    [ "$(id -u)" = "0" ] && chown "$OWNER" "$DIR/req"

    allowed() {
      [ $# -ge 1 ] || return 1
      while [ $# -gt 0 ]; do
        case "$1" in
          install) [ $# -ge 5 ] || return 1
                   case "$2" in
                     "$CONF") ;;
                     "$TWEAKS"/*.dylib) n=${2#"$TWEAKS"/}; case "$n" in */*|.*) return 1 ;; esac ;;
                     *) return 1 ;;
                   esac
                   shift 5 ;;
          remove)  [ $# -ge 3 ] || return 1
                   case "$2" in "$TWEAKS"/*.dylib) n=${2#"$TWEAKS"/}; case "$n" in */*|.*) return 1 ;; esac ;; *) return 1 ;; esac
                   shift 3 ;;
          restart) shift ;;
          *) return 1 ;;
        esac
      done
    }

    serve() {
      START=$(date +%s)
      while :; do
        # While waiting for a request, a watchdog ends the server after IDLE seconds (or at MAX): a blocked open
        # can't be interrupted otherwise. It kills this loop (its PID is in the pid file) and removes the folder.
        left=$(( MAX - ($(date +%s) - START) )); [ "$left" -lt "$IDLE" ] && wait_for=$left || wait_for=$IDLE
        [ "$wait_for" -le 0 ] && break
        ( sleep "$wait_for"; kill -9 "$(cat "$DIR/pid" 2>/dev/null)" 2>/dev/null; rm -rf "$DIR" ) &
        WATCH=$!
        set --
        while IFS= read -r line; do set -- "$@" "$line"; done < "$DIR/req"
        kill "$WATCH" 2>/dev/null; WATCH=""   # no deadline while a request runs
        [ $# -eq 0 ] && continue
        if [ "$1" = "quit" ]; then
          { echo 0; echo DW-STDERR; } > "$DIR/resp"
          break
        fi
        if allowed "$@"; then
          /bin/sh -c "$HELPER" dw-helper "$@" > "$DIR/out" 2> "$DIR/err"; st=$?
        else
          : > "$DIR/out"; echo "DW-ERROR not something the approval window does" > "$DIR/err"; st=99
        fi
        { echo "$st"; cat "$DIR/out"; echo DW-STDERR; cat "$DIR/err"; } > "$DIR/resp"
      done
      [ -n "$WATCH" ] && kill "$WATCH" 2>/dev/null
      rm -rf "$DIR"
    }

    serve </dev/null >/dev/null 2>&1 &
    echo $! > "$DIR/pid"
    exit 0
    """#
}
