import Foundation
import Testing
@testable import TokenBarCore

/// Regression for spec §13 V3: the live `/api/oauth/usage` body (2026-10-06) has many more top-level
/// keys than the reverse-engineered shape, several of them window-like. The fixture copies that key set
/// with synthetic values. Only the known windows and model-scoped `limits[]` rows may be mapped.
@Suite("Claude live response shape")
struct ClaudeLiveShapeTests {
    private let now = Date(timeIntervalSince1970: 1_791_300_000)  // 2026-10-06T15:20:00Z

    @Test func mapsOnlyKnownWindowsAndModelRows() throws {
        let mapped = try ClaudeUsageMapper.map(data: Fixtures.data("claude/usage-response-live-shape.json"))
        #expect(mapped.windows.map(\.kind) == [.fiveHour, .weekly, .model(name: "Fable")])
        #expect(mapped.windows.map(\.usedPercent) == [39, 74, 79])
        #expect(!mapped.limitReached, "window-like unknown keys at 100% must not count")
        #expect(mapped.windows[2].resetsAt == Date(timeIntervalSince1970: 1_791_378_000))
    }

    @Test func theModelLimitIsTheBindingConstraint() throws {
        let mapped = try ClaudeUsageMapper.map(data: Fixtures.data("claude/usage-response-live-shape.json"))
        let snapshot = UsageSnapshot(accountID: UUID(), fetchedAt: now, dataAsOf: now, source: .claudeAPI,
                                     identity: AccountIdentity(plan: "Team"), windows: mapped.windows,
                                     limitReached: mapped.limitReached)
        let display = DisplayDerivation.derive(snapshot, now: now)
        #expect(display.worstWindow?.kind == .model(name: "Fable"))
        #expect(display.status == .gettingLow)
        #expect(display.worstWindow.map { DisplayDerivation.percentText($0, mode: .remaining) } == "21% left")
    }
}
