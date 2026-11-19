import DynjectCore
import Foundation
import XCTest

enum Fixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
    }

    static func text(_ name: String) -> String {
        try! String(contentsOf: url(name), encoding: .utf8)
    }
}

enum Apps {
    static func make(_ name: String, _ bundleID: String, exe: String? = nil,
                     dir: String = "/System/Applications") -> InstalledApp {
        let exe = exe ?? name
        let bundle = "\(dir)/\(name).app"
        return InstalledApp(displayName: name, bundleID: bundleID, executableName: exe,
                            executablePath: "\(bundle)/Contents/MacOS/\(exe)", bundlePath: bundle)
    }

    static let finder = make("Finder", "com.apple.finder", dir: "/System/Library/CoreServices")
    static let textEdit = make("TextEdit", "com.apple.TextEdit")
    static let notes = make("Notes", "com.apple.Notes")
    static let safari = make("Safari", "com.apple.Safari", dir: "/Applications")
    static let safariTP = make("Safari Technology Preview", "com.apple.SafariTechnologyPreview", dir: "/Applications")
    static let terminal = make("Terminal", "com.apple.Terminal", dir: "/System/Applications/Utilities")
    static let pathFinder = make("Path Finder", "com.cocoatech.PathFinder", exe: "Path Finder", dir: "/Applications")
    static let helper = make("Thing Helper", "com.example.thing.helper", exe: "Thing Helper", dir: "/Applications")
    static let outside = make("Tool", "com.example.tool", dir: "/Users/someone/Downloads")

    static let all = [finder, textEdit, notes, safari, safariTP, terminal, pathFinder, helper, outside]

    static func targets(_ apps: [InstalledApp] = all) -> [InjectionTarget] {
        apps.map { InjectionTarget(app: $0, service: ServiceNameResolver.resolve($0, log: nil).value) }
    }

    static func target(_ app: InstalledApp) -> InjectionTarget {
        InjectionTarget(app: app, service: ServiceNameResolver.resolve(app, log: nil).value)
    }
}

/// Every dylib "exists" unless listed.
func exists(except missing: Set<String> = []) -> (String) -> Bool {
    { !missing.contains($0) }
}

func temporaryDirectory(_ name: String = #function) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dw-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Lines added/removed between two texts.
func changedLines(_ a: String, _ b: String) -> (added: [String], removed: [String]) {
    var added: [String] = [], removed: [String] = []
    for op in LineDiff.diff(a, b) {
        switch op {
        case let .added(l): added.append(l)
        case let .removed(l): removed.append(l)
        case .same: break
        }
    }
    return (added, removed)
}
