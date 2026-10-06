// TokenBarApp target: compiled with tools 6.2, Swift 6 language mode, .defaultIsolation(MainActor.self).
// Everything here is implicitly @MainActor; TokenBarCore stays nonisolated.
import AppKit
import SwiftUI
import TokenBarCore
import os

private let logger = Logger(subsystem: "dev.tokenbar.TokenBar", category: "app")

/// Line to stderr (visible with `open --stderr <file>` or when running Contents/MacOS/TokenBar) + unified log.
func emit(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

enum LaunchOptions {
    static let arguments = ProcessInfo.processInfo.arguments
    static var selfTest: Bool { arguments.contains("--selftest") }
    static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

/// How the status item renders (verified on macOS 26.7 by inspecting NSStatusBarButton):
///   .hstack  HStack { Image; Text }      -> button.image + button.title (icon AND text)
///   .label   Label(text, systemImage:)   -> icon only, text dropped
///   .text    Text("\(Image(...)) 42%")    -> title with inline symbol attachment, no image
///   .image   ImageRenderer -> NSImage     -> any custom drawing (e.g. one bar per account)
enum MenuBarLabelStyle: String {
    case hstack, label, text, image
    static var current: MenuBarLabelStyle {
        LaunchOptions.value(after: "--label").flatMap(MenuBarLabelStyle.init(rawValue:)) ?? .hstack
    }
}

// MARK: - App

@main
struct TokenBar: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = UsageModel()
    private let labelStyle = MenuBarLabelStyle.current

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(model: model)
        } label: {
            MenuBarLabel(model: model, style: labelStyle)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        emit("app: didFinishLaunching activationPolicy=\(NSApp.activationPolicy().rawValue) (1 = accessory)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        emit("app: willTerminate")
    }
}

// MARK: - Model

@Observable
final class UsageModel {
    private(set) var accounts: [AccountUsage] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var refreshCount = 0
    private(set) var wakeEvents = 0
    var refreshIntervalSeconds = 60 {
        didSet { startPeriodicRefresh() }
    }

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    init() {
        if LaunchOptions.selfTest { refreshIntervalSeconds = 1 }  // didSet does not run inside init
        startPeriodicRefresh()
        observeWake()
        if LaunchOptions.selfTest { Task { await self.runSelfTest() } }
    }

    var menuBarText: String { UsageFormatting.compactLabel(for: accounts) }
    var menuBarFractions: [Double] { accounts.map { $0.window(.fiveHour)?.fraction ?? 0 } }

    func refresh(reason: String) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            // ProcessRunner.run is nonisolated + async: the child runs without blocking the main actor.
            let probe = try await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/env"), arguments: ["echo", "hi"], timeout: .seconds(5))
            guard probe.status == 0 else { throw ProcessRunnerError.launchFailed("exit \(probe.status)") }
            accounts = SampleData.accounts(now: .now, seed: refreshCount)
            refreshCount += 1
            lastRefresh = .now
            lastError = nil
            logger.debug("refresh(\(reason, privacy: .public)) #\(self.refreshCount)")
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Task-based periodic refresh. Task.sleep uses ContinuousClock, which keeps counting during system sleep,
    /// so an interval that elapsed while asleep fires right after wake.
    private func startPeriodicRefresh() {
        loopTask?.cancel()
        let interval = Duration.seconds(refreshIntervalSeconds)
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(reason: "timer")
                do { try await Task.sleep(for: interval, tolerance: .seconds(1)) } catch { return }
            }
        }
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The block is @Sendable and nonisolated even with queue: .main -> hop explicitly.
            Task { @MainActor in
                self?.wakeEvents += 1
                await self?.refresh(reason: "wake")
            }
        }
    }

    // MARK: Self-test: `TokenBar.app/Contents/MacOS/TokenBar --selftest` (exit 0 = pass). Opens UI briefly.

    private func runSelfTest() async {
        try? await Task.sleep(for: .seconds(2))
        var failures: [String] = []
        guard let button = SelfTest.statusBarButton() else {
            emit("SELFTEST FAIL: status item not found")
            exit(1)
        }
        emit("selftest: status item title=\"\(button.title)\" image=\(button.image.map { NSStringFromSize($0.size) } ?? "nil") width=\(button.frame.width)")
        if button.title.isEmpty && button.image == nil { failures.append("empty status item") }

        button.performClick(nil)  // opens the .window panel; UsagePanel.onAppear then opens Settings
        try? await Task.sleep(for: .seconds(2))
        let panelShown = NSApp.windows.contains { "\(type(of: $0))".hasPrefix("MenuBarExtraWindow") && $0.isVisible }
        let settings = NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }
        emit("selftest: panel=\(panelShown) settings visible=\(settings?.isVisible ?? false) key=\(settings?.isKeyWindow ?? false) appActive=\(NSApp.isActive)")
        if !panelShown { failures.append("panel not shown") }
        if settings?.isVisible != true { failures.append("settings not shown") }

        let wakesBefore = wakeEvents
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        try? await Task.sleep(for: .milliseconds(500))
        if wakeEvents != wakesBefore + 1 { failures.append("wake notification not handled") }
        if refreshCount < 2 { failures.append("periodic refresh not running (count \(refreshCount))") }
        if let lastError { failures.append("refresh error: \(lastError)") }

        if failures.isEmpty {
            emit("SELFTEST PASS refreshCount=\(refreshCount) wakeEvents=\(wakeEvents)")
            NSApp.terminate(nil)
        } else {
            emit("SELFTEST FAIL: \(failures.joined(separator: "; "))")
            exit(1)
        }
    }
}

enum SelfTest {
    static func statusBarButton() -> NSStatusBarButton? {
        for window in NSApp.windows where "\(type(of: window))".contains("StatusBar") {
            if let button = findButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = findButton(in: subview) { return button }
        }
        return nil
    }
}

// MARK: - Views

struct MenuBarLabel: View {
    let model: UsageModel
    let style: MenuBarLabelStyle
    private let symbol = "gauge.with.dots.needle.33percent"

    var body: some View {
        switch style {
        case .hstack:
            HStack(spacing: 3) {
                Image(systemName: symbol)
                Text(model.menuBarText)
            }
        case .label:
            Label(model.menuBarText, systemImage: symbol)
        case .text:
            Text("\(Image(systemName: symbol)) \(model.menuBarText)")
        case .image:
            Image(nsImage: MenuBarImage.render(fractions: model.menuBarFractions, text: model.menuBarText))
        }
    }
}

/// Renders an arbitrary SwiftUI view into a template NSImage for the status item.
enum MenuBarImage {
    static func render(fractions: [Double], text: String) -> NSImage {
        let content = HStack(spacing: 2) {
            ForEach(Array(fractions.enumerated()), id: \.offset) { _, fraction in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1.5).stroke(lineWidth: 1)
                    RoundedRectangle(cornerRadius: 1.5).frame(height: max(1, 14 * fraction))
                }
                .frame(width: 6, height: 14)
            }
            Text(text).font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(Color.black)
        .padding(.horizontal, 1)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true  // AppKit tints it for light/dark menu bars
        return image
    }
}

struct UsagePanel: View {
    let model: UsageModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TokenBar").font(.headline)
            ForEach(model.accounts) { account in
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.displayName).font(.subheadline.weight(.semibold))
                    ForEach(account.windows, id: \.kind) { window in
                        ProgressView(value: window.fraction) {
                            Text(window.kind == .fiveHour ? "5-hour" : "Weekly")
                        } currentValueLabel: {
                            Text("\(Int(window.usedPercent.rounded()))% · \(UsageFormatting.resetDescription(window.resetsAt, now: .now))")
                        }
                    }
                }
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Button("Refresh") {
                    Task { await model.refresh(reason: "button") }
                }
                .disabled(model.isRefreshing)
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Settings…") { showSettings() }
                SettingsLink { Image(systemName: "gearshape") }  // compiles/works, but cannot activate the app first
                Button("Quit") { NSApp.terminate(nil) }
            }
            if let last = model.lastRefresh {
                Text("Updated \(last.formatted(date: .omitted, time: .standard)) · #\(model.refreshCount)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            guard LaunchOptions.selfTest else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                showSettings()
            }
        }
    }

    /// LSUIElement apps are never frontmost by themselves. Verified on macOS 26.7: without activation the
    /// Settings window opens behind other apps (occluded, not key); cooperative NSApp.activate() was refused
    /// for a programmatic open; activate(ignoringOtherApps:) made the app active and Settings key + visible.
    /// NSApp.sendAction(Selector(("showSettingsWindow:")), ...) is a no-op on macOS 14+ ("Please use SettingsLink").
    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}

struct SettingsView: View {
    @Bindable var model: UsageModel

    var body: some View {
        Form {
            Picker("Refresh every", selection: $model.refreshIntervalSeconds) {
                Text("1 second (debug)").tag(1)
                Text("30 seconds").tag(30)
                Text("1 minute").tag(60)
                Text("5 minutes").tag(300)
            }
            LabeledContent("Refreshes so far", value: "\(model.refreshCount)")
            LabeledContent("Last refresh", value: model.lastRefresh?.formatted(date: .omitted, time: .standard) ?? "never")
        }
        .formStyle(.grouped)
        .frame(width: 380)
    }
}
