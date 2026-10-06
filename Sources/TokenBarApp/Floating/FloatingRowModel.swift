// Display data for one floating-window row, derived from Core state (spec §5.1, §6.4).
// Pure value type: the live window builds it from AppModel, the render preview from stub states.
import Foundation
import TokenBarCore

struct AppFloatingRowModel: Identifiable, Equatable {
    enum Condition: Equatable {
        /// Fresh data with a started window.
        case ok
        /// Fresh data, but no window has started yet.
        case notStarted
        /// Data is older than two refresh intervals, or the last refresh failed.
        case stale(age: String)
        case notLoggedIn
        /// No data at all and the last attempt failed.
        case failed(message: String)
        case loading
        case noData
    }

    let id: UUID
    let provider: ProviderKind
    let name: String
    let plan: String?
    /// The displayed percentage (used or left, per settings); `nil` when there is no data.
    let percent: Double?
    /// "used" or "left".
    let suffix: String
    let status: UsageStatus
    /// "Fable · weekly", "5h"…; `nil` when no window has started.
    let windowLabel: String?
    /// "1d 11h"; `nil` without a running countdown.
    let resetText: String?
    /// "1 day 11 hours", for VoiceOver.
    let spokenReset: String?
    let condition: Condition
    /// Shown as a tooltip on the detail line (error text).
    let detailHelp: String?
    let busySessionNames: [String]
    let isRefreshing: Bool

    var fraction: Double? { percent.map { min(max($0 / 100, 0), 1) } }
    var isDimmed: Bool {
        switch condition {
        case .notLoggedIn, .failed, .loading, .noData: return true
        case .ok, .notStarted, .stale: return false
        }
    }

    // MARK: Building

    static func make(state: AccountState, settings: AppSettings, now: Date, busySessionNames: [String])
        -> AppFloatingRowModel
    {
        let mode = settings.displayMode
        let display = state.lastSnapshot.map { DisplayDerivation.derive($0, now: now) }
        let worst = display?.worstWindow
        var percent: Double?
        if display != nil {
            percent = worst.map { DisplayDerivation.percentValue($0, mode: mode) } ?? (mode == .remaining ? 100 : 0)
        }

        let condition: Condition
        if case .notLoggedIn = state.lastError {
            condition = .notLoggedIn
        } else if let snapshot = state.lastSnapshot {
            let interval = TimeInterval(settings.refreshIntervalMinutes(for: state.config.provider) * 60)
            if state.lastError != nil || now.timeIntervalSince(snapshot.dataAsOf) > 2 * interval {
                condition = .stale(age: Formatting.age(since: snapshot.dataAsOf, now: now))
            } else {
                condition = worst == nil ? .notStarted : .ok
            }
        } else if let error = state.lastError {
            condition = .failed(message: error.userMessage)
        } else {
            condition = state.isRefreshing ? .loading : .noData
        }

        let reset = worst?.resetsAt
        return AppFloatingRowModel(
            id: state.config.id,
            provider: state.config.provider,
            name: state.config.displayName,
            plan: state.lastSnapshot?.identity?.plan.flatMap(prettyPlan),
            percent: percent,
            suffix: mode == .remaining ? "left" : "used",
            status: display?.status ?? .normal,
            windowLabel: worst.map { windowLabel($0.kind) },
            resetText: reset.map { Formatting.countdown(to: $0, now: now) },
            spokenReset: reset.map { spokenCountdown(to: $0, now: now) },
            condition: condition,
            detailHelp: state.lastError?.userMessage,
            busySessionNames: busySessionNames,
            isRefreshing: state.isRefreshing)
    }

    /// "Fable · weekly", "Sonnet · weekly", "weekly", "5h", "monthly".
    static func windowLabel(_ kind: UsageWindow.Kind) -> String {
        switch kind {
        case .fiveHour: return "5h"
        case .weekly: return "weekly"
        case .weeklySonnet: return "Sonnet · weekly"
        case .weeklyOpus: return "Opus · weekly"
        case .model(let name): return "\(name) · weekly"
        case .monthly: return "monthly"
        case .other: return kind.shortLabel
        }
    }

    /// "team" → "Team", "max_20x" → "Max 20x"; mixed-case plans are kept as they are.
    static func prettyPlan(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed == trimmed.lowercased() else { return trimmed }
        return trimmed.split(whereSeparator: { $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// "1 day 11 hours", "2 hours 14 minutes", "45 minutes", "less than a minute".
    static func spokenCountdown(to date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded(.down))
        if seconds < 60 { return "less than a minute" }
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3_600, minutes = (seconds % 3_600) / 60
        func unit(_ value: Int, _ name: String) -> String { "\(value) \(name)\(value == 1 ? "" : "s")" }
        if days >= 1 { return hours > 0 ? "\(unit(days, "day")) \(unit(hours, "hour"))" : unit(days, "day") }
        if hours >= 1 { return minutes > 0 ? "\(unit(hours, "hour")) \(unit(minutes, "minute"))" : unit(hours, "hour") }
        return unit(minutes, "minute")
    }

    /// "Work, Team, 82 percent used, Fable weekly, resets in 1 day 11 hours, 2 busy sessions".
    var accessibilityLabel: String {
        var parts = [name]
        if let plan { parts.append(plan) }
        switch condition {
        case .notLoggedIn: parts.append("not logged in")
        case .failed(let message): parts.append(message)
        case .loading: parts.append("loading")
        case .noData: parts.append("no data yet")
        case .ok, .notStarted, .stale: break
        }
        if let percent { parts.append("\(Int(percent.rounded())) percent \(suffix)") }
        if let windowLabel { parts.append(windowLabel.replacingOccurrences(of: " · ", with: " ")) }
        if let spokenReset { parts.append("resets in \(spokenReset)") }
        if condition == .notStarted { parts.append("not started") }
        if case .stale(let age) = condition { parts.append("last updated \(age)") }
        if !busySessionNames.isEmpty {
            parts.append("\(busySessionNames.count) busy session\(busySessionNames.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }
}
