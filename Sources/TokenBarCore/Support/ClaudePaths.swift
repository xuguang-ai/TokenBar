import CryptoKit
import Foundation

/// Where Claude Code keeps things for a given config dir (spec §2.1, §3.1).
public enum ClaudePaths {
    public static let keychainServiceBase = "Claude Code-credentials"
    public static let fallbackKeychainAccount = "claude-code-user"

    /// Expands a leading `~` only, the way a shell assignment would. Nothing else is normalised (spec §3.1).
    public static func expandTilde(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + String(path.dropFirst()) }
        return path
    }

    /// `Claude Code-credentials`, or `Claude Code-credentials-<first 8 hex of sha256(NFC(dir))>` when
    /// `CLAUDE_CONFIG_DIR` is set. The raw string is hashed: no realpath, no trailing-slash removal.
    public static func keychainService(configDir: String?) -> String {
        guard let configDir else { return keychainServiceBase }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return keychainServiceBase + "-" + hex.prefix(8)
    }

    /// The keychain account attribute: the user name if it matches `^[a-zA-Z0-9._-]+$`, else `claude-code-user`.
    public static func keychainAccount(userName: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !userName.isEmpty, userName.unicodeScalars.allSatisfy(allowed.contains) else {
            return fallbackKeychainAccount
        }
        return userName
    }

    /// The same dir string with the trailing "/" toggled, for the exit-44 retry (spec §3.1). nil for the default dir.
    public static func trailingSlashVariant(_ configDir: String?) -> String? {
        guard let configDir, configDir.count > 1 else { return nil }
        return configDir.hasSuffix("/") ? String(configDir.dropLast()) : configDir + "/"
    }

    public static func configDirectoryURL(_ configDir: String?, home: URL) -> URL {
        if let configDir { return URL(fileURLWithPath: configDir, isDirectory: true) }
        return home.appendingPathComponent(".claude", isDirectory: true)
    }

    /// Global config JSON candidates in precedence order (spec §2.1): `<dir>/.config.json`, then
    /// `~/.claude.json` for the default dir or `<dir>/.claude.json` otherwise.
    public static func globalConfigCandidates(_ configDir: String?, home: URL) -> [URL] {
        let directory = configDirectoryURL(configDir, home: home)
        let fallback = configDir == nil
            ? home.appendingPathComponent(".claude.json")
            : directory.appendingPathComponent(".claude.json")
        return [directory.appendingPathComponent(".config.json"), fallback]
    }

    public static func credentialsFileURL(_ configDir: String?, home: URL) -> URL {
        configDirectoryURL(configDir, home: home).appendingPathComponent(".credentials.json")
    }

    public static func sessionsDirectoryURL(_ configDir: String?, home: URL) -> URL {
        configDirectoryURL(configDir, home: home).appendingPathComponent("sessions", isDirectory: true)
    }
}
