import Foundation
import Testing
@testable import TokenBarCore

@Suite("SessionMonitor")
struct SessionMonitorTests {
    private struct StubConfigReader: ClaudeConfigReading {
        /// Keyed by the configDir string passed in (nil = default dir).
        var uuids: [String?: String]
        let calls = Locked<[String?]>([])
        func accountUUID(configDir: String?) async -> String? {
            calls.withLock { $0.append(configDir) }
            return uuids[configDir] ?? nil
        }
    }

    /// Writes `<home>/<dir>/sessions/<pid>.json` and marks the pid alive with `startTime`.
    private static func register(
        _ harness: TestHarness, dir: String = ".claude", pid: Int32, status: String = "busy",
        kind: String? = "interactive", updatedMs: Int = 1_791_296_400_000, procStart: String? = nil,
        startTime: Date? = nil, alive: Bool = true
    ) throws {
        var object: [String: Any] = ["pid": pid, "status": status, "statusUpdatedAt": updatedMs, "cwd": "/w/p\(pid)"]
        if let kind { object["kind"] = kind }
        if let procStart { object["procStart"] = procStart }
        let data = try JSONSerialization.data(withJSONObject: object)
        try harness.temp.write("home/\(dir)/sessions/\(pid).json", data)
        if alive { harness.inspector.setAlive(pid, startTime: startTime) }
    }

    /// `procStart` text the way Claude Code writes it (day padded with a second space), local time zone.
    private static func procStartText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        var parts = formatter.string(from: date).split(separator: " ").map(String.init)
        if parts[2].count == 1 { parts[2] = " " + parts[2] }
        return parts.joined(separator: " ")
    }

    private static func monitor(_ harness: TestHarness, uuids: [String?: String] = [:]) -> SessionMonitor {
        SessionMonitor(env: harness.env, configReader: StubConfigReader(uuids: uuids))
    }

    // MARK: Decoding

    @Test func decodesTheRegistryFixture() throws {
        let session = try #require(SessionMonitor.decode(try Fixtures.data("sessions/registry_interactive.json"), configDir: "/c"))
        #expect(session.pid == 4321)
        #expect(session.sessionId == "00000000-0000-4000-8000-000000000001")
        #expect(session.name == "demo refactor")
        #expect(session.status == .busy)
        #expect(session.statusUpdatedAt == Date(timeIntervalSince1970: 1_791_296_400))
        #expect(session.startedAt == Date(timeIntervalSince1970: 1_791_292_800))
        #expect(session.procStart == "Tue Oct  6 05:33:53 2026")
        #expect(session.kind == "interactive")
        #expect(session.entrypoint == "cli")
        #expect(session.version == "2.1.289")
        #expect(session.configDir == "/c")
        #expect(DateParsing.procStart(session.procStart ?? "") != nil)
    }

    @Test func unknownStatusAndMissingFields() throws {
        let odd = try #require(SessionMonitor.decode(Data(#"{"pid":7,"status":"thinking"}"#.utf8), configDir: "/c"))
        #expect(odd.status == .unknown)
        #expect(odd.kind == nil)
        #expect(SessionMonitor.isInteractive(odd))
        let noStatus = try #require(SessionMonitor.decode(Data(#"{"pid":8}"#.utf8), configDir: "/c"))
        #expect(noStatus.status == .unknown)
        #expect(SessionMonitor.decode(Data(#"{"status":"busy"}"#.utf8), configDir: "/c") == nil)
        #expect(SessionMonitor.decode(Data(#"{"pid":-1}"#.utf8), configDir: "/c") == nil)
        #expect(SessionMonitor.decode(Data("garbage".utf8), configDir: "/c") == nil)
    }

    // MARK: Watched directories

    @Test func watchedDirectoriesAreDefaultPlusClaudeDirsDeduplicated() async throws {
        let harness = try TestHarness()
        let home = harness.home.path
        let settings = AppSettings(accounts: [
            AccountConfig(provider: .claude, displayName: "Default"),
            AccountConfig(provider: .claude, displayName: "Work", claudeConfigDir: "~/.claude-work/"),
            AccountConfig(provider: .claude, displayName: "Work again", claudeConfigDir: home + "/.claude-work"),
            AccountConfig(provider: .claude, displayName: "Explicit default", claudeConfigDir: "~/.claude"),
            AccountConfig(provider: .codex, displayName: "Codex", codexHome: "~/.codex"),
        ])
        let paths = SessionMonitor.watchedDirectoryPaths(settings: settings, home: harness.home)
        #expect(paths.map(\.path) == [home + "/.claude", home + "/.claude-work"])
        #expect(paths.map(\.configDir) == [nil, "~/.claude-work/"])

        let reader = StubConfigReader(uuids: [nil: "U-default", home + "/.claude-work/": "U-work"])
        let watched = await SessionMonitor(env: harness.env, configReader: reader).watchedDirectories(settings: settings)
        #expect(watched == [
            SessionWatchedDirectory(path: home + "/.claude", configDir: nil, accountUuid: "U-default"),
            SessionWatchedDirectory(path: home + "/.claude-work", configDir: "~/.claude-work/", accountUuid: "U-work"),
        ])
        #expect(reader.calls.current == [nil, home + "/.claude-work/"])
    }

    // MARK: Liveness

    @Test func livenessAndProcStartRules() async throws {
        let harness = try TestHarness()
        let start = harness.clock.now.addingTimeInterval(-3_600)
        try Self.register(harness, pid: 101, procStart: Self.procStartText(start), startTime: start)
        try Self.register(harness, pid: 102, procStart: Self.procStartText(start), startTime: start.addingTimeInterval(2))
        try Self.register(harness, pid: 103, procStart: Self.procStartText(start), startTime: start.addingTimeInterval(600))
        try Self.register(harness, pid: 104, procStart: Self.procStartText(start.addingTimeInterval(5 * 3_600)), startTime: start)
        try Self.register(harness, pid: 105, procStart: Self.procStartText(start.addingTimeInterval(-5.75 * 3_600)), startTime: start)
        try Self.register(harness, pid: 106, procStart: Self.procStartText(start.addingTimeInterval(5 * 3_600 + 420)), startTime: start)
        try Self.register(harness, pid: 107, procStart: Self.procStartText(start.addingTimeInterval(15 * 3_600)), startTime: start)
        try Self.register(harness, pid: 108, procStart: "not a date", startTime: start)
        try Self.register(harness, pid: 109, procStart: Self.procStartText(start), startTime: nil)  // short proc_pidinfo
        try Self.register(harness, pid: 110, startTime: start)  // no procStart
        try Self.register(harness, pid: 111, procStart: Self.procStartText(start), startTime: start, alive: false)

        let live = Self.monitor(harness).liveSessions(inDirectory: harness.home.appendingPathComponent(".claude").path)
        #expect(Set(live.map(\.pid)) == [101, 102, 104, 105, 108, 109, 110])
        // Stale files are ignored, not deleted.
        #expect(FileManager.default.fileExists(atPath: harness.home.appendingPathComponent(".claude/sessions/103.json").path))
    }

    @Test func startTimeMatching() {
        let base = Date(timeIntervalSince1970: 1_791_000_000)
        #expect(SessionMonitor.startTimesMatch(recorded: base, actual: base.addingTimeInterval(-2)))
        #expect(!SessionMonitor.startTimesMatch(recorded: base, actual: base.addingTimeInterval(3)))
        #expect(SessionMonitor.startTimesMatch(recorded: base, actual: base.addingTimeInterval(900)))
        #expect(SessionMonitor.startTimesMatch(recorded: base, actual: base.addingTimeInterval(14 * 3_600 + 1)))
        #expect(!SessionMonitor.startTimesMatch(recorded: base, actual: base.addingTimeInterval(14 * 3_600 + 900)))
        #expect(!SessionMonitor.startTimesMatch(recorded: base, actual: base.addingTimeInterval(450)))
    }

    // MARK: Filtering

    @Test func onlyInteractiveSessionsAndNotExcludedPIDs() async throws {
        let harness = try TestHarness()
        try Self.register(harness, pid: 201, kind: "interactive")
        try Self.register(harness, pid: 202, kind: nil)
        try Self.register(harness, pid: 203, kind: "sdk-cli")
        try Self.register(harness, pid: 204, kind: "print")
        try Self.register(harness, pid: 205)
        let settings = AppSettings(accounts: [])
        let groups = await Self.monitor(harness).scan(settings: settings, identities: [:], excludePIDs: [205])
        #expect(groups.count == 1)
        #expect(groups.first?.accountID == nil)
        #expect(Set(groups.first?.sessions.map(\.pid) ?? []) == [201, 202])
    }

    @Test func neverOpensKeyFilesOrSymlinks() async throws {
        let harness = try TestHarness()
        try Self.register(harness, pid: 301)
        // A directory named like a key file: reading it would throw, and the recorder sees any attempt.
        try harness.temp.makeDirectory("home/.claude/sessions/301.key")
        let keyFile = try harness.temp.write("home/.claude/sessions/302.key", #"{"pid":302,"status":"busy"}"#)
        harness.inspector.setAlive(302, startTime: nil)
        try FileManager.default.createSymbolicLink(
            at: harness.home.appendingPathComponent(".claude/sessions/302.json"), withDestinationURL: keyFile)
        try harness.temp.makeDirectory("home/.claude/sessions/303.json")

        var env = harness.env
        let recorder = ReadRecorder()
        env.fileSystem = recorder
        let monitor = SessionMonitor(env: env, configReader: StubConfigReader(uuids: [:]))
        let groups = await monitor.scan(settings: AppSettings(accounts: []), identities: [:], excludePIDs: [])

        #expect(groups.flatMap(\.sessions).map(\.pid) == [301])
        #expect(recorder.readPaths.map { URL(fileURLWithPath: $0).lastPathComponent } == ["301.json"])
        #expect(!recorder.readPaths.contains { $0.hasSuffix(".key") })
    }

    // MARK: Attribution

    @Test func attributionPrefersDedicatedAccountsAndUnmatchedGoToOther() async throws {
        let harness = try TestHarness()
        let home = harness.home.path
        let main = AccountConfig(provider: .claude, displayName: "Main")
        let dedicated = AccountConfig(provider: .claude, displayName: "Dedicated",
                                      claudeConfigDir: home + "/.tokenbar/claude/a", isDedicatedLogin: true)
        let personal = AccountConfig(provider: .claude, displayName: "Personal", claudeConfigDir: "~/.claude-personal")
        let disabled = AccountConfig(provider: .claude, displayName: "Off", claudeConfigDir: "~/.claude-off", isEnabled: false)
        let settings = AppSettings(accounts: [main, dedicated, personal, disabled])
        // ~/.claude is logged in as U1, the same account as the dedicated login.
        let identities: [UUID: AccountIdentity] = [
            main.id: AccountIdentity(accountUuid: "U1"),
            dedicated.id: AccountIdentity(accountUuid: "U1"),
            personal.id: AccountIdentity(accountUuid: "U2"),
            disabled.id: AccountIdentity(accountUuid: "U4"),
        ]
        let uuids: [String?: String] = [
            nil: "U1", home + "/.tokenbar/claude/a": "U1", home + "/.claude-personal": "U3", home + "/.claude-off": "U4",
        ]
        try Self.register(harness, dir: ".claude", pid: 401)
        try Self.register(harness, dir: ".tokenbar/claude/a", pid: 402)
        try Self.register(harness, dir: ".claude-personal", pid: 403)
        try Self.register(harness, dir: ".claude-off", pid: 404)

        let groups = await Self.monitor(harness, uuids: uuids).scan(settings: settings, identities: identities, excludePIDs: [])
        #expect(groups.map(\.accountID) == [dedicated.id, nil])
        #expect(groups[0].sessions.map(\.pid) == [401, 402])
        #expect(Set(groups[1].sessions.map(\.pid)) == [403, 404])
        #expect(groups[0].sessions[0].configDir == home + "/.claude")
    }

    @Test func defaultAccountGetsItsOwnDirWhenNoDedicatedMatch() async throws {
        let harness = try TestHarness()
        let main = AccountConfig(provider: .claude, displayName: "Main")
        let settings = AppSettings(accounts: [main])
        try Self.register(harness, pid: 501)
        let groups = await Self.monitor(harness, uuids: [nil: "U1"])
            .scan(settings: settings, identities: [main.id: AccountIdentity(accountUuid: "U1")], excludePIDs: [])
        #expect(groups.map(\.accountID) == [main.id])
    }

    // MARK: Sorting

    @Test func busyFirstLongestRunningFirst() async throws {
        let harness = try TestHarness()
        try Self.register(harness, pid: 601, status: "idle", updatedMs: 1_000)
        try Self.register(harness, pid: 602, status: "busy", updatedMs: 3_000)
        try Self.register(harness, pid: 603, status: "busy", updatedMs: 2_000)
        try Self.register(harness, pid: 604, status: "weird", updatedMs: 500)
        try Self.register(harness, pid: 605, status: "idle", updatedMs: 4_000)
        let groups = await Self.monitor(harness).scan(settings: AppSettings(accounts: []), identities: [:], excludePIDs: [])
        let group = try #require(groups.first)
        #expect(group.sessions.map(\.pid) == [603, 602, 601, 605, 604])
        #expect(group.busy.map(\.pid) == [603, 602])
        #expect(group.notBusy.count == 3)
    }

    // MARK: Step ② precondition

    @Test func hasLiveSessions() async throws {
        let harness = try TestHarness()
        let monitor = Self.monitor(harness)
        #expect(await monitor.hasLiveSessions(configDir: "~/.claude-work") == false)
        try Self.register(harness, dir: ".claude-work", pid: 702, alive: false)
        #expect(await monitor.hasLiveSessions(configDir: "~/.claude-work/") == false)
        try Self.register(harness, dir: ".claude-work", pid: 703)
        #expect(await monitor.hasLiveSessions(configDir: harness.home.path + "/.claude-work"))
        #expect(await monitor.hasLiveSessions(configDir: "~/.claude-work", excludePIDs: [703]) == false)
    }

    @Test func nonInteractiveSessionsBlockStep2ButAreNotDisplayed() async throws {
        let harness = try TestHarness()
        let monitor = Self.monitor(harness)
        try Self.register(harness, dir: ".claude-work", pid: 701, kind: "sdk-cli")
        // Any live session in the dir blocks step ②, whatever its kind ...
        #expect(await monitor.hasLiveSessions(configDir: "~/.claude-work"))
        #expect(await monitor.hasLiveSessions(configDir: "~/.claude-work", excludePIDs: [701]) == false)
        // ... while the session list still shows interactive sessions only.
        #expect(monitor.liveSessions(inDirectory: harness.home.path + "/.claude-work").isEmpty)
    }
}
