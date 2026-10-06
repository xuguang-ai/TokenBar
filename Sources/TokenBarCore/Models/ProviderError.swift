import Foundation

/// What the UI should tell the user to run in order to log in. The UI builds the actual text.
public enum LoginHint: Codable, Sendable, Hashable {
    case claude(configDir: String?)
    case codex(home: String?)
}

public enum BinaryKind: String, Codable, Sendable, CaseIterable {
    case claude, codex

    /// Apple Developer Team ID that must sign the binary (spec §5.6).
    public var teamID: String {
        switch self {
        case .claude: return "Q6L2SF6YDW"
        case .codex: return "2DC432GLL2"
        }
    }
}

public enum ProtocolErrorCode: String, Codable, Sendable, Hashable {
    case serverExited, malformedResponse, unexpectedMessage, methodNotAllowed, handshakeFailed, launchFailed, unexpected
}

/// Closed set of failures. Payloads never carry raw subprocess output, HTTP bodies or JSON values (spec §9.3).
public enum ProviderError: Error, Codable, Sendable, Hashable {
    case notLoggedIn(hint: LoginHint)
    /// A non-dedicated Claude login's token expired; the user's own Claude Code will refresh it.
    case waitingForClaudeCode
    case tokenLacksProfileScope
    case keychainLocked
    /// The user denied or cancelled the keychain prompt, or it timed out.
    case keychainAccessDenied(exitCode: Int32)
    case keychainReadFailed(exitCode: Int32)
    case unauthorized(until: Date)
    case rateLimited(until: Date)
    /// `URLError.Code` raw value only.
    case network(urlErrorCode: Int)
    case httpStatus(Int)
    /// No signed claude ≥ 2.1.289 found.
    case claudeBinaryNotFound
    case codexBinaryNotFound
    case binarySignatureInvalid(BinaryKind)
    case notACodexProfile
    case protocolError(ProtocolErrorCode)
    /// Key names only, never values.
    case decoding(codingPath: [String])
    case timeout
    case accountChanged

    /// Stable machine-readable name, used for `{"code": ...}` in CLI JSON.
    public var code: String {
        switch self {
        case .notLoggedIn: return "not_logged_in"
        case .waitingForClaudeCode: return "waiting_for_claude_code"
        case .tokenLacksProfileScope: return "token_lacks_profile_scope"
        case .keychainLocked: return "keychain_locked"
        case .keychainAccessDenied: return "keychain_access_denied"
        case .keychainReadFailed: return "keychain_read_failed"
        case .unauthorized: return "unauthorized"
        case .rateLimited: return "rate_limited"
        case .network: return "network"
        case .httpStatus: return "http_status"
        case .claudeBinaryNotFound: return "claude_binary_not_found"
        case .codexBinaryNotFound: return "codex_binary_not_found"
        case .binarySignatureInvalid: return "binary_signature_invalid"
        case .notACodexProfile: return "not_a_codex_profile"
        case .protocolError: return "protocol_error"
        case .decoding: return "decoding"
        case .timeout: return "timeout"
        case .accountChanged: return "account_changed"
        }
    }

    /// End of a backoff period, if this error represents one.
    public var pausedUntil: Date? {
        switch self {
        case .unauthorized(let until), .rateLimited(let until): return until
        default: return nil
        }
    }

    /// Short English text for the UI. Contains no secrets.
    public var userMessage: String {
        switch self {
        case .notLoggedIn: return "Not logged in"
        case .waitingForClaudeCode: return "Waiting for Claude Code to refresh"
        case .tokenLacksProfileScope: return "Token lacks user:profile"
        case .keychainLocked: return "Keychain is locked"
        case .keychainAccessDenied: return "Keychain access denied — showing cached data · Refresh to retry"
        case .keychainReadFailed(let code): return "Keychain read failed (\(code))"
        case .unauthorized: return "Login rejected by the server"
        case .rateLimited: return "Rate limited"
        case .network: return "Network error"
        case .httpStatus(let status): return "Server returned HTTP \(status)"
        case .claudeBinaryNotFound: return "Claude Code ≥ 2.1.289 not found — dedicated logins can't refresh"
        case .codexBinaryNotFound: return "Codex CLI not found"
        case .binarySignatureInvalid(let kind): return "\(kind.rawValue) binary failed the signature check"
        case .notACodexProfile: return "Not a Codex profile"
        case .protocolError(let code): return "Codex app-server error (\(code.rawValue))"
        case .decoding: return "Unexpected response format"
        case .timeout: return "Timed out"
        case .accountChanged: return "Account changed"
        }
    }
}
