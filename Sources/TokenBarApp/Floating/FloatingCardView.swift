// The floating window's content (spec §6.4): one two-line row per enabled account, hover-only controls.
// Presentation only: it takes plain row models, so the live window and the render preview share it.
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

struct AppFloatingCard: View {
    let rows: [AppFloatingRowModel]
    let isRefreshing: Bool
    let isHovering: Bool
    let canRefresh: Bool
    let onUnpin: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if rows.isEmpty {
                Text("No accounts enabled")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { AppFloatingHairline() }
                AppFloatingRow(row: row)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, AppFloatingMetrics.padding)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(width: AppFloatingMetrics.width, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: isHovering)
    }

    /// Quiet title; the controls fade in on hover. Fixed height, so nothing moves when they appear.
    private var header: some View {
        HStack(spacing: 2) {
            Text("TokenBar")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if canRefresh {
                AppFloatingHeaderButton(symbol: "arrow.clockwise", help: "Refresh now", spinning: isRefreshing,
                                        action: onRefresh)
                    .opacity(isHovering || isRefreshing ? 1 : 0)
                    .allowsHitTesting(isHovering)
            }
            AppFloatingHeaderButton(symbol: "pin.slash", help: "Unpin", spinning: false, action: onUnpin)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
        }
        .frame(height: 18)
    }
}

private struct AppFloatingHeaderButton: View {
    let symbol: String
    let help: String
    let spinning: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .modifier(AppFloatingSpin(active: spinning))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 20, height: 18)
                .background(Circle().fill(.primary.opacity(isHovered ? 0.08 : 0)).frame(width: 18, height: 18))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Rotates a symbol while active (macOS 15+); a static symbol earlier or with Reduce Motion.
private struct AppFloatingSpin: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.symbolEffect(.rotate, options: .repeating, isActive: active && !reduceMotion)
        } else {
            content
        }
    }
}

struct AppFloatingHairline: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(.primary.opacity(contrast == .increased ? 0.25 : 0.1))
            .frame(height: 1 / max(displayScale, 1))
            .padding(.leading, AppFloatingMetrics.iconColumn + AppFloatingMetrics.iconGap)
    }
}

private struct AppFloatingRow: View {
    let row: AppFloatingRowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleLine
            AppFloatingBar(fraction: row.fraction, status: row.status, opacity: barOpacity)
                .padding(.leading, textInset)
                .padding(.top, 7)
            detailLine
                .padding(.top, 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    /// Dimmed without data, slightly muted while stale.
    private var barOpacity: Double {
        if row.isDimmed { return 0.45 }
        if case .stale = row.condition { return 0.6 }
        return 1
    }

    private var textInset: CGFloat { AppFloatingMetrics.iconColumn + AppFloatingMetrics.iconGap }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Image(systemName: Self.symbol(for: row.provider))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: AppFloatingMetrics.iconColumn, alignment: .center)
                .padding(.trailing, AppFloatingMetrics.iconGap)
            Text(row.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if let plan = row.plan {
                Text(plan)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.primary.opacity(0.07)))
                    .padding(.leading, 6)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            percent.layoutPriority(1)
        }
    }

    @ViewBuilder
    private var percent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if let value = row.percent {
                (Text("\(Int(value.rounded()))")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                 + Text("%")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded)))
                    .monospacedDigit()
                    .foregroundStyle(percentStyle)
                Text(row.suffix)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("–")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .fixedSize()
    }

    private var percentStyle: AnyShapeStyle {
        if row.isDimmed { return AnyShapeStyle(.tertiary) }
        switch row.status {
        case .critical: return AnyShapeStyle(AppFloatingPalette.color(for: .critical))
        default: return AnyShapeStyle(.primary)
        }
    }

    private var detailLine: some View {
        HStack(spacing: 4) {
            detailText
            Spacer(minLength: 6)
            if !row.busySessionNames.isEmpty {
                AppFloatingBusyBadge(names: row.busySessionNames)
            }
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.leading, textInset)
    }

    @ViewBuilder
    private var detailText: some View {
        switch row.condition {
        case .ok:
            Text(windowAndReset)
        case .notStarted:
            Text("not started")
        case .stale(let age):
            warningIcon
            Text([age, row.windowLabel].compactMap { $0 }.joined(separator: " · "))
                .help(row.detailHelp.map { "\($0) — showing data from \(age)" } ?? "Data from \(age)")
        case .notLoggedIn:
            Image(systemName: "person.crop.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Not logged in")
        case .failed(let message):
            warningIcon
            Text(message).truncationMode(.tail).help(message)
        case .loading:
            Text("Loading…")
        case .noData:
            Text("No data yet")
        }
    }

    private var windowAndReset: String {
        var text = row.windowLabel ?? ""
        if let reset = row.resetText { text += " · resets \(reset)" }
        return text
    }

    private var warningIcon: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AppFloatingPalette.warning)
    }

    /// Neutral SF Symbols, not brand marks.
    static func symbol(for provider: ProviderKind) -> String {
        switch provider {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

private struct AppFloatingBar: View {
    let fraction: Double?
    let status: UsageStatus
    let opacity: Double
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            let value = fraction ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(contrast == .increased ? 0.18 : 0.09))
                if value > 0 {
                    Capsule()
                        .fill(AppFloatingPalette.color(for: status))
                        .frame(width: max(AppFloatingMetrics.barHeight, proxy.size.width * value))
                }
            }
        }
        .frame(height: AppFloatingMetrics.barHeight)
        .opacity(opacity)
    }
}

private struct AppFloatingBusyBadge: View {
    let names: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(AppFloatingPalette.busy)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            Text("\(names.count)")
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
        }
        .fixedSize()
        .help("Busy: " + names.joined(separator: ", "))
    }
}
