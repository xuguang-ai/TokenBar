// `TokenBar.app/Contents/MacOS/TokenBar --selftest` (spec §6.6): stub providers, a temp app support and
// home directory, wake delay 0. No keychain, no network, no subprocess, nothing written to the real
// Application Support or UserDefaults. Prints "SELFTEST PASS" and exits 0, or prints failures and exits 1.
import AppKit
import Foundation
import TokenBarCore

/// Fixed usage data. The menu bar must read "32%": Claude's 5-hour window has 32% left and is the worst.
nonisolated struct AppSelfTestStubProvider: UsageProvider {
    let kind: ProviderKind
    let now: @Sendable () -> Date

    func fetchUsage(for account: AccountConfig, settings: AppSettings, context: RefreshContext) async throws -> ProviderOutcome {
        let now = now()
        let windows: [UsageWindow]
        let plan: String
        switch kind {
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
            identity: AccountIdentity(accountUuid: "selftest-\(kind.rawValue)", plan: plan),
            windows: windows, limitReached: false)
        return ProviderOutcome(snapshot: snapshot)
    }
}

struct AppSelfTest {
    static let expectedMenuBarText = "32%"
    static let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TokenBar-selftest-\(UUID().uuidString)", isDirectory: true)

    let model: AppModel

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
            Self.statusBarButton() != nil && model.enabledAccounts.allSatisfy { $0.lastSnapshot != nil }
        }
        try? await Task.sleep(for: .milliseconds(300))  // let the status item re-render

        // 1. Status item.
        guard let button = Self.statusBarButton() else { return ["status item not found"] }
        Self.log("status item title=\"\(button.title)\" image=\(button.image != nil)")
        if button.title.isEmpty && button.image == nil { failures.append("status item is empty") }

        // 2. Launch refresh reached every enabled account.
        if !model.triggerLog.contains(.launch) { failures.append("no .launch refresh") }
        let missing = model.enabledAccounts.filter { $0.lastSnapshot == nil }.map(\.config.displayName)
        if !missing.isEmpty { failures.append("no snapshot for \(missing.joined(separator: ", "))") }

        // 3. Floating panel shows without activating the app.
        let wasActive = NSApp.isActive
        model.isPinned = true
        let floatingShown = await Self.waitUntil(seconds: 2) {
            NSApp.windows.contains { $0 is AppFloatingPanel && $0.isVisible }
        }
        try? await Task.sleep(for: .milliseconds(300))  // give a wrongful activation time to show up
        Self.log("floating visible=\(floatingShown) appActive before=\(wasActive) after=\(NSApp.isActive)")
        if !floatingShown { failures.append("floating panel not shown") }
        if NSApp.isActive != wasActive { failures.append("floating panel changed NSApp.isActive") }

        // 4. The panel opens and is observed as visible. The first launch of a fresh bundle can be slow,
        //    so poll and click once more if needed.
        var panelShown = false
        for _ in 0..<2 where !panelShown {
            button.performClick(nil)
            panelShown = await Self.waitUntil(seconds: 3) { Self.panelWindowVisible() }
        }
        _ = await Self.waitUntil(seconds: 2) { model.isPanelVisible }
        Self.log("panel shown=\(Self.panelWindowVisible()) observedVisible=\(model.isPanelVisible)")
        if !Self.panelWindowVisible() { failures.append("panel not shown") }
        if !model.isPanelVisible { failures.append("panel visibility not observed") }

        // 5. Settings window.
        model.openSettings()
        let settingsShown = await Self.waitUntil(seconds: 4) {
            NSApp.windows.contains { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" && $0.isVisible }
        }
        Self.log("settings visible=\(settingsShown)")
        if !settingsShown { failures.append("settings window not shown") }

        // 6. Menu bar text matches the stubbed data.
        let summary = model.menuBarSummary.text
        Self.log("menu bar summary=\"\(summary)\" title=\"\(button.title)\"")
        if summary != Self.expectedMenuBarText { failures.append("menu bar summary \"\(summary)\" != \"\(Self.expectedMenuBarText)\"") }
        if !button.title.contains(Self.expectedMenuBarText) { failures.append("status item title \"\(button.title)\" lacks \(Self.expectedMenuBarText)") }

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

        failures += loginChecks()

        model.isPinned = false
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

    private static func panelWindowVisible() -> Bool {
        NSApp.windows.contains { "\(type(of: $0))".hasPrefix("MenuBarExtraWindow") && $0.isVisible }
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
