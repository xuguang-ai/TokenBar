import Foundation

/// The non-secret identity fields of `oauthAccount` (spec §2.1, §5.3 step 5).
public struct ClaudeOAuthAccount: Sendable, Hashable, CustomStringConvertible {
    public var accountUuid: String?
    public var organizationName: String?
    public var organizationType: String?
    /// For live display in Settings only. Never put it in a snapshot, a log or CLI output (spec §9.7).
    public var emailAddress: String?

    public init(accountUuid: String?, organizationName: String?, organizationType: String?, emailAddress: String?) {
        self.accountUuid = accountUuid
        self.organizationName = organizationName
        self.organizationType = organizationType
        self.emailAddress = emailAddress
    }

    public var description: String {
        "ClaudeOAuthAccount(accountUuid: \(accountUuid ?? "nil"), organizationType: \(organizationType ?? "nil"), "
            + "emailAddress: \(emailAddress == nil ? "nil" : "<redacted>"))"
    }
}

/// `cachedUsageUtilization`, already mapped (spec §5.3 step ③).
public struct ClaudeCachedUsage: Sendable, Hashable {
    public var fetchedAt: Date
    public var accountUuid: String?
    public var usage: ClaudeMappedUsage

    public init(fetchedAt: Date, accountUuid: String?, usage: ClaudeMappedUsage) {
        self.fetchedAt = fetchedAt
        self.accountUuid = accountUuid
        self.usage = usage
    }
}

/// The only two keys TokenBar takes from Claude Code's global config JSON (spec §5.3, §9.6).
public struct ClaudeGlobalConfig: Sendable, Hashable {
    public var oauthAccount: ClaudeOAuthAccount?
    public var cachedUsage: ClaudeCachedUsage?

    public init(oauthAccount: ClaudeOAuthAccount?, cachedUsage: ClaudeCachedUsage?) {
        self.oauthAccount = oauthAccount
        self.cachedUsage = cachedUsage
    }

    /// The cache, only when its `accountUuid` equals `oauthAccount.accountUuid` (both present).
    public var matchingCachedUsage: ClaudeCachedUsage? {
        guard let cache = cachedUsage, let owner = oauthAccount?.accountUuid, cache.accountUuid == owner else { return nil }
        return cache
    }
}

/// Reads `oauthAccount` and `cachedUsageUtilization` from the global config JSON of a config dir.
/// The file is parsed with `JSONSerialization`, every other key is dropped on the spot, and nothing
/// from the file is logged, cached or put into an error (spec §5.3, §9.3).
public struct ClaudeConfigReader: ClaudeConfigReading {
    private let fileSystem: any FileSystemAccess
    private let homeDirectory: URL

    public init(fileSystem: any FileSystemAccess, homeDirectory: URL) {
        self.fileSystem = fileSystem
        self.homeDirectory = homeDirectory
    }

    public init(env: CoreEnvironment) {
        self.init(fileSystem: env.fileSystem, homeDirectory: env.homeDirectory)
    }

    /// The file Claude Code would use (spec §2.1): `<dir>/.config.json` if it exists, otherwise
    /// `~/.claude.json` (default dir) or `<dir>/.claude.json`. nil when neither exists.
    public func configFileURL(configDir: String?) -> URL? {
        let dir = configDir.map { ClaudePaths.expandTilde($0, home: homeDirectory) }
        return ClaudePaths.globalConfigCandidates(dir, home: homeDirectory).first { fileSystem.fileExists($0) }
    }

    /// nil when the file is missing, unreadable or not a JSON object. The first existing candidate
    /// wins even when it is malformed, as in Claude Code.
    public func read(configDir: String?) -> ClaudeGlobalConfig? {
        guard let url = configFileURL(configDir: configDir),
              let data = try? fileSystem.readFile(url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }
        return ClaudeGlobalConfig(
            oauthAccount: Self.oauthAccount(root["oauthAccount"]),
            cachedUsage: Self.cachedUsage(root["cachedUsageUtilization"]))
    }

    public func accountUUID(configDir: String?) async -> String? {
        read(configDir: configDir)?.oauthAccount?.accountUuid
    }

    static func oauthAccount(_ value: Any?) -> ClaudeOAuthAccount? {
        guard let object = value as? [String: Any] else { return nil }
        return ClaudeOAuthAccount(
            accountUuid: nonEmptyString(object["accountUuid"]),
            organizationName: nonEmptyString(object["organizationName"]),
            organizationType: nonEmptyString(object["organizationType"]),
            emailAddress: nonEmptyString(object["emailAddress"]))
    }

    static func cachedUsage(_ value: Any?) -> ClaudeCachedUsage? {
        guard let object = value as? [String: Any],
              let fetchedAtMs = ClaudeUsageMapper.percent(object["fetchedAtMs"]),
              let utilization = object["utilization"] as? [String: Any] else { return nil }
        return ClaudeCachedUsage(
            fetchedAt: Date(timeIntervalSince1970: fetchedAtMs / 1000),
            accountUuid: nonEmptyString(object["accountUuid"]),
            usage: ClaudeUsageMapper.map(utilization))
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
