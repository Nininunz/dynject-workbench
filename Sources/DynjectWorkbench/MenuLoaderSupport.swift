import DynjectCore
import Foundation

/// Persists Workbench's MenuLoader preferences (per-tweak "Show in Apple menu", placement, submenu title).
/// Live mode: the app's own user defaults. Fixture mode: a JSON file in the support folder, so fixture runs
/// never touch the real app's defaults.
struct MenuLoaderSettingsStore {
    static let defaultsKey = "MenuLoaderSettings"

    var file: URL?
    var defaults: UserDefaults = .standard

    func load() -> MenuLoaderSettings {
        let data = file.flatMap { try? Data(contentsOf: $0) } ?? (file == nil ? defaults.data(forKey: Self.defaultsKey) : nil)
        return data.flatMap { try? JSONDecoder().decode(MenuLoaderSettings.self, from: $0) } ?? MenuLoaderSettings()
    }

    func save(_ settings: MenuLoaderSettings) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(settings)
        if let file {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } else {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
