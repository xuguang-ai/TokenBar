import Foundation

/// Windows mapped from a Claude usage body or from `cachedUsageUtilization.utilization` (spec §5.3.1).
public struct ClaudeMappedUsage: Sendable, Hashable {
    public var windows: [UsageWindow]
    /// True when any window or `limits[]` row is at or above 100%.
    public var limitReached: Bool

    public init(windows: [UsageWindow], limitReached: Bool) {
        self.windows = windows
        self.limitReached = limitReached
    }
}

/// Pure mapping of the `/api/oauth/usage` JSON shape (spec §5.3.1). Unknown keys are ignored, null or
/// non-object windows are skipped, and an unparseable `resets_at` only drops the countdown.
public enum ClaudeUsageMapper {
    static let topLevelWindows: [(key: String, kind: UsageWindow.Kind)] = [
        ("five_hour", .fiveHour),
        ("seven_day", .weekly),
        ("seven_day_sonnet", .weeklySonnet),
        ("seven_day_opus", .weeklyOpus),
    ]

    /// Maps a decoded JSON object.
    public static func map(_ object: [String: Any]) -> ClaudeMappedUsage {
        var windows: [UsageWindow] = []
        for (key, kind) in topLevelWindows {
            guard let window = object[key] as? [String: Any],
                  let used = percent(window["utilization"]) else { continue }
            windows.append(UsageWindow(kind: kind, usedPercent: used, resetsAt: DateParsing.flexible(window["resets_at"])))
        }
        if let limits = object["limits"] as? [Any] {
            for case let row as [String: Any] in limits {
                guard let scope = row["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = model["display_name"] as? String,
                      !name.trimmingCharacters(in: .whitespaces).isEmpty,
                      let used = percent(row["percent"]) else { continue }
                windows.append(UsageWindow(
                    kind: .model(name: name), usedPercent: used, resetsAt: DateParsing.flexible(row["resets_at"])))
            }
        }
        return ClaudeMappedUsage(
            windows: windows.sortedForDisplay(),
            limitReached: windows.contains { $0.usedPercent >= 100 })
    }

    /// Maps a raw body. Throws `.decoding` (no values) when it is not a JSON object.
    public static func map(data: Data) throws(ProviderError) -> ClaudeMappedUsage {
        guard let object = try? JSONSerialization.jsonObject(with: data), let dictionary = object as? [String: Any] else {
            throw ProviderError.decoding(codingPath: [])
        }
        return map(dictionary)
    }

    /// A finite JSON number that is not a boolean.
    static func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}
