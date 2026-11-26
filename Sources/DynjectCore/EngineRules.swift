import Foundation

/// Which dynjectd behaviour Workbench models when it predicts what the engine will do (`dw why`, the app list,
/// the config validator). The two differ in how a config is read and in who gets a dylib:
///
/// | | `.stock` | `.revised` |
/// |---|---|---|
/// | system-daemon names | anywhere in the label | whole words of the label |
/// | a dylib's overrides | matched against the label | the label and "application.<bundle id>." must both allow |
/// | `ui_apps` / `skip_helpers` | on unless "no" or "0" | yes/no/true/false/on/off/1/0; another value changes nothing |
/// | `dylib-override` above its `dylib:` line | ignored | counts |
///
/// `.stock` is the original engine (ut0mt8/dynject up to its pull request 1). `.revised` is the engine with the
/// hardening and launch/config changes of pull requests 2 and 3.
public enum EngineRules: String, Sendable {
    case stock
    case revised

    // MARK: The rules in force

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixed: EngineRules = .stock
    nonisolated(unsafe) private static var followed: Follower?

    /// The rules of the engine that is installed, as far as Workbench knows. `.stock` until `follow(logAt:)` or a
    /// direct assignment says otherwise, so library code and tests get the same answer on every machine.
    public static var active: EngineRules {
        get {
            lock.lock(); defer { lock.unlock() }
            return followed?.current() ?? fixed
        }
        set {
            lock.lock(); defer { lock.unlock() }
            followed = nil
            fixed = newValue
        }
    }

    /// Makes `active` follow the engine that writes this log: the rules are read from the loader's latest start
    /// line and looked up again when the log has grown (an engine can be replaced while Workbench runs).
    public static func follow(logAt path: String) {
        lock.lock(); defer { lock.unlock() }
        followed = Follower(path: path)
    }

    // MARK: Telling the engines apart

    /// The loader's line after it started dynjectd. Only the loader writes lines that begin this way: text that
    /// dynjectd logs from outside (a launchd label, an app's name) sits behind a "[dynjectd …] dynjectd: " prefix.
    private static let loaderDone = try! NSRegularExpression(
        pattern: #"^\[dynject_loader \d{2}:\d{2}:\d{2}\] dynject_loader: done dynjectd running\b(.*)$"#,
        options: [.anchorsMatchLines])

    /// The rules of the engine whose loader wrote the last start line in `logText`; nil when there is none.
    /// The revised loader says how it left amfid ("…; amfid hook removed (…)"), the stock one doesn't.
    public static func detect(in logText: String) -> EngineRules? {
        let ns = logText as NSString
        guard let last = loaderDone.matches(in: logText, range: NSRange(location: 0, length: ns.length)).last else {
            return nil
        }
        return ns.substring(with: last.range(at: 1)).contains("amfid hook removed") ? .revised : .stock
    }

    /// The same from the log file, reading back from its end only as far as the latest start line (up to `limit`
    /// bytes). nil: no log, or no start line in it.
    public static func detect(logAt path: String, limit: UInt64 = 64 << 20) -> EngineRules? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        var size: UInt64 = 256 << 10
        while true {
            let start = end > size ? end - size : 0
            guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
            if let found = detect(in: String(decoding: data, as: UTF8.self)) { return found }
            if start == 0 || size >= limit { return nil }
            size *= 4
        }
    }

    /// Remembers what the log said and reads only what was appended since.
    private final class Follower {
        let path: String
        private var rules: EngineRules?
        private var scannedTo: UInt64 = 0
        private var checkedAt = Date.distantPast

        init(path: String) { self.path = path }

        func current() -> EngineRules? {
            let now = Date()
            guard now.timeIntervalSince(checkedAt) > 5 else { return rules }
            checkedAt = now
            let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value
            guard let size else { return rules }
            if rules == nil || size < scannedTo {
                // First look, or the log was replaced: find the latest start line wherever it is.
                rules = EngineRules.detect(logAt: path)
            } else if size > scannedTo, let handle = FileHandle(forReadingAtPath: path) {
                defer { try? handle.close() }
                // Back up a little so a line that was half written last time is seen whole.
                let from = scannedTo > 512 ? scannedTo - 512 : 0
                if (try? handle.seek(toOffset: from)) != nil, let data = try? handle.readToEnd(),
                   let found = EngineRules.detect(in: String(decoding: data, as: UTF8.self)) {
                    rules = found
                }
            }
            scannedTo = size
            return rules
        }
    }
}
