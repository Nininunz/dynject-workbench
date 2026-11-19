// Swift classes for DynjectHook's Swift class-lookup tests (Tests/DynjectHookTests).
//
// The Objective-C tests never import this module's generated header. They reach
// these classes through the Objective-C runtime only (DHSwiftClass,
// DHFindClassWithSuffix, NSClassFromString), which is exactly how a tweak finds
// Swift classes inside a host app.
//
// Image path: the tests locate the image that holds these classes at runtime with
// dladdr() on the class pointer returned by DHSwiftClass (under `swift test` the
// fixtures are linked statically into the .xctest bundle, so that is the image).

import Foundation

/// Public top-level class. Runtime name "DynjectHookSwiftFixtures.DHTSwiftPublic",
/// mangled form "_TtC24DynjectHookSwiftFixtures14DHTSwiftPublic".
public class DHTSwiftPublic: NSObject {
    @objc public dynamic func swiftValue() -> Int {
        return 42
    }

    @objc public dynamic func swiftGreeting(_ name: String) -> String {
        return "hello " + name
    }

    /// Calls `swiftValue` from Swift. Because the method is `@objc dynamic`, Swift
    /// dispatches through objc_msgSend, so a DynjectHook hook is observed here too.
    @objc public func swiftValueCalledFromSwift() -> Int {
        return swiftValue()
    }

    /// The file-private class below, for comparing against DHFindClassWithSuffix.
    @objc public class func privateCellClass() -> AnyClass {
        return DHTSwiftPrivateCell.self
    }
}

/// File-private class: its runtime name carries a private discriminator, e.g.
/// "_TtC24DynjectHookSwiftFixturesP33_<32 hex digits>19DHTSwiftPrivateCell", so it
/// can only be found by suffix ("19DHTSwiftPrivateCell" or "DHTSwiftPrivateCell").
private final class DHTSwiftPrivateCell: NSObject {
    @objc dynamic func cellTag() -> Int {
        return 7
    }
}
