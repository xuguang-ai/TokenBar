import Foundation

public enum BackoffReason: String, Codable, Sendable {
    case unauthorized, rateLimited
}

public enum KeychainAccessState: String, Codable, Sendable {
    case ok, deniedOrPrompting
}

public struct Step2InFlight: Codable, Sendable, Equatable {
    public var pid: Int32
    public var startedAt: Date

    public init(pid: Int32, startedAt: Date) {
        self.pid = pid
        self.startedAt = startedAt
    }
}

/// Per-account runtime state shared by the App and the CLI (`state.json`, spec §5.8).
/// It holds no token-derived value other than `expiresAt`.
public struct AccountRuntimeState: Codable, Sendable, Equatable {
    public var backoffUntil: Date?
    public var backoffReason: BackoffReason?
    /// The `expiresAt` (ms since epoch) of the token that a 401/403 backoff is bound to.
    /// `nil` for per-account (429 / bare 403) backoff.
    public var backoffTokenExpiresAt: Double?
    public var lastStep2At: Date?
    public var step2InFlight: Step2InFlight?
    /// Step ② failed for the token with this `expiresAt`; don't retry automatically until it changes.
    public var step2FailedForTokenExpiresAt: Double?
    public var lastHTTPAt: Date?
    public var keychainAccess: KeychainAccessState
    /// Rate limits (429 / bare 403) in a row; the per-account backoff doubles with each. A 200 resets it.
    public var consecutiveRateLimits: Int
    /// The Retry-After seconds of the last rate limit (nil when absent). Diagnostic only.
    public var lastRetryAfterSeconds: Double?

    public init(
        backoffUntil: Date? = nil,
        backoffReason: BackoffReason? = nil,
        backoffTokenExpiresAt: Double? = nil,
        lastStep2At: Date? = nil,
        step2InFlight: Step2InFlight? = nil,
        step2FailedForTokenExpiresAt: Double? = nil,
        lastHTTPAt: Date? = nil,
        keychainAccess: KeychainAccessState = .ok,
        consecutiveRateLimits: Int = 0,
        lastRetryAfterSeconds: Double? = nil
    ) {
        self.backoffUntil = backoffUntil
        self.backoffReason = backoffReason
        self.backoffTokenExpiresAt = backoffTokenExpiresAt
        self.lastStep2At = lastStep2At
        self.step2InFlight = step2InFlight
        self.step2FailedForTokenExpiresAt = step2FailedForTokenExpiresAt
        self.lastHTTPAt = lastHTTPAt
        self.keychainAccess = keychainAccess
        self.consecutiveRateLimits = consecutiveRateLimits
        self.lastRetryAfterSeconds = lastRetryAfterSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case backoffUntil, backoffReason, backoffTokenExpiresAt, lastStep2At, step2InFlight
        case step2FailedForTokenExpiresAt, lastHTTPAt, keychainAccess, consecutiveRateLimits, lastRetryAfterSeconds
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backoffUntil = try c.decodeIfPresent(Date.self, forKey: .backoffUntil)
        backoffReason = try c.decodeIfPresent(BackoffReason.self, forKey: .backoffReason)
        backoffTokenExpiresAt = try c.decodeIfPresent(Double.self, forKey: .backoffTokenExpiresAt)
        lastStep2At = try c.decodeIfPresent(Date.self, forKey: .lastStep2At)
        step2InFlight = try c.decodeIfPresent(Step2InFlight.self, forKey: .step2InFlight)
        step2FailedForTokenExpiresAt = try c.decodeIfPresent(Double.self, forKey: .step2FailedForTokenExpiresAt)
        lastHTTPAt = try c.decodeIfPresent(Date.self, forKey: .lastHTTPAt)
        keychainAccess = try c.decodeIfPresent(KeychainAccessState.self, forKey: .keychainAccess) ?? .ok
        consecutiveRateLimits = try c.decodeIfPresent(Int.self, forKey: .consecutiveRateLimits) ?? 0
        lastRetryAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .lastRetryAfterSeconds)
    }
}

public protocol StateStoring: Sendable {
    func read(_ accountID: UUID) async -> AccountRuntimeState
    func readAll() async -> [UUID: AccountRuntimeState]
    /// Atomic read-modify-write. The file-backed store holds its flock for the whole closure.
    @discardableResult
    func update(_ accountID: UUID, _ body: @Sendable (inout AccountRuntimeState) -> Void) async -> AccountRuntimeState
}

/// Process-local store, used by tests and as a fallback when `state.json` is unavailable.
public actor InMemoryStateStore: StateStoring {
    private var states: [UUID: AccountRuntimeState]

    public init(_ initial: [UUID: AccountRuntimeState] = [:]) {
        states = initial
    }

    public func read(_ accountID: UUID) -> AccountRuntimeState {
        states[accountID] ?? AccountRuntimeState()
    }

    public func readAll() -> [UUID: AccountRuntimeState] {
        states
    }

    @discardableResult
    public func update(_ accountID: UUID, _ body: @Sendable (inout AccountRuntimeState) -> Void) -> AccountRuntimeState {
        var state = states[accountID] ?? AccountRuntimeState()
        body(&state)
        states[accountID] = state
        return state
    }
}
