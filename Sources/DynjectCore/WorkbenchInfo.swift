// Version and notices shown by `dw --version` and Workbench's About panel.
import Foundation

public enum WorkbenchInfo {
    /// Keep in step with CFBundleShortVersionString in Resources/Info.plist (a test checks).
    public static let version = "0.1.11"

    public static let licenseNotice =
        "free software (PolyForm Noncommercial 1.0.0). if you paid for it, you were scammed — report the seller: https://github.com/Nininunz/dynject-workbench/issues"

    public static let engineCredit =
        "injection engine: dynject by ut0mt8 (https://github.com/ut0mt8/dynject, MIT). not affiliated with or endorsed by its author."

    /// The lines `dw --version` prints.
    public static var versionText: String {
        "dynject-workbench \(version)\n\(licenseNotice)\n\(engineCredit)"
    }
}
