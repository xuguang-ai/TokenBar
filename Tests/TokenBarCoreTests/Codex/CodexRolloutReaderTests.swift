import Foundation
import Testing
@testable import TokenBarCore

extension CodexTestKit {
    /// LocalFileSystem that records every path whose contents are read.
    final class RecordingFileSystem: FileSystemAccess, @unchecked Sendable {
        private let base = LocalFileSystem()
        private let reads = Locked<[String]>([])
        var readPaths: [String] { reads.current }

        private func record(_ url: URL) { reads.withLock { $0.append(url.path) } }

        func readFile(_ url: URL) throws -> Data { record(url); return try base.readFile(url) }
        func readFilePrefix(_ url: URL, maxBytes: Int) throws -> Data {
            record(url); return try base.readFilePrefix(url, maxBytes: maxBytes)
        }
        func readFileTail(_ url: URL, maxBytes: Int) throws -> Data {
            record(url); return try base.readFileTail(url, maxBytes: maxBytes)
        }
        func writeFileAtomically(_ data: Data, to url: URL, permissions: UInt16) throws {
            try base.writeFileAtomically(data, to: url, permissions: permissions)
        }
        func createDirectory(_ url: URL, permissions: UInt16) throws { try base.createDirectory(url, permissions: permissions) }
        func setPermissions(_ url: URL, _ permissions: UInt16) throws { try base.setPermissions(url, permissions) }
        func contentsOfDirectory(_ url: URL) throws -> [URL] { try base.contentsOfDirectory(url) }
        func stat(_ url: URL) -> FileStat? { base.stat(url) }
        func lstat(_ url: URL) -> FileStat? { base.lstat(url) }
        func realpath(_ url: URL) -> URL? { base.realpath(url) }
        func fileExists(_ url: URL) -> Bool { base.fileExists(url) }
        func moveItem(_ source: URL, to destination: URL) throws { try base.moveItem(source, to: destination) }
        func removeItem(_ url: URL) throws { try base.removeItem(url) }
        func withExclusiveLock<T>(_ lockFile: URL, _ body: () throws -> T) throws -> T {
            try base.withExclusiveLock(lockFile, body)
        }
    }

    static func setModificationDate(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    static func tokenCountLine(timestamp: String, limitID: String? = "codex", used: Double, minutes: Int = 300,
                               resetsAt: Int = 1_791_835_147) -> String {
        let id = limitID.map { #""limit_id":"\#($0)","# } ?? ""
        return #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{\#(id)"primary":{"used_percent":\#(used),"window_minutes":\#(minutes),"resets_at":\#(resetsAt)},"secondary":null,"plan_type":"pro"}}}"#
    }
}

@Suite("CodexRolloutReader")
struct CodexRolloutReaderTests {
    @Test func mixedFixtureKeepsNewestCodexEventWithAWindow() throws {
        let temp = try TempDir()
        try temp.write("codex/sessions/2026/10/05/rollout-2026-10-05T20-30-00-a.jsonl", try Fixtures.data("codex/rollout_mixed.jsonl"))
        let reader = CodexRolloutReader(fileSystem: LocalFileSystem())
        let snapshot = try #require(reader.latestSnapshot(codexHome: temp.url.appendingPathComponent("codex")))

        let expectedEvent = try #require(DateParsing.iso8601("2026-10-05T20:50:00.123Z"))
        #expect(snapshot.eventAt == expectedEvent)
        #expect(snapshot.plan == "Plus")
        #expect(snapshot.limitReached == false)
        #expect(snapshot.windows.map(\.kind) == [.fiveHour, .weekly])
        #expect(snapshot.windows.map(\.usedPercent) == [98, 15])
        #expect(snapshot.windows.map(\.resetsAt) == [
            Date(timeIntervalSince1970: 1_791_248_347), Date(timeIntervalSince1970: 1_791_835_147),
        ])
        #expect(snapshot.windows.map(\.isStarted) == [true, true])
    }

    @Test func missingLimitIDCountsAndResetsInSecondsIsRelativeToTheEvent() throws {
        let temp = try TempDir()
        try temp.write("codex/archived_sessions/rollout-old.jsonl", try Fixtures.data("codex/rollout_resets_in_seconds.jsonl"))
        let reader = CodexRolloutReader(fileSystem: LocalFileSystem())
        let snapshot = try #require(reader.latestSnapshot(codexHome: temp.url.appendingPathComponent("codex")))
        let eventAt = try #require(DateParsing.iso8601("2026-08-21T10:00:00Z"))
        #expect(snapshot.eventAt == eventAt)
        #expect(snapshot.windows == [UsageWindow(kind: .weekly, usedPercent: 40, resetsAt: eventAt.addingTimeInterval(86_400))])
        #expect(snapshot.limitReached)
    }

    @Test func onlyNullWindowsOrForeignLimitsGiveNil() throws {
        let temp = try TempDir()
        try temp.write("codex/sessions/rollout-a.jsonl", """
        {"timestamp":"2026-10-05T20:55:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":null,"secondary":null}}}
        \(CodexTestKit.tokenCountLine(timestamp: "2026-10-05T20:56:00Z", limitID: "premium", used: 5))

        """)
        let reader = CodexRolloutReader(fileSystem: LocalFileSystem())
        #expect(reader.latestSnapshot(codexHome: temp.url.appendingPathComponent("codex")) == nil)
        #expect(reader.latestSnapshot(codexHome: temp.url.appendingPathComponent("missing")) == nil)
    }

    @Test func notStartedWindowIsJudgedAgainstTheEventTime() throws {
        let temp = try TempDir()
        let eventAt = try #require(DateParsing.iso8601("2026-10-05T20:00:00Z"))
        let reset = Int(eventAt.timeIntervalSince1970) + 300 * 60
        try temp.write("codex/sessions/rollout-a.jsonl",
                       CodexTestKit.tokenCountLine(timestamp: "2026-10-05T20:00:00Z", used: 0, resetsAt: reset) + "\n")
        let snapshot = try #require(CodexRolloutReader(fileSystem: LocalFileSystem())
            .latestSnapshot(codexHome: temp.url.appendingPathComponent("codex")))
        #expect(snapshot.windows.first?.isStarted == false)
    }

    @Test func partialFirstLineOfTheTailIsDropped() throws {
        // The tail starts exactly at a JSON object that is really the end of a longer garbage line.
        // It is newer than every complete line, so reading it would change the result.
        let partial = CodexTestKit.tokenCountLine(timestamp: "2026-10-05T23:00:00Z", used: 77)
        let base = CodexTestKit.tokenCountLine(timestamp: "2026-10-05T21:00:00Z", used: 11)
        // Pad `old` inside a JSON string so that len(partial) + len(old) + 2 == tailBytes.
        let fixedOld = base.dropLast() + #","pad":""# + "\"}"
        let padding = CodexRolloutReader.tailBytes - partial.utf8.count - fixedOld.utf8.count - 2
        let old = base.dropLast() + #","pad":""# + String(repeating: "x", count: padding) + "\"}"
        let file = "garbage-prefix-" + partial + "\n" + old + "\n"
        let temp = try TempDir()
        try temp.write("codex/sessions/rollout-big.jsonl", file)

        let snapshot = try #require(CodexRolloutReader(fileSystem: LocalFileSystem())
            .latestSnapshot(codexHome: temp.url.appendingPathComponent("codex")))
        #expect(snapshot.windows.map(\.usedPercent) == [11])
    }

    @Test func readsOnlyTheThreeNewestRolloutFiles() throws {
        let temp = try TempDir()
        let home = temp.url.appendingPathComponent("codex")
        let now = Date(timeIntervalSince1970: 1_791_300_000)
        // The file with the newest event has the oldest mtime, so it is not among the 3 newest files.
        let files: [(String, String, TimeInterval)] = [
            ("sessions/2026/10/01/rollout-1.jsonl", "2026-10-05T23:59:00Z", -400),
            ("sessions/2026/10/02/rollout-2.jsonl", "2026-10-05T10:00:00Z", -300),
            ("sessions/2026/10/03/rollout-3.jsonl", "2026-10-05T11:00:00Z", -200),
            ("archived_sessions/rollout-4.jsonl", "2026-10-05T12:00:00Z", -100),
        ]
        for (index, (path, timestamp, age)) in files.enumerated() {
            let url = try temp.write("codex/" + path,
                                     CodexTestKit.tokenCountLine(timestamp: timestamp, used: Double(index + 1)) + "\n")
            try CodexTestKit.setModificationDate(url, now.addingTimeInterval(age))
        }
        try temp.write("codex/state_5.sqlite", "sqlite")
        try temp.write("codex/logs_2.sqlite", "sqlite")
        try temp.write("codex/auth.json", "{}")
        try temp.write("codex/sessions/session_index.jsonl", "{}")
        try temp.write("codex/sessions/notes-rollout.jsonl", "{}")

        let fs = CodexTestKit.RecordingFileSystem()
        let reader = CodexRolloutReader(fileSystem: fs)
        #expect(reader.newestRolloutFiles(codexHome: home).map(\.lastPathComponent) == [
            "rollout-4.jsonl", "rollout-3.jsonl", "rollout-2.jsonl",
        ])
        let snapshot = try #require(reader.latestSnapshot(codexHome: home))
        #expect(snapshot.windows.map(\.usedPercent) == [4])
        #expect(Set(fs.readPaths.map { URL(fileURLWithPath: $0).lastPathComponent }) == [
            "rollout-4.jsonl", "rollout-3.jsonl", "rollout-2.jsonl",
        ])
    }
}
