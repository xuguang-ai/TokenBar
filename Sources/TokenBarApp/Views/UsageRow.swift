// One usage window row: label, colored bar, percent per display mode, countdown (spec §6.3).
import SwiftUI
import TokenBarCore

struct AppUsageRow: View {
    let window: DisplayWindow
    let mode: DisplayMode
    let now: Date

    var body: some View {
        let fraction = min(1, max(0, DisplayDerivation.percentValue(window, mode: mode) / 100))
        HStack(spacing: 8) {
            Text(window.kind.shortLabel)
                .frame(width: 52, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(AppStatusColor.color(for: window.status))
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 6)
            Text(DisplayDerivation.percentText(window, mode: mode))
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
            Text(trailing)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
        .font(.caption)
    }

    private var trailing: String {
        if let reset = window.resetsAt { return Formatting.countdown(to: reset, now: now) }
        return window.didReset ? "reset" : "not started"
    }
}
