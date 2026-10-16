// Shared look of the panel and Settings: metrics, colors and small controls. Status colors and provider
// symbols match the floating window (AppFloatingPalette), so every surface reads the same.
import AppKit
import SwiftUI
import TokenBarCore

enum AppStyle {
    // MARK: Panel metrics

    static let panelWidth: CGFloat = 360
    static let panelInset: CGFloat = 10
    static let moduleRadius: CGFloat = 11
    static let modulePadding: CGFloat = 11
    static let moduleSpacing: CGFloat = 8
    static let iconColumn: CGFloat = 16
    static let barHeight: CGFloat = 5
    /// Usage row columns, fixed so they line up across rows and across cards.
    static let labelColumn: CGFloat = 42
    static let percentColumn: CGFloat = 60
    /// Fits "Wed 12:00 AM" (about 78 pt at the 11 pt row font); the flexible bar gives up the room.
    static let resetColumn: CGFloat = 80

    // MARK: Colors

    static func statusColor(_ status: UsageStatus) -> Color { AppFloatingPalette.color(for: status) }
    static let warning = AppFloatingPalette.warning
    /// Activity (busy sessions), deliberately not a status color.
    static let busy = AppFloatingPalette.busy

    /// Neutral SF Symbols, not brand marks (same as the floating window).
    static func symbol(for provider: ProviderKind) -> String {
        switch provider {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// "team" → "Team", "max_20x" → "Max 20x".
    static func plan(_ raw: String?) -> String? { raw.flatMap(AppFloatingRowModel.prettyPlan) }

    static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

// MARK: - Module (Control Center style card)

private struct AppModuleBackground: ViewModifier {
    let tint: Color?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppStyle.moduleRadius, style: .continuous)
        let dark = scheme == .dark
        let fill: Color = tint.map { $0.opacity(dark ? 0.16 : 0.10) }
            ?? Color.primary.opacity(dark ? 0.07 : 0.045)
        let stroke: Color = tint.map { $0.opacity(dark ? 0.30 : 0.22) }
            ?? Color.primary.opacity(contrast == .increased ? 0.2 : (dark ? 0.07 : 0.06))
        content
            .padding(AppStyle.modulePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(stroke, lineWidth: 0.5))
    }
}

extension View {
    /// A rounded panel module: padding, a faint fill and a hairline edge; `tint` for notices.
    func appModule(tint: Color? = nil) -> some View { modifier(AppModuleBackground(tint: tint)) }
}

// MARK: - Small pieces

/// "Team", "Max": a quiet capsule badge (as in the floating window).
struct AppPlanBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(.primary.opacity(0.07)))
            .fixedSize()
    }
}

/// A capsule meter on a faint track, in the status color.
struct AppUsageBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = AppStyle.barHeight
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(contrast == .increased ? 0.18 : 0.09))
                if fraction > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: max(height, proxy.size.width * min(1, fraction)))
                }
            }
        }
        .frame(height: height)
    }
}

/// "82% used": semibold rounded number, a smaller "%", and a quiet suffix.
struct AppPercentText: View {
    let value: Double
    let suffix: String
    var style: AnyShapeStyle = AnyShapeStyle(.primary)
    var size: CGFloat = 13

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2.5) {
            (Text("\(Int(value.rounded()))").font(.system(size: size, weight: .semibold, design: .rounded))
             + Text("%").font(.system(size: size * 0.77, weight: .semibold, design: .rounded)))
                .monospacedDigit()
                .foregroundStyle(style)
            Text(suffix)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

struct AppHairline: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(.primary.opacity(contrast == .increased ? 0.25 : 0.1))
            .frame(height: 1 / max(displayScale, 1))
    }
}

/// The pulsing accent dot of a busy session (as in the floating window).
struct AppBusyDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 6.5))
            .foregroundStyle(AppStyle.busy)
            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
    }
}

/// Borderless icon button with a hover highlight, for the panel header and footer.
struct AppIconButton: View {
    let symbol: String
    let help: String
    var spinning = false
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .modifier(AppSpin(active: spinning))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(isHovered && isEnabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Borderless text button with a hover highlight ("Quit").
struct AppTextButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.primary.opacity(isHovered ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// Rotates a symbol while active (macOS 15+); a static symbol earlier or with Reduce Motion.
struct AppSpin: ViewModifier {
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

/// A one-line status message: an SF Symbol and text. Warnings are orange, info is secondary.
struct AppStatusLine: View {
    enum Tone { case warning, info }
    let symbol: String
    let text: String
    var tone: Tone = .info

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tone == .warning ? AnyShapeStyle(AppStyle.warning) : AnyShapeStyle(.secondary))
                .frame(width: AppStyle.iconColumn - 2)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(tone == .warning ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
