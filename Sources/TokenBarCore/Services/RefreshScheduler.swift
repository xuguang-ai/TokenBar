import Foundation

/// Decides when refreshes happen (spec §5.8, §6.1). The App forwards launch, NSWorkspace sleep/wake,
/// settings changes and button presses; the scheduler calls `onRefresh` with the trigger and the
/// provider kinds to refresh. Every wait goes through `env.sleep`, so tests drive it with `TestClock`.
///
/// - Each provider kind has its own interval: Claude uses `refreshIntervalMinutes`, Codex
///   `max(refreshIntervalMinutes, 5)` (`AppSettings.refreshIntervalMinutes(for:)`). One timer loop
///   tracks the next due time of every kind and fires the kinds that are due together.
/// - `start()` fires `.launch` for every kind, then starts the loops from that moment.
/// - `willSleep()` cancels the loops; `didWake()` waits `wakeDelay` (10 s), fires one `.wake` for every
///   kind, then restarts the loops from that moment. A `didWake()` without a preceding `willSleep()`
///   is ignored, so duplicate wake notifications cause one wake refresh.
/// - Changing the refresh interval restarts the loops from the moment of the change.
/// - The loop awaits `onRefresh` before scheduling the next tick. A cancelled loop (sleep, interval
///   change, stop) does not cancel a handler that is already running.
///
/// The "drop non-manual triggers within 60 s of a success" rule lives in `UsageAggregator`.
public actor RefreshScheduler {
    public typealias Handler = @Sendable (RefreshTrigger, Set<ProviderKind>) async -> Void

    public enum Phase: Sendable, Equatable {
        /// Not started, or stopped.
        case stopped
        /// Launch or wake refresh done or in progress; the interval loops are running.
        case running
        /// Between `willSleep()` and `didWake()`.
        case asleep
        /// Waiting `wakeDelay` after `didWake()`.
        case waking
    }

    /// Small slack so floating-point clock arithmetic never misses a due time.
    private static let dueTolerance: TimeInterval = 0.001

    private let env: CoreEnvironment
    private let wakeDelay: Duration
    private let onRefresh: Handler
    private var settings: AppSettings
    private var activeTask: Task<Void, Never>?

    public private(set) var phase: Phase = .stopped

    public init(
        env: CoreEnvironment,
        settings: AppSettings,
        wakeDelay: Duration = .seconds(10),
        onRefresh: @escaping Handler
    ) {
        self.env = env
        self.settings = settings
        self.wakeDelay = wakeDelay
        self.onRefresh = onRefresh
    }

    /// Fires `.launch` for every kind, then starts the interval loops. Call after the App has loaded
    /// SnapshotStore so the UI already shows data. Ignored unless stopped.
    public func start() {
        guard phase == .stopped else { return }
        phase = .running
        activeTask = Task {
            await self.fire(.launch, Set(ProviderKind.allCases))
            guard !Task.isCancelled else { return }
            await self.runLoop()
        }
    }

    /// Cancels every pending wait and loop.
    public func stop() {
        activeTask?.cancel()
        phase = .stopped
    }

    /// The system is going to sleep: cancel the loops.
    public func willSleep() {
        guard phase != .stopped else { return }
        activeTask?.cancel()
        phase = .asleep
    }

    /// The system woke: wait `wakeDelay`, fire one `.wake`, then restart the loops from that moment.
    public func didWake() {
        guard phase == .asleep else { return }
        phase = .waking
        let delay = wakeDelay
        activeTask = Task {
            do { try await self.env.sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            self.phase = .running
            await self.fire(.wake, Set(ProviderKind.allCases))
            guard !Task.isCancelled else { return }
            await self.runLoop()
        }
    }

    /// Applies new settings. A changed refresh interval restarts the running loops from now; a wake in
    /// progress picks up the new interval when it starts its loops.
    public func updateSettings(_ newSettings: AppSettings) {
        let intervalChanged = ProviderKind.allCases.contains {
            newSettings.refreshIntervalMinutes(for: $0) != settings.refreshIntervalMinutes(for: $0)
        }
        settings = newSettings
        guard intervalChanged, phase == .running else { return }
        activeTask?.cancel()
        activeTask = Task { await self.runLoop() }
    }

    /// Fires `trigger` (e.g. `.manual`, `.configChange`) for every kind now. Does not move the loops.
    public func requestRefresh(_ trigger: RefreshTrigger) async {
        await fire(trigger, Set(ProviderKind.allCases))
    }

    /// The interval in seconds currently used for `kind`.
    public func interval(for kind: ProviderKind) -> TimeInterval {
        TimeInterval(settings.refreshIntervalMinutes(for: kind) * 60)
    }

    // MARK: - Internals

    /// Runs the handler outside the loop task so cancelling the loop never cancels a refresh.
    private func fire(_ trigger: RefreshTrigger, _ kinds: Set<ProviderKind>) async {
        let handler = onRefresh
        await Task { await handler(trigger, kinds) }.value
    }

    private func runLoop() async {
        let start = env.now()
        var nextDue: [ProviderKind: Date] = [:]
        for kind in ProviderKind.allCases {
            nextDue[kind] = start.addingTimeInterval(interval(for: kind))
        }
        while !Task.isCancelled {
            guard let soonest = nextDue.values.min() else { return }
            let delay = soonest.timeIntervalSince(env.now())
            if delay > Self.dueTolerance {
                do { try await env.sleep(.seconds(delay)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let now = env.now().addingTimeInterval(Self.dueTolerance)
            let due = Set(nextDue.filter { $0.value <= now }.keys)
            guard !due.isEmpty else { continue }
            await fire(.scheduled, due)
            guard !Task.isCancelled else { return }
            let after = env.now()
            for kind in due {
                let next = (nextDue[kind] ?? after).addingTimeInterval(interval(for: kind))
                nextDue[kind] = max(next, after)
            }
        }
    }

    /// Waits until the current loop or wake task has ended (tests only).
    func waitUntilIdleForTesting() async {
        while let task = activeTask {
            await task.value
            if task == activeTask { return }
        }
    }
}
