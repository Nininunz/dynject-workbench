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
        .testTarget(
            name: "DynjectCoreTests",
            dependencies: ["DynjectCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
