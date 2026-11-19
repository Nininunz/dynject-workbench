// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DynjectWorkbench",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DynjectWorkbench", targets: ["DynjectWorkbench"]),
        .executable(name: "dw", targets: ["dw"]),
        .library(name: "DynjectCore", targets: ["DynjectCore"]),
    ],
    targets: [
        .target(name: "DynjectCore"),
        .executableTarget(name: "DynjectWorkbench", dependencies: ["DynjectCore"]),
        // Live privileged trial against /opt/dynject. Run only with the owner's approval.
        .executableTarget(name: "DynjectLiveTrial", dependencies: ["DynjectCore"]),
        // `dw` CLI for tweak development: install, enable/disable per app, relaunch, logs.
        .executableTarget(name: "dw", dependencies: ["DynjectCore"]),
        // Header-only SDK for tweak authors (TweakSDK/include/DynjectTweak.h).
        .target(name: "DynjectTweakSDK", path: "TweakSDK", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        // Swift classes for DynjectHook's Swift class-lookup tests.
        .target(name: "DynjectHookSwiftFixtures", path: "Tests/DynjectHookSwiftFixtures"),
        // Objective-C tests for DynjectHook (TweakSDK/DynjectHook.{h,m}).
        .testTarget(
            name: "DynjectHookTests",
            dependencies: ["DynjectTweakSDK", "DynjectHookSwiftFixtures"],
            cSettings: [.unsafeFlags(["-fobjc-arc"])]
        ),
        .testTarget(
            name: "DynjectCoreTests",
            dependencies: ["DynjectCore", "DynjectTweakSDK"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
