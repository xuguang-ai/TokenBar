import Foundation
import Testing
@testable import TokenBarCore

@Suite("TokenBarRuntime")
struct TokenBarRuntimeTests {
    private struct RuntimeStubProvider: UsageProvider {
        let used: Double
        func fetchUsage(for account: AccountConfig, settings: AppSettings, context: RefreshContext) async throws -> ProviderOutcome {
            ProviderOutcome(snapshot: UsageSnapshot(
                accountID: account.id, fetchedAt: context.deadline, dataAsOf: context.deadline, source: .codexAppServer,
                identity: AccountIdentity(plan: "Stub"),
                windows: [UsageWindow(kind: .fiveHour, usedPercent: used, resetsAt: nil)], limitReached: false))
        }
    }

    @Test func providerOverridesAreUsedByTheAggregator() async throws {
        let harness = try TestHarness()
        // TestClock's sleep returns at once, which would fire the aggregator's safety timeout immediately.
        var env = harness.env
        env.sleep = { try await Task.sleep(for: $0) }
        let runtime = TokenBarRuntime(env: env, providerOverrides: [.claude: RuntimeStubProvider(used: 12),
                                                                    .codex: RuntimeStubProvider(used: 34)])
        let settings = AppSettings.makeDefault()
        let batch = await runtime.aggregator.refresh(accounts: settings.accounts, settings: settings, trigger: .manual,
                                                     allowClaudeCodeRefresh: false)
        var used: [UUID: Double] = [:]
        for await event in batch.events {
            if case .success(let outcome) = event.result { used[event.accountID] = outcome.snapshot.windows.first?.usedPercent }
        }
        #expect(used == [AppSettings.defaultClaudeAccountID: 12, AppSettings.defaultCodexAccountID: 34])
        #expect(harness.processes.calls.isEmpty, "stub providers must not spawn anything")
    }

    @Test func step2ChildPIDsIgnoreReservations() async throws {
        let harness = try TestHarness()
        let runtime = TokenBarRuntime(env: harness.env)
        let reserved = UUID()
        let running = UUID()
        await runtime.stateStore.update(reserved) { $0.step2InFlight = Step2InFlight(pid: 0, startedAt: harness.clock.now) }
        await runtime.stateStore.update(running) { $0.step2InFlight = Step2InFlight(pid: 4242, startedAt: harness.clock.now) }
        #expect(await runtime.step2ChildPIDs() == [4242])
    }

    @Test func claudeIdentitiesComeFromTheGlobalConfigOnly() async throws {
        let harness = try TestHarness()
        try harness.writeHome(".claude.json", #"{"oauthAccount":{"accountUuid":"uuid-default"},"mcpServers":{"x":{"env":{"K":"canary-secret"}}}}"#)
        try harness.writeHome(".tokenbar/claude/work/.claude.json", #"{"oauthAccount":{"accountUuid":"uuid-work"}}"#)
        var settings = AppSettings.makeDefault()
        let work = AccountConfig(provider: .claude, displayName: "Work",
                                 claudeConfigDir: harness.home.path + "/.tokenbar/claude/work", isDedicatedLogin: true)
        settings.accounts.append(work)
        let runtime = TokenBarRuntime(env: harness.env)
        let identities = await runtime.currentClaudeIdentities(settings: settings)
        #expect(identities[AppSettings.defaultClaudeAccountID]?.accountUuid == "uuid-default")
        #expect(identities[work.id]?.accountUuid == "uuid-work")
        #expect(identities[AppSettings.defaultCodexAccountID] == nil)
        #expect(!String(describing: identities).contains("canary-secret"))
        #expect(harness.processes.calls.isEmpty, "no keychain access")
    }

    // MARK: Session scan (spec §5.5)

    private struct CountingConfigReader: ClaudeConfigReading {
        let calls = Locked<[String?]>([])
        func accountUUID(configDir: String?) async -> String? {
            calls.withLock { $0.append(configDir) }
            return configDir == nil ? "uuid-default" : nil
        }
    }

    /// Writes a live interactive session `<home>/<dir>/sessions/<pid>.json`.
    private static func register(_ harness: TestHarness, dir: String, pid: Int32) throws {
        let object: [String: Any] = ["pid": pid, "status": "busy", "kind": "interactive",
                                     "statusUpdatedAt": 1_791_296_400_000, "cwd": "/w/p\(pid)"]
        try harness.temp.write("home/\(dir)/sessions/\(pid).json", try JSONSerialization.data(withJSONObject: object))
        harness.inspector.setAlive(pid, startTime: nil)
    }

    @Test func sessionScanReadsTheActiveLoginAndParsesEachGlobalConfigOnce() async throws {
        let harness = try TestHarness()
        try harness.writeHome(".claude.json", #"{"oauthAccount":{"accountUuid":"uuid-default"}}"#)
        try harness.writeHome(".tokenbar/claude/work/.claude.json", #"{"oauthAccount":{"accountUuid":"uuid-work"}}"#)
        try Self.register(harness, dir: ".claude", pid: 101)
        try Self.register(harness, dir: ".tokenbar/claude/work", pid: 102)
        var settings = AppSettings.makeDefault()
        // A `~` path: the session monitor expands it, the identities do not; both must share one read.
        let work = AccountConfig(provider: .claude, displayName: "Work", claudeConfigDir: "~/.tokenbar/claude/work",
                                 isDedicatedLogin: true)
        settings.accounts.append(work)
        var env = harness.env
        let recorder = ReadRecorder()
        env.fileSystem = recorder

        let scan = await TokenBarRuntime(env: env).sessionScan(settings: settings)

        #expect(scan.activeClaudeAccountUuid == "uuid-default")
        #expect(scan.groups.map(\.accountID) == [AppSettings.defaultClaudeAccountID, work.id])
        #expect(scan.groups.flatMap(\.sessions).map(\.pid) == [101, 102])
        let configReads = recorder.readPaths.filter { $0.hasSuffix("/.claude.json") }
        #expect(configReads.sorted() == [harness.home.path + "/.claude.json",
                                         harness.home.path + "/.tokenbar/claude/work/.claude.json"])
        #expect(harness.processes.calls.isEmpty, "no keychain access")
    }

    @Test func memoizingReaderAsksOncePerExpandedDir() async {
        let base = CountingConfigReader()
        let reader = MemoizingClaudeConfigReader(base, homeDirectory: URL(fileURLWithPath: "/Users/tester"))
        #expect(await reader.accountUUID(configDir: nil) == "uuid-default")
        #expect(await reader.accountUUID(configDir: nil) == "uuid-default")
        #expect(await reader.accountUUID(configDir: "~/work") == nil)
        #expect(await reader.accountUUID(configDir: "/Users/tester/work") == nil)  // a remembered nil
        #expect(base.calls.current == [nil, "/Users/tester/work"])
    }
}
