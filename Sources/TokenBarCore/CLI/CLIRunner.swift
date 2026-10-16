import Foundation

/// What one CLI invocation prints and returns. `main.swift` only writes these out and exits.
public struct CLIResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// The `tokenbar` command (spec §7). It reads `config.json` in CLI mode and `snapshots.json`
/// read-only; it never writes either. Providers read and write `state.json` as usual.
public enum CLIRunner {
    /// - Parameter makeRuntime: called only for `status` and `sessions`, so `--help` and `--version`
    ///   touch nothing.
    public static func run(arguments: [String], makeRuntime: @Sendable () -> TokenBarRuntime) async -> CLIResult {
        switch CLIArguments.parse(arguments) {
        case .failure(let error):
            return usageFailure(error)
        case .success(.help):
            return CLIResult(stdout: CLIArguments.helpText, exitCode: CLIExitCode.success)
        case .success(.version):
            return CLIResult(stdout: "tokenbar \(TokenBarVersion.current)\n", exitCode: CLIExitCode.success)
        case .success(.status(let options)):
            return await status(options: options, runtime: makeRuntime())
        case .success(.sessions(let options)):
            return await sessions(options: options, runtime: makeRuntime())
        }
    }

    // MARK: - status

    public static func status(options: CLIOptions, runtime: TokenBarRuntime) async -> CLIResult {
        let settings: AppSettings
        switch loadSettings(runtime) {
        case .success(let loaded): settings = loaded
        case .failure(let error): return usageFailure(error)
        }
        let selected: [AccountConfig]
        switch CLIArguments.selectAccounts(options.accounts, in: settings) {
        case .success(let accounts): selected = accounts
        case .failure(let error): return usageFailure(error)
        }

        // Read-only: older data is shown for accounts that fail now; the CLI never saves snapshots.
        let stored = runtime.snapshotStore.load()
        var states: [UUID: AccountState] = [:]
        for account in selected {
            let previous = stored[account.id]
            states[account.id] = AccountState(
                config: account, lastSnapshot: previous?.lastSnapshot, lastError: previous?.lastError,
                lastAttemptAt: previous?.lastAttemptAt)
        }
        let previousIdentities = stored.compactMapValues { $0.lastSnapshot?.identity }

        let batch = await runtime.aggregator.refresh(
            accounts: selected, settings: settings, trigger: .manual,
            allowClaudeCodeRefresh: options.allowClaudeRefresh, previousIdentities: previousIdentities)
        var succeeded = Set<UUID>()
        for await event in batch.events {
            guard states[event.accountID] != nil else { continue }
            states[event.accountID]?.apply(event, wakeGraceUntil: nil)
            if case .success(let outcome) = event.result, isCleanSuccess(outcome) { succeeded.insert(event.accountID) }
        }

        let ordered = selected.compactMap { states[$0.id] }
        let now = runtime.env.now()
        let stdout = options.json
            ? CLIStatusBuilder.encode(CLIStatusBuilder.build(states: ordered, now: now))
            : CLIStatusTable.render(states: ordered, displayMode: settings.displayMode,
                                    resetTimeStyle: settings.resetTimeStyle, now: now)
        return CLIResult(stdout: stdout, exitCode: statusExitCode(selected: selected.map(\.id), succeeded: succeeded))
    }

    /// Whether a provider result counts as a success for the exit code: fresh data, or data with only an
    /// informational warning. Data served from a fallback (cache, rollout log) because of an error is a
    /// failure that still prints what it could get (spec §7, §8).
    public static func isCleanSuccess(_ outcome: ProviderOutcome) -> Bool {
        guard let warning = outcome.warning else { return true }
        // Live data, flagged only because the logged-in account differs from the last snapshot's.
        if case .accountChanged = warning { return true }
        return false
    }

    /// 0 when every selected account produced fresh data or only an informational warning, else 1.
    /// An account that failed, was served from a fallback because of an error, or produced no result
    /// at all counts as failed.
    public static func statusExitCode(selected: [UUID], succeeded: Set<UUID>) -> Int32 {
        selected.allSatisfy(succeeded.contains) ? CLIExitCode.success : CLIExitCode.accountFailed
    }

    // MARK: - sessions

    public static func sessions(options: CLIOptions, runtime: TokenBarRuntime) async -> CLIResult {
        let settings: AppSettings
        switch loadSettings(runtime) {
        case .success(let loaded): settings = loaded
        case .failure(let error): return usageFailure(error)
        }
        var groups = await runtime.scanSessions(settings: settings)
        var stderr = ""
        if !options.accounts.isEmpty {
            switch CLIArguments.selectAccounts(options.accounts, in: settings) {
            case .success(let accounts):
                let ids = Set(accounts.map(\.id))
                groups = groups.filter { $0.accountID.map(ids.contains) ?? false }
                // Sessions are attributed to enabled accounts only; say why a disabled one shows nothing.
                for account in accounts where !account.isEnabled {
                    stderr += "tokenbar: account \(CLIFormat.printable(account.displayName)) is disabled\n"
                }
            case .failure(let error):
                return usageFailure(error)
            }
        }
        let now = runtime.env.now()
        let stdout = options.json
            ? CLIStatusBuilder.encode(CLISessionsRenderer.json(groups: groups, accounts: settings.accounts, now: now))
            : CLISessionsRenderer.table(groups: groups, accounts: settings.accounts, now: now)
        return CLIResult(stdout: stdout, stderr: stderr, exitCode: CLIExitCode.success)
    }

    // MARK: - Helpers

    /// CLI mode: a missing file gives in-memory defaults and nothing is written.
    public static func loadSettings(_ runtime: TokenBarRuntime) -> Result<AppSettings, CLIUsageError> {
        do throws(ConfigLoadError) {
            return .success(try runtime.configStore.loadOrDefault(forApp: false).settings)
        } catch {
            return .failure(configError(error))
        }
    }

    public static func configError(_ error: ConfigLoadError) -> CLIUsageError {
        switch error {
        case .tooNew(let version):
            return CLIUsageError(
                "config.json has schema version \(version), newer than this tokenbar supports. Update TokenBar.")
        case .corrupt:
            return CLIUsageError("config.json could not be read. Fix it, or open TokenBar to reset it.")
        case .missing:
            return CLIUsageError("config.json is missing.")
        }
    }

    static func usageFailure(_ error: CLIUsageError) -> CLIResult {
        CLIResult(stderr: "tokenbar: \(error.message)\n", exitCode: CLIExitCode.usage)
    }
}
