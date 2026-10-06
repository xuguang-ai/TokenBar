import Foundation

/// Date formats found in Claude Code and Codex data (spec §5.3.1, §5.5).
public enum DateParsing {
    /// An ISO-8601 string (any number of fractional digits; offset or `Z`), or a number of epoch
    /// seconds. Booleans and anything unparseable give nil, which means "no countdown", not an error.
    public static func flexible(_ value: Any?) -> Date? {
        switch value {
        case let string as String:
            return iso8601(string)
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return Date(timeIntervalSince1970: number.doubleValue)
        default:
            return nil
        }
    }

    /// ISO-8601 with or without fractional seconds. Fractions are normalised to milliseconds first,
    /// because `ISO8601DateFormatter` only accepts up to three digits on some systems.
    public static func iso8601(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let normalized = normalizeFraction(trimmed) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: normalized) { return date }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    /// The `procStart` field of a session registry file, e.g. "Tue Oct  6 05:33:53 2026" (spec §5.5).
    public static func procStart(_ string: String, timeZone: TimeZone = .current) -> Date? {
        let collapsed = string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: collapsed)
    }

    /// Rewrites the fractional seconds of an ISO-8601 timestamp to exactly three digits.
    /// Returns nil when the string has no fractional part.
    private static func normalizeFraction(_ string: String) -> String? {
        guard let timeStart = string.firstIndex(of: "T"),
              let dot = string[timeStart...].firstIndex(of: ".") else { return nil }
        var end = string.index(after: dot)
        while end < string.endIndex, string[end].isNumber { end = string.index(after: end) }
        let digits = string[string.index(after: dot)..<end]
        guard !digits.isEmpty else { return nil }
        let millis = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
        return String(string[..<dot]) + "." + millis + String(string[end...])
    }
}
