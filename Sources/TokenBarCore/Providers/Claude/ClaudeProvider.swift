import Foundation

/// Claude usage for one config dir (spec §5.3): step 0 (pre-checks), 1 (keychain), ① (usage API),
/// ② (let Claude Code refresh a dedicated login), ③ (cached usage), 5 (identity and account change).
public struct ClaudeProvider: UsageProvider {
    /// Every step's timeout is clipped to `deadline − now − 2 s` (spec §5.3 time budget).
    public static let deadlineReserve: TimeInterval = 2
    /// A step does not start with less budget than this; the flow goes to step ③ instead.
    public static let minimumStepBudget: TimeInterval = 1
    /// Minimum spacing between two non-manual usage requests of one account.
    public static let httpSpacing: TimeInterval = 60
    /// Minimum spacing between two non-manual step ② runs of one account.
    public static let step2Spacing: TimeInterval = 15 * 60
    /// Token-bound backoff after a 401 or a 403 with an API error body.
    public static let unauthorizedBackoff: TimeInterval = 3600
    /// Per-account backoff after a 429 or a bare 403 without Retry-After, and the cap with it.
    public static let defaultRateLimitBackoff: TimeInterval = 300
    public static let maxRateLimitBackoff: TimeInterval = 3600

    private let env: CoreEnvironment
    private let stateStore: any StateStoring
    private let credentialReader: ClaudeCredentialReader
    private let configReader: ClaudeConfigReader
    private let usageClient: ClaudeUsageClient
    private let refresher: ClaudeCodeRefresher
    private let liveSessionChecker: @Sendable (String) async -> Bool

    /// - Parameter liveSessionChecker: whether the given config dir has live interactive sessions right now;
    ///   step ② never runs while it does.
    public init(
        env: CoreEnvironment,
        stateStore: any StateStoring,
        binaryLocator: any BinaryLocating,
        liveSessionChecker: @escaping @Sendable (String) async -> Bool
    ) {
        self.env = env
        self.stateStore = stateStore
        self.credentialReader = ClaudeCredentialReader(env: env)
        self.configReader = ClaudeConfigReader(env: env)
        self.usageClient = ClaudeUsageClient(env: env)
        self.refresher = ClaudeCodeRefresher(env: env, stateStore: stateStore, binaryLocator: binaryLocator)
        self.liveSessionChecker = liveSessionChecker
    }

    public func fetchUsage(for account: AccountConfig, settings: AppSettings, context: RefreshContext) async throws
        -> ProviderOutcome
    {
        let flow = ClaudeRefreshFlow(
            env: env, stateStore: stateStore, credentialReader: credentialReader, configReader: configReader,
            usageClient: usageClient, refresher: refresher, liveSessionChecker: liveSessionChecker,
            account: account, settings: settings, context: context)
        return try await flow.run()
    }

    /// Plan name (spec §5.3 step 5): `subscriptionType` first, then `organizationType`.
    public static func planName(subscriptionType: String?, organizationType: String?) -> String? {
        switch subscriptionType?.lowercased() {
        case "max": return "Max"
        case "pro": return "Pro"
        default: break
        }
        switch organizationType?.lowercased() {
        case "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        default: return nil
        }
    }

    public static func identity(_ account: ClaudeOAuthAccount?, subscriptionType: String?) -> AccountIdentity? {
        guard account != nil || subscriptionType != nil else { return nil }
        return AccountIdentity(
            accountUuid: account?.accountUuid,
            plan: planName(subscriptionType: subscriptionType, organizationType: account?.organizationType),
            organization: account?.organizationName)
    }
}

/// One `fetchUsage` call. Lives inside a single task; nothing in it is shared.
private final class ClaudeRefreshFlow {
    private enum APIResult {
        case done(ProviderOutcome)
        /// Go to step ③ with this error.
        case fallback(ProviderError)
        /// 401 and a re-read did not give a new token; dedicated logins may continue with step ②.
        case unauthorized(ProviderError)
    }

    let env: CoreEnvironment
    let stateStore: any StateStoring
    let credentialReader: ClaudeCredentialReader
    let configReader: ClaudeConfigReader
    let usageClient: ClaudeUsageClient
    let refresher: ClaudeCodeRefresher
    let liveSessionChecker: @Sendable (String) async -> Bool
    let account: AccountConfig
    let settings: AppSettings
    let context: RefreshContext

    let accountID: UUID
    /// The configured dir with a leading `~` expanded; nil for the default login.
    let configDir: String?
    let hint: LoginHint
    let manual: Bool
    let dedicated: Bool
    /// `oauthAccount.accountUuid` when the refresh started.
    var initialUuid: String?
    var subscriptionType: String?
    /// Whether state.json marks the keychain `deniedOrPrompting`; a successful read clears it.
    var keychainMarkedDenied = false

    init(
        env: CoreEnvironment, stateStore: any StateStoring, credentialReader: ClaudeCredentialReader,
        configReader: ClaudeConfigReader, usageClient: ClaudeUsageClient, refresher: ClaudeCodeRefresher,
        liveSessionChecker: @escaping @Sendable (String) async -> Bool,
        account: AccountConfig, settings: AppSettings, context: RefreshContext
    ) {
        self.env = env
        self.stateStore = stateStore
        self.credentialReader = credentialReader
        self.configReader = configReader
        self.usageClient = usageClient
        self.refresher = refresher
        self.liveSessionChecker = liveSessionChecker
        self.account = account
        self.settings = settings
        self.context = context
        accountID = account.id
        configDir = account.claudeConfigDir.map { ClaudePaths.expandTilde($0, home: env.homeDirectory) }
        hint = .claude(configDir: account.claudeConfigDir)
        manual = context.isManual
        dedicated = account.isDedicatedLogin && account.claudeConfigDir != nil
    }

    func run() async throws(ProviderError) -> ProviderOutcome {
        // Step 5, checked first so that backoff state of a previous account cannot block the new one.
        initialUuid = configReader.read(configDir: configDir)?.oauthAccount?.accountUuid
        var accountChanged = false
        if let previous = context.previousIdentity?.accountUuid, let current = initialUuid, previous != current {
            accountChanged = true
            await resetAccountBoundState()
        }
        do {
            var outcome = try await steps()
            if accountChanged { outcome.warning = .accountChanged }
            return outcome
        } catch {
            throw accountChanged ? .accountChanged : error
        }
    }

    // MARK: - Steps 0, 1, ①, ②

    private func steps() async throws(ProviderError) -> ProviderOutcome {
        var state = await stateStore.read(accountID)
        let now = env.now()

        // Step 0.
        if state.backoffReason == .rateLimited, state.backoffTokenExpiresAt == nil, let until = state.backoffUntil, until > now {
            return try fallback(.rateLimited(until: until))
        }
        keychainMarkedDenied = state.keychainAccess == .deniedOrPrompting
        if keychainMarkedDenied, !manual {
            return try fallback(.keychainAccessDenied(exitCode: ClaudeCredentialReader.noExitCode))
        }

        // Step 1.
        var credentials: ClaudeCredentials
        var spawnDir = configDir
        switch await readCredentials() {
        case .success(let found):
            credentials = found.credentials
            if let matched = found.keychainDir { spawnDir = matched }
        case .failure(let error):
            return try fallback(error)
        }
        subscriptionType = credentials.subscriptionType
        guard credentials.hasToken else { return try fallback(.notLoggedIn(hint: hint)) }
        guard credentials.hasProfileScope else { return try fallback(.tokenLacksProfileScope) }

        // A token-bound backoff ends as soon as the token changes.
        let tokenKey = Self.tokenKey(credentials)
        if state.backoffReason == .unauthorized, state.backoffTokenExpiresAt != tokenKey {
            state = await stateStore.update(accountID) { state in
                guard state.backoffReason == .unauthorized, state.backoffTokenExpiresAt != tokenKey else { return }
                state.backoffUntil = nil
                state.backoffReason = nil
                state.backoffTokenExpiresAt = nil
            }
        }

        // Step ①.
        var step2Error: ProviderError
        if credentials.isExpired(at: env.now()) {
            step2Error = .waitingForClaudeCode
        } else if state.backoffReason == .unauthorized, state.backoffTokenExpiresAt == tokenKey,
                  let until = state.backoffUntil, until > env.now() {
            return try fallback(dedicated ? .unauthorized(until: until) : .waitingForClaudeCode)
        } else {
            if !manual, let last = state.lastHTTPAt, env.now().timeIntervalSince(last) < ClaudeProvider.httpSpacing {
                return try fallback(.rateLimited(until: last.addingTimeInterval(ClaudeProvider.httpSpacing)), quietIfCached: true)
            }
            switch try await callAPI(&credentials, retryOn401: true) {
            case .done(let outcome): return outcome
            case .fallback(let error): return try fallback(error)
            case .unauthorized(let error): step2Error = error
            }
        }

        // Step ②: dedicated logins only, and only when every condition holds.
        guard dedicated, let spawnDir, let configDir else { return try fallback(step2Error) }
        guard settings.allowClaudeCodeRefresh, context.allowClaudeCodeRefresh else { return try fallback(step2Error) }
        state = await stateStore.read(accountID)
        if !manual, state.step2FailedForTokenExpiresAt == Self.tokenKey(credentials) {
            return try fallback(.notLoggedIn(hint: hint))
        }
        if !manual, let last = state.lastStep2At, env.now().timeIntervalSince(last) < ClaudeProvider.step2Spacing {
            return try fallback(step2Error)
        }
        if await liveSessionChecker(configDir) { return try fallback(step2Error) }
        guard let wait = budget(ClaudeCodeRefresher.maxWait.timeInterval) else { return try fallback(.timeout) }

        let result = await refresher.refresh(
            accountID: accountID, configDir: spawnDir, settings: settings, wait: .milliseconds(Int64(wait * 1000)))
        switch result {
        case .binaryNotFound, .spawnFailed:
            return try fallback(.claudeBinaryNotFound)
        case .alreadyInFlight:
            return try fallback(step2Error)
        case .stillRunning:
            return try fallback(.timeout)
        case .exited(_, let startedAt):
            return try await afterStep2(startedAt: startedAt, previous: credentials)
        }
    }

    /// After step ②: cache first, else one re-read and one usage request (spec §5.3).
    private func afterStep2(startedAt: Date, previous: ClaudeCredentials) async throws(ProviderError) -> ProviderOutcome {
        let config = configReader.read(configDir: configDir)
        try checkSameAccount(config)
        if let cache = config?.matchingCachedUsage, cache.fetchedAt > startedAt {
            await clearBackoff()
            return snapshot(cache.usage, source: .claudeAPIAfterCLIRefresh, dataAsOf: cache.fetchedAt, config: config)
        }

        var credentials: ClaudeCredentials
        switch await readCredentials() {
        case .success(let found):
            credentials = found.credentials
        case .failure(.notLoggedIn):
            await markStep2Failed(Self.tokenKey(previous))
            return try fallback(.notLoggedIn(hint: hint))
        case .failure(let error):
            return try fallback(error)
        }
        subscriptionType = credentials.subscriptionType ?? subscriptionType
        guard credentials.hasToken, !credentials.isExpired(at: env.now()) else {
            await markStep2Failed(Self.tokenKey(credentials))
            return try fallback(.notLoggedIn(hint: hint))
        }
        guard credentials.hasProfileScope else { return try fallback(.tokenLacksProfileScope) }
        switch try await callAPI(&credentials, retryOn401: false) {
        case .done(let outcome): return outcome
        case .fallback(let error), .unauthorized(let error): return try fallback(error)
        }
    }

    // MARK: - Keychain

    private struct FoundCredentials {
        var credentials: ClaudeCredentials
        /// The config dir string whose keychain item matched (the trailing-slash variant if that one hit).
        var keychainDir: String?
    }

    /// Step 1 with the spec's classification; marks the account `deniedOrPrompting` on a denial.
    private func readCredentials() async -> Result<FoundCredentials, ProviderError> {
        let result = await credentialReader.read(configDir: configDir, manual: manual, deadline: context.deadline)
        switch result {
        case .found(let credentials, let source):
            if keychainMarkedDenied {
                await stateStore.update(accountID) { $0.keychainAccess = .ok }
                keychainMarkedDenied = false
            }
            if case .keychain(let dir) = source { return .success(FoundCredentials(credentials: credentials, keychainDir: dir)) }
            return .success(FoundCredentials(credentials: credentials, keychainDir: nil))
        case .notFound:
            return .failure(.notLoggedIn(hint: hint))
        case .timedOut(let truncated):
            // A cut-short read says nothing about a prompt; a full-length timeout probably was one.
            if truncated { return .failure(.timeout) }
            await markKeychainDenied()
            return .failure(.keychainAccessDenied(exitCode: ClaudeCredentialReader.noExitCode))
        case .failed(let error):
            if case .keychainAccessDenied = error { await markKeychainDenied() }
            return .failure(error)
        }
    }

    // MARK: - Usage API (step ①)

    private func callAPI(_ credentials: inout ClaudeCredentials, retryOn401: Bool) async throws(ProviderError) -> APIResult {
        guard let seconds = budget(ClaudeUsageClient.requestTimeout.timeInterval) else { return .fallback(.timeout) }
        let requestedAt = env.now()
        await stateStore.update(accountID) { $0.lastHTTPAt = requestedAt }
        do {
            let usage = try await usageClient.fetchUsage(
                accessToken: credentials.accessToken, timeout: .milliseconds(Int64(seconds * 1000)))
            // The account must not have changed while the request was in flight.
            let config = configReader.read(configDir: configDir)
            try checkSameAccount(config)
            await clearBackoff()
            return .done(snapshot(usage, source: .claudeAPI, dataAsOf: env.now(), config: config))
        } catch let error as ClaudeUsageClientError {
            let now = env.now()
            switch error {
            case .unauthorized:
                if retryOn401, case .success(let reread) = await readCredentials(),
                   reread.credentials.hasToken, reread.credentials.accessToken != credentials.accessToken,
                   reread.credentials.hasProfileScope, !reread.credentials.isExpired(at: env.now()) {
                    credentials = reread.credentials
                    subscriptionType = credentials.subscriptionType ?? subscriptionType
                    return try await callAPI(&credentials, retryOn401: false)
                }
                let until = now.addingTimeInterval(ClaudeProvider.unauthorizedBackoff)
                await setTokenBackoff(until: until, tokenKey: Self.tokenKey(credentials))
                return .unauthorized(dedicated ? .unauthorized(until: until) : .waitingForClaudeCode)
            case .forbidden:
                let until = now.addingTimeInterval(ClaudeProvider.unauthorizedBackoff)
                await setTokenBackoff(until: until, tokenKey: Self.tokenKey(credentials))
                return .fallback(.unauthorized(until: until))
            case .rateLimited(let retryAfter):
                let delay = min(max(retryAfter ?? ClaudeProvider.defaultRateLimitBackoff, 0), ClaudeProvider.maxRateLimitBackoff)
                let until = now.addingTimeInterval(delay)
                await stateStore.update(accountID) { state in
                    state.backoffUntil = until
                    state.backoffReason = .rateLimited
                    state.backoffTokenExpiresAt = nil
                }
                return .fallback(.rateLimited(until: until))
            case .network(let code):
                // Shortly after wake a network failure is transient: report it as is so the caller keeps
                // the previous state instead of replacing it with cached data.
                if let grace = context.wakeGraceUntil, now <= grace { throw .network(urlErrorCode: code) }
                return .fallback(.network(urlErrorCode: code))
            case .httpStatus(let status):
                return .fallback(.httpStatus(status))
            case .decoding:
                return .fallback(.decoding(codingPath: []))
            }
        } catch let error as ProviderError {
            throw error
        } catch {
            return .fallback(.network(urlErrorCode: URLError.Code.unknown.rawValue))
        }
    }

    // MARK: - Step ③

    /// Cached usage when it belongs to the logged-in account; otherwise `error` is thrown.
    /// `quietIfCached` drops the warning, for skips that are not failures (HTTP spacing).
    private func fallback(_ error: ProviderError, quietIfCached: Bool = false) throws(ProviderError) -> ProviderOutcome {
        let config = configReader.read(configDir: configDir)
        try checkSameAccount(config)
        guard let cache = config?.matchingCachedUsage else { throw error }
        var outcome = snapshot(cache.usage, source: .claudeCache(fetchedAt: cache.fetchedAt), dataAsOf: cache.fetchedAt, config: config)
        outcome.warning = quietIfCached ? nil : error
        return outcome
    }

    // MARK: - Helpers

    private func snapshot(_ usage: ClaudeMappedUsage, source: SnapshotSource, dataAsOf: Date, config: ClaudeGlobalConfig?)
        -> ProviderOutcome
    {
        ProviderOutcome(snapshot: UsageSnapshot(
            accountID: accountID,
            fetchedAt: env.now(),
            dataAsOf: dataAsOf,
            source: source,
            identity: ClaudeProvider.identity(config?.oauthAccount, subscriptionType: subscriptionType),
            windows: usage.windows,
            limitReached: usage.limitReached))
    }

    /// Throws `.accountChanged` when the config now names a different account than at the start.
    private func checkSameAccount(_ config: ClaudeGlobalConfig?) throws(ProviderError) {
        guard let initialUuid else { return }
        if config?.oauthAccount?.accountUuid != initialUuid { throw .accountChanged }
    }

    /// Remaining budget for a step capped at `cap` seconds, or nil when too little is left to start it.
    private func budget(_ cap: TimeInterval) -> TimeInterval? {
        let remaining = context.deadline.timeIntervalSince(env.now()) - ClaudeProvider.deadlineReserve
        let seconds = min(cap, remaining)
        return seconds >= ClaudeProvider.minimumStepBudget ? seconds : nil
    }

    /// The key a token-bound backoff or `step2Failed` mark is stored under: `expiresAt` in ms (0 if absent).
    private static func tokenKey(_ credentials: ClaudeCredentials) -> Double { credentials.expiresAtMs ?? 0 }

    private func markKeychainDenied() async {
        await stateStore.update(accountID) { $0.keychainAccess = .deniedOrPrompting }
        keychainMarkedDenied = true
    }

    private func markStep2Failed(_ tokenKey: Double) async {
        await stateStore.update(accountID) { $0.step2FailedForTokenExpiresAt = tokenKey }
    }

    private func setTokenBackoff(until: Date, tokenKey: Double) async {
        await stateStore.update(accountID) { state in
            state.backoffUntil = until
            state.backoffReason = .unauthorized
            state.backoffTokenExpiresAt = tokenKey
        }
    }

    private func clearBackoff() async {
        await stateStore.update(accountID) { state in
            state.backoffUntil = nil
            state.backoffReason = nil
            state.backoffTokenExpiresAt = nil
            state.step2FailedForTokenExpiresAt = nil
        }
    }

    private func resetAccountBoundState() async {
        await stateStore.update(accountID) { state in
            state.backoffUntil = nil
            state.backoffReason = nil
            state.backoffTokenExpiresAt = nil
            state.step2FailedForTokenExpiresAt = nil
            state.lastStep2At = nil
        }
    }
}
