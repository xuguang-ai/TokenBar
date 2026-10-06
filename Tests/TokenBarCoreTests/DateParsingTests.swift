import Foundation
import Testing
@testable import TokenBarCore

@Suite("DateParsing")
struct DateParsingTests {
    private let expected = Date(timeIntervalSince1970: 1_791_300_000)  // 2026-10-06T15:20:00Z

    @Test(arguments: [
        "2026-10-06T15:20:00Z",
        "2026-10-06T15:20:00.0Z",
        "2026-10-06T15:20:00.000Z",
        "2026-10-06T15:20:00.000000+00:00",
        "2026-10-06T15:20:00.000000000Z",
        "2026-10-06T11:20:00-04:00",
    ])
    func parsesISO8601Variants(_ text: String) throws {
        let date = try #require(DateParsing.flexible(text))
        #expect(abs(date.timeIntervalSince(expected)) < 0.001)
    }

    @Test func keepsMillisecondsAndTruncatesBeyond() throws {
        let date = try #require(DateParsing.iso8601("2026-10-06T15:20:00.943648+00:00"))
        #expect(abs(date.timeIntervalSince(expected) - 0.943) < 0.0005)
    }

    @Test func numbersAreEpochSeconds() {
        #expect(DateParsing.flexible(NSNumber(value: 1_791_300_000)) == expected)
        #expect(DateParsing.flexible(NSNumber(value: 1_791_300_000.5)) == expected + 0.5)
        #expect(DateParsing.flexible(1_791_300_000) == expected)
    }

    @Test func rejectsBooleansGarbageAndNil() {
        #expect(DateParsing.flexible(NSNumber(value: true)) == nil)
        #expect(DateParsing.flexible("not a date") == nil)
        #expect(DateParsing.flexible(nil) == nil)
        #expect(DateParsing.flexible(["resets_at": 1]) == nil)
    }

    @Test func procStartWithDoubleSpaceDay() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(DateParsing.procStart("Tue Oct  6 05:33:53 2026", timeZone: utc))
        #expect(date == Date(timeIntervalSince1970: 1_791_264_833))
        #expect(DateParsing.procStart("garbage", timeZone: utc) == nil)
    }
}
