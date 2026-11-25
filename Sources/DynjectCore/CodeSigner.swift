import Foundation

/// Who signed a dylib, from `codesign -dv` (docs/install-approval.md, "Approval prompt"). Unlike a manifest's name and
/// version, a Team ID is checked by macOS: it says which developer account's certificate signed the file.
public enum CodeSigner: Equatable, Sendable {
    /// Signed with a developer certificate: its Team ID, and the certificate's name ("Developer ID Application: …").
    case team(String, authority: String?)
    /// Signed without an identity (`codesign -s -`, what build.sh does): anyone can make one.
    case adhoc
    case unsigned
    /// codesign couldn't say.
    case unknown(String)

    /// One line for the install plan.
    public var summary: String {
        switch self {
        case let .team(id, authority?): return "signed by \(authority) (Team ID \(id))"
        case let .team(id, nil): return "signed by Team ID \(id)"
        case .adhoc: return "ad-hoc signed (no developer identity)"
        case .unsigned: return "not signed"
        case let .unknown(why): return "signature unknown (\(why))"
        }
    }

    /// Whether two signatures come from the same signer: the same Team ID, or both ad-hoc, or both unsigned.
    public func sameSigner(as other: CodeSigner) -> Bool {
        switch (self, other) {
        case let (.team(a, _), .team(b, _)): return a == b
        case (.adhoc, .adhoc), (.unsigned, .unsigned): return true
        default: return false
        }
    }

    /// `codesign -dv --verbose=2 <path>` (it prints to stderr).
    public static func of(fileAt path: String) -> CodeSigner {
        guard let r = try? ProcessRunner.run("/usr/bin/codesign", ["-dv", "--verbose=2", path]) else {
            return .unknown("codesign didn't run")
        }
        return parse(r.stdout + r.stderr, status: r.status)
    }

    public static func parse(_ output: String, status: Int32) -> CodeSigner {
        if output.contains("code object is not signed at all") { return .unsigned }
        var team: String?, authority: String?, adhoc = false
        for line in output.split(separator: "\n") {
            if line == "Signature=adhoc" { adhoc = true }
            if line.hasPrefix("TeamIdentifier="), line != "TeamIdentifier=not set" { team = String(line.dropFirst("TeamIdentifier=".count)) }
            if authority == nil, line.hasPrefix("Authority=") { authority = String(line.dropFirst("Authority=".count)) }
        }
        if adhoc { return .adhoc }
        if let team { return .team(team, authority: authority) }
        if status != 0 {
            let last = output.split(separator: "\n").last.map(String.init) ?? "exit \(status)"
            return .unknown(last)
        }
        return .unknown("no Team ID in codesign's output")
    }
}
