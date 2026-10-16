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
    /// The account the text describes; `nil` when no account was chosen.
    public var accountID: UUID?
    /// The window the percent comes from; `nil` when no window was used.
    public var windowKind: UsageWindow.Kind?

    public init(text: String, status: UsageStatus?, accountID: UUID? = nil, windowKind: UsageWindow.Kind? = nil) {
        self.text = text
        self.status = status
        self.accountID = accountID
        self.windowKind = windowKind
    }
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

    /// Rule 5: which account the menu bar follows (`settings.menuBarSource`) and what it shows.
    /// - `.account(id)`: that enabled account; while it is missing or disabled, as `.activeClaude`.
    /// - `.activeClaude`: the enabled Claude account whose snapshot identity matches
    ///   `activeClaudeAccountUuid` (the newest `dataAsOf` among several); else as `.mostConstrained`.
    /// - `.mostConstrained`: the worst enabled account that has a snapshot, showing its worst window.
    /// A chosen account shows its 5h window (else its worst started window, else 0% used), with the icon
    /// status of its worst window. A trailing "?" marks data older than two refresh intervals or an account
    /// whose last refresh failed. "!" means no data and a failing refresh (for `.mostConstrained`: every
    /// enabled account). "–" means no data yet.
    public static func menuBar(states: [AccountState], settings: AppSettings, activeClaudeAccountUuid: String?,
                               now: Date) -> MenuBarSummary {
        let enabled = states.filter(\.config.isEnabled)
        if case .account(let id) = settings.menuBarSource, let chosen = enabled.first(where: { $0.config.id == id }) {
            return chosenSummary(chosen, settings: settings, now: now)
        }
        if settings.menuBarSource != .mostConstrained, let uuid = activeClaudeAccountUuid {
            let matches = enabled.compactMap { state -> (state: AccountState, dataAsOf: Date)? in
                guard state.config.provider == .claude, let snapshot = state.lastSnapshot,
                      snapshot.identity?.accountUuid == uuid else { return nil }
                return (state, snapshot.dataAsOf)
            }
            if let freshest = matches.max(by: { $0.dataAsOf < $1.dataAsOf }) {
                return chosenSummary(freshest.state, settings: settings, now: now)
            }
        }
        return mostConstrained(enabled, settings: settings, now: now)
    }

    private static func chosenSummary(_ state: AccountState, settings: AppSettings, now: Date) -> MenuBarSummary {
        let id = state.config.id
        guard let snapshot = state.lastSnapshot else {
            return state.lastError != nil
                ? MenuBarSummary(text: "!", status: .critical, accountID: id)
                : MenuBarSummary(text: "–", status: nil, accountID: id)
        }
        let account = derive(snapshot, now: now)
        let window = account.windows.first { $0.kind == .fiveHour } ?? account.worstWindow
        return summary(state, snapshot, account, window: window, settings: settings, now: now)
    }

    private static func mostConstrained(_ enabled: [AccountState], settings: AppSettings, now: Date) -> MenuBarSummary {
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
        return summary(worst.state, worst.snapshot, worst.account, window: worst.account.worstWindow,
                       settings: settings, now: now)
    }

    /// The percent of `window` (0% used when there is none), "?" when stale or failing.
    private static func summary(_ state: AccountState, _ snapshot: UsageSnapshot, _ account: DisplayAccount,
                                window: DisplayWindow?, settings: AppSettings, now: Date) -> MenuBarSummary {
        let value = window.map { percentValue($0, mode: settings.displayMode) }
            ?? (settings.displayMode == .remaining ? 100 : 0)
        var text = Formatting.percent(value)
        let interval = TimeInterval(settings.refreshIntervalMinutes(for: state.config.provider) * 60)
        if now.timeIntervalSince(snapshot.dataAsOf) > 2 * interval || state.lastError != nil {
            text += "?"
        }
        return MenuBarSummary(text: text, status: account.status, accountID: state.config.id,
                              windowKind: window?.kind)
    }

    static func isWorse(_ a: DisplayAccount, than b: DisplayAccount) -> Bool {
        if a.status != b.status { return a.status > b.status }
        return (a.worstWindow?.remainingPercent ?? 100) < (b.worstWindow?.remainingPercent ?? 100)
    }
}
