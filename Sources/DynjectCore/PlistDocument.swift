import Foundation

public enum PlistError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case invalid(String)
    case notXML
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(m): return m
        case let .invalid(m): return m
        case .notXML: return "The text parses, but not as an XML property list. Keep the <?xml …?> / <plist> form."
        case let .unsupportedFormat(m): return m
        }
    }
}

public struct PlistDocument {
    public enum Format: String, Sendable {
        case xml = "XML"
        case binary = "Binary"
        case openStep = "OpenStep (read-only)"
    }

    public let path: String
    public let originalData: Data
    public let format: Format
    /// Parsed original value.
    public let original: Any
    /// The text shown in the editor initially.
    public let initialXML: String

    public init(path: String) throws {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw PlistError.unreadable("Could not read \(path).")
        }
        try self.init(path: path, data: data)
    }

    public init(path: String, data: Data) throws {
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: &fmt)
        } catch {
            throw PlistError.invalid("Not a property list: \(Self.message(error))")
        }
        self.path = path
        self.originalData = data
        self.original = object
        switch fmt {
        case .xml:
            format = .xml
            // Show the file verbatim so comments and layout survive.
            initialXML = String(data: data, encoding: .utf8) ?? Self.xmlString(object)
        case .binary:
            format = .binary
            initialXML = Self.xmlString(object)
        default:
            format = .openStep
            initialXML = Self.xmlString(object)
        }
    }

    public var canSave: Bool { format != .openStep }

    public static func xmlString(_ object: Any) -> String {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses editor text; it must be an XML plist.
    public static func validate(_ xml: String) -> Result<Any, PlistError> {
        guard let data = xml.data(using: .utf8) else { return .failure(.invalid("Text is not UTF-8.")) }
        var fmt = PropertyListSerialization.PropertyListFormat.xml
        do {
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &fmt)
            guard fmt == .xml else { return .failure(.notXML) }
            return .success(object)
        } catch {
            return .failure(.invalid(message(error)))
        }
    }

    public func isUnchanged(_ xml: String) -> Bool {
        if xml == initialXML { return true }
        guard case let .success(edited) = Self.validate(xml) else { return false }
        return PlistValue.equal(edited, original)
    }

    /// Bytes to write for the edited text, in the file's original format.
    public func encoded(_ xml: String) throws -> Data {
        let edited: Any
        switch Self.validate(xml) {
        case let .success(o): edited = o
        case let .failure(e): throw e
        }
        switch format {
        case .xml:
            // Write the user's validated text verbatim: their formatting is the format.
            return Data(xml.utf8)
        case .binary:
            let roundTrip = (try? PropertyListSerialization.propertyList(
                from: Data(Self.xmlString(original).utf8), options: [], format: nil)) ?? original
            let merged = Self.preserveUntouched(original: original, roundTrip: roundTrip, edited: edited)
            let data = try PropertyListSerialization.data(fromPropertyList: merged, format: .binary, options: 0)
            let check = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard PlistValue.equal(check, merged) else {
                throw PlistError.invalid("Binary re-encoding did not round-trip; nothing was written.")
            }
            return data
        case .openStep:
            throw PlistError.unsupportedFormat(
                "This file uses the legacy OpenStep text format, which Foundation cannot write. Saving would change its format, so it is read-only here.")
        }
    }

    /// Wherever the edited value equals the XML round-trip of the original, keep the original value.
    /// This preserves details XML cannot express (sub-second dates, float32 reals) for untouched values.
    static func preserveUntouched(original: Any, roundTrip: Any, edited: Any) -> Any {
        if PlistValue.equal(edited, roundTrip) { return original }
        if let e = edited as? [String: Any], let o = original as? [String: Any], let r = roundTrip as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in e {
                if let ov = o[k], let rv = r[k] {
                    out[k] = preserveUntouched(original: ov, roundTrip: rv, edited: v)
                } else {
                    out[k] = v
                }
            }
            return out
        }
        if let e = edited as? [Any], let o = original as? [Any], let r = roundTrip as? [Any], e.count == o.count, o.count == r.count {
            return zip(zip(o, r), e).map { preserveUntouched(original: $0.0, roundTrip: $0.1, edited: $1) }
        }
        return edited
    }

    static func message(_ error: Error) -> String {
        let ns = error as NSError
        return (ns.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ns.localizedDescription
    }
}

// MARK: - Manual plist ↔ dylib associations

public struct PlistAssociation: Codable, Hashable, Identifiable, Sendable {
    public var id: String { dylibPath + "\u{0}" + plistPath }
    public var dylibPath: String
    public var plistPath: String
    public var note: String

    public init(dylibPath: String, plistPath: String, note: String = "") {
        self.dylibPath = dylibPath
        self.plistPath = plistPath
        self.note = note
    }
}

public struct AssociationStore: Sendable {
    public var url: URL

    public init(url: URL) { self.url = url }

    public func load() -> [PlistAssociation] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PlistAssociation].self, from: data)) ?? []
    }

    public func save(_ items: [PlistAssociation]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(items).write(to: url, options: .atomic)
    }
}

// MARK: - Line diff for review

public enum LineDiff {
    public enum Op: Equatable, Sendable {
        case same(String), added(String), removed(String)
    }

    public static func diff(_ a: String, _ b: String) -> [Op] {
        let x = a.components(separatedBy: "\n"), y = b.components(separatedBy: "\n")
        let n = x.count, m = y.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = x[i] == y[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if x[i] == y[j] { ops.append(.same(x[i])); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { ops.append(.removed(x[i])); i += 1 }
            else { ops.append(.added(y[j])); j += 1 }
        }
        while i < n { ops.append(.removed(x[i])); i += 1 }
        while j < m { ops.append(.added(y[j])); j += 1 }
        return ops
    }
}

// MARK: - Structural equality

/// Property-list equality that also compares keyed-archiver UIDs by value.
/// (`CFKeyedArchiverUID` only has identity equality, so `isEqual` fails on any NSKeyedArchiver plist.)
public enum PlistValue {
    public static func equal(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? [String: Any], let y = b as? [String: Any] {
            guard x.count == y.count else { return false }
            return x.allSatisfy { k, v in y[k].map { equal(v, $0) } ?? false }
        }
        if let x = a as? [Any], let y = b as? [Any] {
            return x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        }
        if let x = uidValue(a), let y = uidValue(b) { return x == y }
        if uidValue(a) != nil || uidValue(b) != nil { return false }
        return (a as AnyObject).isEqual(b)
    }

    /// The integer inside a CFKeyedArchiverUID, or nil for any other value.
    static func uidValue(_ v: Any) -> UInt64? {
        let d = String(describing: v)
        guard d.contains("CFKeyedArchiverUID"), let r = d.range(of: #"value = (\d+)"#, options: .regularExpression) else {
            return nil
        }
        return UInt64(d[r].dropFirst("value = ".count))
    }
}
