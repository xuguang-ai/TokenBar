import Foundation

public enum DisplayMode: String, Codable, Sendable, CaseIterable {
    case remaining, used
}

/// User settings persisted in `config.json` (spec §5.1, §5.8).
public struct AppSettings: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let allowedRefreshIntervals = [1, 2, 5, 10, 15, 30]
    public static let defaultRefreshIntervalMinutes = 5

    public var schemaVersion: Int
    /// Display order.
    public var accounts: [AccountConfig]
    public var refreshIntervalMinutes: Int
    public var displayMode: DisplayMode
    /// Only affects dedicated Claude logins (spec §5.3 step ②).
    public var allowClaudeCodeRefresh: Bool
    public var claudeBinaryOverride: String?
    public var codexBinaryOverride: String?
    /// For example "http://proxy.example:8080". `nil` means subprocesses get the system proxy settings.
    public var subprocessProxy: String?

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        accounts: [AccountConfig],
        refreshIntervalMinutes: Int = AppSettings.defaultRefreshIntervalMinutes,
        displayMode: DisplayMode = .used,
        allowClaudeCodeRefresh: Bool = true,
        claudeBinaryOverride: String? = nil,
        codexBinaryOverride: String? = nil,
        subprocessProxy: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.displayMode = displayMode
        self.allowClaudeCodeRefresh = allowClaudeCodeRefresh
        self.claudeBinaryOverride = claudeBinaryOverride
        self.codexBinaryOverride = codexBinaryOverride
        self.subprocessProxy = subprocessProxy
    }

    /// Fixed IDs for the first-launch accounts, so state keyed by account ID (`state.json`) is stable
    /// across CLI runs that have no `config.json` yet.
    public static let defaultClaudeAccountID = UUID(uuidString: "7B0C1A0D-E000-4000-8000-000000000001")!
    public static let defaultCodexAccountID = UUID(uuidString: "7B0C0DE5-E000-4000-8000-000000000002")!

    /// First-launch configuration (spec §3.1).
    public static func makeDefault() -> AppSettings {
        AppSettings(accounts: [
            AccountConfig(id: defaultClaudeAccountID, provider: .claude,
                          displayName: ProviderKind.claude.defaultDisplayName),
            AccountConfig(id: defaultCodexAccountID, provider: .codex,
                          displayName: ProviderKind.codex.defaultDisplayName),
        ])
    }

    /// Codex never polls faster than every 5 minutes (spec §5.8).
    public func refreshIntervalMinutes(for provider: ProviderKind) -> Int {
        provider == .codex ? max(refreshIntervalMinutes, 5) : refreshIntervalMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, accounts, refreshIntervalMinutes, displayMode, allowClaudeCodeRefresh
        case claudeBinaryOverride, codexBinaryOverride, subprocessProxy
    }

    /// Every field except `accounts` falls back to its default; unknown keys are ignored (spec §5.8).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? AppSettings.currentSchemaVersion
        accounts = try c.decode([AccountConfig].self, forKey: .accounts)
        let interval = try c.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes)
            ?? AppSettings.defaultRefreshIntervalMinutes
        refreshIntervalMinutes = AppSettings.allowedRefreshIntervals.contains(interval)
            ? interval : AppSettings.defaultRefreshIntervalMinutes
        displayMode = try c.decodeIfPresent(DisplayMode.self, forKey: .displayMode) ?? .used
        allowClaudeCodeRefresh = try c.decodeIfPresent(Bool.self, forKey: .allowClaudeCodeRefresh) ?? true
        claudeBinaryOverride = try c.decodeIfPresent(String.self, forKey: .claudeBinaryOverride)
        codexBinaryOverride = try c.decodeIfPresent(String.self, forKey: .codexBinaryOverride)
        subprocessProxy = try c.decodeIfPresent(String.self, forKey: .subprocessProxy)
    }
}
