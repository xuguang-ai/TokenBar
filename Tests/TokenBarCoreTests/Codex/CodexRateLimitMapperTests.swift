import Foundation
import Testing
@testable import TokenBarCore

@Suite("CodexRateLimitMapper")
struct CodexRateLimitMapperTests {
    /// Capture time of the Phase 0 example: primary resets exactly 300 min later.
    static let captured = Date(timeIntervalSince1970: 1_791_251_178)

    static func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    @Test func mapsTheRealResultExample() throws {
        let object = try JSONSerialization.jsonObject(with: Fixtures.data("codex/rate_limits_result.json"))
        let result = try #require(CodexRateLimitMapper.decodeRateLimitsResult(object))
        let mapped = try #require(CodexRateLimitMapper.map(result, now: Self.captured))
        #expect(mapped.plan == "Plus")
        #expect(mapped.limitReached == false)
        #expect(mapped.windows.count == 2)
        let fiveHour = mapped.windows[0]
        #expect(fiveHour.kind == .fiveHour)
        #expect(fiveHour.usedPercent == 0)
        #expect(fiveHour.isStarted == false)
        #expect(fiveHour.resetsAt == Date(timeIntervalSince1970: 1_791_269_178))
        let weekly = mapped.windows[1]
        #expect(weekly.kind == .weekly)
        #expect(weekly.usedPercent == 16)
        #expect(weekly.isStarted)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_791_835_147))
    }

    @Test func weeklyOnlyPlanInThePrimarySlot() throws {
        let object = try Self.json("""
        {"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1791835147},
          "secondary":null,"planType":"plus","rateLimitReachedType":null}}
        """)
        let result = try #require(CodexRateLimitMapper.decodeRateLimitsResult(object))
        let mapped = try #require(CodexRateLimitMapper.map(result, now: Self.captured))
        #expect(mapped.windows.map(\.kind) == [.weekly])
        #expect(mapped.windows[0].usedPercent == 40)
    }

    @Test func thirtyDayWindowAndUnknownDuration() throws {
        let object = try Self.json("""
        {"rateLimits":{"primary":{"usedPercent":3,"windowDurationMins":43200,"resetsAt":1793000000},
          "secondary":{"usedPercent":1,"windowDurationMins":1440,"resetsAt":null},"planType":"free"}}
        """)
        let result = try #require(CodexRateLimitMapper.decodeRateLimitsResult(object))
        let mapped = try #require(CodexRateLimitMapper.map(result, now: Self.captured))
        #expect(mapped.windows.map(\.kind) == [.monthly, .other(minutes: 1440)])
        #expect(mapped.plan == "Free")
    }

    @Test func nullPrimaryKeepsSecondary() throws {
        let object = try Self.json("""
        {"rateLimits":{"primary":null,"secondary":{"usedPercent":16,"windowDurationMins":10080,"resetsAt":1791835147}}}
        """)
        let result = try #require(CodexRateLimitMapper.decodeRateLimitsResult(object))
        let mapped = try #require(CodexRateLimitMapper.map(result, now: Self.captured))
        #expect(mapped.windows.map(\.kind) == [.weekly])
        #expect(mapped.plan == nil)
    }

    @Test func prefersRateLimitsByLimitIdCodex() throws {
        let object = try Self.json("""
        {"rateLimits":{"limitId":"premium","primary":{"usedPercent":90,"windowDurationMins":300,"resetsAt":1791260000}},
         "rateLimitsByLimitId":{"premium":{"primary":{"usedPercent":90,"windowDurationMins":300}},
           "codex":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1791260000},"planType":"pro"}},
         "unknownKey":{"nested":true}}
        """)
        let result = try #require(CodexRateLimitMapper.decodeRateLimitsResult(object))
        let mapped = try #require(CodexRateLimitMapper.map(result, now: Self.captured))
        #expect(mapped.windows.map(\.usedPercent) == [12])
        #expect(mapped.plan == "Pro")
    }

    @Test func limitReachedFromReachedTypeOrOrdinaryUsage() throws {
        let reached = try #require(CodexRateLimitMapper.decodeRateLimitsResult(try Self.json("""
        {"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300,"resetsAt":1791260000},
          "rateLimitReachedType":"rate_limit_reached"}}
        """)))
        #expect(CodexRateLimitMapper.map(reached, now: Self.captured)?.limitReached == true)

        let blocked = try #require(CodexRateLimitMapper.decodeRateLimitsResult(try Self.json("""
        {"ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300}}}
        """)))
        #expect(CodexRateLimitMapper.map(blocked, now: Self.captured)?.limitReached == true)

        let unknown = try #require(CodexRateLimitMapper.decodeRateLimitsResult(try Self.json("""
        {"ordinaryUsageAllowed":null,"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300}}}
        """)))
        #expect(CodexRateLimitMapper.map(unknown, now: Self.captured)?.limitReached == false)
    }

    @Test func isStartedUsesTheTwoMinuteRule() {
        let now = Self.captured
        func started(_ used: Double, _ offset: TimeInterval) -> Bool {
            CodexRateLimitMapper.isStarted(
                usedPercent: used, resetsAt: now.addingTimeInterval(18_000 + offset), durationMinutes: 300, reference: now)
        }
        #expect(started(0, 0) == false)
        #expect(started(0, 120) == false)
        #expect(started(0, -120) == false)
        #expect(started(0, 121) == true)
        #expect(started(0, -3_600) == true)  // under 1% of a started window still reports 0
        #expect(started(1, 0) == true)
        #expect(CodexRateLimitMapper.isStarted(usedPercent: 0, resetsAt: nil, durationMinutes: 300, reference: now))
    }

    @Test func noSnapshotGivesNil() throws {
        let result = try #require(CodexRateLimitMapper.decodeRateLimitsResult(try Self.json(#"{"rateLimits":null}"#)))
        #expect(CodexRateLimitMapper.map(result, now: Self.captured) == nil)
        #expect(CodexRateLimitMapper.decodeRateLimitsResult("not an object") == nil)
    }

    @Test func tolerantScalarDecoding() throws {
        let object = try Self.json("""
        {"rateLimits":{"primary":{"usedPercent":true,"windowDurationMins":300},
          "secondary":{"usedPercent":7.5,"windowDurationMins":"10080","resetsAt":"2026-10-12T19:59:07Z"}}}
        """)
        let result = try #require(CodexRateLimitMapper.decodeRateLimitsResult(object))
        let snapshot = try #require(result.rateLimits)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 7.5)
        #expect(snapshot.secondary?.windowDurationMins == nil)
        #expect(snapshot.secondary?.resetsAt == Date(timeIntervalSince1970: 1_791_835_147))
    }

    @Test func accountResultDecoding() throws {
        let object = try JSONSerialization.jsonObject(with: Fixtures.data("codex/account_read_result.json"))
        let account = try #require(CodexRateLimitMapper.decodeAccountResult(object))
        #expect(account == CodexAccountReadResult(isLoggedIn: true, accountType: "chatgpt", planType: "plus"))
        #expect(!String(describing: account).contains("email"))

        let loggedOut = try #require(CodexRateLimitMapper.decodeAccountResult(
            try Self.json(#"{"account":null,"requiresOpenaiAuth":true,"workspaceRouting":null}"#)))
        #expect(loggedOut.isLoggedIn == false)
    }

    @Test func displayPlan() {
        #expect(CodexRateLimitMapper.displayPlan("plus") == "Plus")
        #expect(CodexRateLimitMapper.displayPlan("prolite") == "Prolite")
        #expect(CodexRateLimitMapper.displayPlan("unknown") == nil)
        #expect(CodexRateLimitMapper.displayPlan("") == nil)
        #expect(CodexRateLimitMapper.displayPlan(nil) == nil)
    }
}
