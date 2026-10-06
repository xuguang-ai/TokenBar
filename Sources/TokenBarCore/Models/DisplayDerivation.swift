import Foundation

/// A window as it should be displayed at a given moment (spec §5.1 "Display derivation").
public struct DisplayWindow: Sendable, Hashable {
    public var kind: UsageWindow.Kind
    public var usedPercent: Double
    /// `nil` when the window has not started or has already reset: no countdown is shown.
    public var resetsAt: Date?
    public var isStarted: Bool
    /// True when the stored reset time has already passed.
    public var didReset: Bool
    public var status: UsageStatus

    public var remainingPercent: Double { max(0, 100 - usedPercent) }
}

public struct DisplayAccount: Sendable, Hashable {
    public var windows: [DisplayWindow]
    public var status: UsageStatus
    /// The started window with the least remaining; `nil` when no window has started.
    public var worstWindow: DisplayWindow?
    public var limitReached: Bool
}

public struct MenuBarSummary: Sendable, Equatable {
    /// "31%", "31%?", "!" or "–".
    public var text: String
    /// `nil` when there is no data at all.
    public var status: UsageStatus?
}

/// Pure display rules shared by the App and the CLI (spec §5.1).
public enum DisplayDerivation {
    /// Rule 1: a window whose reset time has passed shows as reset (0% used, not started, no countdown)
    /// and no longer counts toward `limitReached`. Rules 3–4: status tiers, worst started window.
    public static func derive(_ snapshot: UsageSnapshot, now: Date) -> DisplayAccount {
        var anyReset = false
        let windows: [DisplayWindow] = snapshot.windows.sortedForDisplay().map { window in
            if let reset = window.resetsAt, reset <= now {
                anyReset = true
                return DisplayWindow(kind: window.kind, usedPercent: 0, resetsAt: nil,
                                     isStarted: false, didReset: true, status: .normal)
            }
            guard window.isStarted else {
                return DisplayWindow(kind: window.kind, usedPercent: window.usedPercent, resetsAt: nil,
                                     isStarted: false, didReset: false, status: .normal)
            }
            return DisplayWindow(
                kind: window.kind, usedPercent: window.usedPercent, resetsAt: window.resetsAt,
                isStarted: true, didReset: false,
                status: UsageStatus(remainingPercent: window.remainingPercent, limitReached: window.usedPercent >= 100))
        }
        let started = windows.filter(\.isStarted)
        let limitReached = anyReset ? started.contains { $0.usedPercent >= 100 } : snapshot.limitReached
        let worst = started.min { a, b in
            a.remainingPercent != b.remainingPercent
                ? a.remainingPercent < b.remainingPercent
                : a.kind.sortRank < b.kind.sortRank
        }
        var status = started.map(\.status).max() ?? .normal
        if limitReached { status = .critical }
        return DisplayAccount(windows: windows, status: status, worstWindow: worst, limitReached: limitReached)
    }

    /// Rule 2: the earliest future reset; the App re-renders at that moment.
    public static func nextResetDate(_ snapshots: [UsageSnapshot], now: Date) -> Date? {
        snapshots.flatMap(\.windows).compactMap(\.resetsAt).filter { $0 > now }.min()
    }

    public static func percentValue(_ window: DisplayWindow, mode: DisplayMode) -> Double {
        mode == .remaining ? window.remainingPercent : window.usedPercent
    }

    /// "32% left" or "68% used".
    public static func percentText(_ window: DisplayWindow, mode: DisplayMode) -> String {
        Formatting.percent(percentValue(window, mode: mode)) + (mode == .remaining ? " left" : " used")
    }

    /// Rule 5: the menu bar shows the worst enabled account that has a snapshot. A trailing "?" marks
    /// data older than two refresh intervals or an account whose last refresh failed. "!" means every
    /// enabled account is failing and none has data. "–" means no data yet.
    public static func menuBar(states: [AccountState], settings: AppSettings, now: Date) -> MenuBarSummary {
        let enabled = states.filter(\.config.isEnabled)
        var worst: (state: AccountState, snapshot: UsageSnapshot, account: DisplayAccount)?
        for state in enabled {
            guard let snapshot = state.lastSnapshot else { continue }
            let account = derive(snapshot, now: now)
            if let current = worst, !isWorse(account, than: current.account) { continue }
            worst = (state, snapshot, account)
        }
        guard let worst else {
            if !enabled.isEmpty, enabled.allSatisfy({ $0.lastError != nil }) {
                return MenuBarSummary(text: "!", status: .critical)
            }
            return MenuBarSummary(text: "–", status: nil)
        }
        let value: Double
        if let window = worst.account.worstWindow {
            value = percentValue(window, mode: settings.displayMode)
        } else {
            value = settings.displayMode == .remaining ? 100 : 0
        }
        var text = Formatting.percent(value)
        let interval = TimeInterval(settings.refreshIntervalMinutes(for: worst.state.config.provider) * 60)
        if now.timeIntervalSince(worst.snapshot.dataAsOf) > 2 * interval || worst.state.lastError != nil {
            text += "?"
        }
        return MenuBarSummary(text: text, status: worst.account.status)
    }

    static func isWorse(_ a: DisplayAccount, than b: DisplayAccount) -> Bool {
        if a.status != b.status { return a.status > b.status }
        return (a.worstWindow?.remainingPercent ?? 100) < (b.worstWindow?.remainingPercent ?? 100)
    }
}
