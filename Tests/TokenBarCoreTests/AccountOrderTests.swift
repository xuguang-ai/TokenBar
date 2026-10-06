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

    @Test func appendsWhenTheProviderHasNoAccountYet() {
        var settings = AppSettings(accounts: [AccountConfig(provider: .codex, displayName: "Codex")])
        settings.insertAccountGroupedByProvider(AccountConfig(provider: .claude, displayName: "Work"))
        #expect(settings.accounts.map(\.displayName) == ["Codex", "Work"])
    }
}
