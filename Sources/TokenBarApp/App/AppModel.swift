// AppModel: the App's single source of truth (spec §6.1). MainActor by default (.defaultIsolation).
import AppKit
import Foundation
import Observation
import SwiftUI
import TokenBarCore

/// Where the App's configuration came from, as shown in Settings and the panel.
enum AppConfigState: Equatable {
    case ok
    /// `config.json` was written by a newer TokenBar: read-only error state, never written (spec §5.8).
    case tooNew(Int)
}

@Observable
final class AppModel {
    // MARK: Observable state

    private(set) var settings: AppSettings
    private(set) var accounts: [AccountState] = []
    private(set) var sessions: [SessionGroup] = []
    private(set) var lastRefreshAt: Date?
    private(set) var configState: AppConfigState = .ok
    private(set) var configWarning: String?
    private(set) var lastSaveError: String?
    /// The clock the views render against; ticks every 30 s and at the next window reset (spec §5.1 rule 2).
    private(set) var now: Date
    /// Realpaths of located binaries for login commands; "claude"/"codex" is used until (or unless) found.
    private(set) var loginBinaryPaths: [BinaryKind: String] = [:]
    /// Dedicated login dirs that are being polled for a completed `auth login` (spec §6.5 step 5).
    private(set) var pendingDedicatedLogins: [String: String] = [:]  // configDir -> display name

    var isPinned: Bool {
        didSet {
            guard isPinned != oldValue else { return }
            defaults?.set(isPinned, forKey: Self.pinnedDefaultsKey)
            floatingController?.setVisible(isPinned)
            updateSessionCadence()
        }
    }

    var isPanelVisible = false {
        didSet {
            guard isPanelVisible != oldValue else { return }
            if isPanelVisible {
                reloadConfigIfChanged()
                tick()
            }
            updateSessionCadence()
        }
    }

    // MARK: Dependencies and tasks

    @ObservationIgnored let runtime: TokenBarRuntime
    @ObservationIgnored let isSelfTest: Bool
    @ObservationIgnored private let wakeDelay: Duration
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private(set) var scheduler: RefreshScheduler?
    @ObservationIgnored private var lastConfigModificationDate: Date?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var sessionCadence: Duration?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var loginPollTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var systemEvents: AppSystemEventsBridge?
    @ObservationIgnored var floatingController: AppFloatingPanelController?
    @ObservationIgnored var openSettingsAction: OpenSettingsAction?
    /// Every trigger the scheduler handed us, in order (the selftest counts `.wake`).
    @ObservationIgnored private(set) var triggerLog: [RefreshTrigger] = []
    @ObservationIgnored private var started = false

    static let pinnedDefaultsKey = "AppFloatingPinned"
    static let wakeGrace: TimeInterval = 30
    static let loginPollInterval: Duration = .seconds(5)
    static let loginPollLimit = 180  // 15 minutes of 5 s polls

    init(runtime: TokenBarRuntime, isSelfTest: Bool, wakeDelay: Duration, defaults: UserDefaults?) {
        self.runtime = runtime
        self.isSelfTest = isSelfTest
        self.wakeDelay = wakeDelay
        self.defaults = defaults
        self.now = runtime.env.now()
        self.isPinned = defaults?.bool(forKey: Self.pinnedDefaultsKey) ?? false
        self.settings = ConfigStore.defaultSettings()
        loadInitialState()
    }

    // MARK: Startup

    private func loadInitialState() {
        do {
            let outcome = try runtime.configStore.loadOrDefault(forApp: true)
            settings = outcome.settings
            configWarning = outcome.warning.map(Self.describe)
            lastConfigModificationDate = runtime.configStore.modificationDate()
        } catch .tooNew(let version) {
            configState = .tooNew(version)
            settings = AppSettings(accounts: [])
        } catch {
            // loadOrDefault(forApp: true) only throws .tooNew; keep defaults in memory just in case.
            configWarning = "Settings could not be loaded; using defaults."
        }
        let stored = runtime.snapshotStore.load()
        accounts = settings.accounts.map { config in
            let saved = stored[config.id]
            return AccountState(config: config, lastSnapshot: saved?.lastSnapshot,
                                lastError: saved?.lastError, lastAttemptAt: saved?.lastAttemptAt)
        }
    }

    /// Called once the run loop is up (NSApp exists).
    func start() {
        guard !started else { return }
        started = true
        floatingController = AppFloatingPanelController(model: self, autosave: !isSelfTest)
        if isPinned { floatingController?.setVisible(true) }
        startClock()
        updateSessionCadence()
        guard configState == .ok else { return }
        let scheduler = RefreshScheduler(env: runtime.env, settings: settings, wakeDelay: wakeDelay) {
            [weak self] trigger, kinds in
            await self?.handleRefresh(trigger, kinds: kinds)
        }
        self.scheduler = scheduler
        systemEvents = AppSystemEventsBridge(scheduler: scheduler, onActivate: { [weak self] in
            self?.reloadConfigIfChanged()
        })
        Task { await scheduler.start() }
    }

    // MARK: Refresh

    private func handleRefresh(_ trigger: RefreshTrigger, kinds: Set<ProviderKind>) async {
        triggerLog.append(trigger)
        reloadConfigIfChanged()
        guard configState == .ok else { return }
        let current = settings
        let targets = current.accounts.filter { $0.isEnabled && kinds.contains($0.provider) }
        guard !targets.isEmpty else { return }
        var identities: [UUID: AccountIdentity] = [:]
        for state in accounts {
            if let identity = state.lastSnapshot?.identity { identities[state.config.id] = identity }
        }
        let grace: Date? = trigger == .wake ? runtime.env.now().addingTimeInterval(Self.wakeGrace) : nil
        let batch = await runtime.aggregator.refresh(
            accounts: targets, settings: current, trigger: trigger,
            allowClaudeCodeRefresh: current.allowClaudeCodeRefresh,
            previousIdentities: identities, wakeGraceUntil: grace)
        for index in accounts.indices where batch.started.contains(accounts[index].config.id) {
            accounts[index].isRefreshing = true
        }
        for await event in batch.events {
            guard let index = accounts.firstIndex(where: { $0.config.id == event.accountID }) else { continue }
            accounts[index].apply(event, wakeGraceUntil: grace)
            lastRefreshAt = event.finishedAt
            persistSnapshots()
            tick()
        }
        // A stale result is dropped by the aggregator; never leave a spinner behind.
        for index in accounts.indices where batch.started.contains(accounts[index].config.id) {
            accounts[index].isRefreshing = false
        }
    }

    func refreshNow() {
        guard let scheduler else { return }
        Task { await scheduler.requestRefresh(.manual) }
    }

    private func persistSnapshots() {
        var states: [UUID: StoredAccountState] = [:]
        for state in accounts { states[state.config.id] = StoredAccountState(state) }
        do {
            try runtime.snapshotStore.save(states)
        } catch {
            lastSaveError = "Could not save cached usage."
        }
    }

    // MARK: Settings

    var isReadOnly: Bool { configState != .ok }

    /// Saves, applies, tells the scheduler and requests a `.configChange` refresh (spec §6.5).
    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        guard !isReadOnly else { return }
        var updated = settings
        mutate(&updated)
        guard updated != settings else { return }
        do {
            try runtime.configStore.save(updated)
            lastSaveError = nil
        } catch {
            lastSaveError = "Could not save settings."
            return
        }
        lastConfigModificationDate = runtime.configStore.modificationDate()
        apply(settings: updated)
        if let scheduler {
            Task {
                await scheduler.updateSettings(updated)
                await scheduler.requestRefresh(.configChange)
            }
        }
    }

    func updateAccount(_ id: UUID, _ mutate: (inout AccountConfig) -> Void) {
        updateSettings { settings in
            guard let index = settings.accounts.firstIndex(where: { $0.id == id }) else { return }
            mutate(&settings.accounts[index])
        }
    }

    private func apply(settings new: AppSettings) {
        let previous = Dictionary(uniqueKeysWithValues: accounts.map { ($0.config.id, $0) })
        settings = new
        accounts = new.accounts.map { config in
            var state = previous[config.id] ?? AccountState(config: config)
            state.config = config
            return state
        }
        if accounts.count != previous.count || Set(previous.keys) != Set(accounts.map(\.config.id)) {
            persistSnapshots()
        }
    }

    /// Reloads `config.json` when its modification date changed (checked on every refresh and when the
    /// panel opens).
    func reloadConfigIfChanged() {
        let modified = runtime.configStore.modificationDate()
        guard modified != lastConfigModificationDate else { return }
        lastConfigModificationDate = modified
        guard modified != nil else { return }  // deleted: keep what we have; the next save recreates it
        do {
            let loaded = try runtime.configStore.load()
            if configState != .ok {
                // A downgrade or fix made the file usable again; start fresh from it next launch.
                configWarning = "config.json changed; restart TokenBar to use it."
                return
            }
            guard loaded != settings else { return }
            apply(settings: loaded)
            if let scheduler { Task { await scheduler.updateSettings(loaded) } }
        } catch .tooNew(let version) {
            configState = .tooNew(version)
            Task { await scheduler?.stop() }
        } catch {
            configWarning = "config.json could not be read; keeping the current settings."
        }
    }

    static func describe(_ warning: ConfigLoadWarning) -> String {
        switch warning {
        case .corruptFileRenamed(let backup):
            return "config.json was unreadable and was moved to \(backup). Defaults are in use."
        case .corruptFileNotRenamed:
            return "config.json is unreadable and could not be moved aside. Defaults are in use and nothing was saved."
        case .defaultsNotSaved:
            return "Default settings could not be saved to config.json."
        }
    }

    // MARK: Accounts

    func addAccount(_ provider: ProviderKind) -> UUID {
        let config = AccountConfig(provider: provider, displayName: provider.defaultDisplayName)
        updateSettings { $0.accounts.append(config) }
        return config.id
    }

    func removeAccount(_ id: UUID) {
        updateSettings { $0.accounts.removeAll { $0.id == id } }
    }

    func moveAccounts(from source: IndexSet, to destination: Int) {
        updateSettings { $0.accounts.move(fromOffsets: source, toOffset: destination) }
    }

    func state(for id: UUID) -> AccountState? {
        accounts.first { $0.config.id == id }
    }

    var enabledAccounts: [AccountState] { accounts.filter(\.config.isEnabled) }

    /// Card title. The default Claude login becomes "Claude (current /login)" once dedicated logins exist,
    /// plus the dedicated account it currently matches (spec §3.1).
    func title(for state: AccountState) -> String {
        let config = state.config
        guard config.provider == .claude, config.claudeConfigDir == nil,
              settings.accounts.contains(where: { $0.provider == .claude && $0.isDedicatedLogin })
        else { return config.displayName }
        var title = "\(config.displayName) (current /login)"
        if let uuid = state.lastSnapshot?.identity?.accountUuid,
           let match = accounts.first(where: {
               $0.config.id != config.id && $0.config.isDedicatedLogin
                   && $0.lastSnapshot?.identity?.accountUuid == uuid
           }) {
            title += " · \(match.config.displayName)"
        }
        return title
    }

    func sessions(for accountID: UUID) -> SessionGroup? {
        sessions.first { $0.accountID == accountID }
    }

    /// Sessions that match no enabled account card.
    var otherSessions: [SessionInfo] {
        let enabledIDs = Set(enabledAccounts.map(\.config.id))
        return sessions.filter { group in
            guard let id = group.accountID else { return true }
            return !enabledIDs.contains(id)
        }.flatMap(\.sessions)
    }

    func busySessionCount(for accountID: UUID) -> Int {
        sessions(for: accountID)?.busy.count ?? 0
    }

    // MARK: Menu bar

    var menuBarSummary: MenuBarSummary {
        DisplayDerivation.menuBar(states: accounts, settings: settings, now: now)
    }

    // MARK: Login commands

    /// The login command for a `notLoggedIn` hint, using the located binary (or "claude"/"codex").
    func loginCommand(for hint: LoginHint) -> String {
        switch hint {
        case .claude(let configDir):
            let path = loginBinaryPaths[.claude] ?? "claude"
            if let configDir { return ShellQuoting.claudeLoginCommand(configDir: configDir, claudePath: path) }
            return "env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_CUSTOM_OAUTH_URL "
                + "\(ShellQuoting.quote(path)) auth login"
        case .codex(let home):
            return ShellQuoting.codexLoginCommand(home: home, codexPath: loginBinaryPaths[.codex] ?? "codex")
        }
    }

    /// Locates the binary once so login commands carry its realpath. Skipped in the selftest.
    func resolveLoginBinary(_ kind: BinaryKind) async -> String {
        if let known = loginBinaryPaths[kind] { return known }
        guard !isSelfTest else { return kind.rawValue }
        let located = await runtime.binaryLocator.locate(kind, settings: settings)
        if let path = located?.url.path { loginBinaryPaths[kind] = path }
        return located?.url.path ?? kind.rawValue
    }

    // MARK: Dedicated Claude logins (spec §6.5)

    enum DedicatedLoginError: Error, Equatable {
        case invalidName, alreadyConfigured, cannotCreateDirectory
        var message: String {
            switch self {
            case .invalidName: return "The name needs at least one letter or digit."
            case .alreadyConfigured: return "An account already uses this login directory."
            case .cannotCreateDirectory: return "Could not create the login directory."
            }
        }
    }

    /// Creates `~/.tokenbar/claude/<slug>` (0700) and returns its absolute path (no trailing slash).
    func prepareDedicatedLogin(name: String) throws(DedicatedLoginError) -> String {
        guard let slug = ShellQuoting.slug(from: name) else { throw .invalidName }
        let root = runtime.env.dedicatedClaudeLoginsRoot
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        let path = dir.standardizedFileURL.path
        if settings.accounts.contains(where: { $0.claudeConfigDir == path }) { throw .alreadyConfigured }
        let fs = runtime.env.fileSystem
        do {
            try fs.createDirectory(dir, permissions: 0o700)
            try fs.setPermissions(root.deletingLastPathComponent(), 0o700)  // ~/.tokenbar
            try fs.setPermissions(root, 0o700)  // ~/.tokenbar/claude
            try fs.setPermissions(dir, 0o700)
        } catch {
            throw .cannotCreateDirectory
        }
        return path
    }

    /// Polls the dir every 5 s until Claude Code wrote an `oauthAccount`, then adds the account.
    func watchDedicatedLogin(configDir: String, name: String) {
        guard loginPollTasks[configDir] == nil else { return }
        pendingDedicatedLogins[configDir] = name
        loginPollTasks[configDir] = Task { [weak self] in
            for _ in 0..<Self.loginPollLimit {
                do { try await Task.sleep(for: Self.loginPollInterval) } catch { break }
                guard let self else { return }
                if self.runtime.configReader.read(configDir: configDir)?.oauthAccount != nil {
                    self.completeDedicatedLogin(configDir: configDir, name: name)
                    return
                }
            }
            self?.pendingDedicatedLogins[configDir] = nil
            self?.loginPollTasks[configDir] = nil
        }
    }

    func cancelDedicatedLogin(configDir: String) {
        loginPollTasks[configDir]?.cancel()
        loginPollTasks[configDir] = nil
        pendingDedicatedLogins[configDir] = nil
    }

    private func completeDedicatedLogin(configDir: String, name: String) {
        loginPollTasks[configDir] = nil
        pendingDedicatedLogins[configDir] = nil
        guard !settings.accounts.contains(where: { $0.claudeConfigDir == configDir }) else { return }
        let isFirst = !settings.accounts.contains { $0.provider == .claude && $0.isDedicatedLogin }
        let account = AccountConfig(provider: .claude, displayName: name, claudeConfigDir: configDir,
                                    isDedicatedLogin: true)
        updateSettings { $0.accounts.append(account) }  // also requests a .configChange refresh
        if isFirst { offerToDisableDefaultClaude() }
    }

    /// After the first dedicated login, suggest disabling the default (nil-dir) Claude account (spec §3.1).
    private func offerToDisableDefaultClaude() {
        guard let defaultAccount = settings.accounts.first(where: {
            $0.provider == .claude && $0.claudeConfigDir == nil && $0.isEnabled
        }) else { return }
        let alert = NSAlert()
        alert.messageText = "Disable the default Claude account?"
        alert.informativeText = "Your first dedicated login is ready. The default account follows whoever is "
            + "logged in with /login in ~/.claude. If you keep it, it is shown as \"Claude (current /login)\"."
        alert.addButton(withTitle: "Disable")
        alert.addButton(withTitle: "Keep")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            updateAccount(defaultAccount.id) { $0.isEnabled = false }
        }
    }

    // MARK: Settings window

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettingsAction?()
    }

    // MARK: Sessions (spec §5.5): 3 s while the panel or the floating window is visible, else 30 s

    var sessionsVisible: Bool { isPanelVisible || isPinned }

    private func updateSessionCadence() {
        let cadence: Duration = sessionsVisible ? .seconds(3) : .seconds(30)
        guard cadence != sessionCadence || sessionTask == nil else { return }
        sessionCadence = cadence
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let groups = await self.runtime.scanSessions(settings: self.settings)
                guard !Task.isCancelled else { return }
                if groups != self.sessions { self.sessions = groups }
                do { try await Task.sleep(for: cadence) } catch { return }
            }
        }
    }

    // MARK: Clock

    func tick() {
        now = runtime.env.now()
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let current = self.runtime.env.now()
                var wake = current.addingTimeInterval(30)
                let snapshots = self.accounts.compactMap(\.lastSnapshot)
                if let reset = DisplayDerivation.nextResetDate(snapshots, now: current), reset < wake {
                    wake = reset.addingTimeInterval(0.5)
                }
                let delay = max(0.5, wake.timeIntervalSince(current))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self.tick()
            }
        }
    }
}
