// The floating window (spec §6.4): a non-activating, draggable panel on every Space, toggled by the status item.
import AppKit
import SwiftUI

/// Borderless and transparent, so the SwiftUI card's continuous corners are the window's real shape and
/// the system shadow follows them.
final class AppFloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    override var canBecomeKey: Bool { true }

    /// The window hangs from the menu bar: when the content changes height in place (same origin), keep the
    /// top edge where it is and grow or shrink downward.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if rect.origin == frame.origin && rect.height != frame.height && frame.height > 0 {
            rect.origin.y = frame.maxY - rect.height
        }
        super.setFrame(rect, display: flag)
    }
}

/// Pointer-inside state for the hover-only controls. Fed by an `.activeAlways` tracking area, so it works
/// while TokenBar is not the active app.
@Observable
final class AppFloatingHoverState {
    var isHovering = false
}

/// Lets a drag anywhere on the SwiftUI content move the window. Specialized on `AppFloatingRootView` rather
/// than generic: a generic NSHostingView subclass crashes the Swift 6.2.4 optimizer (-c release, signal 11
/// in EarlyPerfInliner on its deallocating deinit).
final class AppDraggableHostingView: NSHostingView<AppFloatingRootView> {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { true }
    /// The panel never becomes active, so the first click must reach the buttons.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea { onHoverChange?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { onHoverChange?(false) }
    }

    /// The shadow of a transparent window is computed from its content; recompute it when the size changes.
    override func layout() {
        super.layout()
        window?.invalidateShadow()
    }
}
