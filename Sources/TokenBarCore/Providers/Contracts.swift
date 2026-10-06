import Foundation

/// Per-call inputs a provider needs besides the account and settings (spec §5.2, §5.3).
public struct RefreshContext: Sendable {
    public var trigger: RefreshTrigger
    /// The provider must return by this time, falling back to cached data if needed (spec §5.3 time budget).
    public var deadline: Date
    /// Whether step ② may run at all for this caller. The CLI allows it only with --allow-claude-refresh (spec §7).
    public var allowClaudeCodeRefresh: Bool
    /// Identity from the last good snapshot, used to detect account changes (spec §5.3 step 5).
    public var previousIdentity: AccountIdentity?
    /// Network failures that finish before this time are transient (wake grace, spec §5.3 step ①).
    public var wakeGraceUntil: Date?

    public init(
        trigger: RefreshTrigger,
        deadline: Date,
        allowClaudeCodeRefresh: Bool,
        previousIdentity: AccountIdentity? = nil,
        wakeGraceUntil: Date? = nil
    ) {
        self.trigger = trigger
        self.deadline = deadline
        self.allowClaudeCodeRefresh = allowClaudeCodeRefresh
        self.previousIdentity = previousIdentity
        self.wakeGraceUntil = wakeGraceUntil
    }

    public var isManual: Bool { trigger == .manual }
}

public protocol UsageProvider: Sendable {
    /// Returns data, possibly from a fallback path (see `ProviderOutcome.warning`), or throws
    /// `ProviderError` when no data is available at all.
    func fetchUsage(for account: AccountConfig, settings: AppSettings, context: RefreshContext) async throws -> ProviderOutcome
}

/// A verified binary that may be executed.
public struct LocatedBinary: Sendable, Hashable {
    /// realpath of the verified file. Execute exactly this URL.
    public var url: URL
    public var version: SemVer?
    public var kind: BinaryKind

    public init(url: URL, version: SemVer?, kind: BinaryKind) {
        self.url = url
        self.version = version
        self.kind = kind
    }
}

/// One candidate binary and why it can or cannot be used (Settings page).
public struct BinaryCandidate: Sendable, Hashable {
    public enum Status: String, Sendable, Hashable {
        case usable, signatureInvalid, notMachO, notExecutable, versionTooOld, versionUnknown, missing
    }

    public var path: URL
    public var realpath: URL?
    public var version: SemVer?
    public var status: Status
    public var isOverride: Bool

    public init(path: URL, realpath: URL?, version: SemVer?, status: Status, isOverride: Bool) {
        self.path = path
        self.realpath = realpath
        self.version = version
        self.status = status
        self.isOverride = isOverride
    }
}

public protocol BinaryLocating: Sendable {
    /// The best verified binary per spec §5.3.2 (claude) or §5.4 step 1 (codex), or nil.
    /// Re-resolves and re-verifies on every call; claude must be ≥ 2.1.289.
    func locate(_ kind: BinaryKind, settings: AppSettings) async -> LocatedBinary?
    /// Every candidate with its status, for the Settings page.
    func candidates(_ kind: BinaryKind, settings: AppSettings) async -> [BinaryCandidate]
}

public protocol ClaudeConfigReading: Sendable {
    /// `oauthAccount.accountUuid` from the given config dir's global config JSON, or nil (spec §3.2).
    func accountUUID(configDir: String?) async -> String?
}
