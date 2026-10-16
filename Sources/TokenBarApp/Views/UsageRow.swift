// One usage window row: label, colored bar, percent per display mode, reset time (spec §6.3).
// Fixed column widths keep the bars and numbers aligned across rows and cards.
import SwiftUI
import TokenBarCore

struct AppUsageRow: View {
    let window: DisplayWindow
    let mode: DisplayMode
    /// The reset column as a clock time ("Wed 11:00 PM") or a countdown ("1d 12h").
    let resetStyle: ResetTimeStyle
    let now: Date
    /// The data is older than the last attempt: mute the bar and the number.
    var isStale = false
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var environmentCalendar
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        let value = DisplayDerivation.percentValue(window, mode: mode)
        HStack(spacing: 10) {
            Text(window.kind.shortLabel)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: AppStyle.labelColumn, alignment: .leading)
            AppUsageBar(fraction: min(1, max(0, value / 100)), color: AppStyle.statusColor(window.status))
                .opacity(isStale ? 0.55 : 1)
            AppPercentText(value: value, suffix: mode == .remaining ? "left" : "used", style: percentStyle)
                .frame(width: AppStyle.percentColumn, alignment: .trailing)
            Text(trailing)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(window.isStarted ? .secondary : .tertiary)
                .lineLimit(1)
                .frame(width: AppStyle.resetColumn, alignment: .trailing)
                .help(resetHelp)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var percentStyle: AnyShapeStyle {
        if isStale || !window.isStarted { return AnyShapeStyle(.secondary) }
        if window.status == .critical { return AnyShapeStyle(AppStyle.statusColor(.critical)) }
        return AnyShapeStyle(.primary)
    }

    private var calendar: Calendar {
        var calendar = environmentCalendar
        calendar.timeZone = timeZone
        return calendar
    }

    private var trailing: String {
        if let reset = window.resetsAt {
            return Formatting.resetText(reset, now: now, style: resetStyle, calendar: calendar, locale: locale)
        }
        return window.didReset ? "reset" : "not started"
    }

    /// The other format, as a tooltip: "Resets in 1d 12h" for clock times, "Resets Wed 11:00 PM" for countdowns.
    private var resetHelp: String {
        guard let reset = window.resetsAt, reset > now else { return "" }
        switch resetStyle {
        case .clock: return "Resets in " + Formatting.countdown(to: reset, now: now)
        case .countdown: return "Resets " + Formatting.resetClock(reset, now: now, calendar: calendar, locale: locale)
        }
    }

    /// "5h, 60% used, resets in 2h 14m".
    private var accessibilityText: String {
        var parts = [window.kind.shortLabel, DisplayDerivation.percentText(window, mode: mode)]
        if let reset = window.resetsAt {
            parts.append("resets in " + AppFloatingRowModel.spokenCountdown(to: reset, now: now))
        } else {
            parts.append(window.didReset ? "reset" : "not started")
        }
        if isStale { parts.append("not current") }
        return parts.joined(separator: ", ")
    }
}
