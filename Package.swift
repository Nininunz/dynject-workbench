// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DynjectWorkbench",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DynjectWorkbench", targets: ["DynjectWorkbench"]),
        .library(name: "DynjectCore", targets: ["DynjectCore"]),
    ],
    targets: [
        .target(name: "DynjectCore"),
        .executableTarget(name: "DynjectWorkbench", dependencies: ["DynjectCore"]),
        // Live privileged trial against /opt/dynject. Run only with the owner's approval.
        .executableTarget(name: "DynjectLiveTrial", dependencies: ["DynjectCore"]),
        // Header-only SDK for tweak authors (TweakSDK/include/DynjectTweak.h).
        .target(name: "DynjectTweakSDK", path: "TweakSDK", publicHeadersPath: "include",
                cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .testTarget(
            name: "DynjectCoreTests",
            dependencies: ["DynjectCore", "DynjectTweakSDK"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
