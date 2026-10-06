import Foundation
import Testing
@testable import TokenBarCore

@Suite("ClaudeConfigReader")
struct ClaudeConfigReaderTests {
    private static let canaries = [
        "CANARY-mcpServersEnv-synthetic-4f9c", "CANARY-primaryApiKey-synthetic-77e2",
        "CANARY-userID-synthetic-0b1d", "CANARY-displayName-synthetic-91aa", "someone@example.invalid",
    ]

    @Test func extractsOnlyIdentityAndCacheFromTheDefaultFile() async throws {
        let h = try TestHarness()
        try h.writeHome(".claude.json", try Fixtures.string("claude/global-config-with-secrets.json"))
        let reader = ClaudeConfigReader(env: h.env)
        let config = try #require(reader.read(configDir: nil))
        #expect(config.oauthAccount?.accountUuid == "00000000-0000-4000-8000-00000000c1a0")
        #expect(config.oauthAccount?.organizationType == "claude_max")
        #expect(config.oauthAccount?.organizationName == "Example Org")
        #expect(config.cachedUsage?.fetchedAt == Date(timeIntervalSince1970: 1_791_249_501.737))
        #expect(config.cachedUsage?.usage.windows.map(\.usedPercent) == [68, 42])
        #expect(config.matchingCachedUsage != nil)
        #expect(await reader.accountUUID(configDir: nil) == "00000000-0000-4000-8000-00000000c1a0")

        for text in [String(describing: config), String(reflecting: config)] {
            for canary in Self.canaries { #expect(!text.contains(canary)) }
        }
    }

    @Test func dotConfigJSONWinsOverDotClaudeJSON() throws {
        let h = try TestHarness()
        try h.writeHome("work/.claude.json", #"{"oauthAccount": {"accountUuid": "from-claude-json"}}"#)
        let reader = ClaudeConfigReader(env: h.env)
        let dir = h.home.appendingPathComponent("work").path
        #expect(reader.read(configDir: dir)?.oauthAccount?.accountUuid == "from-claude-json")
        try h.writeHome("work/.config.json", #"{"oauthAccount": {"accountUuid": "from-config-json"}}"#)
        #expect(reader.read(configDir: dir)?.oauthAccount?.accountUuid == "from-config-json")
        // The default dir never reads <dir>/.claude.json, only ~/.claude.json.
        #expect(reader.read(configDir: nil) == nil)
    }

    @Test func tildeIsExpanded() throws {
        let h = try TestHarness()
        try h.writeHome("work/.claude.json", #"{"oauthAccount": {"accountUuid": "u1"}}"#)
        #expect(ClaudeConfigReader(env: h.env).read(configDir: "~/work")?.oauthAccount?.accountUuid == "u1")
    }

    @Test func malformedJSONGivesNil() throws {
        let h = try TestHarness()
        try h.writeHome(".claude.json", #"{"oauthAccount": "#)
        #expect(ClaudeConfigReader(env: h.env).read(configDir: nil) == nil)
        try h.writeHome(".claude.json", "[1]")
        #expect(ClaudeConfigReader(env: h.env).read(configDir: nil) == nil)
    }

    @Test func malformedDotConfigJSONDoesNotFallBack() throws {
        let h = try TestHarness()
        try h.writeHome("work/.claude.json", #"{"oauthAccount": {"accountUuid": "u1"}}"#)
        try h.writeHome("work/.config.json", "{")
        #expect(ClaudeConfigReader(env: h.env).read(configDir: h.home.appendingPathComponent("work").path) == nil)
    }

    @Test func cacheForAnotherAccountDoesNotMatch() throws {
        let h = try TestHarness()
        try h.writeHome(".claude.json", """
            {"oauthAccount": {"accountUuid": "a"},
             "cachedUsageUtilization": {"fetchedAtMs": 1, "accountUuid": "b", "utilization": {}}}
            """)
        let config = try #require(ClaudeConfigReader(env: h.env).read(configDir: nil))
        #expect(config.cachedUsage != nil)
        #expect(config.matchingCachedUsage == nil)
    }

    @Test func cacheWithoutFetchedAtIsIgnored() throws {
        let h = try TestHarness()
        try h.writeHome(".claude.json", #"{"cachedUsageUtilization": {"accountUuid": "a", "utilization": {}}}"#)
        #expect(ClaudeConfigReader(env: h.env).read(configDir: nil)?.cachedUsage == nil)
    }
}
