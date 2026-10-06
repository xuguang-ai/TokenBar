// Owns the floating panel, which shows the full panel content (spec §6.4).
import AppKit
import SwiftUI
import TokenBarCore

final class AppFloatingPanelController {
    static let autosaveName = "TokenBarFloating"
    private static let menuBarGap: CGFloat = 8

    private weak var model: AppModel?
    private let autosave: Bool
    private var panel: AppFloatingPanel?
    private let hover = AppFloatingHoverState()

    init(model: AppModel, autosave: Bool) {
        self.model = model
        self.autosave = autosave
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func setVisible(_ visible: Bool) {
        if visible {
            let panel = self.panel ?? makePanel()
            // orderFrontRegardless never activates the app (NSApp.isActive stays unchanged).
            panel.orderFrontRegardless()
        } else {
            hover.isHovering = false
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> AppFloatingPanel {
        let panel = AppFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: AppStyle.panelWidth, height: 300))
        if let model {
            let hover = self.hover
            let hosting = AppDraggableHostingView(rootView: AppFloatingRootView(model: model))
            hosting.onHoverChange = { hover.isHovering = $0 }
            // Min, max and intrinsic size: the window hugs the content as rows come and go.
            hosting.sizingOptions = [.minSize, .maxSize, .intrinsicContentSize]
            panel.contentView = hosting
            panel.setContentSize(hosting.fittingSize)
        }
        let restored = autosave && panel.setFrameUsingName(Self.autosaveName)
        if !restored { placeTopRight(panel) }
        if autosave { panel.setFrameAutosaveName(Self.autosaveName) }
        self.panel = panel
        return panel
    }

    /// Top-right of the main screen, 8 pt below the menu bar.
    private func placeTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: visible.maxX - size.width - Self.menuBarGap,
                             y: visible.maxY - size.height - Self.menuBarGap)
        panel.setFrameOrigin(origin)
    }
}

/// The hosted root: the full panel (the same content as the menu bar panel) on the floating chrome.
/// Pinning simply detaches the panel; there is no separate compact layout.
struct AppFloatingRootView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        AppPanelContent(model: model)
            .modifier(AppFloatingChrome(backdrop: .live))
            .onAppear {
                // The pinned window can appear before the menu bar panel ever opened; give its gear
                // button a working Settings action too.
                if model.openSettingsAction == nil { model.openSettingsAction = openSettings }
            }
    }
}

/// Material, continuous corners and a hairline border.
struct AppFloatingChrome: ViewModifier {
    enum Backdrop {
        /// Liquid Glass on macOS 26+, else a behind-window visual effect view.
        case live
        /// An opaque stand-in for offscreen renders, which cannot show vibrancy.
        case solid(Color)
    }

    let backdrop: Backdrop
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: AppFloatingMetrics.cornerRadius, style: .continuous)
        material(content, shape: shape)
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1 / max(displayScale, 1)))
            .contentShape(shape)
    }

    @ViewBuilder
    private func material(_ content: Content, shape: RoundedRectangle) -> some View {
        switch backdrop {
        case .solid(let color):
            content.background(color, in: shape)
        case .live:
            if #available(macOS 26, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(AppFloatingEffectView().clipShape(shape))
            }
        }
    }

    private var borderColor: Color {
        let boost = contrast == .increased ? 2.0 : 1.0
        return colorScheme == .dark ? .white.opacity(0.12 * boost) : .black.opacity(0.08 * boost)
    }
}

private struct AppFloatingEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
