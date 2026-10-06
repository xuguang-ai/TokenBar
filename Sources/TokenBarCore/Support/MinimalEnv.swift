import Foundation

/// Builds the exact environment for child processes (spec §5.7). Nothing is inherited from TokenBar's own
/// environment, so API keys or tokens set in a shell can never switch a child's auth source.
public enum MinimalEnv {
    public static let path = "/usr/bin:/bin:/usr/sbin:/sbin"

    public static func make(
        userName: String,
        home: URL,
        temporaryDirectory: URL,
        proxy: ProxySettings?,
        extra: [String: String?] = [:]
    ) -> [String: String] {
        var env: [String: String] = [
            "HOME": home.path,
            "USER": userName,
            "LOGNAME": userName,
            "PATH": path,
            "TMPDIR": temporaryDirectory.path.hasSuffix("/") ? temporaryDirectory.path : temporaryDirectory.path + "/",
        ]
        if let proxy {
            if let value = proxy.httpsProxy { env["HTTPS_PROXY"] = value; env["https_proxy"] = value }
            if let value = proxy.httpProxy { env["HTTP_PROXY"] = value; env["http_proxy"] = value }
            if let value = proxy.noProxy { env["NO_PROXY"] = value; env["no_proxy"] = value }
        }
        for (key, value) in extra {
            if let value { env[key] = value }
        }
        return env.filter { !isForbidden($0.key) }
    }

    /// Keys that must never reach a child.
    public static func isForbidden(_ key: String) -> Bool {
        let upper = key.uppercased()
        return upper.hasSuffix("_API_KEY")
            || upper.hasSuffix("_TOKEN")
            || upper.hasPrefix("ANTHROPIC_")
            || upper.hasPrefix("CLAUDE_CODE_")
            || upper == "CLAUDE_SECURESTORAGE_CONFIG_DIR"
            || upper.hasPrefix("OPENAI_")
            || upper == "CODEX_API_KEY"
            || upper == "CODEX_ACCESS_TOKEN"
    }
}
