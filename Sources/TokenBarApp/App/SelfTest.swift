// `TokenBar.app/Contents/MacOS/TokenBar --selftest` (spec §6.6): stub providers, a temp app support and
// home directory, wake delay 0. No keychain, no network, no subprocess, nothing written to the real
// Application Support or UserDefaults. Prints "SELFTEST PASS" and exits 0, or prints failures and exits 1.
import AppKit
import Foundation
import TokenBarCore

/// Fixed usage data. With the default display mode (used) and no `~/.claude.json` in the temp home, the
/// menu bar falls back to the most constrained account and must read "68%": Claude's 5-hour window is 68%
/// used (32% left) and is the worst. A dedicated Claude login (any `claudeConfigDir`) is another account
/// whose 5-hour window is 23% used but whose weekly window, at 90%, is worse.
nonisolated struct AppSelfTestStubProvider: UsageProvider {
    let kind: ProviderKind
    let now: @Sendable () -> Date

    func fetchUsage(for account: AccountConfig, settings: AppSettings, context: RefreshContext) async throws -> ProviderOutcome {
        let now = now()
        let windows: [UsageWindow]
        let plan: String
        var uuid = "selftest-\(kind.rawValue)"
        switch kind {
        case .claude where account.claudeConfigDir != nil:
            plan = "Pro"
            uuid = AppSelfTest.dedicatedAccountUuid
            windows = [
                UsageWindow(kind: .fiveHour, usedPercent: 23, resetsAt: now.addingTimeInterval(4 * 3600)),
                UsageWindow(kind: .weekly, usedPercent: 90, resetsAt: now.addingTimeInterval(30 * 3600)),
            ]
        case .claude:
            plan = "Max"
            windows = [
                UsageWindow(kind: .fiveHour, usedPercent: 68, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
                UsageWindow(kind: .weekly, usedPercent: 19, resetsAt: now.addingTimeInterval(76 * 3600)),
                UsageWindow(kind: .weeklySonnet, usedPercent: 8, resetsAt: now.addingTimeInterval(76 * 3600)),
            ]
        case .codex:
            plan = "Plus"
            windows = [
                UsageWindow(kind: .fiveHour, usedPercent: 0, resetsAt: nil, isStarted: false),
                UsageWindow(kind: .weekly, usedPercent: 16, resetsAt: now.addingTimeInterval(161 * 3600)),
            ]
        }
        let snapshot = UsageSnapshot(
            accountID: account.id, fetchedAt: now, dataAsOf: now,
            source: kind == .claude ? .claudeAPI : .codexAppServer,
            identity: AccountIdentity(accountUuid: uuid, plan: plan),
            windows: windows, limitReached: false)
        return ProviderOutcome(snapshot: snapshot)
    }
}

struct AppSelfTest {
    static let expectedMenuBarText = "68%"
    nonisolated static let dedicatedAccountUuid = "selftest-claude-dedicated"
    static let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TokenBar-selftest-\(UUID().uuidString)", isDirectory: true)

    let model: AppModel
    let statusItem: AppStatusItemController

    static func makeModel() -> AppModel {
        var env = CoreEnvironment.live()
        env.appSupportDirectory = rootDirectory.appendingPathComponent("AppSupport", isDirectory: true)
        // A fresh home too: session scans, config reads and dedicated-login paths stay inside the temp dir.
        env.homeDirectory = rootDirectory.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: env.homeDirectory, withIntermediateDirectories: true)
        let now = env.now
        let runtime = TokenBarRuntime(env: env, providerOverrides: [
            .claude: AppSelfTestStubProvider(kind: .claude, now: now),
            .codex: AppSelfTestStubProvider(kind: .codex, now: now),
        ])
        // nil UserDefaults: the open state is not persisted, and the floating window has no frame autosave.
        return AppModel(runtime: runtime, isSelfTest: true, wakeDelay: .zero, defaults: nil)
    }

    func run() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            Self.finish(failures: ["timed out after 60 s"])
        }
        Task { @MainActor in
            Self.finish(failures: await checks())
        }
    }

    private func checks() async -> [String] {
        var failures: [String] = []
        // Launch refresh with the stubs.
        _ = await Self.waitUntil(seconds: 5) {
            statusItem.button != nil && model.enabledAccounts.allSatisfy { $0.lastSnapshot != nil }
        }
        // The label follows the model through observation; give it a moment to re-render.
        _ = await Self.waitUntil(seconds: 2) { statusItem.button?.title.contains(Self.expectedMenuBarText) == true }
        // The status bar lays the item out asynchronously: wait until its frame holds still, as it has by the
        // time a user can click it.
        var lastFrame = statusItem.buttonScreenFrame
        var stablePolls = 0
        _ = await Self.waitUntil(seconds: 3) {
            let frame = statusItem.buttonScreenFrame
            stablePolls = frame == lastFrame ? stablePolls + 1 : 0
            lastFrame = frame
            return stablePolls >= 5
        }

        // 1. Status item: in the system status bar, with the symbol and the expected text.
        guard let button = statusItem.button else { return ["status item not found"] }
        let inStatusBar = button.window.map { "\(type(of: $0))".contains("StatusBar") } ?? false
        Self.log("status item title=\"\(button.title)\" image=\(button.image != nil) inStatusBar=\(inStatusBar) "
            + "accessibility=\"\(button.accessibilityLabel() ?? "")\"")
        if button.image == nil { failures.append("status item has no symbol") }
        if !inStatusBar { failures.append("status item button is not in the status bar") }
        let summary = model.menuBarSummary.text
        if summary != Self.expectedMenuBarText {
            failures.append("menu bar summary \"\(summary)\" != \"\(Self.expectedMenuBarText)\"")
        }
        if !button.title.contains(Self.expectedMenuBarText) {
            failures.append("status item title \"\(button.title)\" lacks \(Self.expectedMenuBarText)")
        }

        // 2. Launch refresh reached every enabled account.
        if !model.triggerLog.contains(.launch) { failures.append("no .launch refresh") }
        let missing = model.enabledAccounts.filter { $0.lastSnapshot == nil }.map(\.config.displayName)
        if !missing.isEmpty { failures.append("no snapshot for \(missing.joined(separator: ", "))") }

        // 3. A left click shows the floating window, without activating the app, under the status item.
        if Self.floatingWindow() != nil { failures.append("floating window visible before the first click") }
        let wasActive = NSApp.isActive
        button.performClick(nil)
        let shown = await Self.waitUntil(seconds: 2) { Self.floatingWindow() != nil }
        try? await Task.sleep(for: .milliseconds(300))  // give a wrongful activation time to show up
        Self.log("click 1: floating visible=\(shown) model=\(model.isFloatingVisible) "
            + "appActive before=\(wasActive) after=\(NSApp.isActive)")
        if !shown || !model.isFloatingVisible { failures.append("left click did not show the floating window") }
        if NSApp.isActive != wasActive { failures.append("showing the floating window changed NSApp.isActive") }
        if let window = Self.floatingWindow() {
            failures += anchorChecks(window)
        }

        // 4. A second click hides it.
        button.performClick(nil)
        let hidden = await Self.waitUntil(seconds: 2) { Self.floatingWindow() == nil }
        Self.log("click 2: floating hidden=\(hidden) model=\(model.isFloatingVisible)")
        if !hidden || model.isFloatingVisible { failures.append("second click did not hide the floating window") }

        // 5. The right-click menu (inspected, never sent).
        let titles = statusItem.contextMenu.items.map { $0.isSeparatorItem ? "---" : $0.title }
        Self.log("menu items=\(titles)")
        if titles != ["Refresh", "Settings…", "---", "Quit TokenBar"] {
            failures.append("unexpected status menu \(titles)")
        }
        if statusItem.statusItem?.menu != nil { failures.append("status menu attached outside a right click") }

        // 6. Settings opens through the gear's path (AppModel.openSettings), with the floating window open.
        model.isFloatingVisible = true
        _ = await Self.waitUntil(seconds: 2) { Self.floatingWindow() != nil }
        model.openSettings()
        let settingsShown = await Self.waitUntil(seconds: 4) { Self.settingsWindow() != nil }
        try? await Task.sleep(for: .seconds(1))  // past the fallback check in openSettings()
        Self.log("settings visible=\(settingsShown) via=\(model.lastSettingsOpenPath?.rawValue ?? "none") "
            + "appActive=\(NSApp.isActive)")
        if !settingsShown { failures.append("settings window not shown") }
        if model.lastSettingsOpenPath != .swiftUI {
            failures.append("settings did not open through the captured SwiftUI action "
                + "(\(model.lastSettingsOpenPath?.rawValue ?? "none"))")
        }
        Self.settingsWindow()?.close()

        // 6b. The fallback (the app menu's Settings item) works too, should the SwiftUI action be missing.
        _ = await Self.waitUntil(seconds: 2) { Self.settingsWindow() == nil }
        let captured = model.openSettingsAction
        model.openSettingsAction = nil
        model.openSettings()
        let fallbackShown = await Self.waitUntil(seconds: 4) { Self.settingsWindow() != nil }
        model.openSettingsAction = captured
        Self.log("settings fallback visible=\(fallbackShown) via=\(model.lastSettingsOpenPath?.rawValue ?? "none")")
        if !fallbackShown || model.lastSettingsOpenPath != .appMenu { failures.append("settings fallback failed") }
        Self.settingsWindow()?.close()

        // 7. A simulated sleep/wake (with a duplicate wake notification) triggers exactly one .wake refresh.
        let wakesBefore = model.triggerLog.filter { $0 == .wake }.count
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        try? await Task.sleep(for: .milliseconds(300))
        center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        try? await Task.sleep(for: .seconds(1))
        let wakes = model.triggerLog.filter { $0 == .wake }.count - wakesBefore
        Self.log("wake refreshes=\(wakes) triggers=\(model.triggerLog.map(\.rawValue))")
        if wakes != 1 { failures.append("expected exactly one .wake refresh, got \(wakes)") }

        failures += await menuBarSourceChecks(button)
        failures += loginChecks()

        model.isFloatingVisible = false
        return failures
    }

    /// First open without an autosaved frame: on the status item's screen, about `anchorGap` below the menu
    /// bar, centered under the item whenever that fits within the visible frame's margins, else clamped to
    /// the margin on the side nearest the item.
    private func anchorChecks(_ window: NSWindow) -> [String] {
        guard let item = statusItem.buttonScreenFrame, let screen = window.screen else {
            return ["no status item frame or screen for the anchor check"]
        }
        var failures: [String] = []
        let itemScreen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: item.midX, y: item.midY)) }
        if itemScreen != screen { failures.append("floating window is not on the status item's screen") }
        let visible = screen.visibleFrame
        let frame = window.frame
        let gap = min(item.minY, visible.maxY) - frame.maxY
        let margin = AppFloatingPanelController.screenMargin
        let centeredMinX = item.midX - frame.width / 2
        let fits = centeredMinX >= visible.minX + margin - 1 && centeredMinX + frame.width <= visible.maxX - margin + 1
        let centered = abs(frame.midX - item.midX) <= 1
        let nearLeft = item.midX < visible.midX
        let clamped = nearLeft
            ? abs(frame.minX - (visible.minX + margin)) <= 1
            : abs(frame.maxX - (visible.maxX - margin)) <= 1
        Self.log("anchor item=\(NSStringFromRect(item)) window=\(NSStringFromRect(frame)) gap=\(gap) "
            + "fits=\(fits) centered=\(centered) clamped=\(clamped) sameScreen=\(itemScreen == screen)")
        if abs(gap - AppFloatingPanelController.anchorGap) > 1 { failures.append("floating window is \(gap) pt below the menu bar") }
        if fits && !centered { failures.append("floating window is not centered under the status item") }
        if !fits && !clamped {
            failures.append("floating window is not clamped to the \(nearLeft ? "left" : "right") margin")
        }
        if frame.minX < visible.minX || frame.maxX > visible.maxX { failures.append("floating window is off screen") }
        return failures
    }

    /// 7b. The menu bar follows the account `~/.claude` is logged in to (spec §5.1 rule 5): without
    ///     `~/.claude.json` it shows the most constrained account; once the file names the dedicated stub
    ///     account, it shows that account's 5h window although its weekly window is worse. The switch also
    ///     refreshes the default login, whose snapshot belongs to another account, exactly once.
    private func menuBarSourceChecks(_ button: NSStatusBarButton) async -> [String] {
        var failures: [String] = []
        let home = model.runtime.env.homeDirectory
        let dedicated = AccountConfig(provider: .claude, displayName: "Selftest Active",
                                      claudeConfigDir: home.appendingPathComponent("active").path,
                                      isDedicatedLogin: true)
        model.updateSettings { $0.insertAccountGroupedByProvider(dedicated) }
        _ = await Self.waitUntil(seconds: 5) { model.menuBarSummary.text == "90%" }
        let fallback = model.menuBarSummary
        Self.log("menu bar without ~/.claude.json text=\"\(fallback.text)\" "
            + "account=\(fallback.accountID == dedicated.id ? "dedicated" : "other")")
        if fallback.text != "90%" || fallback.accountID != dedicated.id {
            failures.append("menu bar did not fall back to the most constrained account (\(fallback.text))")
        }

        let configChanges = { model.triggerLog.filter { $0 == .configChange }.count }
        let configChangesBefore = configChanges()
        let config = home.appendingPathComponent(".claude.json")
        let json = #"{"oauthAccount":{"accountUuid":"\#(Self.dedicatedAccountUuid)"}}"#
        do { try Data(json.utf8).write(to: config) } catch { failures.append("could not write ~/.claude.json") }
        model.refreshNow()  // the active account is re-read right after the refresh batch
        _ = await Self.waitUntil(seconds: 5) {
            model.menuBarSummary.text == "23%" && button.title.contains("23%")
        }
        let active = model.menuBarSummary
        Self.log("menu bar with ~/.claude.json text=\"\(active.text)\" title=\"\(button.title)\" "
            + "tooltip=\"\(button.toolTip ?? "")\" active=\(model.activeClaudeAccountUuid ?? "nil")")
        if model.activeClaudeAccountUuid != Self.dedicatedAccountUuid { failures.append("active Claude uuid not read") }
        if active.text != "23%" || active.accountID != dedicated.id || active.windowKind != .fiveHour {
            failures.append("menu bar does not show the active account's 5h window (\(active.text))")
        }
        if active.status != .low { failures.append("menu bar icon status is not the active account's worst") }
        if !button.title.contains("23%") { failures.append("status item title \"\(button.title)\" lacks 23%") }
        if button.toolTip != "Selftest Active · 5h 23% used" {
            failures.append("unexpected status item tooltip \"\(button.toolTip ?? "")\"")
        }
        if button.accessibilityLabel()?.contains("Selftest Active") != true {
            failures.append("status item accessibility label lacks the account name")
        }
        _ = await Self.waitUntil(seconds: 5) { configChanges() > configChangesBefore }
        try? await Task.sleep(for: .seconds(1))  // a second refresh would be a loop
        let switchRefreshes = configChanges() - configChangesBefore
        Self.log("account switch refreshes=\(switchRefreshes)")
        if switchRefreshes != 1 { failures.append("expected one refresh after the account switch, got \(switchRefreshes)") }

        try? FileManager.default.removeItem(at: config)
        model.removeAccount(dedicated.id)
        return failures
    }

    /// 8. Login commands never carry a leading `~`; a dedicated login is saved at once with the exact dir
    ///    string its command uses; the disable-default offer is a non-modal banner state.
    private func loginChecks() -> [String] {
        var failures: [String] = []
        let home = model.runtime.env.homeDirectory.path
        let claude = model.loginCommand(for: .claude(configDir: "~/cw"))
        let codex = model.loginCommand(for: .codex(home: "~/cx"))
        if claude.contains("'~") || !claude.contains("CLAUDE_CONFIG_DIR='\(home)/cw'") {
            failures.append("claude login command keeps ~: \(claude)")
        }
        if codex.contains("'~") || !codex.contains("CODEX_HOME='\(home)/cx'") {
            failures.append("codex login command keeps ~: \(codex)")
        }
        do {
            let dir = try model.addDedicatedLogin(name: "Selftest")
            let saved = (try? model.runtime.configStore.load())?.accounts.first { $0.claudeConfigDir == dir }
            Self.log("dedicated dir absolute=\(dir.hasPrefix("/")) saved=\(saved != nil)")
            if saved?.isDedicatedLogin != true || saved?.isEnabled != true || dir.hasSuffix("/") {
                failures.append("dedicated account not saved at creation")
            }
            if !model.loginCommand(for: .claude(configDir: dir)).contains("CLAUDE_CONFIG_DIR='\(dir)'") {
                failures.append("dedicated login command does not use the stored dir")
            }
            model.offerToDisableDefaultClaude()
            let hasDefault = model.settings.accounts.contains {
                $0.provider == .claude && $0.claudeConfigDir == nil && $0.isEnabled
            }
            if hasDefault && model.disableDefaultOffer == nil { failures.append("disable-default banner not set") }
            model.answerDisableDefaultOffer(disable: false)
            if model.disableDefaultOffer != nil { failures.append("disable-default banner not cleared") }
            if let saved { model.removeAccount(saved.id) }
        } catch {
            failures.append("dedicated login failed: \(error.message)")
        }
        return failures
    }

    private static func floatingWindow() -> NSWindow? {
        NSApp.windows.first { $0 is AppFloatingPanel && $0.isVisible }
    }

    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == AppModel.settingsWindowIdentifier && $0.isVisible }
    }

    /// Polls `condition` every 100 ms until it holds or `seconds` pass.
    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func finish(failures: [String]) {
        try? FileManager.default.removeItem(at: rootDirectory)
        if failures.isEmpty {
            print("SELFTEST PASS")
            fflush(stdout)
            exit(0)
        }
        print("SELFTEST FAIL: \(failures.joined(separator: "; "))")
        fflush(stdout)
        exit(1)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("selftest: \(message)\n".utf8))
    }
}
