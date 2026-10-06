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
    /// Realpaths from the most recent locate, for login commands; "claude"/"codex" is used until (or unless)
    /// found. Re-located every time a login command is shown or copied (never cached for the App's lifetime).
    private(set) var loginBinaryPaths: [BinaryKind: String] = [:]
    /// Dedicated login dirs that are being polled for a completed `auth login` (spec §6.5 step 5).
    private(set) var pendingDedicatedLogins: [String: String] = [:]  // configDir -> display name
    /// Dedicated login dirs whose `auth login` was detected by polling in this session.
    private(set) var completedDedicatedLogins: Set<String> = []
    /// The default (nil-dir) Claude account TokenBar offers to disable after the first dedicated login.
    /// Shown as a non-modal banner in the panel and the Accounts pane (spec §3.1).
    private(set) var disableDefaultOfferID: UUID?

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
    /// Per account: how many refresh batches still owe an event for it (`started` ∪ `queued`). Accounts
    /// `merged` into another batch's run or rerun are covered by that batch's count.
    @ObservationIgnored private var inFlightRefreshCounts: [UUID: Int] = [:]

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

    /// - Parameter only: restricts the refresh to these accounts (a config reload or a detected login).
    private func handleRefresh(_ trigger: RefreshTrigger, kinds: Set<ProviderKind>, only: Set<UUID>? = nil) async {
        triggerLog.append(trigger)
        reloadConfigIfChanged(refreshChanged: false)
        guard configState == .ok else { return }
        let current = settings
        let targets = current.accounts.filter {
            $0.isEnabled && kinds.contains($0.provider) && (only?.contains($0.id) ?? true)
        }
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
        // This batch owes one event per started or queued account; merged ones ride on another batch's count.
        var owed = batch.started.union(batch.queued)
        for id in owed { inFlightRefreshCounts[id, default: 0] += 1 }
        syncRefreshingFlags()
        for await event in batch.events {
            if owed.remove(event.accountID) != nil { finishRefresh(event.accountID) }
            guard let index = accounts.firstIndex(where: { $0.config.id == event.accountID }) else { continue }
            accounts[index].apply(event, wakeGraceUntil: grace)
            lastRefreshAt = event.finishedAt
            syncRefreshingFlags()
            persistSnapshots()
            tick()
        }
        // A stale result is dropped by the aggregator; release its count so no spinner is left behind.
        for id in owed { finishRefresh(id) }
        syncRefreshingFlags()
    }

    private func finishRefresh(_ id: UUID) {
        let remaining = (inFlightRefreshCounts[id] ?? 0) - 1
        inFlightRefreshCounts[id] = remaining > 0 ? remaining : nil
    }

    /// `isRefreshing` holds while any batch still owes an event for the account.
    private func syncRefreshingFlags() {
        for index in accounts.indices {
            let refreshing = (inFlightRefreshCounts[accounts[index].config.id] ?? 0) > 0
            if accounts[index].isRefreshing != refreshing { accounts[index].isRefreshing = refreshing }
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
        updated.groupAccountsByProvider()  // Claude accounts stay together, whatever the edit did
        guard updated != settings else { return }
        do {
            try runtime.configStore.save(updated)
            lastSaveError = nil
        } catch {
            lastSaveError = "Could not save settings."
            return
        }
        lastConfigModificationDate = runtime.configStore.modificationDate()
        // A changed override makes the last located path meaningless; views re-locate on their next show.
        if updated.claudeBinaryOverride != settings.claudeBinaryOverride { loginBinaryPaths[.claude] = nil }
        if updated.codexBinaryOverride != settings.codexBinaryOverride { loginBinaryPaths[.codex] = nil }
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
            state.isRefreshing = (inFlightRefreshCounts[config.id] ?? 0) > 0
            return state
        }
        if accounts.count != previous.count || Set(previous.keys) != Set(accounts.map(\.config.id)) {
            persistSnapshots()
        }
    }

    /// Reloads `config.json` when its modification date changed (checked on every refresh and when the
    /// panel opens). Accounts that are new or whose refresh fingerprint changed get a `.configChange`
    /// refresh, unless the caller refreshes right after anyway (`refreshChanged: false`).
    func reloadConfigIfChanged(refreshChanged: Bool = true) {
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
            let changed = Self.changedAccountIDs(from: settings, to: loaded)
            apply(settings: loaded)
            if let scheduler {
                Task {
                    await scheduler.updateSettings(loaded)
                    if refreshChanged, !changed.isEmpty {
                        await self.handleRefresh(.configChange, kinds: Set(ProviderKind.allCases), only: changed)
                    }
                }
            }
        } catch .tooNew(let version) {
            configState = .tooNew(version)
            Task { await scheduler?.stop() }
        } catch {
            configWarning = "config.json could not be read; keeping the current settings."
        }
    }

    /// Accounts in `new` that are not in `old` or whose refresh fingerprint differs.
    static func changedAccountIDs(from old: AppSettings, to new: AppSettings) -> Set<UUID> {
        let before = Dictionary(old.accounts.map { ($0.id, UsageAggregator.fingerprint(for: $0, settings: old)) },
                                uniquingKeysWith: { first, _ in first })
        return Set(new.accounts.filter { before[$0.id] != UsageAggregator.fingerprint(for: $0, settings: new) }
            .map(\.id))
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

    /// - Parameter directory: an already-expanded path, stored as `claudeConfigDir` (Claude) or `codexHome`
    ///   (Codex) — "Add account with config dir…". `nil` adds the default login / `~/.codex`.
    func addAccount(_ provider: ProviderKind, directory: String? = nil, displayName: String? = nil) -> UUID {
        let config = AccountConfig(provider: provider, displayName: displayName ?? provider.defaultDisplayName,
                                   claudeConfigDir: provider == .claude ? directory : nil,
                                   codexHome: provider == .codex ? directory : nil)
        updateSettings { $0.insertAccountGroupedByProvider(config) }
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

    /// Enabled accounts in display order. One provider's accounts are always adjacent: Core keeps
    /// `settings.accounts` grouped, and this guards the panel and the floating window against any
    /// ungrouped state (stable; providers keep the order in which they first appear).
    var enabledAccounts: [AccountState] {
        let enabled = accounts.filter(\.config.isEnabled)
        var providers: [ProviderKind] = []
        for state in enabled where !providers.contains(state.config.provider) {
            providers.append(state.config.provider)
        }
        return providers.flatMap { provider in enabled.filter { $0.config.provider == provider } }
    }

    /// Card title: the account's display name. The card adds the provider name and the plan.
    func title(for state: AccountState) -> String {
        state.config.displayName
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

    /// The login command for a `notLoggedIn` hint, using the last located binary (or "claude"/"codex").
    /// A leading `~` in the dir is expanded (spec §3.1): the shell never expands it inside single quotes, and
    /// the expanded string is what TokenBar sets as CLAUDE_CONFIG_DIR / CODEX_HOME and hashes for the keychain.
    func loginCommand(for hint: LoginHint) -> String {
        let home = runtime.env.homeDirectory
        switch hint {
        case .claude(let configDir):
            let path = loginBinaryPaths[.claude] ?? "claude"
            if let configDir {
                return ShellQuoting.claudeLoginCommand(configDir: ClaudePaths.expandTilde(configDir, home: home),
                                                       claudePath: path)
            }
            return "env -u CLAUDE_CONFIG_DIR -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_CUSTOM_OAUTH_URL "
                + "\(ShellQuoting.quote(path)) auth login"
        case .codex(let codexHome):
            return ShellQuoting.codexLoginCommand(home: codexHome.map { ClaudePaths.expandTilde($0, home: home) },
                                                  codexPath: loginBinaryPaths[.codex] ?? "codex")
        }
    }

    /// Re-locates the binary and returns the login command with its current realpath. Use it whenever a
    /// command is built, copied or opened. BinaryLocator caches the signature check, so this is cheap.
    func resolvedLoginCommand(for hint: LoginHint) async -> String {
        _ = await resolveLoginBinary(hint.appBinaryKind)
        return loginCommand(for: hint)
    }

    /// Locates the binary now (never cached here: an update or a changed override must show up). Skipped in
    /// the selftest.
    func resolveLoginBinary(_ kind: BinaryKind) async -> String {
        guard !isSelfTest else { return kind.rawValue }
        let located = await runtime.binaryLocator.locate(kind, settings: settings)
        let path = located?.url.path
        if loginBinaryPaths[kind] != path { loginBinaryPaths[kind] = path }
        return path ?? kind.rawValue
    }

    // MARK: Dedicated Claude logins (spec §6.5)

    enum DedicatedLoginError: Error, Equatable {
        case invalidName, alreadyConfigured, cannotCreateDirectory, cannotSaveAccount
        var message: String {
            switch self {
            case .invalidName: return "The name needs at least one letter or digit."
            case .alreadyConfigured: return "An account already uses this login directory."
            case .cannotCreateDirectory: return "Could not create the login directory."
            case .cannotSaveAccount: return "Could not save the account to settings."
            }
        }
    }

    /// Creates `~/.tokenbar/claude/<slug>` (0700), saves an enabled dedicated Claude account for it right away
    /// (spec §6.5 step 2) and returns the dir: an absolute path with no trailing slash, the exact string that
    /// is stored as `claudeConfigDir` and used in the login command. Until the login is done the card shows
    /// "Not logged in" with the command.
    func addDedicatedLogin(name: String) throws(DedicatedLoginError) -> String {
        let path = try prepareDedicatedLogin(name: name)
        let account = AccountConfig(provider: .claude, displayName: name, claudeConfigDir: path,
                                    isDedicatedLogin: true)
        updateSettings { $0.insertAccountGroupedByProvider(account) }  // also requests a .configChange refresh
        guard settings.accounts.contains(where: { $0.id == account.id }) else { throw .cannotSaveAccount }
        return path
    }

    /// Creates `~/.tokenbar/claude/<slug>` (0700) and returns its absolute path (no trailing slash).
    private func prepareDedicatedLogin(name: String) throws(DedicatedLoginError) -> String {
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

    /// Polls the dir every 5 s until Claude Code wrote an `oauthAccount`, then refreshes the (already saved)
    /// account. Stopping or timing out leaves the account in place.
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
        completedDedicatedLogins.insert(configDir)
        guard let account = settings.accounts.first(where: { $0.claudeConfigDir == configDir }) else { return }
        let isFirst = !settings.accounts.contains {
            $0.isEffectiveDedicatedLogin && $0.id != account.id
        }
        Task { await handleRefresh(.configChange, kinds: [.claude], only: [account.id]) }
        if isFirst { offerToDisableDefaultClaude() }
    }

    /// After the first dedicated login, suggest disabling the default (nil-dir) Claude account (spec §3.1).
    /// Non-modal: a banner in the panel and the Accounts pane; nothing blocks the MainActor.
    func offerToDisableDefaultClaude() {
        disableDefaultOfferID = settings.accounts.first(where: {
            $0.provider == .claude && $0.claudeConfigDir == nil && $0.isEnabled
        })?.id
    }

    /// The default Claude account the banner offers to disable, while it still exists and is enabled.
    var disableDefaultOffer: AccountConfig? {
        guard let id = disableDefaultOfferID else { return nil }
        return settings.accounts.first { $0.id == id && $0.isEnabled && $0.claudeConfigDir == nil }
    }

    func answerDisableDefaultOffer(disable: Bool) {
        if disable, let account = disableDefaultOffer { updateAccount(account.id) { $0.isEnabled = false } }
        disableDefaultOfferID = nil
    }

    // MARK: Render preview

    /// `--render-panel` / `--render-settings` only: replaces the observable state with stub data before
    /// `start()`. Nothing is saved, and no refresh, session scan or clock task runs.
    func installRenderState(settings: AppSettings, accounts: [AccountState], sessions: [SessionGroup], now: Date,
                            lastRefreshAt: Date?, offerToDisableDefault: Bool) {
        precondition(!started, "render state is for previews only")
        self.settings = settings
        self.accounts = accounts
        self.sessions = sessions
        self.now = now
        self.lastRefreshAt = lastRefreshAt
        if offerToDisableDefault { offerToDisableDefaultClaude() }
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
