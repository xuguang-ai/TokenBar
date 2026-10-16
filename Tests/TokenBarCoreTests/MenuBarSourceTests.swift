import Foundation
import Testing
@testable import TokenBarCore

// Which account the menu bar follows (spec §5.1 rule 5).

private let now = Date(timeIntervalSince1970: 1_791_300_000)
private let activeUuid = "11111111-2222-3333-4444-555555555555"

private func state(_ name: String, provider: ProviderKind = .claude, uuid: String? = nil,
                   dataAsOf: Date = now, limitReached: Bool = false, _ windows: [UsageWindow]) -> AccountState {
    let config = AccountConfig(provider: provider, displayName: name)
    let snapshot = UsageSnapshot(accountID: config.id, fetchedAt: dataAsOf, dataAsOf: dataAsOf, source: .claudeAPI,
                                 identity: AccountIdentity(accountUuid: uuid), windows: windows,
                                 limitReached: limitReached)
    return AccountState(config: config, lastSnapshot: snapshot)
}

private func window(_ kind: UsageWindow.Kind, _ used: Double, resetIn: TimeInterval = 3_600) -> UsageWindow {
    UsageWindow(kind: kind, usedPercent: used, resetsAt: now + resetIn)
}

@Suite("Menu bar source")
struct MenuBarSourceTests {
    /// The user's case: an inactive account is at 100% while the active one is at 36%.
    private let inactive = state("Other", uuid: "other-uuid", [window(.fiveHour, 100), window(.weekly, 50)])
    private let active = state("Work", uuid: activeUuid, [window(.fiveHour, 36), window(.weekly, 90)])
    private let codex = state("Codex", provider: .codex, [window(.fiveHour, 99)])

    private func summary(_ states: [AccountState], uuid: String? = activeUuid,
                         source: MenuBarSource = .activeClaude, mode: DisplayMode = .used) -> MenuBarSummary {
        var settings = AppSettings(accounts: states.map(\.config), displayMode: mode)
        settings.menuBarSource = source
        return DisplayDerivation.menuBar(states: states, settings: settings, activeClaudeAccountUuid: uuid, now: now)
    }

    @Test func activeAccountIsChosenByUuidAndShowsItsFiveHourWindow() {
        let s = summary([inactive, active, codex])
        #expect(s.text == "36%")
        #expect(s.accountID == active.config.id)
        #expect(s.windowKind == .fiveHour)
    }

    @Test func iconStatusIsTheAccountsWorstWindow() {
        // The weekly window at 90% makes the account .low although its 5h is at 36%.
        #expect(summary([inactive, active]).status == .low)
        // A reached limit shows the warning icon.
        let limited = state("Work", uuid: activeUuid, limitReached: true, [window(.fiveHour, 10)])
        #expect(summary([limited]) == MenuBarSummary(text: "10%", status: .critical,
                                                     accountID: limited.config.id, windowKind: .fiveHour))
    }

    @Test func bothDisplayModes() {
        #expect(summary([inactive, active], mode: .remaining).text == "64%")
        #expect(summary([inactive, active], mode: .used).text == "36%")
    }

    @Test func passedFiveHourResetShowsAsReset() {
        let reset = state("Work", uuid: activeUuid, [window(.fiveHour, 80, resetIn: -60), window(.weekly, 20)])
        #expect(summary([reset]).text == "0%")
        #expect(summary([reset], mode: .remaining).text == "100%")
        #expect(summary([reset]).windowKind == .fiveHour)
    }

    @Test func withoutFiveHourUsesTheWorstStartedWindowElseZero() {
        let weeklyOnly = state("Work", uuid: activeUuid, [window(.weekly, 40), window(.weeklyOpus, 70)])
        #expect(summary([weeklyOnly]).text == "70%")
        #expect(summary([weeklyOnly]).windowKind == .weeklyOpus)
        let none = state("Work", uuid: activeUuid, [])
        #expect(summary([none]).text == "0%")
        #expect(summary([none], mode: .remaining).text == "100%")
        #expect(summary([none]).windowKind == nil)
    }

    @Test func fallsBackToMostConstrainedWhenUuidIsNilOrUnmatched() {
        for uuid in [nil, "nobody"] as [String?] {
            let s = summary([inactive, active], uuid: uuid)
            #expect(s.text == "100%")
            #expect(s.accountID == inactive.config.id)
            #expect(s.status == .critical)
        }
    }

    @Test func disabledOrCodexAccountsAreNotActive() {
        var disabled = active
        disabled.config.isEnabled = false
        #expect(summary([inactive, disabled]).accountID == inactive.config.id)
        // A Codex account is never the active Claude account, even with the same uuid.
        let codexSameUuid = state("Codex", provider: .codex, uuid: activeUuid, [window(.fiveHour, 5)])
        #expect(summary([inactive, codexSameUuid]).accountID == inactive.config.id)
    }

    @Test func freshestOfTwoAccountsSharingTheUuidWins() {
        let older = state("Default", uuid: activeUuid, dataAsOf: now - 120, [window(.fiveHour, 20)])
        let newer = state("Dedicated", uuid: activeUuid, dataAsOf: now - 30, [window(.fiveHour, 25)])
        #expect(summary([older, newer]).accountID == newer.config.id)
        #expect(summary([newer, older]).accountID == newer.config.id)
    }

    @Test func mostConstrainedKeepsTheOldBehavior() {
        let s = summary([inactive, active], source: .mostConstrained)
        #expect(s.text == "100%")
        #expect(s.accountID == inactive.config.id)
        #expect(s.windowKind == .fiveHour)
    }

    @Test func explicitAccountIsShownAndFallsBackWhenMissingOrDisabled() {
        let s = summary([inactive, active, codex], source: .account(codex.config.id))
        #expect(s.text == "99%")
        #expect(s.accountID == codex.config.id)
        // A missing account behaves like .activeClaude.
        #expect(summary([inactive, active], source: .account(UUID())).accountID == active.config.id)
        var disabled = codex
        disabled.config.isEnabled = false
        #expect(summary([inactive, active, disabled], source: .account(codex.config.id)).accountID
            == active.config.id)
        // ... and with no active account, like .mostConstrained.
        #expect(summary([inactive, active, disabled], uuid: nil, source: .account(codex.config.id)).accountID
            == inactive.config.id)
    }

    @Test func staleOrFailingChosenAccountGetsAQuestionMark() {
        var failing = active
        failing.lastError = .network(urlErrorCode: -1009)
        #expect(summary([inactive, failing]).text == "36%?")
        // Claude's default interval is 5 minutes: older than 10 minutes is stale.
        let stale = state("Work", uuid: activeUuid, dataAsOf: now - 11 * 60, [window(.fiveHour, 36)])
        #expect(summary([inactive, stale]).text == "36%?")
    }

    @Test func chosenAccountWithoutSnapshot() {
        let empty = AccountState(config: AccountConfig(provider: .claude, displayName: "Empty"))
        let s = summary([inactive, empty], source: .account(empty.config.id))
        #expect(s == MenuBarSummary(text: "–", status: nil, accountID: empty.config.id, windowKind: nil))
        var failing = empty
        failing.lastError = .notLoggedIn(hint: .claude(configDir: nil))
        #expect(summary([inactive, failing], source: .account(empty.config.id))
            == MenuBarSummary(text: "!", status: .critical, accountID: empty.config.id, windowKind: nil))
    }
}

@Suite("MenuBarSource settings")
struct MenuBarSourceSettingsTests {
    @Test func defaultsToActiveClaude() {
        #expect(AppSettings.makeDefault().menuBarSource == .activeClaude)
    }

    @Test func oldConfigDecodesToActiveClaude() throws {
        let json = #"{"accounts":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","provider":"claude"}],"displayMode":"used"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.menuBarSource == .activeClaude)
    }

    @Test(arguments: [MenuBarSource.activeClaude, .mostConstrained, .account(UUID())])
    func roundTrips(source: MenuBarSource) throws {
        var settings = AppSettings.makeDefault()
        settings.menuBarSource = source
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.menuBarSource == source)
    }

    private static let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    @Test(arguments: [
        (MenuBarSource.activeClaude, "activeClaude"),
        (.mostConstrained, "mostConstrained"),
        (.account(id), "account:6F9619FF-8B86-D011-B42D-00C04FC964FF"),
    ])
    func isStoredAsOneString(source: MenuBarSource, stored: String) throws {
        var settings = AppSettings.makeDefault()
        settings.menuBarSource = source
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        #expect(object?["menuBarSource"] as? String == stored)
    }

    @Test(arguments: [
        (#""mostConstrained""#, MenuBarSource.mostConstrained),
        (#""account:6F9619FF-8B86-D011-B42D-00C04FC964FF""#, .account(id)),
        // Unknown or malformed values fall back without making the whole file undecodable (spec §5.8).
        (#""codexOnly""#, .activeClaude),
        (#""account:not-a-uuid""#, .activeClaude),
        (#"{"account":{"_0":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}}"#, .activeClaude),
        ("42", .activeClaude),
    ])
    func decodesTheStringFormLeniently(json: String, expected: MenuBarSource) throws {
        let text = #"{"accounts":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","provider":"claude"}],"#
            + #""displayMode":"remaining","menuBarSource":"# + json + "}"
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(text.utf8))
        #expect(settings.menuBarSource == expected)
        #expect(settings.accounts.count == 1)
        #expect(settings.displayMode == .remaining)
    }
}
