import Foundation

/// What one `UsageAggregator.refresh` call did with each requested account.
///
/// `events` yields one `AccountRefreshEvent` per account in `started` and per account in `queued`
/// (once its rerun finishes), in completion order, then finishes. A result whose configuration
/// fingerprint went stale while it ran is dropped and not yielded. Accounts in `merged` are served by
/// a run or rerun another call owns, so their result arrives on that call's stream. Accounts in
/// `skipped` were not refreshed at all.
public struct RefreshBatch: Sendable {
    /// A provider run started now. The App marks only these accounts as refreshing.
    public var started: Set<UUID>
    /// A run was in flight and could not absorb this request; one rerun follows it (spec §5.8).
    public var queued: Set<UUID>
    /// Joined the in-flight run, or coalesced into an already pending rerun.
    public var merged: Set<UUID>
    /// Dropped: a non-manual trigger within 60 s of a success, or no provider for the account's kind.
    public var skipped: Set<UUID>
    public var events: AsyncStream<AccountRefreshEvent>

    public init(
        started: Set<UUID>, queued: Set<UUID>, merged: Set<UUID>, skipped: Set<UUID>,
        events: AsyncStream<AccountRefreshEvent>
    ) {
        self.started = started
        self.queued = queued
        self.merged = merged
        self.skipped = skipped
        self.events = events
    }
}

/// Runs providers for accounts and merges overlapping refresh requests (spec §5.8).
///
/// Per account there is at most one provider run in flight plus at most one pending rerun:
/// - a request joins the in-flight run when the configuration fingerprint matches and either the
///   running trigger is `.manual` or the new trigger is not `.manual`;
/// - otherwise it becomes the pending rerun, which starts once the current run ends; requests that
///   arrive while a rerun is pending coalesce into it (`.manual` wins, other inputs take the latest);
/// - a result whose fingerprint no longer matches the account's latest requested fingerprint is dropped;
/// - a non-manual request within 60 s of a successful refresh with the same fingerprint is dropped,
///   so the App and the CLI behave the same.
public actor UsageAggregator {
    /// Non-manual requests this soon after a success of the same configuration are dropped.
    public static let successCooldown: TimeInterval = 60

    private struct Request {
        var account: AccountConfig
        var settings: AppSettings
        var trigger: RefreshTrigger
        var allowClaudeCodeRefresh: Bool
        var previousIdentity: AccountIdentity?
        var wakeGraceUntil: Date?
        var fingerprint: Int
    }

    private struct Run {
        var id: UInt64
        var fingerprint: Int
        var trigger: RefreshTrigger
        /// The batch whose stream receives this run's event.
        var owner: UInt64
        var task: Task<Void, Never>?
    }

    private struct Pending {
        var request: Request
        var owner: UInt64
    }

    private struct Subscriber {
        var continuation: AsyncStream<AccountRefreshEvent>.Continuation
        var remaining: Int
    }

    private let providers: [ProviderKind: any UsageProvider]
    private let env: CoreEnvironment
    private let providerDeadline: Duration
    private let safetyTimeout: Duration

    private var inFlight: [UUID: Run] = [:]
    private var pendingRerun: [UUID: Pending] = [:]
    private var latestFingerprint: [UUID: Int] = [:]
    private var lastSuccess: [UUID: (at: Date, fingerprint: Int)] = [:]
    private var subscribers: [UInt64: Subscriber] = [:]
    private var nextID: UInt64 = 0

    public init(
        providers: [ProviderKind: any UsageProvider],
        env: CoreEnvironment,
        providerDeadline: Duration = .seconds(120),
        safetyTimeout: Duration = .seconds(130)
    ) {
        self.providers = providers
        self.env = env
        self.providerDeadline = providerDeadline
        self.safetyTimeout = safetyTimeout
    }

    /// Hash of the account plus the settings fields that change what a provider does. Stable within
    /// one process only (it uses `Hasher`), so never persist it.
    public static func fingerprint(for account: AccountConfig, settings: AppSettings) -> Int {
        var hasher = Hasher()
        hasher.combine(account)
        hasher.combine(settings.allowClaudeCodeRefresh)
        hasher.combine(settings.subprocessProxy)
        switch account.provider {
        case .claude: hasher.combine(settings.claudeBinaryOverride)
        case .codex: hasher.combine(settings.codexBinaryOverride)
        }
        return hasher.finalize()
    }

    /// Accounts with a provider run in flight.
    public var inFlightAccountIDs: Set<UUID> { Set(inFlight.keys) }

    /// Requests a refresh of `accounts`. Synchronous inside the actor, so every in-flight and pending
    /// entry is recorded before anything is awaited.
    /// - Parameters:
    ///   - allowClaudeCodeRefresh: whether step ② may run for this caller (`RefreshContext`).
    ///   - previousIdentities: identity from each account's last good snapshot.
    ///   - wakeGraceUntil: passed through to `RefreshContext.wakeGraceUntil`.
    public func refresh(
        accounts: [AccountConfig],
        settings: AppSettings,
        trigger: RefreshTrigger,
        allowClaudeCodeRefresh: Bool,
        previousIdentities: [UUID: AccountIdentity] = [:],
        wakeGraceUntil: Date? = nil
    ) -> RefreshBatch {
        let batchID = makeID()
        let (stream, continuation) = AsyncStream.makeStream(of: AccountRefreshEvent.self)
        var started = Set<UUID>(), queued = Set<UUID>(), merged = Set<UUID>(), skipped = Set<UUID>()
        var owned = 0
        var seen = Set<UUID>()
        let now = env.now()

        for account in accounts where seen.insert(account.id).inserted {
            let id = account.id
            let request = Request(
                account: account,
                settings: settings,
                trigger: trigger,
                allowClaudeCodeRefresh: allowClaudeCodeRefresh,
                previousIdentity: previousIdentities[id],
                wakeGraceUntil: wakeGraceUntil,
                fingerprint: Self.fingerprint(for: account, settings: settings))

            if var pending = pendingRerun[id] {
                let keptTrigger: RefreshTrigger = pending.request.trigger == .manual ? .manual : trigger
                pending.request = request
                pending.request.trigger = keptTrigger
                pendingRerun[id] = pending
                latestFingerprint[id] = request.fingerprint
                merged.insert(id)
                continue
            }
            if let run = inFlight[id] {
                latestFingerprint[id] = request.fingerprint
                if run.fingerprint == request.fingerprint, run.trigger == .manual || trigger != .manual {
                    merged.insert(id)
                } else {
                    pendingRerun[id] = Pending(request: request, owner: batchID)
                    owned += 1
                    queued.insert(id)
                }
                continue
            }
            guard providers[account.provider] != nil else {
                skipped.insert(id)
                continue
            }
            if trigger != .manual, let last = lastSuccess[id], last.fingerprint == request.fingerprint,
               now.timeIntervalSince(last.at) < Self.successCooldown {
                skipped.insert(id)
                continue
            }
            latestFingerprint[id] = request.fingerprint
            startRun(request, owner: batchID)
            owned += 1
            started.insert(id)
        }

        if owned == 0 {
            continuation.finish()
        } else {
            subscribers[batchID] = Subscriber(continuation: continuation, remaining: owned)
        }
        return RefreshBatch(started: started, queued: queued, merged: merged, skipped: skipped, events: stream)
    }

    // MARK: - Runs

    private func makeID() -> UInt64 {
        nextID &+= 1
        return nextID
    }

    /// Records the run synchronously; the task can only report back once the caller leaves the actor.
    private func startRun(_ request: Request, owner: UInt64) {
        let runID = makeID()
        let accountID = request.account.id
        let context = RefreshContext(
            trigger: request.trigger,
            deadline: env.now().addingTimeInterval(providerDeadline.timeInterval),
            allowClaudeCodeRefresh: request.allowClaudeCodeRefresh,
            previousIdentity: request.previousIdentity,
            wakeGraceUntil: request.wakeGraceUntil)
        let provider = providers[request.account.provider]
        let account = request.account
        let settings = request.settings
        let sleep = env.sleep
        let safetyTimeout = safetyTimeout
        let task = Task {
            let result = await Self.fetch(
                provider: provider, account: account, settings: settings, context: context,
                sleep: sleep, safetyTimeout: safetyTimeout)
            self.complete(accountID: accountID, runID: runID, result: result)
        }
        inFlight[accountID] = Run(
            id: runID, fingerprint: request.fingerprint, trigger: request.trigger, owner: owner, task: task)
    }

    private func complete(accountID: UUID, runID: UInt64, result: Result<ProviderOutcome, ProviderError>) {
        guard let run = inFlight[accountID], run.id == runID else { return }
        inFlight[accountID] = nil
        let finishedAt = env.now()
        if run.fingerprint == latestFingerprint[accountID] {
            if case .success = result {
                lastSuccess[accountID] = (finishedAt, run.fingerprint)
            }
            let event = AccountRefreshEvent(
                accountID: accountID, configFingerprint: run.fingerprint, trigger: run.trigger,
                result: result, finishedAt: finishedAt)
            settle(owner: run.owner, event: event)
        } else {
            settle(owner: run.owner, event: nil)
        }
        if let pending = pendingRerun.removeValue(forKey: accountID) {
            startRun(pending.request, owner: pending.owner)
        }
    }

    private func settle(owner: UInt64, event: AccountRefreshEvent?) {
        guard var subscriber = subscribers[owner] else { return }
        if let event { subscriber.continuation.yield(event) }
        subscriber.remaining -= 1
        if subscriber.remaining <= 0 {
            subscriber.continuation.finish()
            subscribers[owner] = nil
        } else {
            subscribers[owner] = subscriber
        }
    }

    /// Runs the provider, racing it against the safety timeout. The race does not wait for a provider
    /// that ignores cancellation: whichever side finishes first decides the result.
    private nonisolated static func fetch(
        provider: (any UsageProvider)?,
        account: AccountConfig,
        settings: AppSettings,
        context: RefreshContext,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        safetyTimeout: Duration
    ) async -> Result<ProviderOutcome, ProviderError> {
        guard let provider else { return .failure(.protocolError(.unexpected)) }
        let gate = RefreshFirstResultGate()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            let work = Task {
                let result: Result<ProviderOutcome, ProviderError>
                do {
                    result = .success(try await provider.fetchUsage(for: account, settings: settings, context: context))
                } catch let error as ProviderError {
                    result = .failure(error)
                } catch is CancellationError {
                    result = .failure(.timeout)
                } catch {
                    result = .failure(.protocolError(.unexpected))
                }
                gate.resolve(result)
            }
            let timer = Task {
                do { try await sleep(safetyTimeout) } catch { return }
                gate.resolve(.failure(.timeout))
            }
            gate.attach([work, timer])
        }
    }
}

/// Resumes a continuation with the first result only, then cancels the racing tasks.
private final class RefreshFirstResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<ProviderOutcome, ProviderError>, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var resolved = false

    func install(_ continuation: CheckedContinuation<Result<ProviderOutcome, ProviderError>, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func attach(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        let done = resolved
        if !done { self.tasks = tasks }
        lock.unlock()
        if done { tasks.forEach { $0.cancel() } }
    }

    func resolve(_ result: Result<ProviderOutcome, ProviderError>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        let continuation = self.continuation
        let tasks = self.tasks
        self.continuation = nil
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: result)
    }
}
