import Foundation

/// One usage window as reported by a provider (spec §5.1).
public struct UsageWindow: Codable, Sendable, Hashable {
    public enum Kind: Codable, Sendable, Hashable {
        case fiveHour, weekly, weeklySonnet, weeklyOpus, monthly
        /// A model-scoped weekly limit from Claude's `limits[]`.
        case model(name: String)
        case other(minutes: Int)

        /// Display order (spec §5.1).
        public var sortRank: Int {
            switch self {
            case .fiveHour: return 0
            case .weekly: return 1
            case .weeklySonnet: return 2
            case .weeklyOpus: return 3
            case .model: return 4
            case .monthly: return 5
            case .other: return 6
            }
        }

        /// Row label in the panel.
        public var shortLabel: String {
            switch self {
            case .fiveHour: return "5h"
            case .weekly: return "Week"
            case .weeklySonnet: return "Sonnet"
            case .weeklyOpus: return "Opus"
            case .model(let name): return name
            case .monthly: return "Month"
            case .other(let minutes):
                if minutes > 0, minutes % 1440 == 0 { return "\(minutes / 1440)d" }
                if minutes > 0, minutes % 60 == 0 { return "\(minutes / 60)h" }
                return "\(minutes)m"
            }
        }

        /// Classifies a window by its length (Codex, spec §5.4 step 4).
        public static func fromDuration(minutes: Int) -> Kind {
            switch minutes {
            case 300: return .fiveHour
            case 10080: return .weekly
            case 43200: return .monthly
            default: return .other(minutes: minutes)
            }
        }
    }

    public var kind: Kind
    /// 0...100; may exceed 100.
    public var usedPercent: Double
    public var resetsAt: Date?
    /// False when the window has not started yet (Codex). Display derivation can also make it false.
    public var isStarted: Bool

    public init(kind: Kind, usedPercent: Double, resetsAt: Date?, isStarted: Bool = true) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.isStarted = isStarted
    }

    public var remainingPercent: Double { max(0, 100 - usedPercent) }
}

extension Array where Element == UsageWindow {
    /// Stable sort by `Kind.sortRank`.
    public func sortedForDisplay() -> [UsageWindow] {
        enumerated()
            .sorted { a, b in
                a.element.kind.sortRank != b.element.kind.sortRank
                    ? a.element.kind.sortRank < b.element.kind.sortRank
                    : a.offset < b.offset
            }
            .map(\.element)
    }
}
