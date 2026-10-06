// Metrics and status colors of the floating window (spec §6.4). The window itself shows the full panel
// (AppPanelContent) on the floating chrome; the status colors are shared with the panel through AppStyle.
import AppKit
import SwiftUI
import TokenBarCore

enum AppFloatingMetrics {
    static let width: CGFloat = 280
    static let cornerRadius: CGFloat = 14
    static let padding: CGFloat = 12
    static let iconColumn: CGFloat = 16
    static let iconGap: CGFloat = 6
    static let barHeight: CGFloat = 4
}

enum AppFloatingPalette {
    static func color(for status: UsageStatus) -> Color {
        switch status {
        case .normal: return Color(nsColor: .systemGreen)
        case .gettingLow: return Color(nsColor: .systemYellow)
        case .low: return Color(nsColor: .systemOrange)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    static let warning = Color(nsColor: .systemOrange)
    /// Activity, deliberately not a status color.
    static let busy = Color(nsColor: .controlAccentColor)
}
