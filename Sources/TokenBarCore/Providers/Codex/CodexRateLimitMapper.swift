import Foundation

// Decoding and mapping of Codex app-server results (spec §5.4 step 4). Every field is optional and
// unknown keys are ignored. Decoded values stay in memory only; nothing here is logged or thrown.

/// One `primary` / `secondary` window of a Codex rate-limit snapshot.
public struct CodexRateLimitWindow: Sendable, Hashable {
    public var usedPercent: Double
    public var windowDurationMins: Int?
    public var resetsAt: Date?

    public init(usedPercent: Double, windowDurationMins: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}

/// `RateLimitSnapshot` from `account/rateLimits/read`.
public struct CodexRateLimitSnapshot: Sendable, Hashable {
    public var limitId: String?
    public var primary: CodexRateLimitWindow?
    public var secondary: CodexRateLimitWindow?
    public var planType: String?
    public var rateLimitReachedType: String?

    public init(
        limitId: String? = nil,
        primary: CodexRateLimitWindow? = nil,
        secondary: CodexRateLimitWindow? = nil,
        planType: String? = nil,
        rateLimitReachedType: String? = nil
    ) {
        self.limitId = limitId
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
    }
}

/// The parts of the `account/rateLimits/read` result TokenBar uses.
public struct CodexRateLimitsReadResult: Sendable, Hashable {
    public var ordinaryUsageAllowed: Bool?
    public var rateLimits: CodexRateLimitSnapshot?
    public var rateLimitsByLimitId: [String: CodexRateLimitSnapshot]

    public init(
        ordinaryUsageAllowed: Bool? = nil,
        rateLimits: CodexRateLimitSnapshot? = nil,
        rateLimitsByLimitId: [String: CodexRateLimitSnapshot] = [:]
    ) {
        self.ordinaryUsageAllowed = ordinaryUsageAllowed
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
    }

    /// `rateLimitsByLimitId["codex"] ?? rateLimits`.
    public var effectiveSnapshot: CodexRateLimitSnapshot? {
        rateLimitsByLimitId["codex"] ?? rateLimits
    }
}

/// The parts of the `account/read` result TokenBar uses. The email is deliberately not decoded.
public struct CodexAccountReadResult: Sendable, Hashable {
    /// False when `account` is null or missing (spec §5.4 step 5).
    public var isLoggedIn: Bool
    public var accountType: String?
    public var planType: String?

    public init(isLoggedIn: Bool, accountType: String? = nil, planType: String? = nil) {
        self.isLoggedIn = isLoggedIn
        self.accountType = accountType
        self.planType = planType
    }
}

/// Windows and flags ready for a `UsageSnapshot`.
public struct CodexMappedUsage: Sendable, Hashable {
    public var windows: [UsageWindow]
    public var limitReached: Bool
    /// Display form, e.g. "Plus".
    public var plan: String?

    public init(windows: [UsageWindow], limitReached: Bool, plan: String?) {
        self.windows = windows
        self.limitReached = limitReached
        self.plan = plan
    }
}

public enum CodexRateLimitMapper {
    /// A window counts as not started when it reports 0% and its reset is within this many seconds of
    /// `now + duration` (spec §5.4 step 4).
    public static let notStartedTolerance: TimeInterval = 120

    // MARK: Decoding

    public static func decodeRateLimitsResult(_ object: Any?) -> CodexRateLimitsReadResult? {
        guard let dict = object as? [String: Any] else { return nil }
        var byID: [String: CodexRateLimitSnapshot] = [:]
        if let map = dict["rateLimitsByLimitId"] as? [String: Any] {
            for (key, value) in map {
                if let snapshot = decodeSnapshot(value) { byID[key] = snapshot }
            }
        }
        return CodexRateLimitsReadResult(
            ordinaryUsageAllowed: bool(dict["ordinaryUsageAllowed"]),
            rateLimits: decodeSnapshot(dict["rateLimits"]),
            rateLimitsByLimitId: byID)
    }

    public static func decodeAccountResult(_ object: Any?) -> CodexAccountReadResult? {
        guard let dict = object as? [String: Any] else { return nil }
        guard let account = dict["account"] as? [String: Any] else {
            return CodexAccountReadResult(isLoggedIn: false)
        }
        return CodexAccountReadResult(
            isLoggedIn: true, accountType: string(account["type"]), planType: string(account["planType"]))
    }

    static func decodeSnapshot(_ object: Any?) -> CodexRateLimitSnapshot? {
        guard let dict = object as? [String: Any] else { return nil }
        return CodexRateLimitSnapshot(
            limitId: string(dict["limitId"]),
            primary: decodeWindow(dict["primary"]),
            secondary: decodeWindow(dict["secondary"]),
            planType: string(dict["planType"]),
            rateLimitReachedType: string(dict["rateLimitReachedType"]))
    }

    static func decodeWindow(_ object: Any?) -> CodexRateLimitWindow? {
        guard let dict = object as? [String: Any], let used = double(dict["usedPercent"]) else { return nil }
        return CodexRateLimitWindow(
            usedPercent: used,
            windowDurationMins: int(dict["windowDurationMins"]),
            resetsAt: DateParsing.flexible(dict["resetsAt"]))
    }

    // MARK: Mapping

    /// Maps the effective snapshot. Returns nil when the result carries no snapshot at all.
    public static func map(_ result: CodexRateLimitsReadResult, accountPlan: String? = nil, now: Date) -> CodexMappedUsage? {
        guard let snapshot = result.effectiveSnapshot else { return nil }
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }.map { window($0, reference: now) }
        let limitReached = snapshot.rateLimitReachedType != nil || result.ordinaryUsageAllowed == false
        return CodexMappedUsage(
            windows: windows.sortedForDisplay(),
            limitReached: limitReached,
            plan: displayPlan(snapshot.planType ?? accountPlan))
    }

    /// A `UsageWindow` classified by duration, with `isStarted` judged against `reference`.
    public static func window(_ window: CodexRateLimitWindow, reference: Date) -> UsageWindow {
        UsageWindow(
            kind: kind(minutes: window.windowDurationMins),
            usedPercent: window.usedPercent,
            resetsAt: window.resetsAt,
            isStarted: isStarted(
                usedPercent: window.usedPercent, resetsAt: window.resetsAt,
                durationMinutes: window.windowDurationMins, reference: reference))
    }

    /// 300 → 5h, 10080 → weekly, 43200 → monthly, anything else (or unknown) → other.
    public static func kind(minutes: Int?) -> UsageWindow.Kind {
        UsageWindow.Kind.fromDuration(minutes: minutes ?? 0)
    }

    /// `!(usedPercent == 0 && |resetsAt − reference − duration×60| ≤ 120 s)`.
    public static func isStarted(usedPercent: Double, resetsAt: Date?, durationMinutes: Int?, reference: Date) -> Bool {
        guard usedPercent == 0, let resetsAt, let durationMinutes else { return true }
        let expected = reference.addingTimeInterval(TimeInterval(durationMinutes) * 60)
        return abs(resetsAt.timeIntervalSince(expected)) > notStartedTolerance
    }

    /// "plus" → "Plus". Empty or "unknown" gives nil.
    public static func displayPlan(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, raw.lowercased() != "unknown" else {
            return nil
        }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    // MARK: Tolerant scalar helpers (shared with the rollout reader)

    static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    static func int(_ value: Any?) -> Int? {
        guard let result = double(value), result.rounded() == result, abs(result) < 1e15 else { return nil }
        return Int(result)
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBool(number) else { return nil }
        return number.boolValue
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }
}
