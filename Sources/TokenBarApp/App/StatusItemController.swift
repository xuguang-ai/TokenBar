// The menu bar item (spec §6.2): an AppKit NSStatusItem showing the status symbol and the menu bar text.
// A left click toggles the floating window; a right click (or control-click) shows a small menu.
import AppKit
import Observation
import SwiftUI
import TokenBarCore

final class AppStatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private(set) var statusItem: NSStatusItem?
    /// Refresh, Settings…, Quit TokenBar. Attached to the item only while it is shown.
    let contextMenu = NSMenu()
    /// A zero-size SwiftUI host inside the status button that captures `openSettings` (spec §6.1).
    private var settingsBridge: NSView?
    /// The status bar lays the item out after launch and shifts it as other items come and go.
    private var moveObserver: (any NSObjectProtocol)?

    init(model: AppModel) {
        self.model = model
        super.init()
        buildMenu()
    }

    var button: NSStatusBarButton? { statusItem?.button }

    /// The button's frame in screen coordinates, used to anchor the floating window on first open.
    var buttonScreenFrame: NSRect? {
        guard let button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Creates the status item. Called once the run loop is up.
    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.toolTip = "TokenBar"
            let bridge = NSHostingView(rootView: AppSettingsBridge(model: model))
            bridge.frame = .zero
            button.addSubview(bridge)
            settingsBridge = bridge
            if let window = button.window {
                moveObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.model.floatingController?.statusItemDidMove() }
                }
            }
        }
        observeModel()
    }

    // MARK: Label

    /// Re-renders whenever anything the label reads changes (accounts, settings, the minute-level clock).
    private func observeModel() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeModel() }
        }
    }

    private func render() {
        let summary = model.menuBarSummary
        guard let button else { return }
        let image = NSImage(systemSymbolName: AppStatusItemController.symbol(for: summary.status),
                            accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        button.image = image
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        // A leading thin gap between the symbol and the text, as in the former SwiftUI label.
        button.attributedTitle = NSAttributedString(string: " " + summary.text, attributes: [.font: font])
        let mode = model.settings.displayMode
        let name = summary.accountID.flatMap { id in model.settings.accounts.first { $0.id == id }?.displayName }
        button.toolTip = Self.toolTip(summary, mode: mode, accountName: name)
        button.setAccessibilityLabel(Self.accessibilityLabel(summary, mode: mode, accountName: name))
    }

    static func symbol(for status: UsageStatus?) -> String {
        switch status {
        case nil: return "gauge.with.dots.needle.0percent"
        case .normal: return "gauge.with.dots.needle.33percent"
        case .gettingLow: return "gauge.with.dots.needle.50percent"
        case .low: return "gauge.with.dots.needle.67percent"
        case .critical: return "exclamationmark.triangle.fill"
        }
    }

    /// What the menu bar text says, without the account: "5h 36% used", "5h 36% used, may be out of date",
    /// "usage could not be loaded", "no data".
    static func describe(_ summary: MenuBarSummary, mode: DisplayMode) -> String {
        switch summary.text {
        case "!": return "usage could not be loaded"
        case "–": return "no data"
        default:
            let stale = summary.text.hasSuffix("?")
            let value = stale ? String(summary.text.dropLast()) : summary.text
            let window = summary.windowKind.map { $0.shortLabel + " " } ?? ""
            return "\(window)\(value) \(mode == .remaining ? "left" : "used")" + (stale ? ", may be out of date" : "")
        }
    }

    /// "xai@example.com · 5h 36% used"; "TokenBar · no data" when no account was chosen.
    static func toolTip(_ summary: MenuBarSummary, mode: DisplayMode, accountName: String?) -> String {
        "\(accountName ?? "TokenBar") · \(describe(summary, mode: mode))"
    }

    /// "TokenBar, xai@example.com, 5h 36% used", "TokenBar, no data".
    static func accessibilityLabel(_ summary: MenuBarSummary, mode: DisplayMode, accountName: String?) -> String {
        (["TokenBar", accountName, describe(summary, mode: mode)] as [String?]).compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Clicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isSecondary {
            showMenu()
        } else {
            model.isFloatingVisible.toggle()
        }
    }

    private func showMenu() {
        guard let statusItem, let button = statusItem.button else { return }
        // Attach the menu only for this click, so a left click keeps toggling the window.
        statusItem.menu = contextMenu
        button.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }

    private func buildMenu() {
        contextMenu.delegate = self
        contextMenu.autoenablesItems = false
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        let quit = NSMenuItem(title: "Quit TokenBar", action: #selector(quit), keyEquivalent: "q")
        for item in [refresh, settings, quit] { item.target = self }
        contextMenu.items = [refresh, settings, .separator(), quit]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.first?.isEnabled = !model.isReadOnly
    }

    @objc private func refresh() { model.refreshNow() }
    @objc private func openSettings() { model.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Captures the SwiftUI `openSettings` action for the AppKit side (the gear button and the status menu).
/// It lives in the status button, which is on screen for the App's whole life.
struct AppSettingsBridge: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { model.openSettingsAction = openSettings }
    }
}
