import Foundation

// `tokenbar status --json` output (spec §7). The DTOs have hand-written coding keys and an explicit
// `encode(to:)`, so every key is always present (`null` when absent) and the shape never follows
// internal model changes. They carry no email and no accountUuid (spec §9.7).

/// Top level of `tokenbar status --json`.
public struct CLIStatusJSON: Encodable, Sendable, Hashable {
    public var generatedAt: String
    public var accounts: [CLIAccountJSON]

    public init(generatedAt: String, accounts: [CLIAccountJSON]) {
        self.generatedAt = generatedAt
        self.accounts = accounts
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case accounts
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(accounts, forKey: .accounts)
    }
}

/// One account in `tokenbar status --json`.
public struct CLIAccountJSON: Encodable, Sendable, Hashable {
    public var id: String
    /// "claude" or "codex".
    public var provider: String
    public var name: String
    public var plan: String?
    /// See `CLIStatusBuilder.sourceString(_:)`. `nil` when there is no snapshot.
    public var source: String?
    public var dataAsOf: String?
    /// 0–1, from the worst started window after display derivation. 0 when no window has started;
    /// `nil` when there is no snapshot at all.
    public var usage: Double?
    public var resetAt: String?
    public var windows: [CLIWindowJSON]
    public var error: CLIErrorJSON?

    public init(
        id: String, provider: String, name: String, plan: String?, source: String?, dataAsOf: String?,
        usage: Double?, resetAt: String?, windows: [CLIWindowJSON], error: CLIErrorJSON?
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.plan = plan
        self.source = source
        self.dataAsOf = dataAsOf
        self.usage = usage
        self.resetAt = resetAt
        self.windows = windows
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, name, plan, source
        case dataAsOf = "data_as_of"
        case usage
        case resetAt = "reset_at"
        case windows, error
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(provider, forKey: .provider)
        try c.encode(name, forKey: .name)
        try c.encode(plan, forKey: .plan)
        try c.encode(source, forKey: .source)
        try c.encode(dataAsOf, forKey: .dataAsOf)
        try c.encode(usage, forKey: .usage)
        try c.encode(resetAt, forKey: .resetAt)
        try c.encode(windows, forKey: .windows)
        try c.encode(error, forKey: .error)
    }
}

/// One window, after display derivation (a passed reset shows as 0% used and not started).
public struct CLIWindowJSON: Encodable, Sendable, Hashable {
    /// See `CLIStatusBuilder.kindString(_:)`.
    public var kind: String
    public var usedPercent: Double
    public var remainingPercent: Double
    public var resetsAt: String?
    public var started: Bool

    public init(kind: String, usedPercent: Double, remainingPercent: Double, resetsAt: String?, started: Bool) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
        self.started = started
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case usedPercent = "used_percent"
        case remainingPercent = "remaining_percent"
        case resetsAt = "resets_at"
        case started
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(usedPercent, forKey: .usedPercent)
        try c.encode(remainingPercent, forKey: .remainingPercent)
        try c.encode(resetsAt, forKey: .resetsAt)
        try c.encode(started, forKey: .started)
    }
}

/// `{"code": "<ProviderError.code>"}`. Never carries an error payload (spec §9.3).
public struct CLIErrorJSON: Encodable, Sendable, Hashable {
    public var code: String

    public init(code: String) {
        self.code = code
    }

    private enum CodingKeys: String, CodingKey {
        case code
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
    }
}

/// Builds the CLI DTOs from account states (spec §7).
public enum CLIStatusBuilder {
    public static func build(states: [AccountState], now: Date) -> CLIStatusJSON {
        CLIStatusJSON(generatedAt: CLIFormat.iso8601(now), accounts: states.map { account($0, now: now) })
    }

    public static func account(_ state: AccountState, now: Date) -> CLIAccountJSON {
        let config = state.config
        var json = CLIAccountJSON(
            id: config.id.uuidString, provider: config.provider.rawValue, name: config.displayName,
            plan: nil, source: nil, dataAsOf: nil, usage: nil, resetAt: nil, windows: [],
            error: state.lastError.map { CLIErrorJSON(code: $0.code) })
        guard let snapshot = state.lastSnapshot else { return json }
        let display = DisplayDerivation.derive(snapshot, now: now)
        json.plan = snapshot.identity?.plan
        json.source = sourceString(snapshot.source)
        json.dataAsOf = CLIFormat.iso8601(snapshot.dataAsOf)
        if let worst = display.worstWindow {
            json.usage = CLIFormat.rounded(min(1, max(0, worst.usedPercent / 100)), places: 4)
            json.resetAt = worst.resetsAt.map(CLIFormat.iso8601)
        } else {
            json.usage = 0
            json.resetAt = nil
        }
        json.windows = display.windows.map(window)
        return json
    }

    public static func window(_ window: DisplayWindow) -> CLIWindowJSON {
        CLIWindowJSON(
            kind: kindString(window.kind),
            usedPercent: CLIFormat.rounded(window.usedPercent, places: 2),
            remainingPercent: CLIFormat.rounded(window.remainingPercent, places: 2),
            resetsAt: window.resetsAt.map(CLIFormat.iso8601),
            started: window.isStarted)
    }

    /// `five_hour`, `weekly`, `weekly_sonnet`, `weekly_opus`, `model:<name>`, `monthly`, `other_<minutes>`.
    public static func kindString(_ kind: UsageWindow.Kind) -> String {
        switch kind {
        case .fiveHour: return "five_hour"
        case .weekly: return "weekly"
        case .weeklySonnet: return "weekly_sonnet"
        case .weeklyOpus: return "weekly_opus"
        case .model(let name): return "model:\(name)"
        case .monthly: return "monthly"
        case .other(let minutes): return "other_\(minutes)"
        }
    }

    /// `claude_api`, `claude_api_after_cli_refresh`, `claude_cache`, `codex_app_server`, `codex_rollout`.
    public static func sourceString(_ source: SnapshotSource) -> String {
        switch source {
        case .claudeAPI: return "claude_api"
        case .claudeAPIAfterCLIRefresh: return "claude_api_after_cli_refresh"
        case .claudeCache: return "claude_cache"
        case .codexAppServer: return "codex_app_server"
        case .codexRollout: return "codex_rollout"
        }
    }

    /// Pretty-printed, sorted keys, no escaped slashes, trailing newline.
    public static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // The DTOs contain only strings, finite numbers, booleans and nulls, so encoding cannot fail.
        guard let data = try? encoder.encode(value) else { return "{}\n" }
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}

/// Small formatting helpers shared by the CLI renderers.
public enum CLIFormat {
    /// "2026-10-06T13:41:00Z" (UTC, whole seconds).
    public static func iso8601(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!))
    }

    /// Rounds away binary noise such as `68.30000000000001`.
    public static func rounded(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}
