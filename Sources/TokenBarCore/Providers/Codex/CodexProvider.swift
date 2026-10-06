import Foundation
import os

/// Codex usage for one CODEX_HOME (spec §3.3, §5.4).
///
/// 1. `CODEX_HOME` must exist and contain `config.toml` or `auth.json` (stat only) → else `.notACodexProfile`.
/// 2. Locate a verified binary; spawn `app-server` with a minimal env; verify the running pid's
///    signature (team 2DC432GLL2) and kill it on failure.
/// 3. Read `account/read` and `account/rateLimits/read` through `CodexAppServerClient` and map them.
/// 4. `account == null` or "authentication required" → `.notLoggedIn`.
/// 5. No usable binary, a timeout or a protocol error → the newest rollout snapshot, with the error as
///    the outcome's warning; if there is none, the error is thrown.
public struct CodexProvider: UsageProvider {
    /// Verified launch arguments (spec §5.4 step 2).
    public static let launchArguments = [
        "-c", "features.plugins=false",
        "-c", "memories.generate_memories=false",
        "-c", "memories.use_memories=false",
        "app-server", "--listen", "stdio://",
    ]
    /// Used when a binary rejects `launchArguments`.
    public static let legacyLaunchArguments = ["app-server"]
    /// A child that dies this soon without completing the handshake is taken as rejecting its arguments.
    public static let argumentRejectionWindow: TimeInterval = 1
    public static let defaultClientVersion = "0.1.0"

    private let env: CoreEnvironment
    private let binaryLocator: any BinaryLocating
    private let clientVersion: String
    private let rolloutReader: CodexRolloutReader
    private let argumentMemory = CodexLaunchArgumentMemory()

    public init(env: CoreEnvironment, binaryLocator: any BinaryLocating, clientVersion: String = CodexProvider.defaultClientVersion) {
        self.env = env
        self.binaryLocator = binaryLocator
        self.clientVersion = clientVersion
        self.rolloutReader = CodexRolloutReader(fileSystem: env.fileSystem)
    }

    // MARK: CODEX_HOME

    /// `codexHome` with a leading `~` expanded, or `~/.codex`.
    public static func codexHomeURL(_ codexHome: String?, home: URL) -> URL {
        guard let codexHome, !codexHome.isEmpty else { return home.appendingPathComponent(".codex", isDirectory: true) }
        return URL(fileURLWithPath: ClaudePaths.expandTilde(codexHome, home: home), isDirectory: true)
    }

    /// The directory exists and holds `config.toml` or `auth.json`. Stat only; nothing is read (spec §3.3).
    public static func isCodexProfile(_ directory: URL, fileSystem: any FileSystemAccess) -> Bool {
        guard let info = fileSystem.stat(directory), info.isDirectory else { return false }
        return ["config.toml", "auth.json"].contains { fileSystem.stat(directory.appendingPathComponent($0)) != nil }
    }

    // MARK: UsageProvider

    public func fetchUsage(for account: AccountConfig, settings: AppSettings, context: RefreshContext) async throws -> ProviderOutcome {
        let home = Self.codexHomeURL(account.codexHome, home: env.homeDirectory)
        guard Self.isCodexProfile(home, fileSystem: env.fileSystem) else { throw ProviderError.notACodexProfile }

        guard let binary = await binaryLocator.locate(.codex, settings: settings) else {
            return try fallback(account: account, home: home, warning: .codexBinaryNotFound)
        }
        do {
            let readout = try await readAppServer(binary: binary, account: account, home: home, settings: settings, context: context)
            return ProviderOutcome(snapshot: try snapshot(from: readout, account: account))
        } catch let error as ProviderError {
            if case .notLoggedIn = error { throw error }
            return try fallback(account: account, home: home, warning: error)
        }
    }

    // MARK: Steps

    private func snapshot(from readout: CodexAppServerReadout, account: AccountConfig) throws -> UsageSnapshot {
        let notLoggedIn = ProviderError.notLoggedIn(hint: .codex(home: account.codexHome))
        var accountPlan: String?
        switch readout.account {
        case .success(let info):
            guard info.isLoggedIn else { throw notLoggedIn }
            accountPlan = info.planType
        case .failure(let error):
            if error.authenticationRequired { throw notLoggedIn }
        }
        let limits: CodexRateLimitsReadResult
        switch readout.rateLimits {
        case .success(let result): limits = result
        case .failure(let error):
            if error.authenticationRequired { throw notLoggedIn }
            throw ProviderError.protocolError(.unexpected)
        }
        let now = env.now()
        guard let mapped = CodexRateLimitMapper.map(limits, accountPlan: accountPlan, now: now) else {
            throw ProviderError.protocolError(.malformedResponse)
        }
        return UsageSnapshot(
            accountID: account.id, fetchedAt: now, dataAsOf: now, source: .codexAppServer,
            identity: AccountIdentity(plan: mapped.plan), windows: mapped.windows, limitReached: mapped.limitReached)
    }

    private func fallback(account: AccountConfig, home: URL, warning: ProviderError) throws -> ProviderOutcome {
        guard let rollout = rolloutReader.latestSnapshot(codexHome: home) else { throw warning }
        let snapshot = UsageSnapshot(
            accountID: account.id, fetchedAt: env.now(), dataAsOf: rollout.eventAt,
            source: .codexRollout(eventAt: rollout.eventAt),
            identity: rollout.plan.map { AccountIdentity(plan: $0) },
            windows: rollout.windows, limitReached: rollout.limitReached)
        return ProviderOutcome(snapshot: snapshot, warning: warning)
    }

    /// Spawns with the full arguments, falling back once to `legacyLaunchArguments` when the child dies
    /// at once (spec §5.4 step 2). The choice is remembered per binary version.
    private func readAppServer(
        binary: LocatedBinary, account: AccountConfig, home: URL, settings: AppSettings, context: RefreshContext
    ) async throws -> CodexAppServerReadout {
        let key = binary.version?.description ?? binary.url.path
        var legacy = argumentMemory.usesLegacy(key)
        while true {
            let arguments = legacy ? Self.legacyLaunchArguments : Self.launchArguments
            let startedAt = env.now()
            do {
                let readout = try await runOnce(
                    binary: binary, arguments: arguments, account: account, home: home, settings: settings, context: context)
                if legacy { argumentMemory.setUsesLegacy(key) }
                return readout
            } catch let early as CodexEarlyExit {
                let quick = env.now().timeIntervalSince(startedAt) < Self.argumentRejectionWindow
                if !legacy, quick {
                    legacy = true
                    continue
                }
                throw early.error
            }
        }
    }

    private func runOnce(
        binary: LocatedBinary, arguments: [String], account: AccountConfig, home: URL,
        settings: AppSettings, context: RefreshContext
    ) async throws -> CodexAppServerReadout {
        let environment = env.childEnvironment(
            settings: settings,
            extra: ["CODEX_HOME": account.codexHome == nil ? nil : home.path, "RUST_LOG": "error"])
        let request = ProcessRequest(
            executable: binary.url, arguments: arguments, environment: environment,
            timeout: CodexAppServerClient.defaultTimeout)
        let transport: any LineTransport
        do {
            transport = try await env.processRunner.startStreaming(request)
        } catch {
            throw ProviderError.protocolError(.launchFailed)
        }

        guard await env.signatureVerifier.verifyRunningProcess(pid: transport.pid, teamID: BinaryKind.codex.teamID) else {
            // A child that already exited cannot be checked; treat that as an early exit, not a bad signature.
            let alive = env.processInspector.isAlive(pid: transport.pid)
            await transport.terminate()
            if !alive { throw CodexEarlyExit(error: .protocolError(.serverExited)) }
            throw ProviderError.binarySignatureInvalid(.codex)
        }

        let remaining = context.deadline.timeIntervalSince(env.now())
        let seconds = min(CodexAppServerClient.defaultTimeout.timeInterval, max(1, remaining))
        let client = CodexAppServerClient(
            transport: transport, clientVersion: clientVersion, sleep: env.sleep,
            timeout: .milliseconds(Int64((seconds * 1000).rounded())))
        do {
            return try await client.readUsage()
        } catch ProviderError.protocolError(.handshakeFailed) {
            throw CodexEarlyExit(error: .protocolError(.handshakeFailed))
        }
    }
}

/// Internal signal: the child died (or answered nothing usable) before the handshake completed.
struct CodexEarlyExit: Error {
    /// What to report if no retry happens.
    var error: ProviderError
}

/// Binary versions whose app-server rejected the full launch arguments. Shared by copies of a provider.
final class CodexLaunchArgumentMemory: Sendable {
    private let legacyKeys = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    func usesLegacy(_ key: String) -> Bool { legacyKeys.withLock { $0.contains(key) } }
    func setUsesLegacy(_ key: String) { _ = legacyKeys.withLock { $0.insert(key) } }
}
