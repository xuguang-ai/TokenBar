import Foundation

public enum DisplayMode: String, Codable, Sendable, CaseIterable {
    case remaining, used
}

/// How reset times are shown (spec §5.1 rule 6): the local clock time ("Wed 11:00 PM") or a
/// countdown ("1d 12h").
public enum ResetTimeStyle: String, Codable, Sendable, CaseIterable {
    case clock, countdown
}

/// Which account the menu bar number follows (spec §5.1 rule 5). Stored in `config.json` as one string:
/// `"activeClaude"`, `"mostConstrained"` or `"account:<UUID>"` (spec §5.8).
public enum MenuBarSource: Codable, Sendable, Hashable {
    /// The enabled Claude account that `~/.claude` is logged in to; the most constrained one when none matches.
    case activeClaude
    /// The enabled account with the worst status and the least remaining in its worst window.
    case mostConstrained
    /// One account; behaves like `.activeClaude` while it is missing or disabled.
    case account(UUID)

    private static let accountPrefix = "account:"

    /// The `config.json` string.
    var storedValue: String {
        switch self {
        case .activeClaude: return "activeClaude"
        case .mostConstrained: return "mostConstrained"
        case .account(let id): return Self.accountPrefix + id.uuidString
        }
    }

    /// nil for any other string, e.g. one written by a newer TokenBar.
    init?(storedValue: String) {
        switch storedValue {
        case "activeClaude": self = .activeClaude
        case "mostConstrained": self = .mostConstrained
        default:
            guard storedValue.hasPrefix(Self.accountPrefix),
                  let id = UUID(uuidString: String(storedValue.dropFirst(Self.accountPrefix.count)))
            else { return nil }
            self = .account(id)
        }
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let source = MenuBarSource(storedValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown menu bar source"))
        }
        self = source
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storedValue)
    }
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
    /// Panel, floating window and CLI table; the countdown stays in tooltips and VoiceOver.
    public var resetTimeStyle: ResetTimeStyle
    /// Which account the menu bar number follows.
    public var menuBarSource: MenuBarSource
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
        resetTimeStyle: ResetTimeStyle = .clock,
        menuBarSource: MenuBarSource = .activeClaude,
        allowClaudeCodeRefresh: Bool = true,
        claudeBinaryOverride: String? = nil,
        codexBinaryOverride: String? = nil,
        subprocessProxy: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.displayMode = displayMode
        self.resetTimeStyle = resetTimeStyle
        self.menuBarSource = menuBarSource
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

    /// Reorders `accounts` so each provider's accounts are adjacent. Groups keep the order in which their
    /// provider first appears, and accounts keep their relative order inside a group (stable).
    public mutating func groupAccountsByProvider() {
        var providerOrder: [ProviderKind] = []
        for account in accounts where !providerOrder.contains(account.provider) {
            providerOrder.append(account.provider)
        }
        accounts = providerOrder.flatMap { provider in accounts.filter { $0.provider == provider } }
    }

    /// Adds `account` right after the last account of the same provider, so one provider's accounts stay
    /// next to each other in the display order. Appends when there is none.
    public mutating func insertAccountGroupedByProvider(_ account: AccountConfig) {
        if let last = accounts.lastIndex(where: { $0.provider == account.provider }) {
            accounts.insert(account, at: last + 1)
        } else {
            accounts.append(account)
        }
    }

    /// Codex never polls faster than every 5 minutes (spec §5.8).
    public func refreshIntervalMinutes(for provider: ProviderKind) -> Int {
        provider == .codex ? max(refreshIntervalMinutes, 5) : refreshIntervalMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, accounts, refreshIntervalMinutes, displayMode, resetTimeStyle, menuBarSource
        case allowClaudeCodeRefresh, claudeBinaryOverride, codexBinaryOverride, subprocessProxy
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
        resetTimeStyle = try c.decodeIfPresent(ResetTimeStyle.self, forKey: .resetTimeStyle) ?? .clock
        // Lenient: an unknown value (e.g. from a newer TokenBar) must not make the whole file undecodable.
        menuBarSource = (try? c.decodeIfPresent(MenuBarSource.self, forKey: .menuBarSource)) ?? .activeClaude
        allowClaudeCodeRefresh = try c.decodeIfPresent(Bool.self, forKey: .allowClaudeCodeRefresh) ?? true
        claudeBinaryOverride = try c.decodeIfPresent(String.self, forKey: .claudeBinaryOverride)
        codexBinaryOverride = try c.decodeIfPresent(String.self, forKey: .codexBinaryOverride)
        subprocessProxy = try c.decodeIfPresent(String.self, forKey: .subprocessProxy)
        groupAccountsByProvider()  // one provider's accounts are always adjacent (display order)
    }
}
