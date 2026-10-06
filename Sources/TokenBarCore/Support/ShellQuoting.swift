import Foundation

/// Shell-safe text for the login commands shown in Settings (spec §6.5).
public enum ShellQuoting {
    public static let maxSlugLength = 32

    /// Wraps `value` in single quotes; every `'` inside becomes `'\''`. Safe for any POSIX shell:
    /// nothing inside single quotes is expanded, newlines included.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A directory name derived from a user-chosen account name: `[a-z0-9-]{1,32}`, or nil.
    /// Diacritics are folded ("Café" → "cafe"), every run of other characters becomes one `-`,
    /// and leading/trailing dashes are dropped (also after truncation).
    public static func slug(from name: String) -> String? {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var result = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            let isAllowed = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
            if isAllowed {
                if pendingDash && !result.isEmpty { result.append("-") }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        var slug = String(result.prefix(maxSlugLength))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? nil : slug
    }

    /// `env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_CUSTOM_OAUTH_URL CLAUDE_CONFIG_DIR='<dir>' '<claude path>' auth login`
    public static func claudeLoginCommand(configDir: String, claudePath: String) -> String {
        "env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_CUSTOM_OAUTH_URL "
            + "CLAUDE_CONFIG_DIR=\(quote(configDir)) \(quote(claudePath)) auth login"
    }

    /// `CODEX_HOME='<home>' '<codex path>' login`, or `'<codex path>' login` for the default `~/.codex`.
    public static func codexLoginCommand(home: String?, codexPath: String) -> String {
        let command = "\(quote(codexPath)) login"
        guard let home else { return command }
        return "CODEX_HOME=\(quote(home)) " + command
    }
}
