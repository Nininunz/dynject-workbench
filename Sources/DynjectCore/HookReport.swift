import Foundation

// `dw hooks <app>`: what the DynjectHook copies in a running app say they have hooked (their answer to a report
// request, see "Hook reports" in TweakSDK/DynjectHook.m), read back from the unified log and put together.

public struct HookReport: Sendable {
    public struct Hook: Equatable, Sendable {
        public var image: String
        public var tweakID: String
        public var classMethod: Bool
        public var cls: String
        public var sel: String
        /// pending, installed, restored, buried
        public var state: String
        /// The replacement is the method's implementation right now (outermost).
        public var top: Bool
        public var group: String?

        public var method: String { "\(classMethod ? "+" : "-")[\(cls) \(sel)]" }
        /// In the method now (installed, or buried beneath another hook).
        public var present: Bool { state == "installed" || state == "buried" }
    }

    public struct Import: Equatable, Sendable {
        public var image: String
        public var tweakID: String
        public var symbol: String
        public var library: String?
        public var sites: Int
        public var active: Bool
    }

    /// A function hooked inline (DHHookFunction).
    public struct Function: Equatable, Sendable {
        public var image: String
        public var tweakID: String
        /// The function's address in the process ("0x…"): the same function has the same address for every tweak.
        public var address: String
        /// "image`symbol+offset", or the address when it has no symbol.
        public var name: String
        public var active: Bool
        /// Went on top of another inline hook, so it runs before that one.
        public var stacked: Bool
        public var group: String?
    }

    public struct Copy: Equatable, Sendable {
        public var image: String
        public var tweakID: String
        public var sdk: String?
        public var hooks: [Hook] = []
        public var imports: [Import] = []
        public var functions: [Function] = []
        /// Its "end" line arrived.
        public var complete = false
    }

    /// A method of another image's class whose implementation is in a tweak dylib (the --scan).
    public struct Foreign: Equatable, Sendable {
        public var classMethod: Bool
        public var cls: String
        public var sel: String
        public var image: String
        public var classImage: String
        public var method: String { "\(classMethod ? "+" : "-")[\(cls) \(sel)]" }
    }

    public var copies: [Copy] = []
    public var foreign: [Foreign] = []
    public var scanned = false
    public var scanFinished = false
    public var scanMilliseconds: Int?

    public init() {}

    /// The report for `request` in log messages (other requests' lines are skipped).
    public static func parse(_ messages: [String], request: UInt32) -> HookReport {
        var r = HookReport()
        let prefix = "R \(request) "
        func value(_ field: String, _ key: String) -> String? { field.hasPrefix(key + "=") ? String(field.dropFirst(key.count + 1)) : nil }
        func index(_ image: String) -> Int? { r.copies.firstIndex { $0.image == image } }
        var current: [String: String] = [:]   // tweak ID -> image of the copy whose report is in progress
        for message in messages where message.hasPrefix(prefix) {
            let body = String(message.dropFirst(prefix.count))
            let f = body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let kind = f.first else { continue }
            switch kind {
            case "begin" where f.count >= 4:
                let tweak = f[1]
                guard let imageRange = body.range(of: " image=") else { continue }
                let image = String(body[imageRange.upperBound...])
                current[tweak] = image
                if index(image) == nil { r.copies.append(Copy(image: image, tweakID: tweak, sdk: value(f[2], "sdk"))) }
            case "hook" where f.count >= 8:
                let tweak = f[1]
                guard let image = current[tweak], let i = index(image) else { continue }
                let group = body.range(of: " group=").map { String(body[$0.upperBound...]) }
                r.copies[i].hooks.append(Hook(image: image, tweakID: tweak, classMethod: f[2] == "+", cls: f[3], sel: f[4], state: f[5],
                                              top: f[6] == "top", group: group == "-" ? nil : group))
            case "import" where f.count >= 6:
                let tweak = f[1]
                guard let image = current[tweak], let i = index(image) else { continue }
                let lib = value(f[3], "lib")
                r.copies[i].imports.append(Import(image: image, tweakID: tweak, symbol: f[2], library: lib == "-" ? nil : lib,
                                                  sites: Int(value(f[4], "sites") ?? "") ?? 0, active: f[5] == "active"))
            case "function" where f.count >= 7:
                let tweak = f[1]
                guard let image = current[tweak], let i = index(image) else { continue }
                let group = body.range(of: " group=").map { String(body[$0.upperBound...]) }
                r.copies[i].functions.append(Function(image: image, tweakID: tweak, address: f[2], name: f[3], active: f[4] == "active",
                                                      stacked: f[5] == "stacked", group: group == "-" ? nil : group))
            case "end" where f.count >= 2:
                if let image = current[f[1]], let i = index(image) { r.copies[i].complete = true }
            case "scan-begin":
                r.scanned = true
            case "foreign" where f.count >= 5:
                guard let impRange = body.range(of: " imp="), let classRange = body.range(of: " class=", range: impRange.upperBound..<body.endIndex)
                else { continue }
                r.foreign.append(Foreign(classMethod: f[1] == "+", cls: f[2], sel: f[3],
                                         image: String(body[impRange.upperBound..<classRange.lowerBound]),
                                         classImage: String(body[classRange.upperBound...])))
            case "scan-end":
                r.scanFinished = true
                r.scanMilliseconds = f.dropFirst().compactMap { value($0, "ms") }.first.flatMap(Int.init)
            default:
                continue
            }
        }
        return r
    }

    /// Methods hooked by more than one copy (tweak), with the one whose replacement is on top.
    public struct Conflict: Equatable, Sendable {
        public var method: String
        public var tweakIDs: [String]
        public var top: String?
    }

    public var conflicts: [Conflict] {
        var order: [String] = []
        var byMethod: [String: [Hook]] = [:]
        for c in copies {
            for h in c.hooks where h.present {
                if byMethod[h.method] == nil { order.append(h.method) }
                byMethod[h.method, default: []].append(h)
            }
        }
        let methods: [Conflict] = order.compactMap { m in
            let hooks = byMethod[m] ?? []
            var images: [String] = []
            for h in hooks where !images.contains(h.image) { images.append(h.image) }
            guard images.count > 1 else { return nil }
            let ids = images.map { img in hooks.first { $0.image == img }!.tweakID }
            return Conflict(method: m, tweakIDs: ids, top: hooks.first { $0.top }?.tweakID)
        }
        // Functions: by address. The hook that went on top of the others runs first; with more than two, the last
        // one stacked is on top, which the report can't tell apart from the middle ones.
        var addresses: [String] = []
        var byAddress: [String: [Function]] = [:]
        for c in copies {
            for f in c.functions {
                if byAddress[f.address] == nil { addresses.append(f.address) }
                byAddress[f.address, default: []].append(f)
            }
        }
        let functions: [Conflict] = addresses.compactMap { a in
            let hooks = byAddress[a] ?? []
            var images: [String] = []
            for h in hooks where !images.contains(h.image) { images.append(h.image) }
            guard images.count > 1 else { return nil }
            let ids = images.map { img in hooks.first { $0.image == img }!.tweakID }
            let stacked = hooks.filter(\.stacked)
            return Conflict(method: "function " + hooks[0].name, tweakIDs: ids, top: stacked.count == 1 ? stacked[0].tweakID : nil)
        }
        return methods + functions
    }

    /// --scan results that no answering copy reported as its own hook: other hooking code, or categories.
    public var foreignNotReported: [Foreign] {
        let reported = Set(copies.flatMap { c in c.hooks.filter(\.present).map { "\($0.image)|\($0.method)" } })
        return foreign.filter { !reported.contains("\($0.image)|\($0.method)") }
    }

    /// Why a loaded tweak dylib didn't answer.
    public enum Silence: Equatable, Sendable {
        /// Built without DynjectHook: it can't report.
        case noDynjectHook
        /// A DynjectHook from before hook reports.
        case tooOld
        /// It can report, so it isn't active here: its DH_CTOR filter, Safe Mode or the Shift key kept it out.
        case inactive
        /// Couldn't read the file.
        case unknown
    }

    public static func silence(supportsReports: Bool?, usesDynjectHook: Bool?) -> Silence {
        if usesDynjectHook == false { return .noDynjectHook }
        switch supportsReports {
        case true?: return .inactive
        case false?: return .tooOld
        case nil: return .unknown
        }
    }

    // MARK: text

    public func text(header: String, names: [String: String], silent: [(path: String, why: Silence, tweakID: String?)],
                     bundleID: String) -> String {
        var out = [header, ""]
        func file(_ path: String) -> String { (path as NSString).lastPathComponent }
        func label(_ c: Copy) -> String {
            let name = names[c.tweakID].map { "\($0)  " } ?? ""
            return "\(name)\(c.tweakID)  (\(file(c.image))\(c.sdk.map { ", sdk \($0)" } ?? ""))"
        }
        if copies.isEmpty { out.append("no DynjectHook tweak in it answered") }
        for c in copies {
            out.append(label(c) + (c.complete ? "" : "  [report cut short]"))
            let width = min(56, max(30, (c.hooks.map(\.method.count) + c.imports.map { $0.symbol.count + 7 }
                                          + c.functions.map { $0.name.count + 9 }).max() ?? 30))
            func pad(_ s: String) -> String { s.count >= width ? s + "  " : s + String(repeating: " ", count: width - s.count + 2) }
            if c.hooks.isEmpty && c.imports.isEmpty && c.functions.isEmpty { out.append("  no hooks") }
            for h in c.hooks {
                var what = h.state
                if h.present { what += h.top ? ", top" : ", beneath another hook" }
                if let g = h.group { what += ", group \(g)" }
                out.append("  \(pad(h.method))\(what)")
            }
            for i in c.imports {
                let lib = i.library.map { " (\($0))" } ?? ""
                out.append("  \(pad("import " + i.symbol))\(i.sites) site\(i.sites == 1 ? "" : "s")\(lib), \(i.active ? "active" : "inactive")")
            }
            for f in c.functions {
                var what = f.active ? "active" : "inactive"
                if f.stacked { what += ", on top of another hook" }
                if let g = f.group { what += ", group \(g)" }
                out.append("  \(pad("function " + f.name))\(what)")
            }
            out.append("")
        }
        for c in conflicts {
            let who = c.tweakIDs.map { id in (names[id] ?? id) + (id == c.top ? " (top)" : "") }.joined(separator: ", ")
            out.append("! \(c.method) is hooked by \(c.tweakIDs.count) tweaks: \(who). the top one runs first and calls the others' through its original")
        }
        if !conflicts.isEmpty { out.append("") }
        if scanned {
            let rest = foreignNotReported
            if rest.isEmpty {
                out.append("scan: nothing else in tweak dylibs replaces or adds methods of other images' classes" +
                           (scanMilliseconds.map { " (\($0) ms)" } ?? ""))
            } else {
                out.append("scan: methods of other images' classes implemented in tweak dylibs, not reported as DynjectHook hooks (other hooking code, or categories):")
                for f in rest.prefix(200) {
                    out.append("  \(f.method)  in \(file(f.image)), class from \(file(f.classImage))")
                }
                if rest.count > 200 { out.append("  … \(rest.count - 200) more") }
            }
            if !scanFinished { out.append("  [scan cut short]") }
            out.append("")
        }
        if !silent.isEmpty {
            out.append("loaded, didn't answer:")
            for s in silent {
                let why: String
                switch s.why {
                case .noDynjectHook: why = "not built on DynjectHook, so it can't report (--scan shows what it replaced)"
                case .tooOld: why = "built before hook reports: rebuild it with the current TweakSDK"
                case .inactive: why = "loaded but not active here: its DH_CTOR apps, Safe Mode or Shift at launch kept it out (dw why \(s.tweakID ?? file(s.path)) \(bundleID))"
                case .unknown: why = "couldn't read the file"
                }
                out.append("  \(file(s.path)): \(why)")
            }
            out.append("")
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n")
    }
}

/// Whether a dylib carries the hook report marker (DynjectHook with `dw hooks` support).
public enum HookReportSupport {
    public static let marker = "dynject.hooks:report-v1"

    public static func supports(dylibAt path: String) -> Bool? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return data.range(of: Data(marker.utf8)) != nil
    }
}
