import Foundation
import Testing
@testable import TokenBarCore

@Suite("ClaudeUsageMapper")
struct ClaudeUsageMapperTests {
    private func map(_ json: String) throws -> ClaudeMappedUsage {
        try ClaudeUsageMapper.map(data: Data(json.utf8))
    }

    @Test func mapsTheReferenceResponse() throws {
        let usage = try ClaudeUsageMapper.map(data: try Fixtures.data("claude/usage-response.json"))
        #expect(usage.windows.map(\.kind) == [.fiveHour, .weekly, .weeklySonnet, .model(name: "Claude Opus 4.6")])
        #expect(usage.windows.map(\.usedPercent) == [68, 42, 31, 12])
        #expect(usage.windows[0].resetsAt == DateParsing.iso8601("2026-10-05T18:00:00Z"))
        #expect(usage.windows.allSatisfy { $0.isStarted })
        #expect(usage.limitReached == false)
    }

    @Test func mapsTheCachedUtilizationShape() throws {
        let data = try Fixtures.data("claude/cached-usage-utilization.json")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inner = try #require(object["utilization"] as? [String: Any])
        let usage = ClaudeUsageMapper.map(inner)
        #expect(usage.windows.map(\.kind) == [.fiveHour, .weekly])
        #expect(usage.windows.map(\.usedPercent) == [68, 42])
    }

    @Test func skipsNullAndNonObjectWindows() throws {
        let usage = try map("""
            {"five_hour": null, "seven_day": "x", "seven_day_sonnet": {"utilization": null, "resets_at": null},
             "seven_day_opus": {"utilization": true}, "brand_new_key": {"utilization": 99}}
            """)
        #expect(usage.windows.isEmpty)
        #expect(usage.limitReached == false)
    }

    @Test func keepsWindowsWithUnparseableReset() throws {
        let usage = try map(#"{"five_hour": {"utilization": 5, "resets_at": "soon"}}"#)
        #expect(usage.windows == [UsageWindow(kind: .fiveHour, usedPercent: 5, resetsAt: nil)])
    }

    @Test func overHundredSetsLimitReached() throws {
        let usage = try map(#"{"seven_day": {"utilization": 104.5, "resets_at": null}}"#)
        #expect(usage.windows.first?.usedPercent == 104.5)
        #expect(usage.limitReached)
    }

    @Test func modelRowAtHundredSetsLimitReached() throws {
        let usage = try map(#"{"limits": [{"percent": 100, "scope": {"model": {"display_name": "M"}}}]}"#)
        #expect(usage.limitReached)
    }

    @Test func epochResetOnLimitRows() throws {
        let usage = try map("""
            {"limits": [
              {"percent": 7, "resets_at": 1791500000, "scope": {"model": {"display_name": "Claude Sonnet"}}},
              {"percent": 9, "scope": {"model": null, "surface": {"display_name": "Web"}}},
              {"percent": null, "scope": {"model": {"display_name": "No percent"}}},
              {"percent": 3, "scope": {"model": {"display_name": "  "}}},
              "garbage"
            ]}
            """)
        #expect(usage.windows == [
            UsageWindow(kind: .model(name: "Claude Sonnet"), usedPercent: 7, resetsAt: Date(timeIntervalSince1970: 1_791_500_000)),
        ])
    }

    @Test func nonObjectBodyIsADecodingError() {
        #expect(throws: ProviderError.decoding(codingPath: [])) { try map("[1,2]") }
        #expect(throws: ProviderError.decoding(codingPath: [])) { try map("not json") }
    }
}
