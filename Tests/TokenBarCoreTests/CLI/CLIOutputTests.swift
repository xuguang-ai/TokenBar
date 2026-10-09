import Foundation
import Testing
@testable import TokenBarCore

/// Fixed inputs shared by the CLI golden tests.
enum CLIFixtures {
    static let now = Date(timeIntervalSince1970: 1_791_300_000)
    static let canaryEmail = "canary-email-7f3a@example.invalid"
    static let canaryUuid = "canary-uuid-7f3a"
    static let canarySecret = "canary-secret-7f3a"

    static let workID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let codexID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let personalID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let brokenID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    static func at(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(seconds) }

    /// Live Claude data with every window kind, an already-passed reset and canaries in the identity.
    static var work: AccountState {
        let config = AccountConfig(id: workID, provider: .claude, displayName: "Work",
                                   claudeConfigDir: "/Users/test/.tokenbar/claude/work", isDedicatedLogin: true)
        let snapshot = UsageSnapshot(
            accountID: workID, fetchedAt: at(-60), dataAsOf: at(-60), source: .claudeAPI,
            identity: AccountIdentity(accountUuid: canaryUuid, plan: "Max", organization: "Org", email: canaryEmail),
            windows: [
                UsageWindow(kind: .fiveHour, usedPercent: 68, resetsAt: at(2 * 3600 + 14 * 60)),
                UsageWindow(kind: .weekly, usedPercent: 19.7, resetsAt: at(3 * 86400 + 4 * 3600)),
                UsageWindow(kind: .weeklySonnet, usedPercent: 8, resetsAt: at(3 * 86400 + 4 * 3600)),
                UsageWindow(kind: .weeklyOpus, usedPercent: 100, resetsAt: at(-30)),
                UsageWindow(kind: .model(name: "Fable"), usedPercent: 40, resetsAt: at(45 * 60)),
            ],
            limitReached: true)
        return AccountState(config: config, lastSnapshot: snapshot, lastError: nil, lastAttemptAt: at(-60))
    }

    /// Codex from the rollout log: a not-started window, a monthly and an "other" window.
    static var codex: AccountState {
        let config = AccountConfig(id: codexID, provider: .codex, displayName: "Codex")
        let snapshot = UsageSnapshot(
            accountID: codexID, fetchedAt: at(-120), dataAsOf: at(-14 * 60), source: .codexRollout(eventAt: at(-14 * 60)),
            identity: AccountIdentity(plan: "Plus"),
            windows: [
                UsageWindow(kind: .fiveHour, usedPercent: 0, resetsAt: nil, isStarted: false),
                UsageWindow(kind: .weekly, usedPercent: 16, resetsAt: at(6 * 86400 + 17 * 3600)),
                UsageWindow(kind: .monthly, usedPercent: 3, resetsAt: at(20 * 86400)),
                UsageWindow(kind: .other(minutes: 1440), usedPercent: 50, resetsAt: at(30)),
            ],
            limitReached: false)
        return AccountState(config: config, lastSnapshot: snapshot, lastError: nil, lastAttemptAt: at(-120))
    }

    /// A failed refresh over an older cached snapshot; the error payload carries a canary.
    static var personal: AccountState {
        let config = AccountConfig(id: personalID, provider: .claude, displayName: "Personal",
                                   claudeConfigDir: "~/.claude-personal")
        let snapshot = UsageSnapshot(
            accountID: personalID, fetchedAt: at(-3600), dataAsOf: at(-3 * 3600),
            source: .claudeCache(fetchedAt: at(-3 * 3600)),
            identity: AccountIdentity(accountUuid: canaryUuid, plan: "Pro", email: canaryEmail),
            windows: [UsageWindow(kind: .fiveHour, usedPercent: 97.5, resetsAt: at(20 * 60))],
            limitReached: false)
        return AccountState(config: config, lastSnapshot: snapshot,
                            lastError: .decoding(codingPath: ["five_hour", canarySecret]), lastAttemptAt: at(-5))
    }

    /// Never had data; the login hint carries a canary.
    static var broken: AccountState {
        let config = AccountConfig(id: brokenID, provider: .claude, displayName: "Side",
                                   claudeConfigDir: "/tmp/side")
        return AccountState(config: config, lastSnapshot: nil,
                            lastError: .notLoggedIn(hint: .claude(configDir: "/tmp/\(canarySecret)")), lastAttemptAt: at(-5))
    }

    static var states: [AccountState] { [work, codex, personal, broken] }
}

/// Compares `actual` with Fixtures/cli/<name>. Set TOKENBAR_UPDATE_GOLDENS=1 to rewrite the files.
func expectGolden(_ actual: String, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let url = Fixtures.url("cli/\(name)")
    if ProcessInfo.processInfo.environment["TOKENBAR_UPDATE_GOLDENS"] == "1" {
        try actual.write(to: url, atomically: true, encoding: .utf8)
        return
    }
    let expected = try Fixtures.string("cli/\(name)")
    #expect(actual == expected, "golden \(name) differs", sourceLocation: sourceLocation)
}

@Suite("CLI output")
struct CLIOutputTests {
    @Test func statusJSONMatchesGolden() throws {
        let json = CLIStatusBuilder.encode(CLIStatusBuilder.build(states: CLIFixtures.states, now: CLIFixtures.now))
        try expectGolden(json, "status.json")
    }

    @Test func statusTableMatchesGolden() throws {
        let remaining = CLIStatusTable.render(states: CLIFixtures.states, displayMode: .remaining, now: CLIFixtures.now)
        try expectGolden(remaining, "status-remaining.txt")
        let used = CLIStatusTable.render(states: CLIFixtures.states, displayMode: .used, now: CLIFixtures.now)
        try expectGolden(used, "status-used.txt")
    }

    @Test func statusLinesFollowTheCardStates() {
        let utc = TimeZone(identifier: "UTC")!
        func line(_ state: AccountState) -> String? { CLIStatusTable.statusLine(state, now: CLIFixtures.now, timeZone: utc) }
        var paused = CLIFixtures.work
        paused.lastError = .rateLimited(until: CLIFixtures.at(25 * 60))
        // 1_791_300_000 is 15:20 UTC.
        #expect(line(paused) == "Paused until 15:45 · Anthropic is rate-limiting usage checks · Last updated 1 min ago")
        paused.lastError = .rateLimited(until: CLIFixtures.at(-60))
        #expect(line(paused) == "⚠ Anthropic is rate-limiting usage checks · Last updated 1 min ago")
        paused.lastError = .unauthorized(until: CLIFixtures.at(25 * 60))
        #expect(line(paused) == "Paused until 15:45 · Last updated 1 min ago")
        #expect(line(CLIFixtures.work) == nil)
        #expect(line(CLIFixtures.codex) == "(cached · 14 min ago)")
        var waiting = CLIFixtures.personal
        waiting.lastError = .waitingForClaudeCode
        #expect(line(waiting) == "⚠ Waiting for Claude Code to refresh · Last updated 3 h ago (cached)")
        #expect(line(CLIFixtures.broken) == "⚠ Not logged in")
    }

    @Test func jsonFieldsFollowTheSpec() throws {
        let dto = CLIStatusBuilder.build(states: CLIFixtures.states, now: CLIFixtures.now)
        #expect(dto.generatedAt.hasSuffix("Z"))
        let work = try #require(dto.accounts.first)
        // Worst started window is five_hour at 68% used; the passed Opus reset does not count.
        #expect(work.usage == 0.68)
        #expect(work.resetAt == CLIFormat.iso8601(CLIFixtures.at(2 * 3600 + 14 * 60)))
        #expect(work.windows.map(\.kind) == ["five_hour", "weekly", "weekly_sonnet", "weekly_opus", "model:Fable"])
        let opus = work.windows[3]
        #expect(opus.usedPercent == 0 && opus.remainingPercent == 100 && !opus.started && opus.resetsAt == nil)
        #expect(work.windows[1].remainingPercent == 80.3)
        #expect(work.source == "claude_api")
        #expect(work.error == nil)

        let codex = dto.accounts[1]
        #expect(codex.source == "codex_rollout")
        #expect(codex.windows.map(\.kind) == ["five_hour", "weekly", "monthly", "other_1440"])

        let personal = dto.accounts[2]
        #expect(personal.source == "claude_cache")
        #expect(personal.error == CLIErrorJSON(code: "decoding"))
        #expect(personal.dataAsOf == CLIFormat.iso8601(CLIFixtures.at(-3 * 3600)))

        let broken = dto.accounts[3]
        #expect(broken.usage == nil && broken.source == nil && broken.windows.isEmpty)
        #expect(broken.error == CLIErrorJSON(code: "not_logged_in"))
    }

    @Test func noStartedWindowMeansZeroUsageAndNullReset() {
        var state = CLIFixtures.codex
        state.lastSnapshot?.windows = [UsageWindow(kind: .fiveHour, usedPercent: 0, resetsAt: nil, isStarted: false)]
        let account = CLIStatusBuilder.account(state, now: CLIFixtures.now)
        #expect(account.usage == 0)
        #expect(account.resetAt == nil)
        let json = CLIStatusBuilder.encode(account)
        #expect(json.contains("\"reset_at\" : null"))
        #expect(json.contains("\"error\" : null"))
    }

    @Test func allKindAndSourceStrings() {
        #expect(CLIStatusBuilder.kindString(.weeklyOpus) == "weekly_opus")
        #expect(CLIStatusBuilder.kindString(.other(minutes: 90)) == "other_90")
        #expect(CLIStatusBuilder.sourceString(.claudeAPIAfterCLIRefresh) == "claude_api_after_cli_refresh")
        #expect(CLIStatusBuilder.sourceString(.codexAppServer) == "codex_app_server")
    }

    @Test func canariesNeverAppearInAnyOutput() {
        let outputs = [
            CLIStatusBuilder.encode(CLIStatusBuilder.build(states: CLIFixtures.states, now: CLIFixtures.now)),
            CLIStatusTable.render(states: CLIFixtures.states, displayMode: .remaining, now: CLIFixtures.now),
            CLIStatusTable.render(states: CLIFixtures.states, displayMode: .used, now: CLIFixtures.now),
        ]
        for output in outputs {
            #expect(!output.contains("canary"))
            #expect(!output.contains("@"))
            #expect(!output.lowercased().contains("uuid"))
            #expect(!output.contains("email"))
            #expect(!output.contains("\u{1B}"), "no ANSI escapes")
        }
    }

    @Test func barAndRowFormatting() {
        #expect(CLIStatusTable.bar(32) == "███░░░░░░░")
        #expect(CLIStatusTable.bar(100) == "██████████")
        #expect(CLIStatusTable.bar(140) == "██████████")
        #expect(CLIStatusTable.bar(-3) == "░░░░░░░░░░")
    }

    @Test func controlCharactersInNamesAreNeutralised() {
        var state = CLIFixtures.codex
        state.config.displayName = "Evil\u{1B}[31mName"
        let table = CLIStatusTable.render(states: [state], displayMode: .remaining, now: CLIFixtures.now)
        #expect(!table.contains("\u{1B}"))
        #expect(table.hasPrefix("Codex · Evil [31mName  Plus\n"))
    }
}

@Suite("CLI sessions output")
struct CLISessionsOutputTests {
    static let accounts = [CLIFixtures.work.config, CLIFixtures.codex.config]
    static let groups = [
        SessionGroup(accountID: CLIFixtures.workID, sessions: [
            SessionInfo(pid: 101, cwd: "/Users/test/src/TokenBar", status: .busy,
                        statusUpdatedAt: CLIFixtures.at(-180), startedAt: CLIFixtures.at(-7200),
                        configDir: "/Users/test/.tokenbar/claude/work"),
            SessionInfo(pid: 102, name: "Review", status: .idle, statusUpdatedAt: nil,
                        startedAt: CLIFixtures.at(-3720), configDir: "/Users/test/.tokenbar/claude/work"),
        ]),
        SessionGroup(accountID: nil, sessions: [
            SessionInfo(pid: 201, status: .unknown, configDir: "/Users/test/.claude-other"),
        ]),
    ]

    @Test func tableMatchesGolden() throws {
        try expectGolden(CLISessionsRenderer.table(groups: Self.groups, accounts: Self.accounts, now: CLIFixtures.now),
                         "sessions.txt")
    }

    @Test func jsonMatchesGolden() throws {
        let json = CLIStatusBuilder.encode(CLISessionsRenderer.json(groups: Self.groups, accounts: Self.accounts,
                                                                    now: CLIFixtures.now))
        try expectGolden(json, "sessions.json")
    }

    @Test func noSessions() {
        #expect(CLISessionsRenderer.table(groups: [], accounts: Self.accounts, now: CLIFixtures.now)
            == "No Claude Code sessions running.\n")
    }
}
