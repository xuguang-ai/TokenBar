import Foundation

/// Human-readable `tokenbar status` output, mirroring the panel cards (spec §6.3).
///
/// ```text
/// Claude · Work  Max
///   5h      ███████░░░   32% left  2h 14m
///   Week    ██░░░░░░░░   81% left  3d 4h
///   ⚠ Network error · Last updated 14 min ago
/// ```
///
/// Plain Unicode, never ANSI escapes, so it is the same on a TTY and in a pipe. Contains no email,
/// no accountUuid and no error payloads, only `ProviderError.userMessage` (spec §9).
public enum CLIStatusTable {
    public static let barCells = 10

    public static func render(states: [AccountState], displayMode: DisplayMode, now: Date) -> String {
        guard !states.isEmpty else { return "No accounts selected.\n" }
        return states.map { block($0, displayMode: displayMode, now: now) }.joined(separator: "\n")
    }

    /// One account block, ending with a newline.
    public static func block(_ state: AccountState, displayMode: DisplayMode, now: Date) -> String {
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
        if let status = statusLine(state, now: now) {
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

    /// The card status line (spec §6.3): "⚠ <message>", "Last updated N min ago", "(cached)".
    /// `nil` when everything is normal.
    public static func statusLine(_ state: AccountState, now: Date) -> String? {
        var parts: [String] = []
        if let error = state.lastError {
            parts.append("⚠ " + error.userMessage)
        }
        guard let snapshot = state.lastSnapshot else {
            return parts.isEmpty ? "No data yet" : parts.joined(separator: " · ")
        }
        if snapshot.source.isCached || state.lastError != nil {
            parts.append("Last updated " + Formatting.age(since: snapshot.dataAsOf, now: now))
        }
        guard !parts.isEmpty else { return nil }
        var line = parts.joined(separator: " · ")
        if case .claudeCache = snapshot.source { line += " (cached)" }
        return line
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
