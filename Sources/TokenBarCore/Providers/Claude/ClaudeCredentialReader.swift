import Foundation

/// The four `claudeAiOauth` fields TokenBar keeps in memory; everything else in the keychain value is
/// dropped while parsing (spec §5.3 step 1). The token never appears in `description`, `debugDescription`
/// or a mirror.
public struct ClaudeCredentials: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var accessToken: String
    /// Milliseconds since the epoch.
    public var expiresAtMs: Double?
    public var scopes: [String]
    public var subscriptionType: String?

    public init(accessToken: String, expiresAtMs: Double?, scopes: [String], subscriptionType: String?) {
        self.accessToken = accessToken
        self.expiresAtMs = expiresAtMs
        self.scopes = scopes
        self.subscriptionType = subscriptionType
    }

    public static let profileScope = "user:profile"
    /// A token closer than this to `expiresAt` counts as expired (spec §2.1).
    public static let expiryMargin: TimeInterval = 300

    public var hasToken: Bool { !accessToken.isEmpty }
    public var hasProfileScope: Bool { scopes.contains(Self.profileScope) }

    /// `now + 5 min >= expiresAt`. A token without `expiresAt` is treated as not expired.
    public func isExpired(at now: Date) -> Bool {
        guard let expiresAtMs else { return false }
        return now.addingTimeInterval(Self.expiryMargin).timeIntervalSince1970 * 1000 >= expiresAtMs
    }

    public var description: String {
        "ClaudeCredentials(accessToken: <redacted>, expiresAtMs: \(expiresAtMs.map { String($0) } ?? "nil"), "
            + "scopes: \(scopes), subscriptionType: \(subscriptionType ?? "nil"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "accessToken": "<redacted>",
            "expiresAtMs": expiresAtMs as Any,
            "scopes": scopes,
            "subscriptionType": subscriptionType as Any,
        ])
    }

    /// Parses a keychain value or `.credentials.json` (raw JSON or the hex form `security -w` prints for
    /// non-printable data). nil when it is not a JSON object. A missing `claudeAiOauth` gives an empty token.
    static func parse(_ data: Data) -> ClaudeCredentials? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return from(object)
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = hexDecode(text),
              let object = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else { return nil }
        return from(object)
    }

    private static func from(_ object: [String: Any]) -> ClaudeCredentials {
        let oauth = object["claudeAiOauth"] as? [String: Any] ?? [:]
        let expires = ClaudeUsageMapper.percent(oauth["expiresAt"])
        let scopes = (oauth["scopes"] as? [Any])?.compactMap { $0 as? String } ?? []
        return ClaudeCredentials(
            accessToken: oauth["accessToken"] as? String ?? "",
            expiresAtMs: expires,
            scopes: scopes,
            subscriptionType: oauth["subscriptionType"] as? String)
    }

    private static func hexDecode(_ text: String) -> Data? {
        let utf8 = Array(text.utf8)
        guard !utf8.isEmpty, utf8.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: utf8.count / 2)
        var index = 0
        while index < utf8.count {
            guard let high = hexValue(utf8[index]), let low = hexValue(utf8[index + 1]) else { return nil }
            result.append(high << 4 | low)
            index += 2
        }
        return result
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

/// A process-wide FIFO gate: only one `/usr/bin/security` runs at a time, other accounts queue (spec §5.3 step 1).
public actor ClaudeKeychainGate {
    public static let shared = ClaudeKeychainGate()

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func run<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer { release() }
        return await body()
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()  // ownership passes straight to the next waiter
        }
    }
}

public enum ClaudeCredentialReadResult: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// The keychain item for this config dir string. It differs from the account's configured string
        /// when the trailing-slash variant matched (spec §3.1).
        case keychain(configDir: String?)
        case credentialsFile
    }

    case found(ClaudeCredentials, source: Source)
    /// Exit 44 for the dir and its variant, and no `.credentials.json`.
    case notFound
    /// `security` did not finish in time. `truncated` is true when the deadline, not the step's own
    /// timeout, cut it short, so the timeout says nothing about a keychain prompt.
    case timedOut(truncated: Bool)
    /// `.keychainLocked`, `.keychainAccessDenied`, `.keychainReadFailed` or `.decoding`.
    case failed(ProviderError)
}

/// Reads Claude Code's OAuth credentials with `/usr/bin/security` (spec §5.3 step 1). stdout and stderr
/// are classified and parsed in place, then dropped: nothing from them reaches a log or an error.
public struct ClaudeCredentialReader: Sendable {
    public static let securityExecutable = URL(fileURLWithPath: "/usr/bin/security")
    public static let automaticTimeout: Duration = .seconds(10)
    public static let manualTimeout: Duration = .seconds(60)
    /// Exit code reported for a timeout or a launch failure, where `security` gave none.
    public static let noExitCode: Int32 = -1
    /// Steps need at least this much budget to start (spec §5.3 time budget).
    static let minimumBudget: TimeInterval = 1
    static let deadlineReserve: TimeInterval = 2

    private let env: CoreEnvironment
    private let gate: ClaudeKeychainGate

    public init(env: CoreEnvironment, gate: ClaudeKeychainGate = .shared) {
        self.env = env
        self.gate = gate
    }

    /// Reads the item for `configDir` (tilde already expanded), then on exit 44 the trailing-slash
    /// variant, then `<dir>/.credentials.json`.
    public func read(configDir: String?, manual: Bool, deadline: Date) async -> ClaudeCredentialReadResult {
        let first = await readKeychain(configDir: configDir, manual: manual, deadline: deadline)
        guard case .notFound = first else { return first }
        if let variant = ClaudePaths.trailingSlashVariant(configDir) {
            let second = await readKeychain(configDir: variant, manual: manual, deadline: deadline)
            guard case .notFound = second else { return second }
        }
        let file = ClaudePaths.credentialsFileURL(configDir, home: env.homeDirectory)
        guard env.fileSystem.fileExists(file), let data = try? env.fileSystem.readFile(file) else { return .notFound }
        guard let credentials = ClaudeCredentials.parse(data) else {
            return .failed(.decoding(codingPath: []))
        }
        return .found(credentials, source: .credentialsFile)
    }

    private func readKeychain(configDir: String?, manual: Bool, deadline: Date) async -> ClaudeCredentialReadResult {
        let env = self.env
        return await gate.run {
            // The budget is computed after the gate opens: queueing behind other accounts uses it up too.
            let requested = manual ? Self.manualTimeout : Self.automaticTimeout
            let remaining = deadline.timeIntervalSince(env.now()) - Self.deadlineReserve
            let seconds = min(requested.timeInterval, remaining)
            let truncated = remaining < requested.timeInterval
            guard seconds >= Self.minimumBudget else { return .timedOut(truncated: true) }
            let request = ProcessRequest(
                executable: Self.securityExecutable,
                arguments: [
                    "find-generic-password",
                    "-a", ClaudePaths.keychainAccount(userName: env.userName),
                    "-w",
                    "-s", ClaudePaths.keychainService(configDir: configDir),
                ],
                environment: MinimalEnv.make(
                    userName: env.userName, home: env.homeDirectory,
                    temporaryDirectory: env.temporaryDirectory, proxy: nil),
                timeout: .milliseconds(Int64(seconds * 1000)),
                maxOutputBytes: 1 << 20)
            let result: ProcessResult
            do {
                result = try await env.processRunner.run(request)
            } catch {
                return .failed(.keychainReadFailed(exitCode: Self.noExitCode))
            }
            return Self.classify(result, configDir: configDir, truncated: truncated)
        }
    }

    /// Exit-code and stderr classification (spec §5.3 step 1).
    static func classify(_ result: ProcessResult, configDir: String?, truncated: Bool) -> ClaudeCredentialReadResult {
        if result.timedOut { return .timedOut(truncated: truncated) }
        if result.terminatedBySignal { return .failed(.keychainReadFailed(exitCode: result.exitCode)) }
        switch result.exitCode {
        case 0:
            guard let credentials = ClaudeCredentials.parse(result.stdout) else {
                return .failed(.decoding(codingPath: []))
            }
            return .found(credentials, source: .keychain(configDir: configDir))
        case 44:
            return .notFound
        case 36:
            return .failed(.keychainLocked)
        case 128, 51:
            return .failed(.keychainAccessDenied(exitCode: result.exitCode))
        default:
            if stderrSaysDenied(result.stderr) { return .failed(.keychainAccessDenied(exitCode: result.exitCode)) }
            return .failed(.keychainReadFailed(exitCode: result.exitCode))
        }
    }

    private static func stderrSaysDenied(_ stderr: Data) -> Bool {
        let text = String(decoding: stderr.prefix(4096), as: UTF8.self).lowercased()
        return ["user canceled", "user cancelled", "user_canceled", "auth failed", "auth_failed"].contains { text.contains($0) }
    }
}
