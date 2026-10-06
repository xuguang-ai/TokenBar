import Foundation
import Testing
@testable import TokenBarCore

// UsageAggregator (plan Task 6, spec §5.8): merging, reruns, stale results, ordering and timeouts.

/// A provider whose calls stay suspended until the test resolves them.
private final class ControlledProvider: UsageProvider, @unchecked Sendable {
    struct Call: Sendable {
        var account: AccountConfig
        var context: RefreshContext
    }

    private struct Waiter {
        var accountID: UUID
        var continuation: CheckedContinuation<ProviderOutcome, any Error>
    }

    private struct State {
        var calls: [Call] = []
        var waiters: [Waiter] = []
    }

    private let state = Locked(State())

    var calls: [Call] { state.withLock { $0.calls } }
    var waitingCount: Int { state.withLock { $0.waiters.count } }

    func fetchUsage(for account: AccountConfig, settings: AppSettings, context: RefreshContext) async throws -> ProviderOutcome {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock {
                $0.calls.append(Call(account: account, context: context))
                $0.waiters.append(Waiter(accountID: account.id, continuation: continuation))
            }
        }
    }

    /// Resumes the oldest suspended call for `accountID`.
    func resolve(_ accountID: UUID, with result: Result<ProviderOutcome, any Error>) {
        let waiter: Waiter? = state.withLock {
            guard let index = $0.waiters.firstIndex(where: { $0.accountID == accountID }) else { return nil }
            return $0.waiters.remove(at: index)
        }
        waiter?.continuation.resume(with: result)
    }

    func succeed(_ accountID: UUID, at date: Date) {
        resolve(accountID, with: .success(makeOutcome(accountID, date)))
    }
}

/// A provider that suspends until its task is cancelled.
private struct HangingProvider: UsageProvider {
    func fetchUsage(for account: AccountConfig, settings: AppSettings, context: RefreshContext) async throws -> ProviderOutcome {
        try await suspendUntilCancelled()
        throw CancellationError()
    }
}

/// A provider that answers immediately with a fixed result.
private struct ImmediateProvider: UsageProvider {
    var error: (any Error)?
    var now: @Sendable () -> Date

    func fetchUsage(for account: AccountConfig, settings: AppSettings, context: RefreshContext) async throws -> ProviderOutcome {
        if let error { throw error }
        return makeOutcome(account.id, now())
    }
}

/// A provider that takes `duration` seconds of fake time before it answers.
private struct SlowProvider: UsageProvider {
    let clock: TestClock
    let duration: TimeInterval

    func fetchUsage(for account: AccountConfig, settings: AppSettings, context: RefreshContext) async throws -> ProviderOutcome {
        clock.advance(by: duration)
        return makeOutcome(account.id, clock.now)
    }
}

private struct SomeUnknownError: Error {}

private func makeOutcome(_ accountID: UUID, _ date: Date) -> ProviderOutcome {
    ProviderOutcome(snapshot: UsageSnapshot(
        accountID: accountID, fetchedAt: date, dataAsOf: date, source: .claudeAPI,
        identity: nil, windows: [], limitReached: false))
}

/// Suspends until the current task is cancelled, then throws `CancellationError`. Never uses real time.
private func suspendUntilCancelled() async throws {
    let box = Locked<CheckedContinuation<Void, Never>?>(nil)
    await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            box.withLock { $0 = continuation }
            if Task.isCancelled { box.withLock { $0.take() }?.resume() }
        }
    } onCancel: {
        box.withLock { $0.take() }?.resume()
    }
    throw CancellationError()
}

/// Yields until `condition` holds; fails the test if it never does.
private func waitUntil(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<20_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("condition never became true", sourceLocation: sourceLocation)
}

private func collect(_ stream: AsyncStream<AccountRefreshEvent>) async -> [AccountRefreshEvent] {
    var events: [AccountRefreshEvent] = []
    for await event in stream { events.append(event) }
    return events
}

@Suite("RefreshUsageAggregator")
struct RefreshUsageAggregatorTests {
    let harness: TestHarness
    let claude = AccountConfig(provider: .claude, displayName: "Claude")
    let claude2 = AccountConfig(provider: .claude, displayName: "Work", claudeConfigDir: "~/.claude-work")
    let codex = AccountConfig(provider: .codex, displayName: "Codex")

    init() throws {
        harness = try TestHarness()
    }

    /// Harness env whose safety-timer sleep never elapses on its own.
    var holdingEnv: CoreEnvironment {
        var env = harness.env
        env.sleep = { _ in try await suspendUntilCancelled() }
        return env
    }

    var settings: AppSettings { AppSettings(accounts: [claude, claude2, codex]) }

    func makeAggregator(_ provider: any UsageProvider, env: CoreEnvironment? = nil) -> UsageAggregator {
        UsageAggregator(providers: [.claude: provider, .codex: provider], env: env ?? holdingEnv)
    }

    @Test func manualJoinsRunningManual() async throws {
        let provider = ControlledProvider()
        let aggregator = makeAggregator(provider)
        let first = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .manual, allowClaudeCodeRefresh: true)
        let second = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .manual, allowClaudeCodeRefresh: true)
        #expect(first.started == [claude.id])
        #expect(second.started.isEmpty)
        #expect(second.merged == [claude.id])
        #expect(second.queued.isEmpty)

        await waitUntil { provider.waitingCount == 1 }
        provider.succeed(claude.id, at: harness.clock.now)
        let firstEvents = await collect(first.events)
        let secondEvents = await collect(second.events)
        #expect(firstEvents.map(\.accountID) == [claude.id])
        #expect(firstEvents.first?.trigger == .manual)
        #expect(secondEvents.isEmpty)
        #expect(provider.calls.count == 1)
    }

    @Test func scheduledJoinsRunningScheduledAndManual() async throws {
        let provider = ControlledProvider()
        let aggregator = makeAggregator(provider)
        _ = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .manual, allowClaudeCodeRefresh: true)
        let scheduled = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .scheduled, allowClaudeCodeRefresh: true)
        let wake = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .wake, allowClaudeCodeRefresh: true)
        #expect(scheduled.merged == [claude.id])
        #expect(wake.merged == [claude.id])
        await waitUntil { provider.waitingCount == 1 }
        #expect(provider.calls.count == 1)
        provider.succeed(claude.id, at: harness.clock.now)
    }

    @Test func manualDuringScheduledRunQueuesOneRerun() async throws {
        let provider = ControlledProvider()
        let aggregator = makeAggregator(provider)
        let scheduled = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .scheduled, allowClaudeCodeRefresh: true)
        let manual = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .manual, allowClaudeCodeRefresh: true)
        // Later requests coalesce into the pending rerun; the manual trigger is kept.
        let later = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .scheduled, allowClaudeCodeRefresh: true)
        #expect(manual.queued == [claude.id])
        #expect(manual.started.isEmpty)
        #expect(later.merged == [claude.id])

        await waitUntil { provider.waitingCount == 1 }
        provider.succeed(claude.id, at: harness.clock.now)
        let scheduledEvents = await collect(scheduled.events)
        #expect(scheduledEvents.map(\.trigger) == [.scheduled])

        await waitUntil { provider.waitingCount == 1 }
        #expect(provider.calls.map(\.context.trigger) == [.scheduled, .manual])
        provider.succeed(claude.id, at: harness.clock.now)
        let manualEvents = await collect(manual.events)
        #expect(manualEvents.map(\.trigger) == [.manual])
        #expect(await collect(later.events).isEmpty)
        #expect(provider.calls.count == 2)
    }

    @Test func configChangeQueuesRerunAndDropsStaleResult() async throws {
        let provider = ControlledProvider()
        let aggregator = makeAggregator(provider)
        let old = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .scheduled, allowClaudeCodeRefresh: true)

        var changed = claude
        changed.claudeConfigDir = "~/.claude-other"
        let changedSettings = AppSettings(accounts: [changed, claude2, codex])
        let new = await aggregator.refresh(accounts: [changed], settings: changedSettings, trigger: .configChange, allowClaudeCodeRefresh: true)
        #expect(new.queued == [changed.id])

        await waitUntil { provider.waitingCount == 1 }
        provider.succeed(claude.id, at: harness.clock.now)
        #expect(await collect(old.events).isEmpty)

        await waitUntil { provider.waitingCount == 1 }
        #expect(provider.calls.last?.account.claudeConfigDir == "~/.claude-other")
        provider.succeed(claude.id, at: harness.clock.now)
        let events = await collect(new.events)
        #expect(events.count == 1)
        #expect(events.first?.configFingerprint == UsageAggregator.fingerprint(for: changed, settings: changedSettings))
        #expect(events.first?.trigger == .configChange)
    }

    @Test func settingsFieldsChangeTheFingerprint() {
        let base = UsageAggregator.fingerprint(for: claude, settings: settings)
        #expect(base == UsageAggregator.fingerprint(for: claude, settings: settings))
        var other = settings
        other.claudeBinaryOverride = "/opt/claude"
        #expect(base != UsageAggregator.fingerprint(for: claude, settings: other))
        other = settings
        other.subprocessProxy = "http://proxy.example:8080"
        #expect(base != UsageAggregator.fingerprint(for: claude, settings: other))
        other = settings
        other.displayMode = .used
        other.refreshIntervalMinutes = 15
        #expect(base == UsageAggregator.fingerprint(for: claude, settings: other))
    }

    @Test func concurrentCallsMakeOneProviderCall() async throws {
        let provider = ControlledProvider()
        let aggregator = makeAggregator(provider)
        let settings = self.settings
        let claude = self.claude
        async let a = aggregator.refresh(accounts: [claude], settings: settings, trigger: .scheduled, allowClaudeCodeRefresh: true)
        async let b = aggregator.refresh(accounts: [claude], settings: settings, trigger: .scheduled, allowClaudeCodeRefresh: true)
        let (first, second) = await (a, b)
        #expect(first.started.count + second.started.count == 1)
        #expect(first.merged.count + second.merged.count == 1)
        await waitUntil { provider.waitingCount == 1 }
        provider.succeed(claude.id, at: harness.clock.now)
        let events = await collect(first.events) + collect(second.events)
        #expect(events.count == 1)
        #expect(provider.calls.count == 1)
    }

    @Test func eventsArriveInCompletionOrder() async throws {
        let provider = ControlledProvider()
        let aggregator = makeAggregator(provider)
        let batch = await aggregator.refresh(
            accounts: [claude, claude2, codex], settings: settings, trigger: .launch, allowClaudeCodeRefresh: true)
        #expect(batch.started == [claude.id, claude2.id, codex.id])
        await waitUntil { provider.waitingCount == 3 }

        var iterator = batch.events.makeAsyncIterator()
        provider.succeed(codex.id, at: harness.clock.now)
        #expect(await iterator.next()?.accountID == codex.id)
        provider.resolve(claude.id, with: .failure(ProviderError.keychainLocked))
        let second = await iterator.next()
        #expect(second?.accountID == claude.id)
        #expect(second?.result == .failure(.keychainLocked))
        provider.succeed(claude2.id, at: harness.clock.now)
        #expect(await iterator.next()?.accountID == claude2.id)
        #expect(await iterator.next() == nil)
    }

    @Test func contextCarriesDeadlineIdentityAndGrace() async throws {
        let provider = ControlledProvider()
        let aggregator = makeAggregator(provider)
        let start = harness.clock.now
        let identity = AccountIdentity(accountUuid: "uuid-1", plan: "Max")
        let grace = start.addingTimeInterval(30)
        _ = await aggregator.refresh(
            accounts: [claude, codex], settings: settings, trigger: .wake, allowClaudeCodeRefresh: false,
            previousIdentities: [claude.id: identity], wakeGraceUntil: grace)
        await waitUntil { provider.waitingCount == 2 }
        let byAccount = Dictionary(uniqueKeysWithValues: provider.calls.map { ($0.account.id, $0.context) })
        let claudeContext = try #require(byAccount[claude.id])
        #expect(claudeContext.deadline == start.addingTimeInterval(120))
        #expect(claudeContext.trigger == .wake)
        #expect(claudeContext.allowClaudeCodeRefresh == false)
        #expect(claudeContext.previousIdentity == identity)
        #expect(claudeContext.wakeGraceUntil == grace)
        #expect(byAccount[codex.id]?.previousIdentity == nil)
        provider.succeed(claude.id, at: start)
        provider.succeed(codex.id, at: start)
    }

    @Test func safetyTimeoutMapsToTimeout() async throws {
        // TestClock's sleep returns at once and advances the clock, so the 130 s safety timer fires first.
        let aggregator = UsageAggregator(providers: [.claude: HangingProvider()], env: harness.env)
        let start = harness.clock.now
        let batch = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .manual, allowClaudeCodeRefresh: true)
        let events = await collect(batch.events)
        #expect(events.count == 1)
        #expect(events.first?.result == .failure(.timeout))
        #expect(events.first?.finishedAt == start.addingTimeInterval(130))
        #expect(harness.clock.sleeps == [.seconds(130)])
        #expect(await aggregator.inFlightAccountIDs.isEmpty)
    }

    @Test func unknownErrorsMapToUnexpectedProtocolError() async throws {
        let now = harness.clock
        let aggregator = makeAggregator(ImmediateProvider(error: SomeUnknownError(), now: { now.now }))
        let batch = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .manual, allowClaudeCodeRefresh: true)
        #expect(await collect(batch.events).first?.result == .failure(.protocolError(.unexpected)))

        let typed = makeAggregator(ImmediateProvider(error: ProviderError.notACodexProfile, now: { now.now }))
        let other = await typed.refresh(accounts: [codex], settings: settings, trigger: .manual, allowClaudeCodeRefresh: true)
        #expect(await collect(other.events).first?.result == .failure(.notACodexProfile))
    }

    @Test func nonManualTriggersWithin60sOfSuccessAreDropped() async throws {
        let clock = harness.clock
        let aggregator = makeAggregator(ImmediateProvider(now: { clock.now }))
        let first = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .launch, allowClaudeCodeRefresh: true)
        #expect(await collect(first.events).count == 1)

        clock.advance(by: 30)
        let dropped = await aggregator.refresh(accounts: [claude, codex], settings: settings, trigger: .scheduled, allowClaudeCodeRefresh: true)
        #expect(dropped.skipped == [claude.id])
        #expect(dropped.started == [codex.id])
        #expect(await collect(dropped.events).map(\.accountID) == [codex.id])

        let manual = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .manual, allowClaudeCodeRefresh: true)
        #expect(manual.started == [claude.id])
        #expect(await collect(manual.events).count == 1)

        // A different configuration is not covered by the earlier success.
        var changed = settings
        changed.subprocessProxy = "http://proxy.example:8080"
        let config = await aggregator.refresh(accounts: [claude], settings: changed, trigger: .configChange, allowClaudeCodeRefresh: true)
        #expect(config.started == [claude.id])
        #expect(await collect(config.events).count == 1)

        clock.advance(by: 61)
        let later = await aggregator.refresh(accounts: [claude], settings: changed, trigger: .scheduled, allowClaudeCodeRefresh: true)
        #expect(later.started == [claude.id])
        #expect(await collect(later.events).count == 1)
    }

    @Test func oneMinuteCadenceIsNotDroppedBySlowRefreshes() async throws {
        let clock = harness.clock
        let aggregator = makeAggregator(SlowProvider(clock: clock, duration: 2))
        let start = clock.now
        let first = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .scheduled, allowClaudeCodeRefresh: true)
        #expect(await collect(first.events).count == 1)

        // Within the cooldown, measured from the start of the last success.
        clock.set(start.addingTimeInterval(30))
        let early = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .scheduled, allowClaudeCodeRefresh: true)
        #expect(early.skipped == [claude.id])

        // The next tick of a 1-minute cadence runs although the last refresh took 2 s.
        clock.set(start.addingTimeInterval(60))
        let next = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .scheduled, allowClaudeCodeRefresh: true)
        #expect(next.started == [claude.id])
        #expect(await collect(next.events).count == 1)

        // A tick a little early (scheduler jitter) still runs.
        clock.set(start.addingTimeInterval(119))
        let jittered = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .scheduled, allowClaudeCodeRefresh: true)
        #expect(jittered.started == [claude.id])
        _ = await collect(jittered.events)
    }

    @Test func failuresDoNotStartTheCooldown() async throws {
        let clock = harness.clock
        let aggregator = makeAggregator(ImmediateProvider(error: ProviderError.network(urlErrorCode: -1009), now: { clock.now }))
        let first = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .scheduled, allowClaudeCodeRefresh: true)
        #expect(await collect(first.events).first?.result == .failure(.network(urlErrorCode: -1009)))
        clock.advance(by: 5)
        let again = await aggregator.refresh(accounts: [claude], settings: settings, trigger: .scheduled, allowClaudeCodeRefresh: true)
        #expect(again.started == [claude.id])
        _ = await collect(again.events)
    }

    @Test func accountsWithoutAProviderAreSkipped() async throws {
        let clock = harness.clock
        let aggregator = UsageAggregator(providers: [.codex: ImmediateProvider(now: { clock.now })], env: holdingEnv)
        let batch = await aggregator.refresh(accounts: [claude, codex], settings: settings, trigger: .manual, allowClaudeCodeRefresh: true)
        #expect(batch.skipped == [claude.id])
        #expect(await collect(batch.events).map(\.accountID) == [codex.id])
    }
}
