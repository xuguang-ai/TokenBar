import Foundation

/// Composition root shared by the CLI and the App (plan Task 7): one instance per process wires the
/// environment, stores, binary locator, providers, aggregator and session monitor.
public final class TokenBarRuntime: Sendable {
    public let env: CoreEnvironment
    public let configStore: ConfigStore
    public let snapshotStore: SnapshotStore
    public let stateStore: any StateStoring
    public let binaryLocator: any BinaryLocating
    public let configReader: ClaudeConfigReader
    public let sessionMonitor: SessionMonitor
    public let aggregator: UsageAggregator

    /// - Parameter providerOverrides: replaces the real providers (the App's `--selftest` uses stubs).
    public init(env: CoreEnvironment, providerOverrides: [ProviderKind: any UsageProvider] = [:]) {
        let stateStore = StateStore(env: env)
        let binaryLocator = BinaryLocator(env: env)
        let configReader = ClaudeConfigReader(env: env)
        let sessionMonitor = SessionMonitor(env: env, configReader: configReader)

        let claude = ClaudeProvider(
            env: env,
            stateStore: stateStore,
            binaryLocator: binaryLocator,
            liveSessionChecker: { configDir in
                let ownChildren = await TokenBarRuntime.step2ChildPIDs(in: stateStore)
                return await sessionMonitor.hasLiveSessions(configDir: configDir, excludePIDs: ownChildren)
            })
        let codex = CodexProvider(env: env, binaryLocator: binaryLocator, clientVersion: TokenBarVersion.current)
        var providers: [ProviderKind: any UsageProvider] = [.claude: claude, .codex: codex]
        for (kind, provider) in providerOverrides { providers[kind] = provider }

        self.env = env
        self.configStore = ConfigStore(env: env)
        self.snapshotStore = SnapshotStore(env: env)
        self.stateStore = stateStore
        self.binaryLocator = binaryLocator
        self.configReader = configReader
        self.sessionMonitor = sessionMonitor
        self.aggregator = UsageAggregator(providers: providers, env: env)
    }

    public static func live() -> TokenBarRuntime {
        TokenBarRuntime(env: .live())
    }

    /// PIDs of TokenBar's own in-flight step ② children. A pid <= 0 is a pre-spawn reservation, not a process.
    public func step2ChildPIDs() async -> Set<Int32> {
        await Self.step2ChildPIDs(in: stateStore)
    }

    static func step2ChildPIDs(in store: any StateStoring) async -> Set<Int32> {
        Set(await store.readAll().values.compactMap { $0.step2InFlight?.pid }.filter { $0 > 0 })
    }

    /// Claude identities read from each account's global config JSON (`oauthAccount.accountUuid` only).
    /// Uses no keychain and no network, so sessions can be attributed before any usage refresh.
    public func currentClaudeIdentities(settings: AppSettings) async -> [UUID: AccountIdentity] {
        var identities: [UUID: AccountIdentity] = [:]
        for account in settings.accounts where account.provider == .claude {
            if let uuid = await configReader.accountUUID(configDir: account.claudeConfigDir) {
                identities[account.id] = AccountIdentity(accountUuid: uuid)
            }
        }
        return identities
    }

    /// Running Claude Code sessions grouped by account (spec §3.2, §5.5), excluding TokenBar's own children.
    /// `identities` defaults to `currentClaudeIdentities(settings:)`.
    public func scanSessions(settings: AppSettings, identities: [UUID: AccountIdentity]? = nil) async -> [SessionGroup] {
        let resolved: [UUID: AccountIdentity]
        if let identities {
            resolved = identities
        } else {
            resolved = await currentClaudeIdentities(settings: settings)
        }
        return await sessionMonitor.scan(settings: settings, identities: resolved, excludePIDs: step2ChildPIDs())
    }
}
