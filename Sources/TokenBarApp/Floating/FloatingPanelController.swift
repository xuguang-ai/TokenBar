// Owns the floating panel and its compact content (spec §6.4).
import AppKit
import SwiftUI
import TokenBarCore

final class AppFloatingPanelController {
    static let autosaveName = "TokenBarFloating"
    private static let menuBarGap: CGFloat = 8

    private weak var model: AppModel?
    private let autosave: Bool
    private var panel: AppFloatingPanel?

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
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> AppFloatingPanel {
        let panel = AppFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 80))
        if let model {
            let hosting = AppDraggableHostingView(rootView: AppCompactView(model: model))
            hosting.sizingOptions = [.intrinsicContentSize]
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

/// One compact row per enabled account: "Work  32%  2h14m  ●2" (worst started window), plus a 📌 to unpin.
struct AppCompactView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("TokenBar").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.isPinned = false
                } label: {
                    Text("📌").font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Unpin")
            }
            if model.enabledAccounts.isEmpty {
                Text("No accounts").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.enabledAccounts, id: \.config.id) { state in
                AppCompactRow(model: model, state: state)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(width: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AppCompactRow: View {
    let model: AppModel
    let state: AccountState

    var body: some View {
        let now = model.now
        let display = state.lastSnapshot.map { DisplayDerivation.derive($0, now: now) }
        let worst = display?.worstWindow
        let busy = model.busySessionCount(for: state.config.id)
        HStack(spacing: 6) {
            Text(state.config.displayName).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if let display {
                Text(worst.map { Formatting.percent(DisplayDerivation.percentValue($0, mode: model.settings.displayMode)) }
                     ?? (model.settings.displayMode == .remaining ? "100%" : "0%"))
                    .foregroundStyle(AppStatusColor.color(for: display.status))
                    .monospacedDigit()
                if let reset = worst?.resetsAt {
                    Text(Formatting.compactCountdown(to: reset, now: now)).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                Text(state.lastError == nil ? "–" : "!").foregroundStyle(.secondary)
            }
            if state.lastError != nil && display != nil { Text("?").foregroundStyle(.secondary) }
            if busy > 0 {
                Text("●\(busy)").foregroundStyle(.green).monospacedDigit()
            }
        }
        .font(.caption)
    }
}
