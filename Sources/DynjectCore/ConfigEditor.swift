import Foundation

/// An app plus the XPC service name dynjectd will see for it.
public struct InjectionTarget: Hashable, Sendable {
    public var app: InstalledApp
    public var service: String

    public init(app: InstalledApp, service: String) {
        self.app = app
        self.service = service
    }
}

public enum ConfigChange: Equatable, Sendable, CustomStringConvertible {
    case inserted(text: String)
    case removed(text: String)
    case modified(old: String, new: String)

    public var description: String {
        switch self {
        case let .inserted(t): return "+ \(t)"
        case let .removed(t): return "- \(t)"
        case let .modified(o, n): return "~ \(o)  →  \(n)"
        }
    }
}

public struct AffectedApp: Equatable, Sendable {
    public var app: InstalledApp
    public var before: [String]
    public var after: [String]
}

public struct InjectionEditResult: Equatable, Sendable {
    public var document: ConfigDocument
    public var changes: [ConfigChange]
    /// Apps other than the target whose effective injection changes.
    public var sideEffects: [AffectedApp]
    public var notes: [String]
}

public enum InjectionEditError: Error, LocalizedError, Equatable {
    case blocked(String)

    public var errorDescription: String? {
        switch self { case let .blocked(m): return m }
    }
}

public enum ConfigEditor {
    public static func setInjection(
        _ enabled: Bool,
        dylib: String,
        for target: InjectionTarget,
        in original: ConfigDocument,
        allTargets: [InjectionTarget],
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> InjectionEditResult {
        var doc = original
        var changes: [ConfigChange] = []
        var notes: [String] = []
        let app = target.app

        func eval(_ d: ConfigDocument) -> AppEvaluation {
            PolicyEvaluator.evaluate(app: app, service: target.service,
                                     config: EffectiveConfig(document: d), fileExists: fileExists)
        }

        let declarations = EffectiveConfig(document: doc).dylibs.filter { $0.path == dylib }
        guard !declarations.isEmpty else {
            throw InjectionEditError.blocked("\(dylib) is not declared with a dylib: line.")
        }
        guard declarations.count == 1 else {
            let lines = declarations.map { String($0.line + 1) }.joined(separator: ", ")
            throw InjectionEditError.blocked(
                "\(dylib) is declared on several lines (\(lines)). Remove the duplicates in the raw editor first.")
        }
        for field in [app.bundleID, app.executableName] where field.isEmpty || field.contains(where: { "\r\n".contains($0) }) {
            throw InjectionEditError.blocked("\(app.displayName) has an empty or multi-line bundle ID or executable name.")
        }

        // Gates: only touched when enabling.
        if enabled {
            let effective = EffectiveConfig(document: doc)
            let gate = PolicyEvaluator.processGate(name: app.executableName, path: app.executablePath, config: effective)
            if !gate.passed {
                if effective.skipHelpers, app.executableName.contains(" Helper") {
                    throw InjectionEditError.blocked(
                        "dynjectd skips executables whose name contains \" Helper\" while skip_helpers is on. Change skip_helpers in the raw editor if you really want this.")
                }
                if let deny = effective.denyRules.first(where: {
                    app.executableName.contains($0.value) || app.executablePath.contains($0.value)
                }) {
                    throw InjectionEditError.blocked(
                        "Global rule deny:\(deny.value) (line \(deny.line + 1)) blocks \(app.executableName) for every dylib. Edit or remove that rule in the raw editor.")
                }
                let rule = "allow:\(app.executableName)"
                let insertAt = (effective.allowRules.last?.line).map { $0 + 1 } ?? doc.lines.count
                doc.insertLine(rule, at: insertAt)
                changes.append(.inserted(text: rule))
                notes.append("Added \(rule) so dynjectd's process filter lets \(app.executableName) through. It is a substring match on the executable name and path.")
            }
            let service = PolicyEvaluator.serviceGate(target.service, config: EffectiveConfig(document: doc))
            if !service.passed {
                throw InjectionEditError.blocked(
                    "dynjectd's XPC filter rejects this app: \(service.reason). Adjust allow/deny rules in the raw editor.")
            }
        }

        // Dylib policy.
        let effective = EffectiveConfig(document: doc)
        let entry = effective.dylib(path: dylib)!
        let service = target.service
        let deciderIndex = entry.overrides.firstIndex { service.contains($0.pattern) }
        let current = deciderIndex.map { entry.overrides[$0].allow } ?? entry.defaultAllow
        let others = allTargets.filter { $0.app.id != app.id }.map(\.service)

        if current != enabled {
            if let k = deciderIndex, !others.contains(where: { $0.contains(entry.overrides[k].pattern) }) {
                // The deciding line only concerns this app: edit it in place.
                let decider = entry.overrides[k]
                let fallback = entry.overrides[(k + 1)...].first { service.contains($0.pattern) }?.allow ?? entry.defaultAllow
                let oldText = doc.lines[decider.line].text
                if fallback == enabled {
                    doc.removeLine(at: decider.line)
                    changes.append(.removed(text: oldText))
                } else {
                    let newText = try rewritePolicy(in: oldText, to: enabled)
                    doc.replaceLine(at: decider.line, with: newText)
                    changes.append(.modified(old: oldText, new: newText))
                }
            } else {
                let pattern = specificPattern(for: target, others: others)
                let line = "dylib-override:\(dylib):\(enabled ? "allow" : "deny"):\(pattern)"
                let insertAt: Int
                if let k = deciderIndex {
                    insertAt = entry.overrides[k].line   // must win before the broader rule
                    notes.append("Inserted above line \(entry.overrides[k].line + 1) (\"\(entry.overrides[k].pattern)\"), which also matches other apps.")
                } else {
                    insertAt = (entry.overrides.last?.line ?? entry.line) + 1
                }
                doc.insertLine(line, at: insertAt)
                changes.append(.inserted(text: line))
                if others.contains(where: { $0.contains(pattern) }) {
                    notes.append("Pattern \"\(pattern)\" also matches other installed apps; see the side effects list.")
                }
            }
        }

        // When disabling, drop an `allow:<exe>` gate that no longer changes anything.
        if !enabled {
            let gateLines = EffectiveConfig(document: doc).allowRules.filter { $0.value == app.executableName }
            for rule in gateLines.reversed() {
                var candidate = doc
                candidate.removeLine(at: rule.line)
                let neutral = allTargets.allSatisfy { t in
                    let a = PolicyEvaluator.evaluate(app: t.app, service: t.service,
                                                     config: EffectiveConfig(document: doc), fileExists: fileExists)
                    let b = PolicyEvaluator.evaluate(app: t.app, service: t.service,
                                                     config: EffectiveConfig(document: candidate), fileExists: fileExists)
                    return a.injectedDylibs == b.injectedDylibs
                }
                if neutral {
                    changes.append(.removed(text: doc.lines[rule.line].text))
                    doc = candidate
                    notes.append("Removed allow:\(app.executableName); no installed app depends on it any more.")
                }
            }
        }

        let result = eval(doc)
        let decided = result.decision(for: dylib)?.allowed ?? false
        if decided != enabled || (enabled && !result.gatesPass) {
            throw InjectionEditError.blocked("Could not find a safe edit that makes this take effect. Use the raw editor.")
        }
        if enabled, result.decision(for: dylib)?.fileMissing == true {
            notes.append("\(dylib) does not exist on disk, so dynjectd will skip it at launch.")
        }

        let side = affectedApps(from: original, to: doc, targets: allTargets.filter { $0.app.id != app.id },
                                fileExists: fileExists)
        return InjectionEditResult(document: doc, changes: changes, sideEffects: side, notes: notes)
    }

    /// Declares a new dylib (default deny, so it loads nowhere until enabled per app). The line goes right
    /// after the existing dylib/override block, or before the process rules if there is none.
    public static func addDylib(_ path: String, to original: ConfigDocument) throws -> ConfigDocument {
        guard path.hasPrefix("/"), !path.contains(where: { ":\r\n".contains($0) }) else {
            throw InjectionEditError.blocked("A dylib path must be absolute and can't contain ':' or line breaks (dynjectd splits on ':').")
        }
        guard path.utf8.count < DynjectLimits.pathMax else { throw InjectionEditError.blocked("Path is too long.") }
        let kinds = original.kinds
        if kinds.contains(where: { if case let .dylib(p, _) = $0 { return p == path } else { return false } }) {
            throw InjectionEditError.blocked("\(path) is already declared.")
        }
        if EffectiveConfig(document: original).dylibs.count >= DynjectLimits.maxDylibs {
            throw InjectionEditError.blocked("dynjectd supports at most \(DynjectLimits.maxDylibs) dylibs.")
        }
        var doc = original
        let lastDylibLine = kinds.lastIndex { if case .dylib = $0 { return true }; if case .override = $0 { return true }; return false }
        let firstRule = kinds.firstIndex { switch $0 { case .allow, .deny, .uiApps, .skipHelpers: return true; default: return false } }
        let at = lastDylibLine.map { $0 + 1 } ?? firstRule ?? doc.lines.count
        doc.insertLine("dylib:\(path):deny", at: at)
        return doc
    }

    /// Apps whose injected dylib set differs between two configs.
    public static func affectedApps(from a: ConfigDocument, to b: ConfigDocument, targets: [InjectionTarget],
                                    fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> [AffectedApp]
    {
        let ea = EffectiveConfig(document: a), eb = EffectiveConfig(document: b)
        return targets.compactMap { t in
            let before = PolicyEvaluator.evaluate(app: t.app, service: t.service, config: ea, fileExists: fileExists).injectedDylibs
            let after = PolicyEvaluator.evaluate(app: t.app, service: t.service, config: eb, fileExists: fileExists).injectedDylibs
            return before == after ? nil : AffectedApp(app: t.app, before: before, after: after)
        }
    }

    /// The narrowest pattern that matches this app and, ideally, no other installed app.
    public static func specificPattern(for target: InjectionTarget, others: [String]) -> String {
        let bid = target.app.bundleID
        var candidates: [String] = []
        if target.service.hasPrefix("application.") {
            candidates = [bid, "application.\(bid)."]
        } else {
            candidates = [target.service, bid]
        }
        for c in candidates where target.service.contains(c) && !others.contains(where: { $0.contains(c) }) {
            return c
        }
        return target.service.hasPrefix("application.") ? "application.\(bid)." : target.service
    }

    /// Replace only the policy field of a dylib-override line, keeping everything else byte-for-byte.
    static func rewritePolicy(in line: String, to allow: Bool) throws -> String {
        guard let keyColon = line.firstIndex(of: ":") else { throw InjectionEditError.blocked("Unexpected override line.") }
        var i = line.index(after: keyColon)
        while i < line.endIndex, line[i] == " " { i = line.index(after: i) }
        guard let p1 = line[i...].firstIndex(of: ":") else { throw InjectionEditError.blocked("Unexpected override line.") }
        let policyStart = line.index(after: p1)
        guard let p2 = line[policyStart...].firstIndex(of: ":") else { throw InjectionEditError.blocked("Unexpected override line.") }
        var out = line
        out.replaceSubrange(policyStart..<p2, with: allow ? "allow" : "deny")
        return out
    }
}
