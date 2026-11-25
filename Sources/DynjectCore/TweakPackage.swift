import Foundation

// Tweak packages (docs/packages.md): a .dwtweak is a zip of one built tweak folder. Opening one checks the zip's
// directory before anything is extracted, extracts into a private staging folder, and checks what came out; the
// folder then installs like any other (TweakSource.locate, TweakInstaller.plan). `dw tweak pack` makes one.

public enum TweakPackageError: Error, Equatable, LocalizedError {
    case refused(String)
    public var errorDescription: String? { if case let .refused(m) = self { return m }; return nil }
}

/// What the review shows about the package file itself.
public struct TweakPackageInfo: Equatable, Sendable {
    public var fileName: String
    public var path: String
    public var sha256: String
    /// From the file's kMDItemWhereFroms: the download URL, then the page it came from.
    public var whereFrom: [String]
    /// From its quarantine attribute: the app that downloaded it.
    public var downloadedBy: String?
    /// README and LICENSE files at the top of the package, by name.
    public var documents: [String]

    public init(fileName: String, path: String, sha256: String, whereFrom: [String] = [], downloadedBy: String? = nil,
                documents: [String] = []) {
        self.fileName = fileName
        self.path = path
        self.sha256 = sha256
        self.whereFrom = whereFrom
        self.downloadedBy = downloadedBy
        self.documents = documents
    }
}

/// An extracted package: the tweak folder inside the staging folder. `remove()` deletes the staging folder.
public struct OpenedTweakPackage: Sendable {
    public var info: TweakPackageInfo
    public var stagingDirectory: String
    public var folder: String

    public func remove() { try? FileManager.default.removeItem(atPath: stagingDirectory) }
}

public enum TweakPackage {
    public static let fileExtension = "dwtweak"
    public static let maxEntries = 500
    public static let maxUncompressedBytes: UInt64 = 200 << 20
    /// Finder's Compress adds these; they're ignored.
    static let finderMetadata = "__MACOSX"

    public static func isPackage(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == fileExtension
    }

    public static var defaultStagingRoot: String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
        return (caches as NSString).appendingPathComponent("Dynject Workbench/Packages")
    }

    /// Deletes staging folders a crash or a force quit left behind: ones older than `age`. A newer one may be an
    /// install that's running right now (`dw tweak install` in a terminal).
    public static func removeStaleStaging(root: String = defaultStagingRoot, olderThan age: TimeInterval = 3600, now: Date = Date()) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let p = (root as NSString).appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > age else { continue }
            try? fm.removeItem(atPath: p)
        }
    }

    // MARK: The zip's directory

    public struct Entry: Equatable, Sendable {
        public var name: String
        public var isDirectory: Bool
        public var uncompressedSize: UInt64
    }

    /// Every entry of a zip, from its central directory, each checked against its local header. Refuses what a
    /// package must not contain: unsafe names, links and devices, zip64, unknown compression, encryption.
    public static func entries(_ data: Data) throws -> [Entry] {
        func refuse(_ why: String) -> TweakPackageError { .refused("Not a usable package: \(why).") }
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { o + 2 <= bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : -1 }
        func u32(_ o: Int) -> UInt64 {
            o + 4 <= bytes.count ? UInt64(bytes[o]) | UInt64(bytes[o + 1]) << 8 | UInt64(bytes[o + 2]) << 16 | UInt64(bytes[o + 3]) << 24 : 0
        }
        // End of central directory: the last signature within the final 64 KiB + 22 bytes.
        guard bytes.count >= 22 else { throw refuse("it isn't a zip file") }
        var eocd = -1
        var i = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 65_535)
        while i >= floor {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw refuse("it isn't a zip file") }
        let count = u16(eocd + 10), cdSize = Int(u32(eocd + 12)), cdOffset = Int(u32(eocd + 16))
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF { throw refuse("it's a zip64 archive") }
        guard u16(eocd + 4) == 0, cdOffset + cdSize <= eocd else { throw refuse("its directory is damaged or split across files") }
        guard count <= maxEntries else { throw refuse("it has \(count) entries; the limit is \(maxEntries)") }

        var out: [Entry] = []
        var o = cdOffset
        var total: UInt64 = 0
        for _ in 0 ..< count {
            guard u32(o) == 0x0201_4B50 else { throw refuse("its directory is damaged") }
            let madeBy = u16(o + 4) >> 8, flags = u16(o + 8), method = u16(o + 10)
            let size = u32(o + 24), nameLen = u16(o + 28), extraLen = u16(o + 30), commentLen = u16(o + 32)
            let external = u32(o + 38), local = Int(u32(o + 42))
            guard o + 46 + nameLen <= bytes.count else { throw refuse("its directory is damaged") }
            let raw = Array(bytes[(o + 46) ..< (o + 46 + nameLen)])
            guard let name = String(bytes: raw, encoding: .utf8) else { throw refuse("an entry's name isn't UTF-8") }
            if flags & 1 != 0 { throw refuse("\(name) is encrypted") }
            if method != 0 && method != 8 { throw refuse("\(name) uses compression method \(method)") }
            try checkName(name)
            // The local header must name the same file: a mismatch is how a zip shows one name and extracts another.
            guard u32(local) == 0x0403_4B50, u16(local + 26) == nameLen,
                  local + 30 + nameLen <= bytes.count, Array(bytes[(local + 30) ..< (local + 30 + nameLen)]) == raw
            else { throw refuse("\(name)'s local header doesn't match the directory") }
            var isDirectory = name.hasSuffix("/")
            if madeBy == 3 {  // Unix: the mode is in the high 16 bits of the external attributes.
                let type = (external >> 16) & 0o170000
                switch type {
                case 0o120000: throw refuse("\(name) is a symbolic link")
                case 0o040000: isDirectory = true
                case 0, 0o100000: break
                default: throw refuse("\(name) is a device or other special file")
                }
            }
            total += size
            guard total <= maxUncompressedBytes else { throw refuse("it unpacks to more than \(maxUncompressedBytes >> 20) MB") }
            out.append(Entry(name: name, isDirectory: isDirectory, uncompressedSize: size))
            o += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    static func checkName(_ name: String) throws {
        func refuse(_ why: String) -> TweakPackageError { .refused("Not a usable package: \(name.debugDescription) \(why).") }
        if name.isEmpty || name.hasPrefix("/") { throw refuse("is an absolute path") }
        if name.contains("\\") { throw refuse("contains a backslash") }
        if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { throw refuse("contains a control character") }
        var parts = name.split(separator: "/", omittingEmptySubsequences: false)
        if name.hasSuffix("/") { parts.removeLast() }
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { throw refuse("has an empty, . or .. component") }
    }

    /// The one top-level folder every entry is in (Finder's __MACOSX aside).
    public static func topFolder(of entries: [Entry]) throws -> String {
        let tops = Set(entries.map { String($0.name.split(separator: "/").first ?? "") }).subtracting([finderMetadata])
        guard tops.count == 1, let top = tops.first else {
            throw TweakPackageError.refused("Not a usable package: it should hold exactly one folder, and it has "
                                            + (tops.isEmpty ? "none" : tops.sorted().joined(separator: ", ")) + ".")
        }
        guard entries.contains(where: { $0.name.hasPrefix(top + "/") }) else {
            throw TweakPackageError.refused("Not a usable package: \(top) isn't a folder.")
        }
        return top
    }

    // MARK: Opening

    /// Checks, extracts and checks again. The caller removes the staging folder when done (`remove()`).
    public static func open(_ path: String, stagingRoot: String = defaultStagingRoot) throws -> OpenedTweakPackage {
        let fm = FileManager.default
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw TweakPackageError.refused("\(path) isn't a regular file.")
        }
        guard let data = fm.contents(atPath: path) else { throw TweakPackageError.refused("Can't read \(path).") }
        let list = try entries(data)
        let top = try topFolder(of: list)
        let sha = DylibDigest.sha256Hex(data)

        try fm.createDirectory(atPath: stagingRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = (stagingRoot as NSString).appendingPathComponent("\(sha.prefix(16))-\(UUID().uuidString)")
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            // Extract the bytes we checked, from a private copy, not the file at `path` (which could change).
            let copy = (staging as NSString).appendingPathComponent(".package.zip")
            try data.write(to: URL(fileURLWithPath: copy))
            let out = (staging as NSString).appendingPathComponent("contents")
            let r = try ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", copy, out])
            try? fm.removeItem(atPath: copy)
            guard r.status == 0 else { throw TweakPackageError.refused("Couldn't unpack \(path): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
            try? fm.removeItem(atPath: (out as NSString).appendingPathComponent(finderMetadata))
            try checkExtracted(out, expectedTop: top)
            let folder = (out as NSString).appendingPathComponent(top)
            let documents = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter {
                let u = $0.uppercased()
                return u.hasPrefix("README") || u.hasPrefix("LICENSE") || u.hasPrefix("LICENCE")
            }.sorted()
            let (from, by) = provenance(ofFileAt: path)
            let info = TweakPackageInfo(fileName: (path as NSString).lastPathComponent, path: path, sha256: sha,
                                        whereFrom: from, downloadedBy: by, documents: documents)
            return OpenedTweakPackage(info: info, stagingDirectory: staging, folder: folder)
        } catch {
            try? fm.removeItem(atPath: staging)
            throw error
        }
    }

    /// After extraction: one folder, and nothing in it but regular files and folders, within the size limit.
    static func checkExtracted(_ root: String, expectedTop: String) throws {
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        guard top == [expectedTop] else {
            throw TweakPackageError.refused("Not a usable package: it unpacked to \(top.sorted().joined(separator: ", ")), not one folder \(expectedTop).")
        }
        var total: UInt64 = 0, count = 0
        var pending = [root]
        while let dir = pending.popLast() {
            for name in try fm.contentsOfDirectory(atPath: dir) {
                let p = (dir as NSString).appendingPathComponent(name)
                var st = stat()
                guard lstat(p, &st) == 0 else { throw TweakPackageError.refused("Not a usable package: can't read \(name) after unpacking.") }
                switch st.st_mode & S_IFMT {
                case S_IFDIR: pending.append(p)
                case S_IFREG: total += UInt64(st.st_size)
                default: throw TweakPackageError.refused("Not a usable package: \(name) unpacked as a link or special file.")
                }
                count += 1
                if count > maxEntries || total > maxUncompressedBytes {
                    throw TweakPackageError.refused("Not a usable package: it unpacks to more than its directory says.")
                }
            }
        }
    }

    /// Where a downloaded file came from: kMDItemWhereFroms, and the downloading app from com.apple.quarantine.
    public static func provenance(ofFileAt path: String) -> (whereFrom: [String], downloadedBy: String?) {
        func attribute(_ name: String) -> Data? {
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var buf = Data(count: size)
            let got = buf.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            return got == size ? buf : nil
        }
        var from: [String] = []
        if let d = attribute("com.apple.metadata:kMDItemWhereFroms"),
           let list = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String] {
            from = list.filter { !$0.isEmpty }
        }
        var by: String?
        if let d = attribute("com.apple.quarantine") {
            // "0083;6745e3c1;Safari;UUID": flags, time, agent, event.
            let fields = String(decoding: d, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
            if fields.count > 2, !fields[2].isEmpty { by = String(fields[2]) }
        }
        return (from, by)
    }

    // MARK: Packing

    /// A package from a built tweak folder: its manifest, its dylib under build/, its extensionsApp at the path the
    /// manifest names, and README/LICENSE files. Returns the package's path and SHA-256.
    public static func pack(folder: String, outputDirectory: String) throws -> (path: String, sha256: String) {
        let fm = FileManager.default
        let source = try TweakSource.locate(folder)
        let m = source.manifest
        guard let version = m.version else {
            throw TweakPackageError.refused("\(m.name)'s manifest has no version; a package needs one so installs can tell an update.")
        }
        guard let data = fm.contents(atPath: source.dylibPath) else { throw TweakPackageError.refused("Can't read \(source.dylibPath).") }
        let check = MachOInfo.check(data, name: (source.dylibPath as NSString).lastPathComponent)
        if let e = check.errors.first { throw TweakPackageError.refused(e) }
        if let w = check.warnings.first(where: { $0.contains("no code signature") }) { throw TweakPackageError.refused(w) }

        let base = (source.manifestPath as NSString).deletingLastPathComponent
        let name = (base as NSString).lastPathComponent
        let work = (NSTemporaryDirectory() as NSString).appendingPathComponent("dw-pack-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: work) }
        let root = (work as NSString).appendingPathComponent(name)
        func copy(_ from: String, _ relative: String) throws {
            let to = (root as NSString).appendingPathComponent(relative)
            try fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let r = try ProcessRunner.run("/usr/bin/ditto", ["--norsrc", "--noextattr", "--noqtn", "--noacl", from, to])
            guard r.status == 0 else { throw TweakPackageError.refused("Couldn't copy \(from): \(r.stderr)") }
        }
        try copy(source.manifestPath, (source.manifestPath as NSString).lastPathComponent)
        try copy(source.dylibPath, "build/" + (m.dylib as NSString).lastPathComponent)
        if let app = source.extensionsAppPath, let relative = m.extensionsApp { try copy(app, relative) }
        for doc in ((try? fm.contentsOfDirectory(atPath: base)) ?? []).sorted() {
            let u = doc.uppercased()
            if u.hasPrefix("README") || u.hasPrefix("LICENSE") || u.hasPrefix("LICENCE") {
                try copy((base as NSString).appendingPathComponent(doc), doc)
            }
        }
        try fm.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let out = (outputDirectory as NSString).appendingPathComponent("\(m.id)-\(version).\(fileExtension)")
        try? fm.removeItem(atPath: out)
        let r = try ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent", root, out])
        guard r.status == 0, let packed = fm.contents(atPath: out) else {
            throw TweakPackageError.refused("Couldn't write \(out): \(r.stderr)")
        }
        _ = try entries(packed)  // what we make must pass our own checks
        return (out, DylibDigest.sha256Hex(packed))
    }
}

/// `<id>.origin.plist` next to an installed manifest: which package a tweak came from (docs/packages.md).
public struct TweakOrigin: Equatable, Sendable {
    public var packageFile: String
    public var packageSHA256: String
    public var whereFrom: [String]
    public var signer: String
    public var installed: Date

    public init(packageFile: String, packageSHA256: String, whereFrom: [String], signer: String, installed: Date) {
        self.packageFile = packageFile
        self.packageSHA256 = packageSHA256
        self.whereFrom = whereFrom
        self.signer = signer
        self.installed = installed
    }

    public static func path(for tweakID: String, in manifestsDirectory: String) -> String {
        (manifestsDirectory as NSString).appendingPathComponent("\(tweakID).origin.plist")
    }

    public func write(to path: String) throws {
        let plist: [String: Any] = ["packageFile": packageFile, "packageSHA256": packageSHA256, "whereFrom": whereFrom,
                                    "signer": signer, "installed": installed]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: path))
    }

    public static func load(_ path: String) -> TweakOrigin? {
        guard let d = FileManager.default.contents(atPath: path),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
              let file = p["packageFile"] as? String, let sha = p["packageSHA256"] as? String else { return nil }
        return TweakOrigin(packageFile: file, packageSHA256: sha, whereFrom: p["whereFrom"] as? [String] ?? [],
                           signer: p["signer"] as? String ?? "", installed: p["installed"] as? Date ?? .distantPast)
    }

    /// One line for `dw tweak list`.
    public var summary: String {
        "from package \(packageFile) (sha256 \(packageSHA256.prefix(16))…), \(signer)" + (whereFrom.first.map { ", downloaded from \($0)" } ?? "")
    }
}
