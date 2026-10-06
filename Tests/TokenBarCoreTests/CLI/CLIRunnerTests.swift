import Foundation
import Testing
@testable import TokenBarCore

@Suite("CLI arguments")
struct CLIArgumentsTests {
    @Test func parsesSubcommandsAndOptions() {
        #expect(CLIArguments.parse([]) == .success(.help))
        #expect(CLIArguments.parse(["--help"]) == .success(.help))
        #expect(CLIArguments.parse(["status", "-h"]) == .success(.help))
        #expect(CLIArguments.parse(["--version"]) == .success(.version))
        #expect(CLIArguments.parse(["status"]) == .success(.status(CLIOptions())))
        #expect(CLIArguments.parse(["status", "--json", "--account", "Codex", "--account=work", "--allow-claude-refresh"])
            == .success(.status(CLIOptions(json: true, accounts: ["Codex", "work"], allowClaudeRefresh: true))))
        #expect(CLIArguments.parse(["sessions", "--json"]) == .success(.sessions(CLIOptions(json: true))))
    }

    @Test func rejectsBadUsage() {
        for arguments in [["frobnicate"], ["status", "--jsn"], ["status", "--account"], ["status", "--account="],
                          ["sessions", "--allow-claude-refresh"]] {
            guard case .failure = CLIArguments.parse(arguments) else {
                Issue.record("expected a usage error for \(arguments)")
                continue
            }
        }
    }

    @Test func accountSelectionIsCaseInsensitiveAndKeepsSettingsOrder() throws {
        var settings = AppSettings.makeDefault()
        let work = AccountConfig(provider: .claude, displayName: "Work", isEnabled: false)
        settings.accounts.append(work)
        #expect(try CLIArguments.selectAccounts([], in: settings).get().map(\.displayName) == ["Claude", "Codex"])
        #expect(try CLIArguments.selectAccounts(["codex"], in: settings).get().map(\.id) == [AppSettings.defaultCodexAccountID])
        // Explicitly named disabled accounts are used; duplicates collapse; settings order wins.
        #expect(try CLIArguments.selectAccounts([" WORK ", "claude", "Claude"], in: settings).get().map(\.displayName)
            == ["Claude", "Work"])
    }

    @Test func unknownAccountListsValidNames() {
        let result = CLIArguments.selectAccounts(["Nope"], in: AppSettings.makeDefault())
        guard case .failure(let error) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(error.message == "unknown account 'Nope'. Valid names: 'Claude', 'Codex'.")
    }

    @Test func exitCodeMapping() {
        let a = UUID(), b = UUID()
        #expect(CLIRunner.statusExitCode(selected: [a, b], succeeded: [a, b]) == 0)
        #expect(CLIRunner.statusExitCode(selected: [a, b], succeeded: [a]) == 1)
        #expect(CLIRunner.statusExitCode(selected: [a], succeeded: []) == 1)
        #expect(CLIRunner.statusExitCode(selected: [], succeeded: []) == 0)
    }
}

@Suite("CLI runner")
struct CLIRunnerTests {
    private struct StubProvider: UsageProvider {
        var result: Result<ProviderOutcome, ProviderError>
        var allowSeen: Locked<[Bool]>? = nil

        func fetchUsage(for account: AccountConfig, settings: AppSettings, context: RefreshContext) async throws -> ProviderOutcome {
            allowSeen?.withLock { $0.append(context.allowClaudeCodeRefresh) }
            switch result {
            case .success(var outcome):
                outcome.snapshot.accountID = account.id
                return outcome
            case .failure(let error):
                throw error
            }
        }
    }

    private static func outcome(used: Double, plan: String, source: SnapshotSource, at date: Date,
                                warning: ProviderError? = nil) -> ProviderOutcome {
        ProviderOutcome(snapshot: UsageSnapshot(
            accountID: UUID(), fetchedAt: date, dataAsOf: date, source: source,
            identity: AccountIdentity(accountUuid: CLIFixtures.canaryUuid, plan: plan, email: CLIFixtures.canaryEmail),
            windows: [UsageWindow(kind: .fiveHour, usedPercent: used, resetsAt: date.addingTimeInterval(3600))],
            limitReached: false), warning: warning)
    }

    private static func runtime(_ harness: TestHarness, claude: Result<ProviderOutcome, ProviderError>,
                                codex: Result<ProviderOutcome, ProviderError>,
                                allowSeen: Locked<[Bool]>? = nil) -> TokenBarRuntime {
        // TestClock's sleep returns at once, which would fire the aggregator's safety timeout immediately.
        var env = harness.env
        env.sleep = { try await Task.sleep(for: $0) }
        return TokenBarRuntime(env: env, providerOverrides: [
            .claude: StubProvider(result: claude, allowSeen: allowSeen),
            .codex: StubProvider(result: codex),
        ])
    }

    private static func run(_ arguments: [String], _ runtime: TokenBarRuntime) async -> CLIResult {
        await CLIRunner.run(arguments: arguments, makeRuntime: { runtime })
    }

    @Test func allSucceedExitsZero() async throws {
        let harness = try TestHarness()
        let now = harness.clock.now
        let runtime = Self.runtime(
            harness,
            claude: .success(Self.outcome(used: 30, plan: "Max", source: .claudeAPI, at: now,
                                          warning: .keychainAccessDenied(exitCode: 128))),
            codex: .success(Self.outcome(used: 10, plan: "Plus", source: .codexAppServer, at: now)))
        let result = await Self.run(["status", "--json"], runtime)
        #expect(result.exitCode == 0, "a warning still counts as success")
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.contains("\"code\" : \"keychain_access_denied\""))
        #expect(result.stdout.contains("\"usage\" : 0.3"))
        #expect(!result.stdout.contains("canary"))
        // CLI mode writes neither config.json nor snapshots.json.
        #expect(!FileManager.default.fileExists(atPath: runtime.configStore.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: runtime.snapshotStore.fileURL.path))
    }

    @Test func failureFallsBackToStoredSnapshotAndExitsOne() async throws {
        let harness = try TestHarness()
        let now = harness.clock.now
        let runtime = Self.runtime(
            harness,
            claude: .failure(.decoding(codingPath: [CLIFixtures.canarySecret])),
            codex: .success(Self.outcome(used: 10, plan: "Plus", source: .codexAppServer, at: now)))
        var old = Self.outcome(used: 55, plan: "Max", source: .claudeAPI, at: now.addingTimeInterval(-7200)).snapshot
        old.accountID = AppSettings.defaultClaudeAccountID
        old.windows = [UsageWindow(kind: .fiveHour, usedPercent: 55, resetsAt: now.addingTimeInterval(1800))]
        try runtime.snapshotStore.save([AppSettings.defaultClaudeAccountID: StoredAccountState(
            lastSnapshot: old, lastError: .httpStatus(500), lastAttemptAt: old.fetchedAt)])
        let before = try Data(contentsOf: runtime.snapshotStore.fileURL)

        let json = await Self.run(["status", "--json"], runtime)
        #expect(json.exitCode == 1)
        #expect(json.stdout.contains("\"code\" : \"decoding\""))
        #expect(json.stdout.contains("\"data_as_of\" : \"\(CLIFormat.iso8601(old.dataAsOf))\""))
        #expect(json.stdout.contains("\"usage\" : 0.55"))
        #expect(!json.stdout.contains("canary"))

        let table = await Self.run(["status"], runtime)
        #expect(table.exitCode == 1)
        #expect(table.stdout.contains("Claude  Max\n"))
        #expect(table.stdout.contains("⚠ Unexpected response format · Last updated 2 h ago"))
        #expect(!table.stdout.contains("canary"))

        #expect(try Data(contentsOf: runtime.snapshotStore.fileURL) == before, "snapshots.json is read-only")
    }

    @Test func accountFilterRefreshesOnlyThatAccount() async throws {
        let harness = try TestHarness()
        let now = harness.clock.now
        let runtime = Self.runtime(
            harness,
            claude: .failure(.timeout),
            codex: .success(Self.outcome(used: 10, plan: "Plus", source: .codexAppServer, at: now)))
        let result = await Self.run(["status", "--json", "--account", "codex"], runtime)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("\"provider\" : \"codex\""))
        #expect(!result.stdout.contains("\"provider\" : \"claude\""))
    }

    @Test func claudeRefreshIsOffUnlessRequested() async throws {
        let harness = try TestHarness()
        let now = harness.clock.now
        let seen = Locked<[Bool]>([])
        let runtime = Self.runtime(
            harness,
            claude: .success(Self.outcome(used: 1, plan: "Max", source: .claudeAPI, at: now)),
            codex: .failure(.codexBinaryNotFound), allowSeen: seen)
        _ = await Self.run(["status", "--account", "Claude"], runtime)
        // Distinct runtimes: the aggregator's success cooldown does not apply to .manual anyway.
        _ = await Self.run(["status", "--account", "Claude", "--allow-claude-refresh"], runtime)
        #expect(seen.withLock { $0 } == [false, true])
    }

    @Test func usageAndConfigErrorsExitTwo() async throws {
        let harness = try TestHarness()
        let runtime = Self.runtime(harness, claude: .failure(.timeout), codex: .failure(.timeout))

        let unknown = await Self.run(["status", "--account", "Nope"], runtime)
        #expect(unknown.exitCode == 2)
        #expect(unknown.stdout.isEmpty)
        #expect(unknown.stderr.contains("Valid names: 'Claude', 'Codex'"))

        let badOption = await Self.run(["status", "--bogus"], runtime)
        #expect(badOption.exitCode == 2)

        try FileManager.default.createDirectory(at: harness.env.appSupportDirectory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 99}"#.utf8).write(to: runtime.configStore.fileURL)
        let tooNew = await Self.run(["status"], runtime)
        #expect(tooNew.exitCode == 2)
        #expect(tooNew.stderr.contains("schema version 99"))

        try Data("not json \(CLIFixtures.canarySecret)".utf8).write(to: runtime.configStore.fileURL)
        let corrupt = await Self.run(["sessions", "--json"], runtime)
        #expect(corrupt.exitCode == 2)
        #expect(!corrupt.stderr.contains("canary"))
        #expect(try String(contentsOf: runtime.configStore.fileURL, encoding: .utf8).contains("not json"),
                "the CLI never rewrites config.json")
    }

    @Test func versionAndHelpDoNotBuildARuntime() async {
        let version = await CLIRunner.run(arguments: ["--version"], makeRuntime: {
            Issue.record("runtime must not be created")
            return TokenBarRuntime(env: .live())
        })
        #expect(version == CLIResult(stdout: "tokenbar \(TokenBarVersion.current)\n", exitCode: 0))
        let help = await CLIRunner.run(arguments: ["--help"], makeRuntime: {
            Issue.record("runtime must not be created")
            return TokenBarRuntime(env: .live())
        })
        #expect(help.exitCode == 0)
        #expect(help.stdout.hasPrefix("Usage: tokenbar"))
    }

    @Test func sessionsWithNoSessionsDirectory() async throws {
        let harness = try TestHarness()
        let runtime = Self.runtime(harness, claude: .failure(.timeout), codex: .failure(.timeout))
        let result = await Self.run(["sessions", "--json"], runtime)
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("\"groups\" : [\n\n  ]") || result.stdout.contains("\"groups\" : []"))
        #expect(harness.processes.calls.isEmpty)
    }
}
