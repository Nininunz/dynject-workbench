@testable import DynjectCore
import XCTest

// Tweak packages (docs/packages.md): packing, the zip checks (with archives built byte by byte to break them on
// purpose), unpacking, and what installing from a package adds to the plan. Temporary folders only.

/// A minimal zip writer (stored entries) for archives no real tool would make.
struct ZipBuilder {
    struct Entry {
        var name: String
        var data = Data()
        /// Unix mode, e.g. 0o100644; nil for an entry made on DOS.
        var mode: UInt32? = 0o100644
        /// The name in the local header, when it should differ from the directory's.
        var localName: String?
        var declaredSize: UInt32?
        var flags: UInt16 = 0
        var method: UInt16 = 0
    }

    var entries: [Entry] = []

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data {
            crc ^= UInt32(b)
            for _ in 0 ..< 8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    func build() -> Data {
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        var out: [UInt8] = [], central: [UInt8] = []
        for e in entries {
            let name = Array(e.name.utf8), local = Array((e.localName ?? e.name).utf8)
            let crc = Self.crc32(e.data), size = e.declaredSize ?? UInt32(e.data.count)
            let offset = UInt32(out.count)
            out += le32(0x0403_4B50) + le16(20) + le16(e.flags) + le16(e.method) + le16(0) + le16(0)
            out += le32(crc) + le32(UInt32(e.data.count)) + le32(size) + le16(UInt16(local.count)) + le16(0) + local + Array(e.data)
            let madeBy: UInt16 = e.mode == nil ? 20 : (3 << 8) | 20
            central += le32(0x0201_4B50) + le16(madeBy) + le16(20) + le16(e.flags) + le16(e.method) + le16(0) + le16(0)
            central += le32(crc) + le32(UInt32(e.data.count)) + le32(size) + le16(UInt16(name.count)) + le16(0) + le16(0)
            central += le16(0) + le16(0) + le32((e.mode ?? 0) << 16) + le32(offset) + name
        }
        let cdOffset = UInt32(out.count)
        out += central
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        out += le32(UInt32(central.count)) + le32(cdOffset) + le16(0)
        return Data(out)
    }
}

final class TweakPackageTests: XCTestCase {
    var root: URL!
    var loc: TweakLocations!
    var src: URL!
    let template = try! TweakTemplate(name: "MyTweak", identifier: "local.mytweak")

    override func setUpWithError() throws {
        let tmp = try temporaryDirectory()
        root = URL(fileURLWithPath: String(cString: realpath(tmp.path, nil)!))
        loc = .sandbox(root: root.appendingPathComponent("engine"))
        for d in [loc.dylibFileDirectory, (loc.configPath as NSString).deletingLastPathComponent] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        try Fixtures.text("live.conf").write(toFile: loc.configPath, atomically: true, encoding: .utf8)
        src = root.appendingPathComponent("MyTweak")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("build"), withIntermediateDirectories: true)
        try manifest().write(to: src.appendingPathComponent("MyTweak.workbench.plist"), atomically: true, encoding: .utf8)
        try FakeMachO.universal.write(to: src.appendingPathComponent("build/libMyTweak.dylib"))
        try "# MyTweak\n".write(to: src.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// The template's manifest, with a version and optional extra keys before </dict>.
    func manifest(extra: String = "") -> String {
        var text = template.manifest
        if !text.contains("<key>version</key>") {
            text = text.replacingOccurrences(of: "<key>identifier</key>", with: "<key>version</key><string>1.0.0</string><key>identifier</key>")
        }
        if let r = text.range(of: "</dict>\n</plist>", options: .backwards) { text.replaceSubrange(r, with: extra + "</dict>\n</plist>") }
        return text
    }

    var staging: String { root.appendingPathComponent("Staging").path }

    func pack() throws -> String {
        try TweakPackage.pack(folder: src.path, outputDirectory: root.appendingPathComponent("out").path).path
    }

    func refusal(_ zip: ZipBuilder, file: StaticString = #filePath, line: UInt = #line) -> String {
        let path = root.appendingPathComponent("bad-\(UUID().uuidString).dwtweak").path
        try! zip.build().write(to: URL(fileURLWithPath: path))
        do {
            _ = try TweakPackage.open(path, stagingRoot: staging)
            XCTFail("opened a bad package", file: file, line: line)
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Packing and opening

    func testPackThenOpen() throws {
        let path = try pack()
        XCTAssertTrue(path.hasSuffix("/local.mytweak-0.1.0.dwtweak"), path)
        let names = try TweakPackage.entries(Data(contentsOf: URL(fileURLWithPath: path))).map(\.name).sorted()
        XCTAssertEqual(names, ["MyTweak/", "MyTweak/MyTweak.workbench.plist", "MyTweak/README.md", "MyTweak/build/",
                               "MyTweak/build/libMyTweak.dylib"])
        let opened = try TweakPackage.open(path, stagingRoot: staging)
        XCTAssertEqual(opened.info.documents, ["README.md"])
        XCTAssertEqual(opened.info.sha256, DylibDigest.sha256Hex(try Data(contentsOf: URL(fileURLWithPath: path))))
        let source = try TweakSource.locate(opened.folder)
        XCTAssertEqual(source.manifest.id, "local.mytweak")
        XCTAssertEqual(FileManager.default.contents(atPath: source.dylibPath), FakeMachO.universal)
        var st = stat()
        XCTAssertEqual(stat(opened.stagingDirectory, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        opened.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.stagingDirectory))
    }

    func testPackRefusesWhatAPackageNeeds() throws {
        try FakeMachO.make([FakeMachO.x86_64, FakeMachO.arm64]).write(to: src.appendingPathComponent("build/libMyTweak.dylib"))
        XCTAssertThrowsError(try pack()) { XCTAssertTrue($0.localizedDescription.contains("arm64e"), $0.localizedDescription) }
        try FakeMachO.make([FakeMachO.arm64e], signed: false).write(to: src.appendingPathComponent("build/libMyTweak.dylib"))
        XCTAssertThrowsError(try pack()) { XCTAssertTrue($0.localizedDescription.contains("code signature"), $0.localizedDescription) }
        try FakeMachO.universal.write(to: src.appendingPathComponent("build/libMyTweak.dylib"))
        try template.manifest.replacingOccurrences(of: "<key>version</key>", with: "<key>unusedVersion</key>")
            .write(to: src.appendingPathComponent("MyTweak.workbench.plist"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try pack()) { XCTAssertTrue($0.localizedDescription.contains("no version"), $0.localizedDescription) }
    }

    func testRefusesBadArchives() {
        let ok = ZipBuilder.Entry(name: "T/", mode: 0o040755)
        let file = ZipBuilder.Entry(name: "T/a", data: Data("a".utf8))
        func zip(_ e: [ZipBuilder.Entry]) -> ZipBuilder { ZipBuilder(entries: e) }
        XCTAssertTrue(refusal(zip([ok, ZipBuilder.Entry(name: "T/../../evil", data: Data("x".utf8))])).contains(".. component"))
        XCTAssertTrue(refusal(zip([ZipBuilder.Entry(name: "/etc/evil", data: Data("x".utf8))])).contains("absolute path"))
        XCTAssertTrue(refusal(zip([ok, ZipBuilder.Entry(name: "T\\..\\evil", data: Data())])).contains("backslash"))
        XCTAssertTrue(refusal(zip([ok, ZipBuilder.Entry(name: "T/link", data: Data("/etc".utf8), mode: 0o120777)])).contains("symbolic link"))
        XCTAssertTrue(refusal(zip([ok, ZipBuilder.Entry(name: "T/dev", mode: 0o020644)])).contains("special file"))
        XCTAssertTrue(refusal(zip([ok, file, ZipBuilder.Entry(name: "U/b", data: Data("b".utf8))])).contains("exactly one folder"))
        XCTAssertTrue(refusal(zip([ok, ZipBuilder.Entry(name: "T/a", data: Data("a".utf8), localName: "../a")])).contains("local header"))
        XCTAssertTrue(refusal(zip([ok, ZipBuilder.Entry(name: "T/a", data: Data("a".utf8), declaredSize: 250 << 20)])).contains("200 MB"))
        XCTAssertTrue(refusal(zip([ok, ZipBuilder.Entry(name: "T/a", data: Data("a".utf8), flags: 1)])).contains("encrypted"))
        XCTAssertTrue(refusal(zip([ok, ZipBuilder.Entry(name: "T/a", data: Data("a".utf8), method: 14)])).contains("compression method"))
        XCTAssertTrue(refusal(zip([ok] + (0 ..< 501).map { ZipBuilder.Entry(name: "T/f\($0)") })).contains("limit is 500"))
        XCTAssertTrue(refusal(ZipBuilder()).contains("exactly one folder") || refusal(ZipBuilder()).contains("zip"))
        let notZip = root.appendingPathComponent("not.dwtweak").path
        try! Data("hello".utf8).write(to: URL(fileURLWithPath: notZip))
        XCTAssertThrowsError(try TweakPackage.open(notZip, stagingRoot: staging)) { XCTAssertTrue($0.localizedDescription.contains("isn't a zip")) }
        // Nothing is left in the staging root after a refusal.
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: staging)) ?? [], [])
    }

    func testAWellFormedHandMadeArchiveOpens() throws {
        let path = root.appendingPathComponent("hand.dwtweak").path
        try ZipBuilder(entries: [ZipBuilder.Entry(name: "T/", mode: 0o040755), ZipBuilder.Entry(name: "T/a", data: Data("a".utf8)),
                                 ZipBuilder.Entry(name: "__MACOSX/T/._a", data: Data("x".utf8))]).build()
            .write(to: URL(fileURLWithPath: path))
        let opened = try TweakPackage.open(path, stagingRoot: staging)
        defer { opened.remove() }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: (opened.folder as NSString).deletingLastPathComponent), ["T"],
                       "Finder's __MACOSX is dropped")
        XCTAssertEqual(FileManager.default.contents(atPath: opened.folder + "/a"), Data("a".utf8))
    }

    func testProvenanceFromExtendedAttributes() throws {
        let path = try pack()
        let from = try PropertyListSerialization.data(fromPropertyList: ["https://example.com/MyTweak.dwtweak", "https://example.com/"],
                                                      format: .binary, options: 0)
        XCTAssertEqual(from.withUnsafeBytes { setxattr(path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, from.count, 0, 0) }, 0)
        let q = Data("0083;6745e3c1;Safari;0E6D3D5A-0000-0000-0000-000000000000".utf8)
        XCTAssertEqual(q.withUnsafeBytes { setxattr(path, "com.apple.quarantine", $0.baseAddress, q.count, 0, 0) }, 0)
        let p = TweakPackage.provenance(ofFileAt: path)
        XCTAssertEqual(p.whereFrom, ["https://example.com/MyTweak.dwtweak", "https://example.com/"])
        XCTAssertEqual(p.downloadedBy, "Safari")
        let opened = try TweakPackage.open(path, stagingRoot: staging)
        defer { opened.remove() }
        // The unpacked files don't carry the quarantine attribute (--noqtn); the installed copy never would (cat).
        XCTAssertLessThan(getxattr(opened.folder + "/build/libMyTweak.dylib", "com.apple.quarantine", nil, 0, 0, 0), 0)
    }

    /// Staging folders a crash left behind go at the next launch; a fresh one (an install running now) stays.
    func testRemoveStaleStaging() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: staging + "/old", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: staging + "/new", withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: staging + "/old")
        TweakPackage.removeStaleStaging(root: staging)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: staging), ["new"])
        TweakPackage.removeStaleStaging(root: root.appendingPathComponent("nowhere").path)  // no folder: nothing to do
    }

    // MARK: Installing from a package

    func plan(_ opened: OpenedTweakPackage, options: TweakInstallOptions? = nil, signer: CodeSigner = .adhoc,
              installed: CodeSigner = .adhoc) throws -> TweakInstallPlan {
        var o = options ?? TweakInstallOptions()
        o.package = opened.info
        return try TweakInstaller.plan(source: try TweakSource.locate(opened.folder), enableFor: [], targets: Apps.targets(),
                                       locations: loc, options: o,
                                       signer: { $0.contains("/Staging/") ? signer : installed })
    }

    func testPackageReviewOriginAndUninstall() throws {
        let opened = try TweakPackage.open(try pack(), stagingRoot: staging)
        defer { opened.remove() }
        let p = try plan(opened)
        XCTAssertEqual(p.summary.first, "Package local.mytweak-0.1.0.dwtweak (sha256 \(opened.info.sha256.prefix(16))…)")
        XCTAssertTrue(p.summary.contains { $0.hasPrefix("  Claims (unverified): name MyTweak, id local.mytweak, version 0.1.0") }, "\(p.summary)")
        XCTAssertTrue(p.summary.contains("  Includes README.md"), "\(p.summary)")
        XCTAssertTrue(p.summary.contains { $0.hasPrefix("Copy local.mytweak-0.1.0.dwtweak's libMyTweak.dylib to /opt/dynject/lib/tweaks/libMyTweak.dylib") }, "\(p.summary)")
        XCTAssertFalse(p.summary.contains { $0.contains("/Staging/") }, "the staging path isn't shown: \(p.summary)")
        XCTAssertTrue(p.warnings.contains { $0.hasPrefix("It's ad-hoc signed: nothing says who built it") }, "\(p.warnings)")
        XCTAssertFalse(p.isRefused)

        let w = ProtectedFileWriter(backups: BackupStore(root: root.appendingPathComponent("Backups")), executor: RecordingExecutor())
        _ = try TweakInstaller.execute(p, writer: w, restarter: SimulatedRestarter())
        let originPath = TweakOrigin.path(for: "local.mytweak", in: loc.manifestsDirectory)
        let origin = try XCTUnwrap(TweakOrigin.load(originPath))
        XCTAssertEqual(origin.packageSHA256, opened.info.sha256)
        XCTAssertTrue(origin.summary.hasPrefix("from package local.mytweak-0.1.0.dwtweak (sha256 "), origin.summary)

        // Reinstalled from a local folder: no longer from a package.
        try FakeMachO.make([FakeMachO.x86_64, FakeMachO.arm64, FakeMachO.arm64e], tag: "local").write(to: src.appendingPathComponent("build/libMyTweak.dylib"))
        _ = try TweakInstaller.execute(try TweakInstaller.plan(source: try TweakSource.locate(src.path), enableFor: [], targets: Apps.targets(),
                                                               locations: loc, signer: { _ in .adhoc }),
                                       writer: w, restarter: SimulatedRestarter())
        XCTAssertNil(TweakOrigin.load(originPath))

        // From the package again, then uninstalled: the origin file goes with it.
        _ = try TweakInstaller.execute(try plan(opened, options: TweakInstallOptions(allowDowngrade: true)), writer: w, restarter: SimulatedRestarter())
        XCTAssertNotNil(TweakOrigin.load(originPath))
        let un = try TweakInstaller.planUninstall("local.mytweak", keepFile: false, locations: loc, safeMode: nil, force: false, targets: Apps.targets())
        _ = try TweakInstaller.executeUninstall(un, writer: w, restarter: SimulatedRestarter(), safeMode: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: originPath))
    }

    func testPackageRefusesApplyCommandAndSignerChange() throws {
        try manifest(extra: "<key>applyCommand</key><array><string>/usr/bin/true</string></array>")
            .write(to: src.appendingPathComponent("MyTweak.workbench.plist"), atomically: true, encoding: .utf8)
        let opened = try TweakPackage.open(try pack(), stagingRoot: staging)
        defer { opened.remove() }
        var p = try plan(opened)
        XCTAssertEqual(p.compatibility.refusals.map(\.kind), [.applyCommand])
        XCTAssertEqual(p.compatibility.refusals.first?.override, "--allow-apply-command")
        XCTAssertTrue(p.summary.contains { $0.contains("runs /usr/bin/true when a setting changes") }, "\(p.summary)")
        p = try plan(opened, options: TweakInstallOptions(allowApplyCommand: true))
        XCTAssertFalse(p.isRefused)
        let w = ProtectedFileWriter(backups: BackupStore(root: root.appendingPathComponent("Backups")), executor: RecordingExecutor())
        _ = try TweakInstaller.execute(p, writer: w, restarter: SimulatedRestarter())

        // An update from someone else.
        try FakeMachO.make([FakeMachO.x86_64, FakeMachO.arm64, FakeMachO.arm64e], tag: "v2").write(to: src.appendingPathComponent("build/libMyTweak.dylib"))
        let update = try TweakPackage.open(try pack(), stagingRoot: staging)
        defer { update.remove() }
        let other = CodeSigner.team("ZZZZZ99999", authority: nil)
        p = try plan(update, options: TweakInstallOptions(allowApplyCommand: true), signer: other)
        XCTAssertEqual(p.compatibility.refusals.map(\.kind), [.signerChange])
        guard !p.compatibility.refusals.isEmpty else { return }
        XCTAssertTrue(p.compatibility.refusals[0].message.contains("the installed build is ad-hoc signed"), p.compatibility.refusals[0].message)
        p = try plan(update, options: TweakInstallOptions(allowApplyCommand: true, allowSignerChange: true), signer: other)
        XCTAssertFalse(p.isRefused)
        XCTAssertTrue(p.warnings.contains { $0.hasPrefix("Installing anyway (--allow-signer-change)") }, "\(p.warnings)")
        // A local folder with a different signer is still only a warning.
        let local = try TweakInstaller.plan(source: try TweakSource.locate(src.path), enableFor: [], targets: Apps.targets(), locations: loc,
                                            signer: { $0.contains("/MyTweak/build/") ? other : .adhoc })
        XCTAssertFalse(local.isRefused)
        XCTAssertTrue(local.warnings.contains { $0.hasPrefix("The signer changed") })
    }
}
