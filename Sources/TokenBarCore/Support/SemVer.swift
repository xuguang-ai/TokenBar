import Foundation

/// `MAJOR.MINOR.PATCH[-pre.release]` with SemVer 2.0 precedence. Python-style suffixes are accepted
/// as prereleases too: `0.131.0a4` parses as `0.131.0-alpha.4`.
public struct SemVer: Sendable, Hashable, Comparable, CustomStringConvertible, Codable {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// Empty for a release.
    public var prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }

        var core = text
        var pre: [String] = []
        if let dash = text.firstIndex(of: "-") {
            core = String(text[..<dash])
            pre = text[text.index(after: dash)...].split(separator: ".").map(String.init)
            if pre.isEmpty { return nil }
        } else if let match = text.range(of: #"(a|b|rc)(\d+)$"#, options: .regularExpression) {
            core = String(text[..<match.lowerBound])
            let suffix = text[match]
            let letters = suffix.prefix { $0.isLetter }
            let digits = suffix.dropFirst(letters.count)
            let tag: String
            switch letters {
            case "a": tag = "alpha"
            case "b": tag = "beta"
            default: tag = String(letters)
            }
            pre = [tag, String(digits)]
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0
        else { return nil }
        self.init(major: major, minor: minor, patch: patch, prerelease: pre)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false  // a release ranks above any prerelease
        case (false, true): return true
        case (false, false): break
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true  // numeric identifiers rank below alphanumeric ones
            case (nil, .some): return false
            case (nil, nil): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
