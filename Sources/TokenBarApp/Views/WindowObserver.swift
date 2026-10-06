// Panel visibility (spec §6.1): a zero-size view that watches its window's occlusion and key state.
import AppKit
import SwiftUI

struct AppWindowObserver: NSViewRepresentable {
    let onVisibilityChange: (Bool) -> Void

    func makeNSView(context: Context) -> AppWindowObserverView {
        let view = AppWindowObserverView()
        view.onVisibilityChange = onVisibilityChange
        return view
    }

    func updateNSView(_ nsView: AppWindowObserverView, context: Context) {
        nsView.onVisibilityChange = onVisibilityChange
    }

    static func dismantleNSView(_ nsView: AppWindowObserverView, coordinator: ()) {
        nsView.stopObserving()
        nsView.onVisibilityChange?(false)
    }
}

final class AppWindowObserverView: NSView {
    var onVisibilityChange: ((Bool) -> Void)?
    private var observers: [any NSObjectProtocol] = []

    override var intrinsicContentSize: NSSize { .zero }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else {
            onVisibilityChange?(false)
            return
        }
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            })
        }
        report()
        // The window may still be ordering in; check again once it is on screen.
        DispatchQueue.main.async { [weak self] in self?.report() }
    }

    func stopObserving() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
    }

    private func report() {
        guard let window else { return }
        onVisibilityChange?(window.isVisible && window.occlusionState.contains(.visible))
    }
}
