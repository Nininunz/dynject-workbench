import Foundation

// What a tweak needs to work: a macOS version (`minimumSystemVersion`, `testedSystemVersions`), other tweaks or
// Workbench's agents (`depends`), and a current build of DynjectHook. Install planning (TweakInstaller.plan) and
// `dw doctor` (TweakCompatibility) share these checks. Format: docs/tweak-format.md#versions-and-dependencies.

// MARK: - Dependencies

/// Something Workbench installs besides tweaks, that a tweak can depend on by name.
public enum BuiltInComponent: String, CaseIterable, Sendable {
    /// The bridge agent (LaunchAgent local.dynject.bridge, `dw bridge serve`).
    case bridge
    /// The Safe Mode watcher (LaunchAgent local.dynject.safemode, `dw safemode watch`).
    case safemode

    public var displayName: String {
        switch self {
        case .bridge: return "the bridge"
        case .safemode: return "the Safe Mode watcher"
        }
    }

    /// How to install it.
    public var fix: String {
        switch self {
        case .bridge: return "dw bridge agent install (or Workbench → Bridge → Install Bridge)"
        case .safemode: return "dw safemode agent install (or Workbench → Safe Mode)"
        }
    }

    public var launchAgentLabel: String {
        switch self {
        case .bridge: return BridgeAgent.label
        case .safemode: return SafeModeAgent.label
        }
    }

    /// Whether each component's LaunchAgent plist is in `launchAgentsDirectory` (installed; running is the
    /// agent pages' business). Only reads; never asks launchctl.
    public static func installedStatus(launchAgentsDirectory: URL = UserLaunchAgent.defaultLaunchAgentsDirectory)
        -> [BuiltInComponent: Bool]
    {
        var out: [BuiltInComponent: Bool] = [:]
        for c in allCases {
            out[c] = FileManager.default.fileExists(atPath: launchAgentsDirectory.appendingPathComponent("\(c.launchAgentLabel).plist").path)
        }
        return out
    }
}

/// One entry of a manifest's `depends`: "<tweak id>", "<tweak id> >= <version>", "bridge" or "safemode".
public struct TweakDependency: Hashable, Sendable, CustomStringConvertible {
    public enum Target: Hashable, Sendable {
        case tweak(id: String, minimumVersion: SemanticVersion?)
        case component(BuiltInComponent)
    }

    public var target: Target
    /// Not written in `depends`: a manifest with `bridge` capabilities depends on the bridge.
    public var implicit: Bool

    public init(_ target: Target, implicit: Bool = false) {
        self.target = target
        self.implicit = implicit
    }

    /// Parses one entry. nil (with a message) if it is malformed.
    public static func parse(_ raw: String) -> (TweakDependency?, String?) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let pattern = "^([A-Za-z0-9][A-Za-z0-9.-]*)(\\s*>=\\s*(\\S+))?$"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let nameRange = Range(m.range(at: 1), in: s) else {
            return (nil, "\"\(raw)\" is not \"<tweak id>\", \"<tweak id> >= <version>\", \"bridge\" or \"safemode\"")
        }
        let name = String(s[nameRange])
        let version = Range(m.range(at: 3), in: s).map { String(s[$0]) }
        if let c = BuiltInComponent(rawValue: name) {
            if version != nil { return (TweakDependency(.component(c)), "\"\(raw)\": \(name) has no version; the version is ignored") }
            return (TweakDependency(.component(c)), nil)
        }
        guard let version else { return (TweakDependency(.tweak(id: name, minimumVersion: nil)), nil) }
        guard let v = SemanticVersion(version) else {
            return (nil, "\"\(raw)\": \(version) is not a semantic version (MAJOR.MINOR.PATCH)")
        }
        return (TweakDependency(.tweak(id: name, minimumVersion: v)), nil)
    }

    public var description: String {
        switch target {
        case let .tweak(id, v?): return "\(id) >= \(v)"
        case let .tweak(id, nil): return id
        case let .component(c): return c.rawValue
        }
    }
}

public extension TweakManifest {
    /// `version` as a semantic version; nil if absent or not one.
    var semanticVersion: SemanticVersion? { version.flatMap(SemanticVersion.init) }

    /// `depends`, plus "bridge" when the manifest declares bridge capabilities and doesn't list it.
    var allDependencies: [TweakDependency] {
        var out = depends
        if !bridge.isEmpty, !out.contains(where: { $0.target == .component(.bridge) }) {
            out.append(TweakDependency(.component(.bridge), implicit: true))
        }
        return out
    }

    /// The tweak IDs this manifest depends on.
    var dependencyTweakIDs: [String] {
        allDependencies.compactMap { if case let .tweak(id, _) = $0.target { return id } else { return nil } }
    }
}

extension TweakManifestParser {
    /// `version` (warned about unless semantic), `minimumSystemVersion`, `testedSystemVersions` and `depends`.
    static func parseCompatibility(_ root: [String: Any], id: String, into m: inout TweakManifest,
                                   error: (String) -> Void, warning: (String) -> Void) {
        if let raw = root["version"] {
            if let v = raw as? String {
                if SemanticVersion(v) == nil {
                    warning("version \"\(v)\" is not a semantic version (MAJOR.MINOR.PATCH, e.g. 1.2.0, optionally -beta.1); installs can't tell an upgrade from a downgrade.")
                }
            } else {
                warning("version must be a string such as \"1.2.0\"; ignored.")
            }
        }
        if let raw = root["minimumSystemVersion"] {
            if let s = raw as? String, let v = SystemVersion(s) {
                m.minimumSystemVersion = v
            } else {
                error("minimumSystemVersion must be a string such as \"27.0\"; ignored.")
            }
        }
        if let raw = root["testedSystemVersions"] {
            if let s = raw as? String, let r = SystemVersionRange(s) {
                m.testedSystemVersions = r
                if let min = m.minimumSystemVersion, r.upper.truncated(to: r.upper.components.count) < min.truncated(to: r.upper.components.count) {
                    warning("testedSystemVersions \(r) is entirely below minimumSystemVersion \(min).")
                }
            } else {
                error("testedSystemVersions must be a string such as \"27.0 - 27.2\" or \"27.2\" (lowest first); ignored.")
            }
        }
        guard let raw = root["depends"] else { return }
        guard let list = raw as? [Any] else { error("depends must be an array of strings; ignored."); return }
        for (i, entry) in list.enumerated() {
            guard let s = entry as? String else { error("depends[\(i)] is not a string; skipped."); continue }
            let (dep, message) = TweakDependency.parse(s)
            guard let dep else { error("depends[\(i)] \(message ?? s); skipped."); continue }
            if let message { error("depends[\(i)] \(message).") }
            if case let .tweak(other, _) = dep.target, other == id { error("depends[\(i)]: a tweak can't depend on itself; skipped."); continue }
            if m.depends.contains(where: { $0.target == dep.target }) { warning("depends[\(i)] \"\(s)\" is listed twice."); continue }
            m.depends.append(dep)
        }
    }
}

/// Why a dependency isn't met, and what to run about it.
public struct UnmetDependency: Equatable, Sendable {
    public var dependency: TweakDependency
    public var message: String
    public var fix: String
}

/// Checks `depends` against what is installed. Both sources are injectable.
public struct DependencyChecker: Sendable {
    /// Installed tweaks' manifests (the first one per identifier wins, as in TweakManifestLoader).
    public var installed: [TweakManifest]
    /// Whether each component is installed; a component missing from the dictionary is unknown and never unmet.
    public var components: [BuiltInComponent: Bool]

    public init(installed: [TweakManifest], components: [BuiltInComponent: Bool]) {
        self.installed = installed
        self.components = components
    }

    /// Installed manifests and components at `locations`, with the agents' plists in `launchAgentsDirectory`.
    public static func live(locations: TweakLocations,
                            launchAgentsDirectory: URL = UserLaunchAgent.defaultLaunchAgentsDirectory) -> DependencyChecker {
        DependencyChecker(installed: TweakManifestLoader.load(directories: locations.manifestSearchDirectories).manifests,
                          components: BuiltInComponent.installedStatus(launchAgentsDirectory: launchAgentsDirectory))
    }

    public func installedManifest(_ id: String) -> TweakManifest? { installed.first { $0.id == id } }

    /// The one dependency's problem, or nil when it is met (or can't be known).
    public func problem(_ d: TweakDependency) -> UnmetDependency? {
        switch d.target {
        case let .component(c):
            guard components[c] == false else { return nil }
            let why = d.implicit ? " (it declares bridge capabilities)" : ""
            return UnmetDependency(dependency: d, message: "needs \(c.displayName), which isn't installed\(why)", fix: c.fix)
        case let .tweak(id, minimum):
            guard let m = installedManifest(id) else {
                let what = minimum.map { "\(id) \($0) or later" } ?? id
                return UnmetDependency(dependency: d, message: "needs \(what), which isn't installed",
                                       fix: "dw tweak install <\(id)'s folder>")
            }
            guard let minimum else { return nil }
            guard let v = m.semanticVersion else {
                return UnmetDependency(dependency: d,
                                       message: "needs \(m.name) (\(id)) \(minimum) or later; the installed one's version \(m.version.map { "\"\($0)\"" } ?? "(none)") can't be compared",
                                       fix: "dw tweak install <\(id)'s folder, \(minimum) or later>")
            }
            guard v < minimum else { return nil }
            return UnmetDependency(dependency: d, message: "needs \(m.name) (\(id)) \(minimum) or later; \(v) is installed",
                                   fix: "dw tweak install <\(id)'s folder, \(minimum) or later>")
        }
    }

    public func unmet(for manifest: TweakManifest) -> [UnmetDependency] {
        manifest.allDependencies.compactMap(problem)
    }

    /// Installed tweaks (other than `tweakID` itself) that depend on `tweakID`.
    public func dependents(of tweakID: String) -> [TweakManifest] {
        installed.filter { $0.id != tweakID && $0.dependencyTweakIDs.contains(tweakID) }
    }
}

// MARK: - Install checks

/// Choices that let an install go ahead despite a refusal.
public struct TweakInstallOptions: Sendable, Equatable {
    /// Install an older version over a newer one (`dw tweak install --allow-downgrade`).
    public var allowDowngrade: Bool
    /// Install below `minimumSystemVersion` or with unmet `depends` (`--force`).
    public var force: Bool
    /// The macOS to check against (tests).
    public var systemVersion: SystemVersion
    /// Which components are installed, for `depends`. Missing entries are unknown and never unmet.
    public var components: [BuiltInComponent: Bool]
    /// Other apps the config edit may reach too, accepted by bundle ID (`--also`). dynjectd matches service names
    /// by substring, so enabling a tweak for com.apple.controlcenter also reaches
    /// com.apple.controlcenter.PreloginSystemBannerRenderer; a tweak whose DH_CTOR names only the first stays out of it.
    public var alsoAffecting: Set<String>
    /// Installing from a package (docs/packages.md): its file, and the stricter rules that come with it.
    public var package: TweakPackageInfo?
    /// A package's `applyCommand` (`--allow-apply-command`).
    public var allowApplyCommand: Bool
    /// A package signed by someone other than the installed build's signer (`--allow-signer-change`).
    public var allowSignerChange: Bool

    public init(allowDowngrade: Bool = false, force: Bool = false, systemVersion: SystemVersion = .current,
                components: [BuiltInComponent: Bool] = [:], alsoAffecting: Set<String> = [], package: TweakPackageInfo? = nil,
                allowApplyCommand: Bool = false, allowSignerChange: Bool = false) {
        self.package = package
        self.allowApplyCommand = allowApplyCommand
        self.allowSignerChange = allowSignerChange
        self.allowDowngrade = allowDowngrade
        self.force = force
        self.systemVersion = systemVersion
        self.components = components
        self.alsoAffecting = alsoAffecting
    }
}

/// Installed version → new version.
public enum TweakVersionChange: Equatable, Sendable {
    /// Not installed yet.
    case fresh(String?)
    case upgrade(from: SemanticVersion, to: SemanticVersion)
    case downgrade(from: SemanticVersion, to: SemanticVersion)
    /// Same version, same dylib.
    case same(String?)
    /// Same version, a different dylib (a rebuild).
    case rebuilt(String?)
    /// Different versions that can't be ordered (one isn't semantic, or missing).
    case changed(from: String?, to: String?)

    static func between(installed: TweakManifest?, new: TweakManifest, dylibChanged: Bool) -> TweakVersionChange {
        guard let installed else { return .fresh(new.version) }
        if let a = installed.semanticVersion, let b = new.semanticVersion {
            if b > a { return .upgrade(from: a, to: b) }
            if b < a { return .downgrade(from: a, to: b) }
            return dylibChanged ? .rebuilt(new.version) : .same(new.version)
        }
        if installed.version == new.version { return dylibChanged ? .rebuilt(new.version) : .same(new.version) }
        return .changed(from: installed.version, to: new.version)
    }

    public var isDowngrade: Bool { if case .downgrade = self { return true } else { return false } }

    /// One line for the plan summary.
    public var summary: String {
        func v(_ s: String?) -> String { s ?? "(no version)" }
        switch self {
        case let .fresh(s): return "New install: version \(v(s))"
        case let .upgrade(a, b): return "Installed \(a) → new \(b) (upgrade)"
        case let .downgrade(a, b): return "Installed \(a) → new \(b) (downgrade)"
        case let .same(s): return "Installed \(v(s)) → new \(v(s)) (same build)"
        case let .rebuilt(s): return "Installed \(v(s)) → new \(v(s)) (rebuilt: same version, different dylib)"
        case let .changed(a, b): return "Installed \(v(a)) → new \(v(b)) (can't tell upgrade from downgrade: not semantic versions)"
        }
    }
}

/// Something that stops an install unless overridden.
public struct TweakInstallRefusal: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case downgrade, systemTooOld, unmetDependency, applyCommand, signerChange }
    public var id: String { kind.rawValue + ":" + message }
    public var kind: Kind
    public var message: String
    public var fix: String?

    /// The dw option that overrides it.
    public var override: String {
        switch kind {
        case .downgrade: return "--allow-downgrade"
        case .applyCommand: return "--allow-apply-command"
        case .signerChange: return "--allow-signer-change"
        case .systemTooOld, .unmetDependency: return "--force"
        }
    }

    /// Whether `options` override it.
    public func isOverridden(by options: TweakInstallOptions) -> Bool {
        switch kind {
        case .downgrade: return options.allowDowngrade
        case .applyCommand: return options.allowApplyCommand
        case .signerChange: return options.allowSignerChange
        case .systemTooOld, .unmetDependency: return options.force
        }
    }
}

/// The version, macOS and dependency checks of one install plan.
public struct TweakInstallCheck: Sendable, Equatable {
    public var change: TweakVersionChange
    /// Refusals the options don't override; while there are any, the install doesn't run.
    public var refusals: [TweakInstallRefusal]
    /// Refusals the options override (shown as warnings).
    public var overridden: [TweakInstallRefusal]
    /// Soft problems: outside the tested macOS range, for example.
    public var warnings: [String]

    public init(change: TweakVersionChange = .fresh(nil), refusals: [TweakInstallRefusal] = [],
                overridden: [TweakInstallRefusal] = [], warnings: [String] = []) {
        self.change = change
        self.refusals = refusals
        self.overridden = overridden
        self.warnings = warnings
    }

    public static func evaluate(_ manifest: TweakManifest, installed: [TweakManifest], dylibChanged: Bool,
                                options: TweakInstallOptions) -> TweakInstallCheck {
        let current = installed.first { $0.id == manifest.id }
        var check = TweakInstallCheck(change: .between(installed: current, new: manifest, dylibChanged: dylibChanged))
        var all: [TweakInstallRefusal] = []
        if case let .downgrade(a, b) = check.change {
            all.append(.init(kind: .downgrade, message: "\(b) is older than the installed \(a).",
                             fix: "install \(a) or later, or allow the downgrade"))
        }
        let system = options.systemVersion
        if let min = manifest.minimumSystemVersion, system < min {
            all.append(.init(kind: .systemTooOld, message: "\(manifest.name) needs macOS \(min) or later; this Mac runs \(system).", fix: nil))
        }
        if let tested = manifest.testedSystemVersions, !tested.contains(system) {
            check.warnings.append("\(manifest.name) was tested on macOS \(tested); this Mac runs \(system). It may work; if it misbehaves, check for an update.")
        }
        // The tweak being replaced doesn't count as installed for its own dependencies.
        let deps = DependencyChecker(installed: installed.filter { $0.id != manifest.id }, components: options.components)
        for u in deps.unmet(for: manifest) {
            all.append(.init(kind: .unmetDependency, message: "\(manifest.name) \(u.message).", fix: u.fix))
        }
        if options.package != nil, let cmd = manifest.applyCommand, !cmd.isEmpty {
            all.append(.init(kind: .applyCommand,
                             message: "The package's manifest runs \(cmd.joined(separator: " ")) as you, from Workbench, each time you change a setting.",
                             fix: "install it only if you trust that program"))
        }
        for r in all {
            if r.isOverridden(by: options) { check.overridden.append(r) } else { check.refusals.append(r) }
        }
        check.warnings += check.overridden.map { "Installing anyway (\($0.override)): \($0.message)" }
        return check
    }

    /// The refusal as one message, e.g. for an error.
    public var refusalText: String {
        refusals.map { r in
            "\(r.message)\(r.fix.map { " Fix: \($0)." } ?? "") (\(r.override) installs anyway.)"
        }.joined(separator: "\n")
    }
}

// MARK: - Installed tweaks (dw doctor)

/// One compatibility problem of an installed tweak.
public struct CompatibilityIssue: Equatable, Sendable, Identifiable {
    public enum Severity: String, Sendable {
        /// ✗: it won't work as installed.
        case error
        /// !: it may not work, or should be looked at.
        case warning

        public var symbol: String { self == .error ? "✗" : "!" }
    }

    public enum Kind: String, Sendable {
        case systemTooOld, untestedSystem, nonSemanticVersion, oldSDK, missingSDKMarker, unmetDependency
    }

    public var id: String { tweakID + ":" + kind.rawValue + ":" + message }
    public var tweakID: String
    public var severity: Severity
    public var kind: Kind
    public var message: String
    /// What to do about it; nil when there's nothing to run.
    public var fix: String?
}

/// What a built dylib says about itself.
public struct DylibBuildInfo: Equatable, Sendable {
    /// "dynject.sdk:<version>" marker; nil before markers existed (or without DynjectHook).
    public var sdkVersion: String?
    /// DynjectHook is compiled in (Safe Mode marker).
    public var usesDynjectHook: Bool

    public init(sdkVersion: String?, usesDynjectHook: Bool) {
        self.sdkVersion = sdkVersion
        self.usesDynjectHook = usesDynjectHook
    }

    /// Reads the file at `path` (cached); nil when it can't be read.
    public static func read(dylibAt path: String, sdk: SDKVersionChecker = .shared,
                            safeMode: SafeModeSupportChecker = .shared) -> DylibBuildInfo? {
        guard let support = safeMode.support(dylibAt: path) else { return nil }
        return DylibBuildInfo(sdkVersion: sdk.version(dylibAt: path), usesDynjectHook: support != .unsupported)
    }
}

/// Compatibility of installed tweaks with this Mac, this SDK and each other. `dw doctor` lists it.
public enum TweakCompatibility {
    public struct Environment: Sendable {
        public var systemVersion: SystemVersion
        /// The SDK this Workbench ships (DH_SDK_VERSION).
        public var sdkVersion: String
        public var components: [BuiltInComponent: Bool]
        /// The build info of a manifest's dylib; nil when it is missing or unreadable (no SDK issue then).
        public var dylib: @Sendable (TweakManifest) -> DylibBuildInfo?

        public init(systemVersion: SystemVersion = .current, sdkVersion: String = WorkbenchInfo.sdkVersion,
                    components: [BuiltInComponent: Bool] = [:],
                    dylib: @escaping @Sendable (TweakManifest) -> DylibBuildInfo? = { _ in nil }) {
            self.systemVersion = systemVersion
            self.sdkVersion = sdkVersion
            self.components = components
            self.dylib = dylib
        }

        /// This Mac: dylibs read where `locations` keeps them, agents' plists in `launchAgentsDirectory`.
        public static func live(locations: TweakLocations,
                                launchAgentsDirectory: URL = UserLaunchAgent.defaultLaunchAgentsDirectory) -> Environment {
            Environment(components: BuiltInComponent.installedStatus(launchAgentsDirectory: launchAgentsDirectory),
                        dylib: { DylibBuildInfo.read(dylibAt: locations.filePath(forDylib: $0.dylib)) })
        }
    }

    /// The issues of one tweak; `installed` is every installed manifest (for `depends`).
    public static func issues(for m: TweakManifest, installed: [TweakManifest], environment env: Environment) -> [CompatibilityIssue] {
        var out: [CompatibilityIssue] = []
        func add(_ s: CompatibilityIssue.Severity, _ k: CompatibilityIssue.Kind, _ message: String, _ fix: String?) {
            out.append(CompatibilityIssue(tweakID: m.id, severity: s, kind: k, message: message, fix: fix))
        }
        let system = env.systemVersion
        if let min = m.minimumSystemVersion, system < min {
            add(.error, .systemTooOld, "needs macOS \(min) or later; this Mac runs \(system)",
                "uninstall it (dw tweak uninstall \(m.id)) or update macOS")
        } else if let tested = m.testedSystemVersions, !tested.contains(system) {
            add(.warning, .untestedSystem, "tested on macOS \(tested); this Mac runs \(system)",
                "check that it works; look for an update")
        }
        if let v = m.version, SemanticVersion(v) == nil {
            add(.warning, .nonSemanticVersion, "version \"\(v)\" is not a semantic version (MAJOR.MINOR.PATCH)",
                "set version to e.g. \"\(suggestedSemanticVersion(v))\" in \((m.sourcePath as NSString).lastPathComponent)")
        }
        if let build = env.dylib(m), build.usesDynjectHook {
            if let built = build.sdkVersion {
                if let a = SemanticVersion(built), let b = SemanticVersion(env.sdkVersion), a < b {
                    add(.warning, .oldSDK, "built with DynjectHook \(built); the current SDK is \(env.sdkVersion)",
                        "rebuild it with the current SDK and reinstall (dw tweak install <its folder>)")
                }
            } else {
                add(.warning, .missingSDKMarker, "built with a DynjectHook older than \(env.sdkVersion) (no SDK version in the dylib)",
                    "rebuild it with the current SDK and reinstall (dw tweak install <its folder>)")
            }
        }
        let deps = DependencyChecker(installed: installed, components: env.components)
        for u in deps.unmet(for: m) { add(.error, .unmetDependency, u.message, u.fix) }
        return out
    }

    /// Every installed tweak with its issues (empty when fine), in `installed` order.
    public static func check(_ installed: [TweakManifest], environment: Environment) -> [(manifest: TweakManifest, issues: [CompatibilityIssue])] {
        installed.map { ($0, issues(for: $0, installed: installed, environment: environment)) }
    }

    /// The installed tweaks at `locations`, checked against this Mac.
    public static func check(locations: TweakLocations,
                             launchAgentsDirectory: URL = UserLaunchAgent.defaultLaunchAgentsDirectory)
        -> [(manifest: TweakManifest, issues: [CompatibilityIssue])]
    {
        let installed = TweakManifestLoader.load(directories: locations.manifestSearchDirectories).manifests
        return check(installed, environment: .live(locations: locations, launchAgentsDirectory: launchAgentsDirectory))
    }

    /// "1.2" → "1.2.0", "3" → "3.0.0"; otherwise "1.0.0".
    static func suggestedSemanticVersion(_ v: String) -> String {
        let parts = v.split(separator: ".").map(String.init)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return "1.0.0" }
        let nums = parts.compactMap(Int.init)
        guard nums.count == parts.count else { return "1.0.0" }
        return (nums + Array(repeating: 0, count: 3 - nums.count)).map(String.init).joined(separator: ".")
    }
}
