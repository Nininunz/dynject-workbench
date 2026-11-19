@testable import DynjectCore
import XCTest

final class RecordingExecutor: PrivilegedExecutor, @unchecked Sendable {
    var calls: [[String]] = []
    var stagedContents: [Data] = []
    var output = "DW installed\nDW running-before 1 2\nDW running-after 3\nDW ok\n"

    func run(_ arguments: [String], prompt: String) throws -> String {
        calls.append(arguments)
        if arguments.first == "install" { stagedContents.append(FileManager.default.contents(atPath: arguments[2]) ?? Data()) }
        return output
    }
}

struct FakeLiveRestarter: DaemonRestarter {
    var isLive: Bool { true }
    func restart() throws -> RestartReport { XCTFail("should be folded into the install call"); throw WriteError.cancelled }
}

final class ProtectedWriterTests: XCTestCase {
    func testDirectWriteBacksUpAndPreservesPermissions() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("dynjectd.conf").path
        try Data("old\n".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.setAttributes([.posixPermissions: 0o604], ofItemAtPath: target)

        let backups = BackupStore(root: dir.appendingPathComponent("backups"))
        let exec = RecordingExecutor()
        let sim = SimulatedRestarter()
        let writer = ProtectedFileWriter(backups: backups, executor: exec)
        let outcome = try writer.write(Data("new\n".utf8), to: target, expectedCurrent: Data("old\n".utf8),
                                       category: "config", restartWith: sim)

        XCTAssertFalse(outcome.usedAdministratorRights)
        XCTAssertTrue(exec.calls.isEmpty)
        XCTAssertEqual(sim.count, 1)
        XCTAssertEqual(outcome.restart?.simulated, true)
        XCTAssertEqual(FileManager.default.contents(atPath: target), Data("new\n".utf8))
        XCTAssertEqual(try Data(contentsOf: outcome.backup!), Data("old\n".utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? NSNumber)?.intValue, 0o604)
        XCTAssertEqual(backups.list(category: "config").count, 1)
    }

    func testConflictIsDetectedBeforeAnyWrite() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("c.conf").path
        try Data("changed by someone\n".utf8).write(to: URL(fileURLWithPath: target))
        let writer = ProtectedFileWriter(backups: BackupStore(root: dir.appendingPathComponent("b")), executor: RecordingExecutor())
        XCTAssertThrowsError(try writer.write(Data("x".utf8), to: target, expectedCurrent: Data("old\n".utf8), category: "config"))
        XCTAssertEqual(FileManager.default.contents(atPath: target), Data("changed by someone\n".utf8))
    }

    func testProtectedPathUsesOnePrivilegedCallWithRestartFolded() throws {
        let dir = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("etc").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let etc = dir.appendingPathComponent("etc")
        try FileManager.default.createDirectory(at: etc, withIntermediateDirectories: true)
        let target = etc.appendingPathComponent("dynjectd.conf").path
        try Data("old\n".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: etc.path)
        XCTAssertFalse(AtomicFile.canWriteDirectly(target))

        let exec = RecordingExecutor()
        let writer = ProtectedFileWriter(backups: BackupStore(root: dir.appendingPathComponent("b")), executor: exec)
        let new = Data("new\n".utf8)
        let outcome = try writer.write(new, to: target, expectedCurrent: Data("old\n".utf8), category: "config",
                                       restartWith: FakeLiveRestarter())
        XCTAssertTrue(outcome.usedAdministratorRights)
        XCTAssertEqual(exec.calls.count, 1)
        XCTAssertEqual(exec.calls[0][0], "install")
        XCTAssertEqual(exec.calls[0][1], target)
        XCTAssertEqual(exec.calls[0][3], sha256Hex(new))
        XCTAssertEqual(exec.calls[0][4], sha256Hex(Data("old\n".utf8)))
        XCTAssertEqual(exec.calls[0].last, "restart")
        XCTAssertEqual(exec.stagedContents, [new])
        XCTAssertEqual(outcome.restart?.after, [3])
        XCTAssertNotNil(outcome.backup)
        // The staged temp file is removed afterwards.
        XCTAssertFalse(FileManager.default.fileExists(atPath: exec.calls[0][2]))
    }
}

final class PlistDocumentTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = try temporaryDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testBinaryStaysBinaryAndUntouchedSubsecondDatesSurvive() throws {
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000.123456)
        let original: [String: Any] = ["enabled": true, "opacity": 0.75, "when": date, "blob": Data([1, 2, 3]),
                                       "list": [1, "two", ["three": 3]]]
        let data = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
        let doc = try PlistDocument(path: dir.appendingPathComponent("p.plist").path, data: data)
        XCTAssertEqual(doc.format, .binary)
        XCTAssertTrue(doc.initialXML.contains("<key>opacity</key>"))
        XCTAssertTrue(doc.isUnchanged(doc.initialXML))

        let edited = doc.initialXML.replacingOccurrences(of: "<real>0.75</real>", with: "<real>0.5</real>")
        XCTAssertFalse(doc.isUnchanged(edited))
        let out = try doc.encoded(edited)
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        let decoded = try PropertyListSerialization.propertyList(from: out, options: [], format: &fmt) as! [String: Any]
        XCTAssertEqual(fmt, .binary)
        XCTAssertEqual(decoded["opacity"] as? Double, 0.5)
        XCTAssertEqual((decoded["when"] as? Date)?.timeIntervalSinceReferenceDate, date.timeIntervalSinceReferenceDate)
        XCTAssertEqual(decoded["blob"] as? Data, Data([1, 2, 3]))
    }

    func testXMLIsWrittenVerbatimIncludingComments() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <!-- tweak settings -->
        <dict>
            <key>Theme</key>
            <string>dark</string>
        </dict>
        </plist>

        """
        let doc = try PlistDocument(path: "/x.plist", data: Data(xml.utf8))
        XCTAssertEqual(doc.format, .xml)
        XCTAssertEqual(doc.initialXML, xml)
        let edited = xml.replacingOccurrences(of: "dark", with: "light")
        XCTAssertEqual(try doc.encoded(edited), Data(edited.utf8))
    }

    func testValidationErrors() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .xml, options: 0)
        let doc = try PlistDocument(path: "/x.plist", data: data)
        let broken = doc.initialXML.replacingOccurrences(of: "</dict>", with: "")
        guard case .failure = PlistDocument.validate(broken) else { return XCTFail("should fail") }
        XCTAssertThrowsError(try doc.encoded(broken))
        // OpenStep text parses but is not XML.
        guard case .failure(.notXML) = PlistDocument.validate("{ a = 1; }") else { return XCTFail("should be notXML") }
    }

    func testKeyedArchiveUIDsSurviveRoundTrip() throws {
        let archived = try NSKeyedArchiver.archivedData(withRootObject: ["x": NSNumber(value: 1)] as NSDictionary,
                                                        requiringSecureCoding: false)
        let doc = try PlistDocument(path: "/k.plist", data: archived)
        XCTAssertEqual(doc.format, .binary)
        let edited = doc.initialXML.replacingOccurrences(of: "<string>x</string>", with: "<string>y</string>")
        XCTAssertNotEqual(edited, doc.initialXML)
        let out = try doc.encoded(edited)
        let obj = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSString.self, NSNumber.self], from: out)
        XCTAssertEqual((obj as? NSDictionary)?["y"] as? NSNumber, 1)
    }

    func testOpenStepIsReadOnly() throws {
        let doc = try PlistDocument(path: "/o.plist", data: Data("{ a = 1; }".utf8))
        XCTAssertEqual(doc.format, .openStep)
        XCTAssertFalse(doc.canSave)
        XCTAssertThrowsError(try doc.encoded(doc.initialXML))
    }

    func testAssociationsPersist() throws {
        let store = AssociationStore(url: dir.appendingPathComponent("a/associations.json"))
        XCTAssertEqual(store.load(), [])
        let items = [PlistAssociation(dylibPath: "/opt/x.dylib", plistPath: "/Users/me/Library/Preferences/com.x.plist")]
        try store.save(items)
        XCTAssertEqual(store.load(), items)
    }
}
