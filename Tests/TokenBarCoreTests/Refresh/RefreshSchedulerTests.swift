import Foundation
import Testing
@testable import TokenBarCore

// RefreshScheduler (plan Task 6, spec §5.8, §6.1). TestClock's sleep returns at once and advances the
// clock, so the timer loop runs instantly; the handler stops it after a fixed number of calls.

@Suite("RefreshScheduler")
struct RefreshSchedulerTests {
    struct Record: Equatable, CustomStringConvertible {
        var trigger: RefreshTrigger
        var kinds: Set<ProviderKind>
        /// Seconds since the test started.
        var at: TimeInterval

        var description: String { "\(trigger)\(kinds.map(\.rawValue).sorted())@\(at)" }
    }

    typealias Action = @Sendable (RefreshScheduler) async -> Void

    /// Records every handler call and runs `actions[n]` on the n-th call (1-based).
    final class Probe: @unchecked Sendable {
        let clock: TestClock
        let start: Date
        private let recorded = Locked<[Record]>([])
        private let schedulerBox = Locked<RefreshScheduler?>(nil)
        private let actions: [Int: Action]

        init(clock: TestClock, actions: [Int: Action]) {
            self.clock = clock
            self.start = clock.now
            self.actions = actions
        }

        var records: [Record] { recorded.current }

        func makeScheduler(env: CoreEnvironment, settings: AppSettings) -> RefreshScheduler {
            let scheduler = RefreshScheduler(env: env, settings: settings) { [self] trigger, kinds in
                await self.handle(trigger, kinds)
            }
            schedulerBox.withLock { $0 = scheduler }
            return scheduler
        }

        private func handle(_ trigger: RefreshTrigger, _ kinds: Set<ProviderKind>) async {
            let count = recorded.withLock {
                $0.append(Record(trigger: trigger, kinds: kinds, at: clock.now.timeIntervalSince(start)))
                return $0.count
            }
            // Safety net: never let a broken loop spin forever.
            let action = actions[count] ?? (count >= 50 ? { await $0.stop() } : nil)
            if let action, let scheduler = schedulerBox.current {
                await action(scheduler)
            }
        }
    }

    let harness: TestHarness
    static let both: Set<ProviderKind> = [.claude, .codex]

    init() throws {
        harness = try TestHarness()
    }

    func settings(interval: Int) -> AppSettings {
        AppSettings(accounts: [], refreshIntervalMinutes: interval)
    }

    @Test func launchFiresFirstThenPerKindIntervals() async {
        let probe = Probe(clock: harness.clock, actions: [6: { await $0.stop() }])
        let scheduler = probe.makeScheduler(env: harness.env, settings: settings(interval: 1))
        await scheduler.start()
        await scheduler.waitUntilIdleForTesting()
        #expect(probe.records == [
            Record(trigger: .launch, kinds: Self.both, at: 0),
            Record(trigger: .scheduled, kinds: [.claude], at: 60),
            Record(trigger: .scheduled, kinds: [.claude], at: 120),
            Record(trigger: .scheduled, kinds: [.claude], at: 180),
            Record(trigger: .scheduled, kinds: [.claude], at: 240),
            Record(trigger: .scheduled, kinds: Self.both, at: 300),
        ])
        #expect(await scheduler.phase == .stopped)
    }

    @Test func codexNeverPollsFasterThanFiveMinutes() async {
        let probe = Probe(clock: harness.clock, actions: [5: { await $0.stop() }])
        let scheduler = probe.makeScheduler(env: harness.env, settings: settings(interval: 2))
        #expect(await scheduler.interval(for: .claude) == 120)
        #expect(await scheduler.interval(for: .codex) == 300)
        await scheduler.start()
        await scheduler.waitUntilIdleForTesting()
        #expect(probe.records == [
            Record(trigger: .launch, kinds: Self.both, at: 0),
            Record(trigger: .scheduled, kinds: [.claude], at: 120),
            Record(trigger: .scheduled, kinds: [.claude], at: 240),
            Record(trigger: .scheduled, kinds: [.codex], at: 300),
            Record(trigger: .scheduled, kinds: [.claude], at: 360),
        ])
    }

    @Test func intervalChangeRestartsLoopsFromThatMoment() async {
        let newSettings = settings(interval: 10)
        let probe = Probe(clock: harness.clock, actions: [
            3: { await $0.updateSettings(newSettings) },
            4: { await $0.stop() },
        ])
        let scheduler = probe.makeScheduler(env: harness.env, settings: settings(interval: 1))
        await scheduler.start()
        await scheduler.waitUntilIdleForTesting()
        #expect(probe.records == [
            Record(trigger: .launch, kinds: Self.both, at: 0),
            Record(trigger: .scheduled, kinds: [.claude], at: 60),
            Record(trigger: .scheduled, kinds: [.claude], at: 120),
            Record(trigger: .scheduled, kinds: Self.both, at: 720),
        ])
    }

    @Test func unchangedIntervalKeepsTheLoop() async {
        var other = settings(interval: 5)
        other.displayMode = .used
        let sameInterval = other
        let probe = Probe(clock: harness.clock, actions: [
            2: { await $0.updateSettings(sameInterval) },
            3: { await $0.stop() },
        ])
        let scheduler = probe.makeScheduler(env: harness.env, settings: settings(interval: 5))
        await scheduler.start()
        await scheduler.waitUntilIdleForTesting()
        #expect(probe.records.map(\.at) == [0, 300, 600])
    }

    @Test func sleepAndWakeProduceExactlyOneWakeRefresh() async {
        let probe = Probe(clock: harness.clock, actions: [
            2: { await $0.willSleep() },
            4: { await $0.stop() },
        ])
        let scheduler = probe.makeScheduler(env: harness.env, settings: settings(interval: 5))
        await scheduler.start()
        await scheduler.waitUntilIdleForTesting()
        #expect(await scheduler.phase == .asleep)
        #expect(probe.records.count == 2)

        // Asleep for an hour: nothing fires.
        harness.clock.advance(by: 3600)
        await scheduler.didWake()
        await scheduler.didWake()  // duplicate notification
        await scheduler.waitUntilIdleForTesting()

        #expect(probe.records == [
            Record(trigger: .launch, kinds: Self.both, at: 0),
            Record(trigger: .scheduled, kinds: Self.both, at: 300),
            Record(trigger: .wake, kinds: Self.both, at: 3910),
            Record(trigger: .scheduled, kinds: Self.both, at: 4210),
        ])
        #expect(probe.records.filter { $0.trigger == .wake }.count == 1)
        #expect(harness.clock.sleeps.contains(.seconds(10)))
    }

    @Test func wakeWithoutSleepOrStartIsIgnored() async {
        let probe = Probe(clock: harness.clock, actions: [:])
        let scheduler = probe.makeScheduler(env: harness.env, settings: settings(interval: 5))
        await scheduler.didWake()
        await scheduler.willSleep()
        await scheduler.didWake()
        await scheduler.waitUntilIdleForTesting()
        #expect(probe.records.isEmpty)
        #expect(await scheduler.phase == .stopped)
    }

    @Test func requestRefreshFiresForEveryKindWithoutMovingTheLoop() async {
        let probe = Probe(clock: harness.clock, actions: [:])
        let scheduler = probe.makeScheduler(env: harness.env, settings: settings(interval: 5))
        await scheduler.requestRefresh(.manual)
        await scheduler.requestRefresh(.configChange)
        #expect(probe.records == [
            Record(trigger: .manual, kinds: Self.both, at: 0),
            Record(trigger: .configChange, kinds: Self.both, at: 0),
        ])
        #expect(await scheduler.phase == .stopped)
        #expect(harness.clock.sleeps.isEmpty)
    }
}
