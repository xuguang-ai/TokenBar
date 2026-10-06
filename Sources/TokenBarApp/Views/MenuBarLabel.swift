// Menu bar label (spec §6.2): HStack { symbol; text }. A plain Label would drop the text.
import SwiftUI
import TokenBarCore

struct AppMenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let summary = model.menuBarSummary
        HStack(spacing: 3) {
            Image(systemName: Self.symbol(for: summary.status))
            Text(summary.text).monospacedDigit()
        }
    }

    static func symbol(for status: UsageStatus?) -> String {
        switch status {
        case nil: return "gauge.with.dots.needle.0percent"
        case .normal: return "gauge.with.dots.needle.33percent"
        case .gettingLow: return "gauge.with.dots.needle.50percent"
        case .low: return "gauge.with.dots.needle.67percent"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }
}
