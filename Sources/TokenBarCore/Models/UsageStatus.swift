import Foundation

/// Status tiers by remaining percentage (plan §2.3, spec §5.1). Ordered from best to worst.
public enum UsageStatus: Int, Codable, Sendable, Comparable, CaseIterable {
    case normal = 0, gettingLow, low, critical

    /// `> 50` normal, `20...50` getting low, `5..<20` low, `< 5` (or limit reached) critical.
    public init(remainingPercent r: Double, limitReached: Bool = false) {
        if limitReached || r < 5 {
            self = .critical
        } else if r < 20 {
            self = .low
        } else if r <= 50 {
            self = .gettingLow
        } else {
            self = .normal
        }
    }

    public static func < (lhs: UsageStatus, rhs: UsageStatus) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .gettingLow: return "Getting low"
        case .low: return "Low"
        case .critical: return "Critical"
        }
    }
}
