// The 📌 floating window (spec §6.4): a non-activating, draggable panel on every Space.
import AppKit
import SwiftUI

final class AppFloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }
}

/// Lets a drag anywhere on the SwiftUI content move the window. Specialized on `AppCompactView` rather
/// than generic: a generic NSHostingView subclass crashes the Swift 6.2.4 optimizer (-c release, signal 11
/// in EarlyPerfInliner on its deallocating deinit).
final class AppDraggableHostingView: NSHostingView<AppCompactView> {
    override var mouseDownCanMoveWindow: Bool { true }
}
