import Foundation
import Testing
@testable import TokenBarCore

@Suite("Dedicated login flag")
struct DedicatedLoginFlagTests {
    @Test func theDefaultLoginIsNeverEffectivelyDedicated() {
        let flagged = AccountConfig(provider: .claude, displayName: "Claude", claudeConfigDir: nil, isDedicatedLogin: true)
        #expect(!flagged.isEffectiveDedicatedLogin)
        let real = AccountConfig(provider: .claude, displayName: "Work", claudeConfigDir: "/d/work", isDedicatedLogin: true)
        #expect(real.isEffectiveDedicatedLogin)
        let codex = AccountConfig(provider: .codex, displayName: "Codex", isDedicatedLogin: true)
        #expect(!codex.isEffectiveDedicatedLogin)
    }

    @Test func decodingRepairsAFlaggedDefaultLogin() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","provider":"claude","displayName":"Claude","isDedicatedLogin":true}"#
        let account = try JSONDecoder().decode(AccountConfig.self, from: Data(json.utf8))
        #expect(!account.isDedicatedLogin)
    }
}
