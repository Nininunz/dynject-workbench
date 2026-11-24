import CryptoKit
import Foundation

/// Registers app extensions with PlugInKit (`pluginkit -a` / `-r`). Installs use the real one only for the live
/// engine; fixture mode (`--root`) and tests get `simulated` or a recorder, so nothing is registered on the Mac.
public struct ExtensionRegistrar: Sendable {
    public var register: @Sendable (String) throws -> Void
    public var unregister: @Sendable (String) throws -> Void

    public init(register: @escaping @Sendable (String) throws -> Void, unregister: @escaping @Sendable (String) throws -> Void) {
        self.register = register
        self.unregister = unregister
    }

    public static let pluginkit = ExtensionRegistrar(register: { try runPluginKit(["-a", $0]) },
                                                     unregister: { try runPluginKit(["-r", $0]) })
    public static let simulated = ExtensionRegistrar(register: { _ in }, unregister: { _ in })

    /// The real registrar for the live engine, the simulated one otherwise.
    public static func standard(for locations: TweakLocations) -> ExtensionRegistrar {
        locations.isLive ? .pluginkit : .simulated
    }

    static func runPluginKit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TweakInstallError.refused("pluginkit \(arguments.joined(separator: " ")) failed (\(process.terminationStatus))"
                + (output.isEmpty ? "" : ": \(output.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
    }
}

/// The app a tweak ships so app extensions it needs get registered (manifest key `extensionsApp`; SettingsLoader's
/// "Tweaks" Settings extension is one). Installs copy it into Workbench's Extensions folder and register the
/// extensions inside it; uninstalls unregister them and delete the copy. The copy is the one registered, so the
/// source folder can be rebuilt or deleted freely.
public enum TweakExtensions {
    /// The extensions inside an app: Contents/Extensions/*.appex and Contents/PlugIns/*.appex, sorted.
    public static func extensions(in app: String) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for folder in ["Contents/Extensions", "Contents/PlugIns"] {
            let dir = (app as NSString).appendingPathComponent(folder)
            for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where name.hasSuffix(".appex") {
                out.append((dir as NSString).appendingPathComponent(name))
            }
        }
        return out
    }

    /// A digest of a bundle: every file's relative path and contents, and every symlink's target. Equal for the
    /// same build; nil when `path` isn't there.
    public static func digest(_ path: String) -> Data? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
              let names = fm.subpaths(atPath: path) else { return nil }
        var hash = SHA256()
        for name in names.sorted() {
            let full = (path as NSString).appendingPathComponent(name)
            hash.update(data: Data(name.utf8))
            if let target = try? fm.destinationOfSymbolicLink(atPath: full) {
                hash.update(data: Data(("->" + target).utf8))
            } else if let data = fm.contents(atPath: full) {
                hash.update(data: data)
            }
        }
        return Data(hash.finalize())
    }

    /// Copies `source` to `destination` (replacing an earlier copy, whose extensions are unregistered first) and
    /// registers the copy's extensions. Returns them.
    public static func install(app source: String, to destination: String, registrar: ExtensionRegistrar) throws -> [String] {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination) { _ = try remove(destination, registrar: registrar) }
        try fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.copyItem(atPath: source, toPath: destination)
        let found = extensions(in: destination)
        for appex in found { try registrar.register(appex) }
        return found
    }

    /// Unregisters the extensions in `app` and deletes it. Returns the extensions. Unregistering one that isn't
    /// registered isn't an error.
    public static func remove(_ app: String, registrar: ExtensionRegistrar) throws -> [String] {
        let found = extensions(in: app)
        for appex in found { try? registrar.unregister(appex) }
        try FileManager.default.removeItem(atPath: app)
        return found
    }
}
