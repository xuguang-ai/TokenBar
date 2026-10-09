import Foundation

/// Human-readable `tokenbar status` output, mirroring the panel cards (spec §6.3).
///
/// ```text
/// Claude · Work  Max
///   5h      ███████░░░   32% left  2h 14m
///   Week    ██░░░░░░░░   81% left  3d 4h
///   ⚠ Unable to refresh: Network error · Last updated 14 min ago
/// ```
///
/// Plain Unicode, never ANSI escapes, so it is the same on a TTY and in a pipe. Contains no email,
/// no accountUuid and no error payloads, only `ProviderError.userMessage` (spec §9).
public enum CLIStatusTable {
    public static let barCells = 10

    /// - Parameter timeZone: for "Paused until HH:MM" (local time by default).
    public static func render(
        states: [AccountState], displayMode: DisplayMode, now: Date, timeZone: TimeZone = .current
    ) -> String {
        guard !states.isEmpty else { return "No accounts selected.\n" }
        return states.map { block($0, displayMode: displayMode, now: now, timeZone: timeZone) }.joined(separator: "\n")
    }

    /// One account block, ending with a newline.
    public static func block(
        _ state: AccountState, displayMode: DisplayMode, now: Date, timeZone: TimeZone = .current
    ) -> String {
        var lines: [String] = []
        var header = CLIFormat.accountTitle(state.config)
        if let plan = state.lastSnapshot?.identity?.plan, !plan.isEmpty {
            header += "  " + CLIFormat.printable(plan)
        }
        lines.append(header)

        if let snapshot = state.lastSnapshot {
            let display = DisplayDerivation.derive(snapshot, now: now)
            let labelWidth = max(6, display.windows.map { $0.kind.shortLabel.count }.max() ?? 0) + 2
            for window in display.windows {
                lines.append("  " + row(window, labelWidth: labelWidth, displayMode: displayMode, now: now))
            }
        }
        if let status = statusLine(state, now: now, timeZone: timeZone) {
            lines.append("  " + status)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "5h      ███████░░░   32% left  2h 14m"
    public static func row(_ window: DisplayWindow, labelWidth: Int, displayMode: DisplayMode, now: Date) -> String {
        let value = DisplayDerivation.percentValue(window, mode: displayMode)
        let label = CLIFormat.pad(window.kind.shortLabel, to: labelWidth)
        let percent = CLIFormat.leftPad(Formatting.percent(value), to: 4) + (displayMode == .remaining ? " left" : " used")
        let tail: String
        if window.didReset {
            tail = "reset"
        } else if !window.isStarted {
            tail = "not started"
        } else if let reset = window.resetsAt {
            tail = Formatting.countdown(to: reset, now: now)
        } else {
            tail = ""
        }
        let line = label + bar(value) + "  " + percent + (tail.isEmpty ? "" : "  " + tail)
        return line
    }

    /// Ten cells, filled in proportion to `percent` (0…100, clamped).
    public static func bar(_ percent: Double) -> String {
        let filled = min(barCells, max(0, Int((min(100, max(0, percent)) / 10).rounded())))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: barCells - filled)
    }

    /// The card status line, as the panel shows it (spec §6.3, §8):
    /// - backoff: "Paused until HH:MM" (+ the rate-limit message) (+ "Last updated …");
    /// - failure over older data: "⚠ Unable to refresh: <message> · Last updated N min ago[ (cached)]";
    /// - failure without data, or a message that already explains the cached data: "⚠ <message>";
    /// - success from the cache or a log: "(cached · N min ago)".
    /// `nil` when everything is normal.
    public static func statusLine(_ state: AccountState, now: Date, timeZone: TimeZone = .current) -> String? {
        let snapshot = state.lastSnapshot
        guard let error = state.lastError else {
            guard let snapshot else { return "No data yet" }
            return snapshot.source.isCached ? "(cached · \(Formatting.age(since: snapshot.dataAsOf, now: now)))" : nil
        }
        var parts: [String] = []
        if let paused = error.pausedUntil, paused > now {
            parts.append("Paused until " + clock(paused, timeZone: timeZone))
            if case .rateLimited = error { parts.append(error.userMessage) }
        } else if snapshot != nil, !explainsCachedData(error) {
            parts.append("⚠ Unable to refresh: " + error.userMessage)
        } else {
            parts.append("⚠ " + error.userMessage)
        }
        if let snapshot {
            parts.append("Last updated " + Formatting.age(since: snapshot.dataAsOf, now: now)
                + (snapshot.source.isCached ? " (cached)" : ""))
        }
        return parts.joined(separator: " · ")
    }

    /// "23:41".
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Messages that already describe the cached-data situation (spec §8), as on the panel card.
    static func explainsCachedData(_ error: ProviderError) -> Bool {
        switch error {
        case .waitingForClaudeCode, .keychainAccessDenied, .claudeBinaryNotFound, .accountChanged, .rateLimited: return true
        default: return false
        }
    }
}

extension CLIFormat {
    /// "Claude · Work", or just "Codex" when the name is the provider's own name.
    public static func accountTitle(_ config: AccountConfig) -> String {
        let provider = config.provider.defaultDisplayName
        let name = printable(config.displayName).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.caseInsensitiveCompare(provider) == .orderedSame { return provider }
        return "\(provider) · \(name)"
    }

    /// Replaces control characters (e.g. terminal escape sequences in a name) with spaces.
    public static func printable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
    }

    /// Pads on the right to `width` characters (grapheme clusters).
    public static func pad(_ text: String, to width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// Pads on the left to `width` characters.
    public static func leftPad(_ text: String, to width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    /// Cuts `text` to `width` characters, ending with "…" when shortened.
    public static func truncate(_ text: String, to width: Int) -> String {
        guard text.count > width, width > 1 else { return text }
        return String(text.prefix(width - 1)) + "…"
    }
}
