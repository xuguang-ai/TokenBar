// Owns the floating window, which shows the full panel content (spec §6.4). It is TokenBar's only window
// besides Settings: a click on the status item toggles it.
import AppKit
import SwiftUI
import TokenBarCore

final class AppFloatingPanelController {
    static let autosaveName = "TokenBarFloating"
    /// Gap between the menu bar (or the status item) and the window on first open.
    static let anchorGap: CGFloat = 6
    /// Minimum distance from the screen's visible edges.
    static let screenMargin: CGFloat = 6

    private weak var model: AppModel?
    private let autosave: Bool
    /// The status item's screen frame, if known.
    private let anchor: () -> NSRect?
    private var panel: AppFloatingPanel?
    private let hover = AppFloatingHoverState()
    /// True once the frame came from the user: restored from the autosave, or dragged. Until then the window
    /// is re-anchored under the status item every time it opens.
    private(set) var isUserPlaced = false
    private var moveObservers: [any NSObjectProtocol] = []

    init(model: AppModel, autosave: Bool, anchor: @escaping () -> NSRect?) {
        self.model = model
        self.autosave = autosave
        self.anchor = anchor
    }

    /// The status item moved (it is laid out after launch, and shifts as other items come and go): follow it
    /// until the user places the window.
    func statusItemDidMove() {
        guard let panel, panel.isVisible, !isUserPlaced else { return }
        placeUnderStatusItem(panel)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            let panel = self.panel ?? makePanel()
            if !isUserPlaced { placeUnderStatusItem(panel) }
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
            let root = AppFloatingRootView(model: model, hover: hover) { [weak model] in
                model?.isFloatingVisible = false
            }
            let hosting = AppDraggableHostingView(rootView: root)
            hosting.onHoverChange = { hover.isHovering = $0 }
            // Min, max and intrinsic size: the window hugs the content as rows come and go.
            hosting.sizingOptions = [.minSize, .maxSize, .intrinsicContentSize]
            panel.contentView = hosting
            panel.setContentSize(hosting.fittingSize)
        }
        isUserPlaced = autosave && panel.setFrameUsingName(Self.autosaveName)
        observeUserMoves(of: panel)
        self.panel = panel
        return panel
    }

    /// `willMove` is posted only when the user starts dragging, never for programmatic frame changes; the
    /// frame is saved once the drag has moved the window.
    private func observeUserMoves(of panel: NSPanel) {
        let center = NotificationCenter.default
        moveObservers.append(center.addObserver(forName: NSWindow.willMoveNotification, object: panel,
                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isUserPlaced = true }
        })
        moveObservers.append(center.addObserver(forName: NSWindow.didMoveNotification, object: panel,
                                                queue: .main) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel, self.isUserPlaced, self.autosave else { return }
                panel.saveFrame(usingName: Self.autosaveName)
            }
        })
    }

    /// Centered under the status item, `anchorGap` below the menu bar, clamped to the visible frame. Without
    /// a status item frame (it is not laid out yet), the top-right corner of the main screen.
    private func placeUnderStatusItem(_ panel: NSPanel) {
        let item = anchor()
        let screen = item.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        panel.setFrameOrigin(Self.anchoredOrigin(size: panel.frame.size, item: item, visible: screen.visibleFrame))
    }

    static func anchoredOrigin(size: NSSize, item: NSRect?, visible: NSRect) -> NSPoint {
        let top = min(item?.minY ?? visible.maxY, visible.maxY) - anchorGap
        let preferredX = item.map { $0.midX - size.width / 2 } ?? (visible.maxX - size.width)
        let x = min(max(preferredX, visible.minX + screenMargin), visible.maxX - size.width - screenMargin)
        let y = max(top - size.height, visible.minY + screenMargin)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }
}

/// The hosted root: the full panel content on the floating chrome, with a hover-only close button.
struct AppFloatingRootView: View {
    let model: AppModel
    let hover: AppFloatingHoverState
    let onClose: () -> Void

    var body: some View {
        AppPanelContent(model: model, close: .init(isShown: hover.isHovering, action: onClose))
            .modifier(AppFloatingChrome(backdrop: .live))
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
