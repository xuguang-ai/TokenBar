// The 📌 floating window (spec §6.4): a non-activating, draggable panel on every Space.
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
