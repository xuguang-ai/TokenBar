import Foundation

public enum RefreshTrigger: String, Codable, Sendable {
    case scheduled, manual, launch, wake, configChange
}

/// A provider result. `warning` is set when the data came from a fallback path because of an error,
/// e.g. cached usage shown while the keychain was denied (spec §8).
public struct ProviderOutcome: Sendable, Hashable {
    public var snapshot: UsageSnapshot
    public var warning: ProviderError?

    public init(snapshot: UsageSnapshot, warning: ProviderError? = nil) {
        self.snapshot = snapshot
        self.warning = warning
    }
}

/// One finished account refresh, emitted by `UsageAggregator` as soon as it completes (spec §5.8).
public struct AccountRefreshEvent: Sendable {
    public var accountID: UUID
    public var configFingerprint: Int
    public var trigger: RefreshTrigger
    public var result: Result<ProviderOutcome, ProviderError>
    public var finishedAt: Date

    public init(
        accountID: UUID,
        configFingerprint: Int,
        trigger: RefreshTrigger,
        result: Result<ProviderOutcome, ProviderError>,
        finishedAt: Date
    ) {
        self.accountID = accountID
        self.configFingerprint = configFingerprint
        self.trigger = trigger
        self.result = result
        self.finishedAt = finishedAt
    }
}

/// UI-facing state of one account (spec §5.1).
public struct AccountState: Sendable, Hashable {
    public var config: AccountConfig
    /// The last successful result.
    public var lastSnapshot: UsageSnapshot?
    /// Why the last attempt failed or fell back. `nil` after a clean success.
    public var lastError: ProviderError?
    public var lastAttemptAt: Date?
    public var isRefreshing: Bool

    public init(
        config: AccountConfig,
        lastSnapshot: UsageSnapshot? = nil,
        lastError: ProviderError? = nil,
        lastAttemptAt: Date? = nil,
        isRefreshing: Bool = false
    ) {
        self.config = config
        self.lastSnapshot = lastSnapshot
        self.lastError = lastError
        self.lastAttemptAt = lastAttemptAt
        self.isRefreshing = isRefreshing
    }

    public var pausedUntil: Date? { lastError?.pausedUntil }

    /// Applies a finished refresh.
    /// - A network failure that finishes before `wakeGraceUntil` is transient: if the account had no
    ///   error before, nothing changes (spec §5.3 step ①).
    /// - `.accountChanged` drops the old snapshot (spec §5.3 step 5).
    public mutating func apply(_ event: AccountRefreshEvent, wakeGraceUntil: Date?) {
        isRefreshing = false
        switch event.result {
        case .success(let outcome):
            lastAttemptAt = event.finishedAt
            lastSnapshot = outcome.snapshot
            lastError = outcome.warning
        case .failure(let error):
            if case .network = error, let grace = wakeGraceUntil, event.finishedAt <= grace, lastError == nil {
                return
            }
            lastAttemptAt = event.finishedAt
            if case .accountChanged = error {
                lastSnapshot = nil
            }
            lastError = error
        }
    }
}

/// What `SnapshotStore` persists per account (spec §5.8). Email is never included.
public struct StoredAccountState: Codable, Sendable, Hashable {
    public var lastSnapshot: UsageSnapshot?
    public var lastError: ProviderError?
    public var lastAttemptAt: Date?

    public init(lastSnapshot: UsageSnapshot? = nil, lastError: ProviderError? = nil, lastAttemptAt: Date? = nil) {
        self.lastSnapshot = lastSnapshot
        self.lastError = lastError
        self.lastAttemptAt = lastAttemptAt
    }

    public init(_ state: AccountState) {
        self.init(lastSnapshot: state.lastSnapshot, lastError: state.lastError, lastAttemptAt: state.lastAttemptAt)
    }
}
