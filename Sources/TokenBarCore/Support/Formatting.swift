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

    /// The local clock time of a reset, localized (spec §5.1 rule 6):
    /// - the same calendar day as `now`: the time only, "6:10 PM" (en_US) or "18:10" (en_GB);
    /// - one to six calendar days later: weekday and time, "Wed 11:00 PM";
    /// - seven or more calendar days later: the date, "Oct 23" (a weekday would repeat today's);
    /// - a date that has passed: "now".
    /// Days are counted in `calendar`'s time zone, so 23:59 → 00:30 the next day is not the same day.
    public static func resetClock(_ date: Date, now: Date, calendar: Calendar = .current,
                                  locale: Locale = .current) -> String {
        guard date > now else { return "now" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        let template = days <= 0 ? "j:mm" : (days < 7 ? "EEE j:mm" : "MMM d")
        let formatter = DateFormatter()
        formatter.locale = locale  // also brings the locale's calendar, so set it first
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// The reset column text in the chosen style: `resetClock` or `countdown`.
    public static func resetText(_ date: Date, now: Date, style: ResetTimeStyle, calendar: Calendar = .current,
                                 locale: Locale = .current) -> String {
        switch style {
        case .clock: return resetClock(date, now: now, calendar: calendar, locale: locale)
        case .countdown: return countdown(to: date, now: now)
        }
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
