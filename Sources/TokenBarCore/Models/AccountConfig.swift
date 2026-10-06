import Foundation

public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case claude, codex

    public var defaultDisplayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// One monitored account (spec §3, §5.1).
public struct AccountConfig: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var provider: ProviderKind
    public var displayName: String
    /// Claude only. `nil` is the default login (`CLAUDE_CONFIG_DIR` unset, `~/.claude`).
    /// Otherwise the exact string used as `CLAUDE_CONFIG_DIR` and hashed into the keychain
    /// service name. Only a leading `~` is ever expanded (spec §3.1).
    public var claudeConfigDir: String?
    /// Claude only. True for TokenBar-owned login dirs; only these may run step ② (spec §5.3).
    public var isDedicatedLogin: Bool
    /// Codex only. `nil` is `~/.codex`.
    public var codexHome: String?
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        provider: ProviderKind,
        displayName: String,
        claudeConfigDir: String? = nil,
        isDedicatedLogin: Bool = false,
        codexHome: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.claudeConfigDir = claudeConfigDir
        self.isDedicatedLogin = isDedicatedLogin
        self.codexHome = codexHome
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, displayName, claudeConfigDir, isDedicatedLogin, codexHome, isEnabled
    }

    /// Missing optional fields fall back to defaults so older config files keep decoding (spec §5.8).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        provider = try c.decode(ProviderKind.self, forKey: .provider)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? provider.defaultDisplayName
        claudeConfigDir = try c.decodeIfPresent(String.self, forKey: .claudeConfigDir)
        isDedicatedLogin = try c.decodeIfPresent(Bool.self, forKey: .isDedicatedLogin) ?? false
        codexHome = try c.decodeIfPresent(String.self, forKey: .codexHome)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        // Only a Claude account with its own config dir can be a dedicated login; repair older files.
        if provider != .claude || claudeConfigDir == nil { isDedicatedLogin = false }
    }

    /// True only for a Claude account with its own config dir that was created as a dedicated login.
    /// The default login (`claudeConfigDir == nil`) can never be one, whatever `isDedicatedLogin` says.
    public var isEffectiveDedicatedLogin: Bool {
        provider == .claude && isDedicatedLogin && claudeConfigDir != nil
    }
}
