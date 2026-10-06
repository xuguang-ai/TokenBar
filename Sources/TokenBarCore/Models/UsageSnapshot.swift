import Foundation

public struct AccountIdentity: Codable, Sendable, Hashable {
    /// Claude `oauthAccount.accountUuid`. Persisted, because session attribution needs it (spec §3.2).
    public var accountUuid: String?
    /// "Max", "Pro", "Plus", ...
    public var plan: String?
    public var organization: String?
    /// Never persisted and never printed by the CLI (spec §9.7). Only filled for live display in Settings.
    public var email: String? = nil

    public init(accountUuid: String? = nil, plan: String? = nil, organization: String? = nil, email: String? = nil) {
        self.accountUuid = accountUuid
        self.plan = plan
        self.organization = organization
        self.email = email
    }

    private enum CodingKeys: String, CodingKey {
        case accountUuid, plan, organization
    }
}

public enum SnapshotSource: Codable, Sendable, Hashable {
    case claudeAPI
    case claudeAPIAfterCLIRefresh
    case claudeCache(fetchedAt: Date)
    case codexAppServer
    case codexRollout(eventAt: Date)

    /// True when the data was not fetched live during this refresh.
    public var isCached: Bool {
        switch self {
        case .claudeCache, .codexRollout: return true
        case .claudeAPI, .claudeAPIAfterCLIRefresh, .codexAppServer: return false
        }
    }
}

public struct UsageSnapshot: Codable, Sendable, Hashable {
    public var accountID: UUID
    /// When TokenBar obtained the data.
    public var fetchedAt: Date
    /// When the data itself was produced. Cache and log sources can be older than `fetchedAt`.
    public var dataAsOf: Date
    public var source: SnapshotSource
    public var identity: AccountIdentity?
    /// Ordered with `sortedForDisplay()`.
    public var windows: [UsageWindow]
    public var limitReached: Bool

    public init(
        accountID: UUID,
        fetchedAt: Date,
        dataAsOf: Date,
        source: SnapshotSource,
        identity: AccountIdentity?,
        windows: [UsageWindow],
        limitReached: Bool
    ) {
        self.accountID = accountID
        self.fetchedAt = fetchedAt
        self.dataAsOf = dataAsOf
        self.source = source
        self.identity = identity
        self.windows = windows.sortedForDisplay()
        self.limitReached = limitReached
    }
}
