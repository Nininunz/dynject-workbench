import Darwin
import Foundation
import ObjectiveC

// What a tweak needs from macOS (manifest key `requires`), and `dw doctor --apis`, which checks it in its own process
// after a macOS update: dlopen the image, look the class / method / ivar / C symbol up, or find a string in a binary
// that can't be loaded (an app's executable). Format: docs/tweak-format.md#requirements.

/// One thing a tweak needs to find at run time.
public struct TweakRequirement: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// An Objective-C class, with instance (`-sel`) and class (`+sel`) methods and ivars it must have.
        case objcClass(String, methods: [String], ivars: [String])
        /// A C function or variable, looked up with dlsym in `image`.
        case symbol(String)
        /// A NUL-terminated string in the binary `image` (its arm64e slice): for classes in app executables, which
        /// can't be dlopened.
        case string(String)
    }

    public var kind: Kind
    /// A framework or library short name (`AppKit`, `libsystem_sandbox`) or an absolute path.
    public var image: String
    /// Missing means a feature is off, not that the tweak misbehaves.
    public var optional: Bool

    public init(_ kind: Kind, image: String, optional: Bool = false) {
        self.kind = kind
        self.image = image
        self.optional = optional
    }

    public static func objcClass(_ name: String, image: String, methods: [String] = [], ivars: [String] = [],
                                 optional: Bool = false) -> TweakRequirement {
        TweakRequirement(.objcClass(name, methods: methods, ivars: ivars), image: image, optional: optional)
    }

    public static func symbol(_ name: String, image: String, optional: Bool = false) -> TweakRequirement {
        TweakRequirement(.symbol(name), image: image, optional: optional)
    }

    public static func string(_ value: String, image: String, optional: Bool = false) -> TweakRequirement {
        TweakRequirement(.string(value), image: image, optional: optional)
    }

    /// e.g. "_NSAppleMenu (AppKit) + 2 methods", "strlen() (libSystem.B)", "\"TBrowserWindow\" in Finder".
    public var summary: String {
        switch kind {
        case let .objcClass(n, methods, ivars):
            let extras = [methods.isEmpty ? nil : "\(methods.count) method\(methods.count == 1 ? "" : "s")",
                          ivars.isEmpty ? nil : "\(ivars.count) ivar\(ivars.count == 1 ? "" : "s")"].compactMap { $0 }
            return "\(n) (\(imageLabel))" + (extras.isEmpty ? "" : " + " + extras.joined(separator: ", "))
        case let .symbol(n): return "\(n)() (\(imageLabel))"
        case let .string(s): return "\"\(s)\" in \(imageLabel)"
        }
    }

    var imageLabel: String {
        guard image.hasPrefix("/") else { return image }
        let name = (image as NSString).lastPathComponent
        return (name as NSString).deletingPathExtension.isEmpty ? name : (name as NSString).deletingPathExtension
    }

    /// The tweak side of DynjectBridge (DynjectBridge.m): implied by a manifest's `bridge` capabilities.
    public static let bridgeClient: [TweakRequirement] = [
        .symbol("sandbox_extension_consume", image: "libsystem_sandbox"),
    ]

    /// The broker (`dw bridge serve`, BridgeSystem.swift): issuing the token and identifying callers.
    public static let bridgeBroker: [TweakRequirement] = [
        .symbol("sandbox_extension_issue_mach", image: "libsystem_sandbox"),
        .symbol("xpc_connection_get_audit_token", image: "libxpc"),
        .symbol("responsibility_get_pid_responsible_for_pid", image: "libquarantine"),
    ]
}

// MARK: - Parsing

enum TweakRequirementParser {
    static let kindKeys = ["class", "symbol", "string"]
    static let knownKeys: Set<String> = ["class", "symbol", "string", "image", "methods", "ivars", "optional"]

    /// The manifest's `requires` value. nil when absent (the tweak declares nothing; doctor can't tell), [] when it
    /// says it needs nothing. Bad entries are skipped with an error, the rest kept.
    static func parse(_ raw: Any?, error: (String) -> Void, warning: (String) -> Void) -> [TweakRequirement]? {
        guard let raw else { return nil }
        guard let list = raw as? [Any] else {
            error("requires must be an array of requirements; ignored.")
            return nil
        }
        var out: [TweakRequirement] = []
        for (i, entry) in list.enumerated() {
            let at = "requires[\(i)]"
            guard let d = entry as? [String: Any] else { error("\(at): must be a dictionary; skipped."); continue }
            for k in d.keys.sorted() where !knownKeys.contains(k) { warning("\(at): unknown key \"\(k)\"; ignored.") }
            let kinds = kindKeys.filter { d[$0] != nil }
            guard kinds.count == 1, let kindKey = kinds.first else {
                error("\(at): needs exactly one of class, symbol or string; skipped.")
                continue
            }
            guard let value = d[kindKey] as? String, !value.isEmpty, !value.contains("\0") else {
                error("\(at): \(kindKey) must be a non-empty string; skipped.")
                continue
            }
            guard let image = d["image"] as? String, !image.isEmpty else {
                error("\(at): image is required (a framework or library name, or an absolute path); skipped.")
                continue
            }
            guard image.hasPrefix("/") || !image.contains("/") else {
                error("\(at): image \"\(image)\" must be a short name (AppKit) or an absolute path; skipped.")
                continue
            }
            var optional = false
            if let o = d["optional"] {
                if let b = o as? Bool { optional = b } else { error("\(at): optional must be a boolean; treated as false.") }
            }
            let kind: TweakRequirement.Kind
            switch kindKey {
            case "class":
                guard value.range(of: #"^[A-Za-z_][A-Za-z0-9_.$]*$"#, options: .regularExpression) != nil else {
                    error("\(at): \"\(value)\" isn't a class name; skipped.")
                    continue
                }
                let methods = strings(d["methods"], at: "\(at).methods", error: error).filter { m in
                    let ok = m.range(of: #"^[-+][A-Za-z_][A-Za-z0-9_:]*$"#, options: .regularExpression) != nil
                    if !ok { error("\(at).methods: \"\(m)\" must be -selector or +selector; ignored.") }
                    return ok
                }
                let ivars = strings(d["ivars"], at: "\(at).ivars", error: error)
                kind = .objcClass(value, methods: methods, ivars: ivars)
            case "symbol":
                guard value.range(of: #"^[A-Za-z_][A-Za-z0-9_$.]*$"#, options: .regularExpression) != nil else {
                    error("\(at): \"\(value)\" isn't a C symbol name; skipped.")
                    continue
                }
                kind = .symbol(value)
            default:
                guard image.hasPrefix("/") else {
                    error("\(at): a string requirement needs image to be the absolute path of a binary; skipped.")
                    continue
                }
                kind = .string(value)
            }
            if kindKey != "class" {
                for k in ["methods", "ivars"] where d[k] != nil { error("\(at): \(k) only applies to class; ignored.") }
            }
            out.append(TweakRequirement(kind, image: image, optional: optional))
        }
        return out
    }

    private static func strings(_ raw: Any?, at: String, error: (String) -> Void) -> [String] {
        guard let raw else { return [] }
        guard let a = raw as? [Any] else { error("\(at) must be an array of strings; ignored."); return [] }
        return a.compactMap { v in
            guard let s = v as? String, !s.isEmpty else { error("\(at): entries must be non-empty strings; one ignored."); return nil }
            return s
        }
    }
}

// MARK: - Checking

/// The outcome of one requirement: what of it is missing (empty: all present).
public struct TweakRequirementResult: Equatable, Sendable {
    public var requirement: TweakRequirement
    /// e.g. ["-[_NSAppleMenu updateMenu:withEvent:withFlags:]"], ["class NSScrollPocket"], ["AppKit: can't load (...)"]
    public var missing: [String]
    public var satisfied: Bool { missing.isEmpty }
}

/// Checks requirements in this process: loads images with dlopen (their initializers run, nothing else), then asks
/// the Objective-C runtime and dyld. `string` requirements read the file instead. Not thread-safe; use one per thread.
public final class TweakRequirementEvaluator {
    private var handles: [String: Result<UnsafeMutableRawPointer, StringError>] = [:]
    private var strings: [String: Result<Data, StringError>] = [:]

    public struct StringError: Error, Equatable { public var message: String }

    public init() {}

    /// Where a short image name can be: public and private frameworks, then /usr/lib/system and /usr/lib.
    /// (Most of these files exist only in the dyld shared cache; dlopen finds them there.)
    public static func candidatePaths(image: String) -> [String] {
        if image.hasPrefix("/") { return [image] }
        let n = image.hasSuffix(".framework") ? String(image.dropLast(".framework".count)) : image
        let lib = n.hasSuffix(".dylib") ? n : n + ".dylib"
        return ["/System/Library/Frameworks/\(n).framework/\(n)", "/System/Library/PrivateFrameworks/\(n).framework/\(n)",
                "/usr/lib/system/\(lib)", "/usr/lib/\(lib)"]
    }

    func handle(_ image: String) -> Result<UnsafeMutableRawPointer, StringError> {
        if let h = handles[image] { return h }
        var last = "not found"
        var result: Result<UnsafeMutableRawPointer, StringError>?
        for path in Self.candidatePaths(image: image) {
            if let h = dlopen(path, RTLD_LAZY | RTLD_LOCAL) { result = .success(h); break }
            if let e = dlerror() { last = String(cString: e) }
        }
        let r = result ?? .failure(StringError(message: last))
        handles[image] = r
        return r
    }

    func contents(_ path: String) -> Result<Data, StringError> {
        if let d = strings[path] { return d }
        let r: Result<Data, StringError>
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) {
            r = .success(MachOInfo.preferredSlice(of: data))
        } else {
            r = .failure(StringError(message: "can't read \(path)"))
        }
        strings[path] = r
        return r
    }

    public func evaluate(_ r: TweakRequirement) -> TweakRequirementResult {
        func result(_ missing: [String]) -> TweakRequirementResult { TweakRequirementResult(requirement: r, missing: missing) }
        switch r.kind {
        case let .string(s):
            switch contents(r.image) {
            case let .failure(e): return result(["\(r.imageLabel): \(e.message)"])
            case let .success(data): return result(Self.containsCString(data, s) ? [] : ["\"\(s)\" in \(r.imageLabel)"])
            }
        case let .symbol(name):
            switch handle(r.image) {
            case let .failure(e): return result(["\(r.image): can't load (\(e.message))"])
            case let .success(h): return result(dlsym(h, name) == nil ? ["\(name)() in \(r.imageLabel)"] : [])
            }
        case let .objcClass(name, methods, ivars):
            if case let .failure(e) = handle(r.image) { return result(["\(r.image): can't load (\(e.message))"]) }
            guard let cls: AnyClass = objc_lookUpClass(name) else { return result(["class \(name)"]) }
            var missing: [String] = []
            for m in methods {
                let sel = sel_registerName(String(m.dropFirst()))
                let found = m.hasPrefix("+") ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel)
                if found == nil { missing.append("\(m.prefix(1))[\(name) \(m.dropFirst())]") }
            }
            for i in ivars where class_getInstanceVariable(cls, i) == nil { missing.append("ivar \(name).\(i)") }
            return result(missing)
        }
    }

    public func evaluate(_ list: [TweakRequirement]) -> [TweakRequirementResult] { list.map(evaluate) }

    /// `s` as a whole C string (so "XTBrowserWindow" doesn't count for "TBrowserWindow"), searched in the C-string
    /// sections of a Mach-O slice (`__cstring`, `__objc_classname`, ...), where a section's start also begins a
    /// string. Other files: anywhere, with a NUL before and after.
    public static func containsCString(_ data: Data, _ s: String) -> Bool {
        let sections = cStringSections(data)
        guard !sections.isEmpty else { return data.range(of: Data(("\0" + s + "\0").utf8)) != nil }
        let needle = Data((s + "\0").utf8)
        for r in sections {
            var from = r.lowerBound
            while from < r.upperBound, let m = data.range(of: needle, in: from..<r.upperBound) {
                if m.lowerBound == r.lowerBound || data[m.lowerBound - 1] == 0 { return true }
                from = m.lowerBound + 1
            }
        }
        return false
    }

    /// Byte ranges of the S_CSTRING_LITERALS sections of a thin 64-bit Mach-O (as `MachOInfo.preferredSlice` returns).
    static func cStringSections(_ data: Data) -> [Range<Int>] {
        let base = data.startIndex
        func le32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= data.count else { return nil }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[base + o + $1]) << (8 * UInt32($1)) }
        }
        func le64(_ o: Int) -> UInt64? {
            guard let lo = le32(o), let hi = le32(o + 4) else { return nil }
            return UInt64(hi) << 32 | UInt64(lo)
        }
        guard le32(0) == 0xFEED_FACF, let ncmds = le32(16) else { return [] }
        var out: [Range<Int>] = []
        var lc = 32
        for _ in 0..<min(Int(ncmds), 10_000) {
            guard let cmd = le32(lc), let size = le32(lc + 4), size >= 8 else { break }
            if cmd == 0x19, let nsects = le32(lc + 64) {   // LC_SEGMENT_64; section_64 headers follow its 72 bytes
                for i in 0..<min(Int(nsects), 1000) {
                    let sh = lc + 72 + i * 80
                    guard let sz = le64(sh + 40), let off = le32(sh + 48), let flags = le32(sh + 64) else { break }
                    let start = Int(off), end = start + Int(sz)
                    if flags & 0xFF == 0x2, sz > 0, end <= data.count { out.append((base + start)..<(base + end)) }   // S_CSTRING_LITERALS
                }
            }
            lc += Int(size)
        }
        return out
    }
}
