import Foundation

// Installing and uninstalling tweaks: `dw tweak install|uninstall|list` and Workbench's Tweaks page share this code.
//
// A tweak folder holds a manifest (*.workbench.plist) whose `dylib` is the install path (a file directly in
// /opt/dynject/lib/tweaks) and the built dylib (build/<that name>, next to the manifest, or given explicitly).
// Installing copies the dylib, declares it in the config (deny by default) and enables it for the apps asked for,
// all in one privileged helper invocation with the dynjectd restart folded in, then copies the manifest into
// Workbench's Tweaks folder (no privileges needed).

// MARK: - Locations

/// Where installs read and write. `live` is the real engine; tests and fixture mode use temporary folders.
public struct TweakLocations: Sendable, Equatable {
    public static let liveTweaksDirectory = "/opt/dynject/lib/tweaks"
    public static let liveConfigPath = "/opt/dynject/etc/dynjectd.conf"

    public var configPath: String
    /// The folder manifests' `dylib` paths (and the config's `dylib:` lines) name.
    public var tweaksDirectory: String
    /// Where those files really are: `tweaksDirectory`, except in fixture mode and tests, which keep the real paths
    /// in the config but put the bytes in a folder of their own.
    public var dylibFileDirectory: String
    /// Workbench's Tweaks folder (user-writable), where installed manifests go.
    public var manifestsDirectory: String

    public init(configPath: String, tweaksDirectory: String = TweakLocations.liveTweaksDirectory,
                dylibFileDirectory: String? = nil, manifestsDirectory: String) {
        self.configPath = configPath
        self.tweaksDirectory = tweaksDirectory
        self.dylibFileDirectory = dylibFileDirectory ?? tweaksDirectory
        self.manifestsDirectory = manifestsDirectory
    }

    public static var defaultSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dynject Workbench", isDirectory: true)
    }

    public static func live(supportDirectory: URL = defaultSupportDirectory) -> TweakLocations {
        TweakLocations(configPath: liveConfigPath, manifestsDirectory: supportDirectory.appendingPathComponent("Tweaks").path)
    }

    /// Everything under `root`: root/etc/dynjectd.conf, root/lib/tweaks (dylib files), root/Tweaks (manifests).
    public static func sandbox(root: URL) -> TweakLocations {
        // Real path (e.g. /private/tmp, not /tmp): deleting a dylib is refused in a folder reached through a symlink.
        var r = root.standardizedFileURL.path
        if let real = realpath(r, nil) { r = String(cString: real); free(real) }
        return TweakLocations(configPath: r + "/etc/dynjectd.conf", dylibFileDirectory: r + "/lib/tweaks",
                              manifestsDirectory: r + "/Tweaks")
    }

    public var isLive: Bool {
        configPath == Self.liveConfigPath && tweaksDirectory == Self.liveTweaksDirectory && dylibFileDirectory == tweaksDirectory
    }

    /// Where the bytes of the installed dylib `path` live.
    public func filePath(forDylib path: String) -> String {
        guard dylibFileDirectory != tweaksDirectory, path.hasPrefix(tweaksDirectory + "/") else { return path }
        return dylibFileDirectory + String(path.dropFirst(tweaksDirectory.count))
    }

    /// Folders searched for installed manifests: the Tweaks folder, then next to the installed dylibs.
    public var manifestSearchDirectories: [String] { [manifestsDirectory, dylibFileDirectory] }

    /// Why `path` can't be an install path, or nil: it must be a plain `*.dylib` name directly in the tweaks folder,
    /// usable in a `dylib:` line.
    public func installPathProblem(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard path == tweaksDirectory + "/" + name else {
            return "\(path) is not directly in \(tweaksDirectory); tweaks are installed there"
        }
        guard name.hasSuffix(".dylib"), name.count > 6, !name.hasPrefix(".") else { return "\(name) is not a *.dylib file name" }
        if name.contains(where: { ":\r\n\t ".contains($0) }) { return "\(name) contains ':' or whitespace, which dynjectd's config can't hold" }
        if path.utf8.count >= DynjectLimits.pathMax { return "the path is too long" }
        return nil
    }
}

public enum TweakInstallError: Error, LocalizedError, Equatable {
    case refused(String)
    /// The files were written but the privileged step failed afterwards (typically the dynjectd restart).
    case installedButNotRestarted(String)

    public var errorDescription: String? {
        switch self {
        case let .refused(m): return m
        case let .installedButNotRestarted(m):
            return "The tweak is installed, but dynjectd didn't restart: \(m)\nRestart it from Workbench → Daemon; apps launched until then don't get the change."
        }
    }
}

// MARK: - Mach-O check

/// The architectures in a dylib, read from its Mach-O (or universal) header.
public struct MachOInfo: Equatable, Sendable {
    public struct Slice: Equatable, Sendable {
        public var arch: String
        public var isDylib: Bool
        public var isSigned: Bool
        /// Where the slice is in the file (0 and the file's size for a thin file).
        public var offset: Int = 0
        public var size: Int = 0
    }

    public var slices: [Slice]
    public var archs: [String] { slices.map(\.arch) }
    public var isUniversal: Bool { slices.count > 1 }

    /// The bytes of the slice an arm64e process maps: arm64e, else arm64, else the first; the whole file when it isn't
    /// a Mach-O file.
    public static func preferredSlice(of data: Data) -> Data {
        guard let info = inspect(data) else { return data }
        let pick = info.slices.first { $0.arch == "arm64e" } ?? info.slices.first { $0.arch == "arm64" } ?? info.slices.first
        guard let s = pick, s.offset >= 0, s.size > 0, s.offset + s.size <= data.count else { return data }
        return data.subdata(in: data.startIndex + s.offset ..< data.startIndex + s.offset + s.size)
    }

    public static func inspect(_ data: Data) -> MachOInfo? {
        let bytes = [UInt8](data)
        func be32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= bytes.count else { return nil }
            return UInt32(bytes[o]) << 24 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 8 | UInt32(bytes[o + 3])
        }
        func be64(_ o: Int) -> UInt64? {
            guard let hi = be32(o), let lo = be32(o + 4) else { return nil }
            return UInt64(hi) << 32 | UInt64(lo)
        }
        func le32(_ o: Int) -> UInt32? { be32(o).map { $0.byteSwapped } }

        func slice(at offset: Int) -> Slice? {
            guard le32(offset) == 0xFEED_FACF, let cpu = le32(offset + 4), let sub = le32(offset + 8),
                  let fileType = le32(offset + 12), let ncmds = le32(offset + 16) else { return nil }
            var signed = false
            var lc = offset + 32
            for _ in 0..<min(Int(ncmds), 10_000) {
                guard let cmd = le32(lc), let size = le32(lc + 4), size >= 8 else { break }
                if cmd == 0x1D { signed = true }   // LC_CODE_SIGNATURE
                lc += Int(size)
            }
            return Slice(arch: archName(cpu: cpu, subtype: sub), isDylib: fileType == 6, isSigned: signed,
                         offset: offset, size: bytes.count - offset)
        }

        guard let magic = be32(0) else { return nil }
        if magic == 0xCAFE_BABE || magic == 0xCAFE_BABF {
            let is64 = magic == 0xCAFE_BABF
            guard let n = be32(4), n > 0, n < 64 else { return nil }
            var out: [Slice] = []
            for i in 0..<Int(n) {
                let entry = 8 + i * (is64 ? 32 : 20)
                guard let cpu = be32(entry), let sub = be32(entry + 4) else { return nil }
                let off = is64 ? be64(entry + 8).map(Int.init) : be32(entry + 8).map(Int.init)
                let size = is64 ? be64(entry + 16).map(Int.init) : be32(entry + 12).map(Int.init)
                guard let off, let size, var s = slice(at: off) else { return nil }
                s.arch = archName(cpu: cpu, subtype: sub)
                s.size = min(size, bytes.count - off)
                out.append(s)
            }
            return MachOInfo(slices: out)
        }
        return slice(at: 0).map { MachOInfo(slices: [$0]) }
    }

    static func archName(cpu: UInt32, subtype: UInt32) -> String {
        let sub = subtype & 0x00FF_FFFF
        switch cpu {
        case 0x0100_0007: return "x86_64"
        case 0x0100_000C: return sub == 2 ? "arm64e" : "arm64"
        default: return String(format: "cpu-0x%x", cpu)
        }
    }

    /// Errors (refuse) and warnings for a tweak dylib.
    public static func check(_ data: Data, name: String) -> (errors: [String], warnings: [String], archs: [String]) {
        guard let info = inspect(data), !info.slices.isEmpty else {
            return (["\(name) is not a 64-bit Mach-O file."], [], [])
        }
        var errors: [String] = [], warnings: [String] = []
        if info.slices.contains(where: { !$0.isDylib }) { errors.append("\(name) is a Mach-O file but not a dylib (build it with -dynamiclib).") }
        if !info.archs.contains("arm64e") {
            errors.append("\(name) has no arm64e slice (it has \(info.archs.joined(separator: ", "))), so Apple's own apps can't load it. Build with -arch arm64e.")
        }
        let missing = ["x86_64", "arm64"].filter { !info.archs.contains($0) }
        if !missing.isEmpty {
            warnings.append("\(name) is not universal: no \(missing.joined(separator: " or ")) slice, so apps running as \(missing.joined(separator: " or ")) won't load it (most third-party apps run as arm64).")
        }
        let unsigned = info.slices.filter { !$0.isSigned }.map(\.arch)
        if !unsigned.isEmpty { warnings.append("\(name) has no code signature for \(unsigned.joined(separator: ", ")); it won't load there (sign it, ad-hoc is enough).") }
        return (errors, warnings, info.archs)
    }
}

// MARK: - Locating a tweak folder

public struct TweakSource: Sendable {
    public var manifestPath: String
    public var manifestData: Data
    public var manifest: TweakManifest
    /// Parser warnings (errors refuse).
    public var manifestWarnings: [String]
    /// The built dylib to install.
    public var dylibPath: String

    /// `path` is a tweak folder or a manifest. The dylib is `dylib` if given, else build/<install name> or
    /// <install name> next to the manifest.
    public static func locate(_ path: String, dylib: String? = nil,
                              currentDirectory: String = FileManager.default.currentDirectoryPath) throws -> TweakSource {
        let fm = FileManager.default
        func absolute(_ p: String) -> String {
            let e = (p as NSString).expandingTildeInPath
            return URL(fileURLWithPath: e.hasPrefix("/") ? e : (currentDirectory as NSString).appendingPathComponent(e)).standardizedFileURL.path
        }
        let given = absolute(path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: given, isDirectory: &isDir) else { throw TweakInstallError.refused("\(given) does not exist.") }
        let manifestPath: String
        if isDir.boolValue {
            let found = ((try? fm.contentsOfDirectory(atPath: given)) ?? []).filter { $0.hasSuffix(TweakManifest.fileSuffix) }.sorted()
            guard !found.isEmpty else { throw TweakInstallError.refused("No *\(TweakManifest.fileSuffix) in \(given).") }
            guard found.count == 1 else {
                throw TweakInstallError.refused("\(given) holds several manifests (\(found.joined(separator: ", "))); name the one to install.")
            }
            manifestPath = (given as NSString).appendingPathComponent(found[0])
        } else {
            guard given.hasSuffix(TweakManifest.fileSuffix) else {
                throw TweakInstallError.refused("\(given) is not a tweak folder or a *\(TweakManifest.fileSuffix) manifest.")
            }
            manifestPath = given
        }
        guard let data = fm.contents(atPath: manifestPath) else { throw TweakInstallError.refused("Can't read \(manifestPath).") }
        // The dylib isn't installed yet, so don't warn that it is missing.
        let (parsed, issues) = TweakManifestParser.parse(data: data, path: manifestPath, fileExists: { _ in true })
        let errors = issues.filter { $0.severity == .error }.map(\.message)
        guard let manifest = parsed, errors.isEmpty else {
            throw TweakInstallError.refused("The manifest \((manifestPath as NSString).lastPathComponent) has errors:\n"
                + errors.map { "  - \($0)" }.joined(separator: "\n"))
        }
        let folder = (manifestPath as NSString).deletingLastPathComponent
        let name = (manifest.dylib as NSString).lastPathComponent
        let dylibPath: String
        if let dylib {
            dylibPath = absolute(dylib)
            guard fm.fileExists(atPath: dylibPath) else { throw TweakInstallError.refused("\(dylibPath) does not exist.") }
        } else {
            let candidates = [folder + "/build/" + name, folder + "/" + name]
            guard let found = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
                throw TweakInstallError.refused("The built dylib \(name) isn't in \(folder)/build/ or next to the manifest. Build it first (./build.sh) or pass --dylib.")
            }
            dylibPath = found
        }
        return TweakSource(manifestPath: manifestPath, manifestData: data, manifest: manifest,
                           manifestWarnings: issues.filter { $0.severity == .warning }.map(\.message), dylibPath: dylibPath)
    }
}

// MARK: - Install

public enum TweakFileAction: String, Sendable {
    case create, replace, unchanged
}

public struct TweakInstallPlan: Sendable {
    public var locations: TweakLocations
    public var source: TweakSource
    public var manifest: TweakManifest { source.manifest }
    public var dylibData: Data
    public var architectures: [String]
    /// The path in the manifest and the config.
    public var dylibInstallPath: String
    /// Where its bytes go (the same, except in fixture mode and tests).
    public var dylibFilePath: String
    public var dylibCurrent: Data?
    public var dylibAction: TweakFileAction
    public var configOriginal: Data
    /// nil: the config doesn't change.
    public var configNew: String?
    public var configLines: [LineDiff.Op]
    public var declares: Bool
    public var enabledFor: [InstalledApp]
    public var alreadyEnabledFor: [InstalledApp]
    public var manifestDestination: String
    public var manifestCurrent: Data?
    public var manifestAction: TweakFileAction
    /// Manifests in the Tweaks folder with this identifier under another file name; replaced by the new one.
    public var manifestsReplaced: [String]
    public var warnings: [String]
    public var notes: [String]
    /// Version change, macOS and `depends` checks (TweakCompatibility.swift). `execute` refuses while
    /// `compatibility.refusals` isn't empty.
    public var compatibility = TweakInstallCheck()

    public var restartsDaemon: Bool { configNew != nil }
    public var needsPrivilegedStep: Bool { dylibAction != .unchanged || configNew != nil }
    public var changesNothing: Bool { !needsPrivilegedStep && manifestAction == .unchanged && manifestsReplaced.isEmpty }
    public var isRefused: Bool { !compatibility.refusals.isEmpty }

    /// What will happen, one line each, for `dw` and Workbench's review sheet.
    public var summary: [String] {
        var out: [String] = [compatibility.change.summary]
        let size = ByteCountFormatter.string(fromByteCount: Int64(dylibData.count), countStyle: .file)
        let elsewhere = dylibFilePath == dylibInstallPath ? "" : " [file: \(dylibFilePath)]"
        switch dylibAction {
        case .create: out.append("Copy \(source.dylibPath) to \(dylibInstallPath)\(elsewhere) (\(size), \(architectures.joined(separator: " ")))")
        case .replace: out.append("Replace \(dylibInstallPath)\(elsewhere) with \(source.dylibPath) (\(size), \(architectures.joined(separator: " "))); the old file is backed up")
        case .unchanged: out.append("\(dylibInstallPath) is already this build")
        }
        if configNew != nil {
            out.append("Edit \(locations.configPath):")
            for op in configLines {
                if case let .added(l) = op { out.append("  + \(l)") }
                if case let .removed(l) = op { out.append("  - \(l)") }
            }
        } else {
            out.append("\(locations.configPath) already has what's needed; dynjectd is not restarted")
        }
        if !alreadyEnabledFor.isEmpty { out.append("Already enabled for: \(alreadyEnabledFor.map(\.displayName).joined(separator: ", "))") }
        if restartsDaemon { out.append("Restart dynjectd") }
        switch manifestAction {
        case .create: out.append("Copy the manifest to \(manifestDestination)")
        case .replace: out.append("Replace \(manifestDestination) with the new manifest")
        case .unchanged: out.append("\(manifestDestination) is already up to date")
        }
        for p in manifestsReplaced { out.append("Remove \(p) (an older manifest of this tweak)") }
        return out
    }
}

public struct TweakInstallResult: Sendable {
    public var plan: TweakInstallPlan
    public var outcome: BatchOutcome?
    public var manifestWritten: Bool
    /// Problems after the privileged step succeeded (e.g. the manifest couldn't be copied).
    public var problems: [String]
}

public enum TweakInstaller {
    /// Plans an install. `bundleIDs` are the apps to enable the tweak for; `targets` are every installed app with
    /// its service name (used to keep the config edit specific to those apps).
    public static func plan(source: TweakSource, enableFor bundleIDs: [String], targets: [InjectionTarget],
                            locations: TweakLocations, options: TweakInstallOptions = .init()) throws -> TweakInstallPlan {
        let fm = FileManager.default
        let manifest = source.manifest
        let installPath = manifest.dylib
        if let problem = locations.installPathProblem(installPath) {
            throw TweakInstallError.refused("The manifest's dylib path can't be installed: \(problem).")
        }
        guard let dylibData = fm.contents(atPath: source.dylibPath) else { throw TweakInstallError.refused("Can't read \(source.dylibPath).") }
        let check = MachOInfo.check(dylibData, name: (source.dylibPath as NSString).lastPathComponent)
        guard check.errors.isEmpty else { throw TweakInstallError.refused(check.errors.joined(separator: "\n")) }
        var warnings = source.manifestWarnings + check.warnings
        var notes: [String] = []

        let filePath = locations.filePath(forDylib: installPath)
        var st = stat()
        if lstat(filePath, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG {
            throw TweakInstallError.refused("\(filePath) exists and is not a regular file (a symbolic link or folder); not replacing it.")
        }
        let current = fm.contents(atPath: filePath)
        let dylibAction: TweakFileAction = current == nil ? .create : (current == dylibData ? .unchanged : .replace)

        // Config.
        guard let configData = fm.contents(atPath: locations.configPath) else {
            throw TweakInstallError.refused("Can't read \(locations.configPath).")
        }
        let original = ConfigDocument(text: String(decoding: configData, as: UTF8.self))
        var doc = original
        let exists: (String) -> Bool = { $0 == installPath || fm.fileExists(atPath: locations.filePath(forDylib: $0)) }
        let declares = EffectiveConfig(document: doc).dylib(path: installPath) == nil
        if declares {
            do { doc = try ConfigEditor.addDylib(installPath, to: doc) } catch { throw TweakInstallError.refused(error.localizedDescription) }
        }
        var enabled: [InstalledApp] = [], already: [InstalledApp] = []
        var wanted: [String] = []
        for id in bundleIDs where !wanted.contains(id) { wanted.append(id) }
        for id in wanted {
            guard let target = targets.first(where: { $0.app.bundleID == id }) else {
                throw TweakInstallError.refused("No installed app has the bundle ID \(id).")
            }
            do {
                let edit = try ConfigEditor.setInjection(true, dylib: installPath, for: target, in: doc, allTargets: targets, fileExists: exists)
                if edit.changes.isEmpty { already.append(target.app) } else { enabled.append(target.app) }
                doc = edit.document
                notes += edit.notes
            } catch {
                throw TweakInstallError.refused("Can't enable it for \(target.app.displayName): \(error.localizedDescription)")
            }
        }
        let others = ConfigEditor.affectedApps(from: original, to: doc, targets: targets, fileExists: exists)
            .filter { !wanted.contains($0.app.bundleID) }
        if !others.isEmpty {
            throw TweakInstallError.refused("This config edit would also change what loads in \(others.map(\.app.displayName).joined(separator: ", ")). Enable it in Workbench (Apps & Injection) instead.")
        }
        try refuseNewErrors(from: original, to: doc)
        let configNew = doc.text == original.text ? nil : doc.text

        // Manifest.
        let destName = (source.manifestPath as NSString).lastPathComponent
        let destination = (locations.manifestsDirectory as NSString).appendingPathComponent(destName)
        let installed = installedManifests(in: locations.manifestsDirectory)
        if let other = installed.first(where: { $0.path == destination && $0.id != manifest.id }) {
            throw TweakInstallError.refused("\(destination) belongs to another tweak (\(other.id)); rename this manifest.")
        }
        let replaced = installed.filter { $0.id == manifest.id && $0.path != destination }.map(\.path)
        let manifestCurrent = fm.contents(atPath: destination)
        let manifestAction: TweakFileAction = manifestCurrent == nil ? .create : (manifestCurrent == source.manifestData ? .unchanged : .replace)
        for dir in locations.manifestSearchDirectories {
            for m in TweakManifestLoader.load(directories: [dir]).manifests where m.id != manifest.id && m.dylib == installPath {
                warnings.append("\(m.sourcePath) (\(m.id)) names the same dylib.")
            }
        }
        if locations.manifestsDirectory != locations.dylibFileDirectory {
            for m in TweakManifestLoader.load(directories: [locations.dylibFileDirectory]).manifests where m.id == manifest.id {
                warnings.append("\(m.sourcePath) has the same identifier; the copy in the Tweaks folder wins.")
            }
        }

        let compatibility = TweakInstallCheck.evaluate(
            manifest, installed: TweakManifestLoader.load(directories: locations.manifestSearchDirectories).manifests,
            dylibChanged: dylibAction != .unchanged, options: options)
        warnings += compatibility.warnings
        var plan = TweakInstallPlan(
            locations: locations, source: source, dylibData: dylibData, architectures: check.archs,
            dylibInstallPath: installPath, dylibFilePath: filePath, dylibCurrent: current, dylibAction: dylibAction,
            configOriginal: configData, configNew: configNew,
            configLines: configNew.map { LineDiff.diff(original.text, $0) } ?? [],
            declares: declares, enabledFor: enabled, alreadyEnabledFor: already,
            manifestDestination: destination, manifestCurrent: manifestCurrent, manifestAction: manifestAction,
            manifestsReplaced: replaced, warnings: warnings, notes: notes)
        plan.compatibility = compatibility
        return plan
    }

    /// Runs a plan: dylib and config in one `apply` (one administrator prompt at most, restart folded in), then the
    /// manifest. Files that changed since planning are never overwritten.
    public static func execute(_ plan: TweakInstallPlan, writer: ProtectedFileWriter, restarter: DaemonRestarter) throws -> TweakInstallResult {
        guard !plan.isRefused else { throw TweakInstallError.refused(plan.compatibility.refusalText) }
        var changes: [ProtectedChange] = []
        if plan.dylibAction != .unchanged {
            changes.append(.write(plan.dylibData, to: plan.dylibFilePath, expectedCurrent: plan.dylibCurrent, category: "dylibs"))
        }
        if let text = plan.configNew {
            changes.append(.write(Data(text.utf8), to: plan.locations.configPath, expectedCurrent: plan.configOriginal, category: "config"))
        }
        var w = writer
        w.removableDirectory = plan.locations.dylibFileDirectory
        if !plan.locations.isLive {
            // Fixture mode and tests start without the folder; the live one belongs to the engine's installer.
            try? FileManager.default.createDirectory(atPath: plan.locations.dylibFileDirectory, withIntermediateDirectories: true)
        }
        let outcome: BatchOutcome?
        do {
            outcome = changes.isEmpty ? nil : try w.apply(changes, restartWith: plan.restartsDaemon ? restarter : nil)
        } catch {
            // The privileged step can fail after the files are in place (dynjectd didn't come back). Then the
            // install itself happened: finish the user-level step so the tweak shows up, and say what failed.
            let fm = FileManager.default
            let dylibIn = plan.dylibAction == .unchanged || fm.contents(atPath: plan.dylibFilePath) == plan.dylibData
            let configIn = plan.configNew.map { fm.contents(atPath: plan.locations.configPath) == Data($0.utf8) } ?? true
            guard dylibIn, configIn, !changes.isEmpty else { throw error }
            _ = try? writeManifest(plan, backups: writer.backups)
            throw TweakInstallError.installedButNotRestarted(error.localizedDescription)
        }

        var problems: [String] = []
        var written = false
        do {
            written = try writeManifest(plan, backups: writer.backups)
        } catch {
            problems.append("The manifest wasn't copied to \(plan.manifestDestination): \(error.localizedDescription)")
        }
        return TweakInstallResult(plan: plan, outcome: outcome, manifestWritten: written, problems: problems)
    }

    static func writeManifest(_ plan: TweakInstallPlan, backups: BackupStore) throws -> Bool {
        let fm = FileManager.default
        var changed = false
        if plan.manifestAction != .unchanged {
            try fm.createDirectory(atPath: plan.locations.manifestsDirectory, withIntermediateDirectories: true)
            let current = fm.contents(atPath: plan.manifestDestination)
            if current != plan.manifestCurrent { throw WriteError.changedOnDisk(plan.manifestDestination) }
            if let current { try backups.backup(current, originalPath: plan.manifestDestination, category: "manifests") }
            try AtomicFile.write(plan.source.manifestData, to: plan.manifestDestination)
            changed = true
        }
        for old in plan.manifestsReplaced {
            if let data = fm.contents(atPath: old) { try backups.backup(data, originalPath: old, category: "manifests") }
            try fm.removeItem(atPath: old)
            changed = true
        }
        return changed
    }

    /// Error diagnostics the edit introduces (compared by message, since line numbers move).
    static func refuseNewErrors(from a: ConfigDocument, to b: ConfigDocument) throws {
        let before = Set(ConfigValidator.diagnose(a).filter { $0.severity == .error }.map(\.message))
        let added = ConfigValidator.diagnose(b).filter { $0.severity == .error && !before.contains($0.message) }
        if !added.isEmpty {
            throw TweakInstallError.refused("The edited config would have errors:\n" + added.map { "  - \($0.message)" }.joined(separator: "\n"))
        }
    }

    /// (path, identifier) of every parsable manifest directly in `dir`.
    static func installedManifests(in dir: String) -> [(path: String, id: String, manifest: TweakManifest)] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(TweakManifest.fileSuffix) }.sorted()
        return names.compactMap { name in
            let path = (dir as NSString).appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: path),
                  let m = TweakManifestParser.parse(data: data, path: path, fileExists: { _ in true }).0 else { return nil }
            return (path, m.id, m)
        }
    }
}

// MARK: - Uninstall

public struct TweakUninstallPlan: Sendable {
    public var locations: TweakLocations
    public var tweakID: String
    public var name: String
    public var dylibInstallPath: String
    public var dylibFilePath: String
    /// The bytes that will be deleted; nil when the file is kept or already gone.
    public var dylibToRemove: Data?
    public var configOriginal: Data
    public var configNew: String?
    public var removedConfigLines: [String]
    /// Manifests in the Tweaks folder that are deleted.
    public var manifestFiles: [String]
    /// Bundle IDs listed for this tweak in "dynject.safemode" (removed too).
    public var safeModeEntries: [String]
    public var notes: [String]

    public var restartsDaemon: Bool { configNew != nil }
    public var needsPrivilegedStep: Bool { configNew != nil || dylibToRemove != nil }

    public var summary: [String] {
        var out: [String] = []
        if configNew != nil {
            out.append("Remove from \(locations.configPath):")
            out += removedConfigLines.map { "  - \($0)" }
        } else {
            out.append("\(locations.configPath) doesn't mention \(dylibInstallPath)")
        }
        if dylibToRemove != nil {
            out.append("Delete \(dylibInstallPath)\(dylibFilePath == dylibInstallPath ? "" : " [file: \(dylibFilePath)]") (backed up first)")
        }
        if restartsDaemon { out.append("Restart dynjectd") }
        out += manifestFiles.map { "Delete the manifest \($0)" }
        if !safeModeEntries.isEmpty { out.append("Remove its Safe Mode entries (\(safeModeEntries.joined(separator: ", ")))") }
        return out + notes
    }
}

public struct TweakUninstallResult: Sendable {
    public var plan: TweakUninstallPlan
    public var outcome: BatchOutcome?
    public var problems: [String]
}

public extension ConfigEditor {
    /// Removes every `dylib:` and `dylib-override:` line for `path`. Returns the new document and the removed lines.
    static func removeDylib(_ path: String, from original: ConfigDocument) -> (ConfigDocument, [String]) {
        var doc = original
        var removed: [String] = []
        for i in doc.lines.indices.reversed() {
            switch doc.kind(at: i) {
            case let .dylib(p, _) where p == path, let .override(p, _, _) where p == path:
                removed.insert(doc.lines[i].text, at: 0)
                doc.removeLine(at: i)
            default: break
            }
        }
        return (doc, removed)
    }
}

public extension TweakInstaller {
    /// Plans removing a tweak, named by its identifier or a manifest file. `keepFile` leaves the dylib in place.
    /// Refuses when other installed tweaks depend on it (`depends`), unless `force`.
    static func planUninstall(_ tweak: String, keepFile: Bool, locations: TweakLocations, safeMode: SafeMode?,
                              force: Bool = false,
                              currentDirectory: String = FileManager.default.currentDirectoryPath) throws -> TweakUninstallPlan {
        let fm = FileManager.default
        var manifest: TweakManifest?
        let asPath = ((tweak as NSString).expandingTildeInPath as NSString)
        let path = (asPath.isAbsolutePath ? asPath as String : (currentDirectory as NSString).appendingPathComponent(asPath as String) as String)
        if tweak.hasSuffix(TweakManifest.fileSuffix) || tweak.contains("/") {
            guard let data = fm.contents(atPath: path) else { throw TweakInstallError.refused("Can't read \(path).") }
            guard let m = TweakManifestParser.parse(data: data, path: path, fileExists: { _ in true }).0 else {
                throw TweakInstallError.refused("\(path) is not a valid manifest.")
            }
            manifest = m
        } else {
            manifest = TweakManifestLoader.load(directories: locations.manifestSearchDirectories).manifests.first { $0.id == tweak }
            guard manifest != nil else {
                throw TweakInstallError.refused("No installed manifest has the identifier \(tweak) (`dw tweak list` shows them).")
            }
        }
        let m = manifest!
        let installPath = m.dylib
        var notes: [String] = []

        // Another tweak using the same dylib would lose it too.
        let all = locations.manifestSearchDirectories.flatMap { TweakInstaller.installedManifests(in: $0).map(\.manifest) }
        if let other = all.first(where: { $0.id != m.id && $0.dylib == installPath }) {
            throw TweakInstallError.refused("\(installPath) is also the dylib of \(other.name) (\(other.sourcePath)); uninstall it in Workbench or edit the config by hand.")
        }
        var seen = Set<String>()
        let dependents = DependencyChecker(installed: all.filter { seen.insert($0.id).inserted }, components: [:])
            .dependents(of: m.id).map { "\($0.name) (\($0.id))" }
        if !dependents.isEmpty {
            let which = dependents.joined(separator: ", ")
            guard force else {
                throw TweakInstallError.refused("\(which) depend\(dependents.count == 1 ? "s" : "") on \(m.name) and would stop working. Uninstall \(dependents.count == 1 ? "it" : "them") first, or force it (--force).")
            }
            notes.append("Warning: \(which) depend\(dependents.count == 1 ? "s" : "") on it (--force)")
        }

        // Config.
        guard let configData = fm.contents(atPath: locations.configPath) else { throw TweakInstallError.refused("Can't read \(locations.configPath).") }
        let original = ConfigDocument(text: String(decoding: configData, as: UTF8.self))
        let (doc, removed) = ConfigEditor.removeDylib(installPath, from: original)
        if !removed.isEmpty {
            if EffectiveConfig(document: doc).dylibs.isEmpty {
                throw TweakInstallError.refused("""
                \(m.name) is the only dylib in \(locations.configPath). dynjectd refuses to start without a dylib line \
                ("no dylibs configured"), so removing it would stop all injection and leave dynjectd down. Install \
                another tweak first, or keep this one declared and turn it off for every app (Workbench → Apps & \
                Injection, or `dw disable`).
                """)
            }
            try TweakInstaller.refuseNewErrors(from: original, to: doc)
        }

        // The file.
        let filePath = locations.filePath(forDylib: installPath)
        var toRemove: Data?
        if keepFile {
            notes.append("Keeping \(installPath) (--keep-file)")
        } else if locations.installPathProblem(installPath) != nil {
            notes.append("Not deleting \(installPath): it isn't a *.dylib directly in \(locations.tweaksDirectory)")
        } else {
            var st = stat()
            if lstat(filePath, &st) != 0 {
                notes.append("\(installPath) is already gone")
            } else if let problem = ProtectedFileWriter.removalProblem(filePath, directory: locations.dylibFileDirectory) {
                throw TweakInstallError.refused("Refusing to delete the dylib: \(problem). Use --keep-file to leave it.")
            } else {
                toRemove = fm.contents(atPath: filePath)
                if toRemove == nil { throw TweakInstallError.refused("Can't read \(filePath).") }
            }
        }

        // Manifests.
        let files = TweakInstaller.installedManifests(in: locations.manifestsDirectory).filter { $0.id == m.id }.map(\.path)
        if locations.manifestsDirectory != locations.dylibFileDirectory {
            for other in TweakInstaller.installedManifests(in: locations.dylibFileDirectory) where other.id == m.id {
                notes.append("\(other.path) stays (it is in the root-owned tweaks folder; delete it by hand)")
            }
        }

        let entries = safeMode?.keys.entries()[m.id] ?? []
        return TweakUninstallPlan(
            locations: locations, tweakID: m.id, name: m.name, dylibInstallPath: installPath, dylibFilePath: filePath,
            dylibToRemove: toRemove, configOriginal: configData, configNew: removed.isEmpty ? nil : doc.text,
            removedConfigLines: removed, manifestFiles: files, safeModeEntries: entries, notes: notes)
    }

    /// Config edit and file deletion in one `apply` (one administrator prompt at most, restart folded in), then the
    /// manifests and Safe Mode entries.
    static func executeUninstall(_ plan: TweakUninstallPlan, writer: ProtectedFileWriter, restarter: DaemonRestarter,
                                 safeMode: SafeMode?) throws -> TweakUninstallResult {
        var changes: [ProtectedChange] = []
        if let text = plan.configNew {
            changes.append(.write(Data(text.utf8), to: plan.locations.configPath, expectedCurrent: plan.configOriginal, category: "config"))
        }
        if let data = plan.dylibToRemove {
            changes.append(.remove(plan.dylibFilePath, expectedCurrent: data, category: "dylibs"))
        }
        var w = writer
        w.removableDirectory = plan.locations.dylibFileDirectory
        let outcome = changes.isEmpty ? nil : try w.apply(changes, restartWith: plan.restartsDaemon ? restarter : nil)

        var problems: [String] = []
        let fm = FileManager.default
        for file in plan.manifestFiles {
            do {
                if let data = fm.contents(atPath: file) { try writer.backups.backup(data, originalPath: file, category: "manifests") }
                try fm.removeItem(atPath: file)
            } catch {
                problems.append("Couldn't delete \(file): \(error.localizedDescription)")
            }
        }
        if let safeMode {
            let listed = safeMode.keys.entries()[plan.tweakID] != nil
            let recorded = safeMode.stateStore.load().disabled.contains { $0.tweakID == plan.tweakID }
            if listed || recorded {
                do { try safeMode.enable(tweakID: plan.tweakID, bundleID: SafeModeNames.all) } catch {
                    problems.append("Couldn't remove its Safe Mode entries: \(error.localizedDescription)")
                }
            }
        }
        return TweakUninstallResult(plan: plan, outcome: outcome, problems: problems)
    }
}

// MARK: - Listing

public struct InstalledTweak: Sendable {
    public var manifest: TweakManifest
    public var dylibFilePath: String
    public var fileExists: Bool
    /// e.g. "deny by default; allow: com.apple.TextEdit" or "not in the config".
    public var policy: String
    public var safeMode: SafeModeSupport?
}

public extension TweakInstaller {
    static func list(locations: TweakLocations, support: SafeModeSupportChecker = .shared)
        -> (tweaks: [InstalledTweak], issues: [ManifestIssue], unmanifested: [String])
    {
        var (manifests, issues) = TweakManifestLoader.load(directories: locations.manifestSearchDirectories)
        // The listing says whether each dylib exists (at its real location, which may differ in tests).
        issues.removeAll { $0.severity == .warning && $0.message.hasPrefix("dylib not found at ") }
        let text = FileManager.default.contents(atPath: locations.configPath).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let config = EffectiveConfig(document: ConfigDocument(text: text))
        let tweaks = manifests.map { m -> InstalledTweak in
            let file = locations.filePath(forDylib: m.dylib)
            return InstalledTweak(manifest: m, dylibFilePath: file, fileExists: FileManager.default.fileExists(atPath: file),
                                  policy: policyDescription(config.dylib(path: m.dylib)),
                                  safeMode: support.support(dylibAt: file))
        }
        let named = Set(manifests.map(\.dylib))
        return (tweaks, issues, config.dylibPaths.filter { !named.contains($0) })
    }

    static func policyDescription(_ d: EffectiveConfig.Dylib?) -> String {
        guard let d else { return "not in the config" }
        var s = d.defaultAllow ? "allow by default" : "deny by default"
        let allow = d.overrides.filter(\.allow).map(\.pattern), deny = d.overrides.filter { !$0.allow }.map(\.pattern)
        if !allow.isEmpty { s += "; allow: " + allow.joined(separator: ", ") }
        if !deny.isEmpty { s += "; deny: " + deny.joined(separator: ", ") }
        return s
    }
}
