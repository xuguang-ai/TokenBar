import Foundation
import Testing
@testable import TokenBarCore

@Suite("Account order")
struct AccountOrderTests {
    @Test func newAccountsJoinTheirProviderGroup() {
        var settings = AppSettings.makeDefault()  // [Claude, Codex]
        let work = AccountConfig(provider: .claude, displayName: "Work", claudeConfigDir: "/d/work", isDedicatedLogin: true)
        let personal = AccountConfig(provider: .claude, displayName: "Personal", claudeConfigDir: "/d/personal", isDedicatedLogin: true)
        let codex2 = AccountConfig(provider: .codex, displayName: "Codex 2", codexHome: "/c2")
        settings.insertAccountGroupedByProvider(work)
        settings.insertAccountGroupedByProvider(personal)
        settings.insertAccountGroupedByProvider(codex2)
        #expect(settings.accounts.map(\.displayName) == ["Claude", "Work", "Personal", "Codex", "Codex 2"])
    }

    @Test func groupingIsStableAndFollowsFirstAppearance() {
        var settings = AppSettings(accounts: [
            AccountConfig(provider: .claude, displayName: "Claude"),
            AccountConfig(provider: .codex, displayName: "Codex"),
            AccountConfig(provider: .claude, displayName: "xai@iu.edu", claudeConfigDir: "/d/x", isDedicatedLogin: true),
        ])
        settings.groupAccountsByProvider()
        #expect(settings.accounts.map(\.displayName) == ["Claude", "xai@iu.edu", "Codex"])
    }

    @Test func decodingGroupsAnExistingMixedOrder() throws {
        let mixed = AppSettings(accounts: [
            AccountConfig(provider: .codex, displayName: "Codex"),
            AccountConfig(provider: .claude, displayName: "A"),
            AccountConfig(provider: .codex, displayName: "Codex 2"),
            AccountConfig(provider: .claude, displayName: "B"),
        ])
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(mixed))
        #expect(decoded.accounts.map(\.displayName) == ["Codex", "Codex 2", "A", "B"])
    }

    @Test func appendsWhenTheProviderHasNoAccountYet() {
        var settings = AppSettings(accounts: [AccountConfig(provider: .codex, displayName: "Codex")])
        settings.insertAccountGroupedByProvider(AccountConfig(provider: .claude, displayName: "Work"))
        #expect(settings.accounts.map(\.displayName) == ["Codex", "Work"])
    }
}
