import Foundation

/// Text formats used by the panel, the floating window and the CLI (spec §5.1 rule 6).
public enum Formatting {
    /// "3d 4h", "2h 14m", "45m" or "<1m". A date that has passed gives "now".
    public static func countdown(to date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded(.down))
        if seconds <= 0 { return "now" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days >= 1 { return "\(days)d \(hours)h" }
        if hours >= 1 { return "\(hours)h \(minutes)m" }
        if minutes >= 1 { return "\(minutes)m" }
        return "<1m"
    }

    /// Compact form for the floating window: "2h14m".
    public static func compactCountdown(to date: Date, now: Date) -> String {
        countdown(to: date, now: now).replacingOccurrences(of: " ", with: "")
    }

    /// "just now", "14 min ago", "3 h ago" or "2 d ago".
    public static func age(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3_600) h ago" }
        return "\(seconds / 86_400) d ago"
    }

    /// "32%".
    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}

extension Duration {
    /// The duration in seconds.
    public var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
