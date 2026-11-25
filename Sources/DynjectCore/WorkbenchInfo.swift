// Version and notices shown by `dw --version` and Workbench's About panel.
import Foundation

public enum WorkbenchInfo {
    /// Keep in step with CFBundleShortVersionString in Resources/Info.plist (a test checks).
    public static let version = "0.1.12"

    /// DynjectHook's version, DH_SDK_VERSION in TweakSDK/include/DynjectHook.h (a test checks). It moves only when
    /// TweakSDK/ changes, so a tweak built with it isn't told to rebuild after a Workbench release that left the SDK
    /// alone. Tweaks carry it (the "dynject.sdk:" marker), and doctor compares theirs with this one.
    public static let sdkVersion = "0.1.11"
    /// SHA-256 of TweakSDK/'s files, the DH_SDK_VERSION line left out (SDKVersionTests computes it). When the SDK
    /// changes, the test fails until sdkVersion and DH_SDK_VERSION are bumped and this is updated with them.
    public static let sdkFingerprint = "436324e5deab9eee96f85559689c126ae9c72275ff829fe6bf6b70acbb12274a"

    public static let licenseNotice =
        "free software (PolyForm Noncommercial 1.0.0). if you paid for it, you were scammed — report the seller: https://github.com/Nininunz/dynject-workbench/issues"

    public static let engineCredit =
        "injection engine: dynject by ut0mt8 (https://github.com/ut0mt8/dynject, MIT). not affiliated with or endorsed by its author."

    /// The lines `dw --version` prints.
    public static var versionText: String {
        "dynject-workbench \(version)\n\(licenseNotice)\n\(engineCredit)"
    }
}
