import Darwin
import Foundation
import Testing
@testable import TokenBarCore

// Tests for the shared contract (plan Task 1): pure helpers, models and LocalFileSystem.

private let fixedNow = Date(timeIntervalSince1970: 1_791_300_000)

@Suite("ClaudePaths")
struct ClaudePathsTests {
    @Test func defaultServiceHasNoSuffix() {
        #expect(ClaudePaths.keychainService(configDir: nil) == "Claude Code-credentials")
    }

    @Test func hashedServiceMatchesClaudeCode() {
        #expect(ClaudePaths.keychainService(configDir: "/Users/xai/.claude") == "Claude Code-credentials-4405f529")
        #expect(ClaudePaths.keychainService(configDir: "/Users/xai/.claude/") == "Claude Code-credentials-338287a3")
    }

    @Test func hashUsesNFC() {
        #expect(ClaudePaths.keychainService(configDir: "/Users/x/caf\u{E9}") == "Claude Code-credentials-d4155044")
        #expect(ClaudePaths.keychainService(configDir: "/Users/x/cafe\u{301}") == "Claude Code-credentials-d4155044")
    }

    @Test func tildeExpandsOnlyAtTheStart() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(ClaudePaths.expandTilde("~/.claude-work/", home: home) == "/Users/me/.claude-work/")
        #expect(ClaudePaths.expandTilde("~", home: home) == "/Users/me")
        #expect(ClaudePaths.expandTilde("/a/~/b", home: home) == "/a/~/b")
        #expect(ClaudePaths.expandTilde("~other/x", home: home) == "~other/x")
    }

    @Test func trailingSlashVariantToggles() {
        #expect(ClaudePaths.trailingSlashVariant("/d/x") == "/d/x/")
        #expect(ClaudePaths.trailingSlashVariant("/d/x/") == "/d/x")
        #expect(ClaudePaths.trailingSlashVariant(nil) == nil)
    }

    @Test func keychainAccountFallsBackForInvalidNames() {
        #expect(ClaudePaths.keychainAccount(userName: "xai") == "xai")
        #expect(ClaudePaths.keychainAccount(userName: "first.last-2_x") == "first.last-2_x")
        #expect(ClaudePaths.keychainAccount(userName: "bad name") == "claude-code-user")
        #expect(ClaudePaths.keychainAccount(userName: "") == "claude-code-user")
    }

    @Test func globalConfigPrecedence() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(ClaudePaths.globalConfigCandidates(nil, home: home).map(\.path)
            == ["/Users/me/.claude/.config.json", "/Users/me/.claude.json"])
        #expect(ClaudePaths.globalConfigCandidates("/d/x", home: home).map(\.path)
            == ["/d/x/.config.json", "/d/x/.claude.json"])
    }
}

@Suite("AppSettings")
struct AppSettingsTests {
    @Test func defaultsHaveOneClaudeAndOneCodexAccount() {
        let settings = AppSettings.makeDefault()
        #expect(settings.accounts.map(\.provider) == [.claude, .codex])
        #expect(settings.accounts[0].claudeConfigDir == nil)
        #expect(!settings.accounts[0].isDedicatedLogin)
        #expect(settings.refreshIntervalMinutes == 5)
        // Used, as Claude's /usage and Codex's /status show it.
        #expect(settings.displayMode == .used)
        // Clock times ("Wed 11:00 PM"), as the user asked; the countdown is a setting.
        #expect(settings.resetTimeStyle == .clock)
        #expect(settings.allowClaudeCodeRefresh)
    }

    @Test func decodesMissingFieldsWithDefaultsAndIgnoresUnknownKeys() throws {
        let json = #"""
        {"accounts":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","provider":"codex"}],
         "futureKey":true,"refreshIntervalMinutes":7}
        """#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.schemaVersion == AppSettings.currentSchemaVersion)
        #expect(settings.refreshIntervalMinutes == 5)
        #expect(settings.resetTimeStyle == .clock)
        #expect(settings.accounts[0].displayName == "Codex")
        #expect(settings.accounts[0].isEnabled)
        #expect(!settings.accounts[0].isDedicatedLogin)
    }

    @Test func missingAccountsIsAnError() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AppSettings.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        }
    }

    @Test func codexIntervalIsAtLeastFiveMinutes() {
        var settings = AppSettings.makeDefault()
        settings.refreshIntervalMinutes = 1
        #expect(settings.refreshIntervalMinutes(for: .codex) == 5)
        #expect(settings.refreshIntervalMinutes(for: .claude) == 1)
    }

    @Test func roundTrips() throws {
        var settings = AppSettings.makeDefault()
        settings.insertAccountGroupedByProvider(AccountConfig(provider: .claude, displayName: "Work",
                                               claudeConfigDir: "/Users/me/.tokenbar/claude/work", isDedicatedLogin: true))
        settings.subprocessProxy = "http://proxy:8080"
        settings.resetTimeStyle = .countdown
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }
}

@Suite("MinimalEnv")
struct MinimalEnvTests {
    private func make(proxy: ProxySettings? = nil, extra: [String: String?] = [:]) -> [String: String] {
        MinimalEnv.make(userName: "u", home: URL(fileURLWithPath: "/h"),
                        temporaryDirectory: URL(fileURLWithPath: "/t"), proxy: proxy, extra: extra)
    }

    @Test func containsOnlyBaseKeysAndExtras() {
        #expect(make(extra: ["CLAUDE_CONFIG_DIR": "/d", "CODEX_HOME": nil]) == [
            "HOME": "/h", "USER": "u", "LOGNAME": "u", "PATH": MinimalEnv.path, "TMPDIR": "/t/",
            "CLAUDE_CONFIG_DIR": "/d",
        ])
    }

    @Test func forbiddenKeysNeverReachTheChild() {
        let forbidden = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CLAUDE_CODE_ENTRYPOINT",
                         "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CODEX_ACCESS_TOKEN", "CODEX_API_KEY", "GITHUB_TOKEN"]
        var extra: [String: String?] = ["CODEX_HOME": "/c", "RUST_LOG": "error"]
        for key in forbidden { extra[key] = "secret" }
        let env = make(extra: extra)
        #expect(env["CODEX_HOME"] == "/c")
        #expect(env["RUST_LOG"] == "error")
        for key in forbidden { #expect(env[key] == nil, "\(key) leaked") }
    }

    @Test func proxyVariablesAreSetInBothCases() {
        let env = make(proxy: ProxySettings(httpsProxy: "http://p:1", httpProxy: "http://p:2", noProxy: "localhost"))
        #expect(env["HTTPS_PROXY"] == "http://p:1")
        #expect(env["https_proxy"] == "http://p:1")
        #expect(env["HTTP_PROXY"] == "http://p:2")
        #expect(env["no_proxy"] == "localhost")
    }

    @Test func settingsProxyWinsOverSystemProxy() throws {
        let harness = try TestHarness(proxy: ProxySettings(httpsProxy: "http://system:1"))
        var settings = AppSettings.makeDefault()
        #expect(harness.env.childEnvironment(settings: settings)["HTTPS_PROXY"] == "http://system:1")
        settings.subprocessProxy = "http://mine:2"
        #expect(harness.env.childEnvironment(settings: settings)["HTTPS_PROXY"] == "http://mine:2")
    }
}

@Suite("SemVer")
struct SemVerTests {
    @Test func parsesPythonAndSemverPrereleasesTheSame() {
        #expect(SemVer("0.131.0a4") == SemVer("0.131.0-alpha.4"))
        #expect(SemVer("v2.1.289")?.description == "2.1.289")
    }

    @Test func orders() throws {
        func v(_ s: String) throws -> SemVer { try #require(SemVer(s)) }
        #expect(try v("0.160.0-alpha.9") < v("0.160.0"))
        #expect(try v("0.160.0") < v("0.160.1"))
        #expect(try v("2.1.174") < v("2.1.289"))
        #expect(try v("0.160.0-alpha.2") < v("0.160.0-alpha.10"))
        #expect(try v("1.0.0-alpha") < v("1.0.0-alpha.1"))
        #expect(try v("1.0.0-alpha.beta") < v("1.0.0-beta"))
        #expect(try v("26.930.31428") < v("26.930.51102"))
    }

    @Test func rejectsGarbage() {
        #expect(SemVer("garbage") == nil)
        #expect(SemVer("1.2") == nil)
        #expect(SemVer("1.2.3-") == nil)
    }
}

@Suite("UsageStatus")
struct UsageStatusTests {
    @Test(arguments: [
        (51.0, UsageStatus.normal), (50.0, .gettingLow), (20.0, .gettingLow), (19.9, .low),
        (5.0, .low), (4.9, .critical), (0.0, .critical),
    ])
    func tiers(remaining: Double, expected: UsageStatus) {
        #expect(UsageStatus(remainingPercent: remaining) == expected)
    }

    @Test func limitReachedIsAlwaysCritical() {
        #expect(UsageStatus(remainingPercent: 80, limitReached: true) == .critical)
    }
}

@Suite("DisplayDerivation")
struct DisplayDerivationTests {
    private func snapshot(_ windows: [UsageWindow], limitReached: Bool = false, dataAsOf: Date = fixedNow) -> UsageSnapshot {
        UsageSnapshot(accountID: UUID(), fetchedAt: dataAsOf, dataAsOf: dataAsOf, source: .claudeAPI,
                      identity: nil, windows: windows, limitReached: limitReached)
    }

    @Test func passedResetShowsAsResetAndClearsTheLimit() {
        let s = snapshot([
            UsageWindow(kind: .weekly, usedPercent: 40, resetsAt: fixedNow + 3_600),
            UsageWindow(kind: .fiveHour, usedPercent: 100, resetsAt: fixedNow - 60),
        ], limitReached: true)
        let d = DisplayDerivation.derive(s, now: fixedNow)
        #expect(d.windows.map(\.kind) == [.fiveHour, .weekly])
        #expect(d.windows[0].didReset)
        #expect(d.windows[0].usedPercent == 0)
        #expect(d.windows[0].resetsAt == nil)
        #expect(!d.windows[0].isStarted)
        #expect(!d.limitReached)
        #expect(d.status == .normal)
        #expect(d.worstWindow?.kind == .weekly)
    }

    @Test func noStartedWindowIsNormalWithoutWorstWindow() {
        let s = snapshot([UsageWindow(kind: .fiveHour, usedPercent: 0, resetsAt: fixedNow + 18_000, isStarted: false)])
        let d = DisplayDerivation.derive(s, now: fixedNow)
        #expect(d.status == .normal)
        #expect(d.worstWindow == nil)
        #expect(d.windows[0].resetsAt == nil)
    }

    @Test func worstStartedWindowDrivesStatus() {
        let s = snapshot([
            UsageWindow(kind: .fiveHour, usedPercent: 85, resetsAt: fixedNow + 600),
            UsageWindow(kind: .weekly, usedPercent: 30, resetsAt: fixedNow + 86_400),
        ])
        let d = DisplayDerivation.derive(s, now: fixedNow)
        #expect(d.status == .low)
        #expect(d.worstWindow?.kind == .fiveHour)
        #expect(d.windows[1].status == .normal)
    }

    @Test func limitReachedWithoutResetIsCritical() {
        let s = snapshot([UsageWindow(kind: .weekly, usedPercent: 60, resetsAt: fixedNow + 600)], limitReached: true)
        #expect(DisplayDerivation.derive(s, now: fixedNow).status == .critical)
    }

    @Test func percentTextFollowsDisplayMode() throws {
        let d = DisplayDerivation.derive(snapshot([UsageWindow(kind: .fiveHour, usedPercent: 68, resetsAt: fixedNow + 60)]), now: fixedNow)
        let window = try #require(d.worstWindow)
        #expect(DisplayDerivation.percentText(window, mode: .remaining) == "32% left")
        #expect(DisplayDerivation.percentText(window, mode: .used) == "68% used")
    }

    @Test func nextResetIsTheEarliestFutureReset() {
        let a = snapshot([UsageWindow(kind: .fiveHour, usedPercent: 1, resetsAt: fixedNow - 5),
                          UsageWindow(kind: .weekly, usedPercent: 1, resetsAt: fixedNow + 500)])
        let b = snapshot([UsageWindow(kind: .fiveHour, usedPercent: 1, resetsAt: fixedNow + 200)])
        #expect(DisplayDerivation.nextResetDate([a, b], now: fixedNow) == fixedNow + 200)
    }

    @Test func menuBarShowsTheWorstAccountAndMarksStaleOrFailingData() {
        let settings = AppSettings.makeDefault()
        let a = AccountState(config: AccountConfig(provider: .claude, displayName: "A"),
                             lastSnapshot: snapshot([UsageWindow(kind: .fiveHour, usedPercent: 69, resetsAt: fixedNow + 3_600)]))
        let b = AccountState(config: AccountConfig(provider: .codex, displayName: "B"),
                             lastSnapshot: snapshot([UsageWindow(kind: .weekly, usedPercent: 20, resetsAt: fixedNow + 3_600)]))
        // The default display mode is .used.
        #expect(DisplayDerivation.menuBar(states: [a, b], settings: settings, now: fixedNow)
            == MenuBarSummary(text: "69%", status: .gettingLow))

        var failing = a
        failing.lastError = .network(urlErrorCode: -1009)
        #expect(DisplayDerivation.menuBar(states: [failing, b], settings: settings, now: fixedNow).text == "69%?")

        var stale = a
        stale.lastSnapshot?.dataAsOf = fixedNow - 11 * 60
        #expect(DisplayDerivation.menuBar(states: [stale], settings: settings, now: fixedNow).text == "69%?")

        var remaining = settings
        remaining.displayMode = .remaining
        #expect(DisplayDerivation.menuBar(states: [a, b], settings: remaining, now: fixedNow).text == "31%")

        var disabled = a
        disabled.config.isEnabled = false
        #expect(DisplayDerivation.menuBar(states: [disabled, b], settings: settings, now: fixedNow).text == "20%")
        #expect(DisplayDerivation.menuBar(states: [disabled, b], settings: remaining, now: fixedNow).text == "80%")
    }

    @Test func menuBarWithoutData() {
        let settings = AppSettings.makeDefault()
        let empty = AccountState(config: AccountConfig(provider: .claude, displayName: "A"))
        #expect(DisplayDerivation.menuBar(states: [empty], settings: settings, now: fixedNow).text == "–")
        var failing = empty
        failing.lastError = .notLoggedIn(hint: .claude(configDir: nil))
        #expect(DisplayDerivation.menuBar(states: [failing], settings: settings, now: fixedNow)
            == MenuBarSummary(text: "!", status: .critical))
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test func countdowns() {
        #expect(Formatting.countdown(to: fixedNow + (3 * 86_400 + 4 * 3_600 + 59), now: fixedNow) == "3d 4h")
        #expect(Formatting.countdown(to: fixedNow + (2 * 3_600 + 14 * 60 + 30), now: fixedNow) == "2h 14m")
        #expect(Formatting.countdown(to: fixedNow + 45 * 60, now: fixedNow) == "45m")
        #expect(Formatting.countdown(to: fixedNow + 30, now: fixedNow) == "<1m")
        #expect(Formatting.countdown(to: fixedNow - 1, now: fixedNow) == "now")
        #expect(Formatting.compactCountdown(to: fixedNow + (2 * 3_600 + 14 * 60), now: fixedNow) == "2h14m")
    }

    @Test func ages() {
        #expect(Formatting.age(since: fixedNow - 10, now: fixedNow) == "just now")
        #expect(Formatting.age(since: fixedNow - 14 * 60, now: fixedNow) == "14 min ago")
        #expect(Formatting.age(since: fixedNow - 3 * 3_600, now: fixedNow) == "3 h ago")
        #expect(Formatting.age(since: fixedNow - 2 * 86_400, now: fixedNow) == "2 d ago")
    }

    @Test func percentRounds() {
        #expect(Formatting.percent(31.6) == "32%")
        #expect(Formatting.percent(0) == "0%")
    }

    // MARK: Reset clock times (spec §5.1 rule 6)

    private static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    private static let enUS = Locale(identifier: "en_US")
    private static let enGB = Locale(identifier: "en_GB")

    /// A wall-clock time in New York, October 2026 (Mon the 12th … Mon the 19th).
    private static func ny(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        newYork.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// The en_US time formats put a narrow no-break space (U+202F) before AM/PM; compare with a plain space.
    private static func clock(_ date: Date, now: Date, _ locale: Locale = enUS) -> String {
        Formatting.resetClock(date, now: now, calendar: newYork, locale: locale)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func resetClockSameDayShowsTimeOnly() {
        let now = Self.ny(12, 12, 9)  // Monday 12:09
        #expect(Self.clock(Self.ny(12, 18, 10), now: now) == "6:10 PM")
        #expect(Self.clock(Self.ny(12, 18, 10), now: now, Self.enGB) == "18:10")
        #expect(Self.clock(Self.ny(12, 23, 59), now: now) == "11:59 PM")
    }

    @Test func resetClockWithinAWeekShowsWeekdayAndTime() {
        let now = Self.ny(12, 12, 9)
        #expect(Self.clock(Self.ny(13, 9, 5), now: now) == "Tue 9:05 AM")                  // tomorrow
        #expect(Self.clock(Self.ny(14, 23, 0), now: now) == "Wed 11:00 PM")
        #expect(Self.clock(Self.ny(14, 23, 0), now: now, Self.enGB) == "Wed 23:00")
        #expect(Self.clock(Self.ny(18, 23, 30), now: now) == "Sun 11:30 PM")                // 6 days ahead
    }

    @Test func resetClockAWeekOrMoreAheadShowsTheDate() {
        let now = Self.ny(12, 12, 9)
        // Next Monday: same weekday as today, so a weekday name would be ambiguous.
        #expect(Self.clock(Self.ny(19, 8, 0), now: now) == "Oct 19")
        #expect(Self.clock(Self.ny(23, 8, 0), now: now) == "Oct 23")
        #expect(Self.clock(Self.ny(23, 8, 0), now: now, Self.enGB) == "23 Oct")
    }

    @Test func resetClockMidnightBoundaryIsNotSameDay() {
        let now = Self.ny(12, 23, 59)
        #expect(Self.clock(Self.ny(13, 0, 30), now: now) == "Tue 12:30 AM")
        #expect(Self.clock(Self.ny(13, 0, 30), now: now, Self.enGB) == "Tue 00:30")
    }

    @Test func resetClockInThePastIsNow() {
        let now = Self.ny(12, 12, 9)
        #expect(Self.clock(now - 1, now: now) == "now")
        #expect(Self.clock(now, now: now) == "now")
    }

    @Test func resetClockUsesTheCalendarTimeZone() {
        // 23:00 in New York on Wednesday is already Thursday 04:00 in Dublin (UTC+1 in October).
        var dublin = Self.newYork
        dublin.timeZone = TimeZone(identifier: "Europe/Dublin")!
        let text = Formatting.resetClock(Self.ny(14, 23, 0), now: Self.ny(12, 12, 9), calendar: dublin, locale: Self.enGB)
        #expect(text == "Thu 04:00")
    }

    @Test func resetTextFollowsTheStyle() {
        let now = Self.ny(12, 12, 9)
        let reset = now + (2 * 3_600 + 14 * 60)
        #expect(Formatting.resetText(reset, now: now, style: .countdown, calendar: Self.newYork, locale: Self.enGB)
            == "2h 14m")
        #expect(Formatting.resetText(reset, now: now, style: .clock, calendar: Self.newYork, locale: Self.enGB)
            == "14:23")
    }
}

@Suite("AccountState.apply")
struct AccountStateApplyTests {
    private let account = AccountConfig(provider: .claude, displayName: "A")

    private func snapshot(_ uuid: String) -> UsageSnapshot {
        UsageSnapshot(accountID: account.id, fetchedAt: fixedNow, dataAsOf: fixedNow, source: .claudeAPI,
                      identity: AccountIdentity(accountUuid: uuid),
                      windows: [UsageWindow(kind: .fiveHour, usedPercent: 10, resetsAt: fixedNow + 60)],
                      limitReached: false)
    }

    private func event(_ result: Result<ProviderOutcome, ProviderError>, at time: Date = fixedNow) -> AccountRefreshEvent {
        AccountRefreshEvent(accountID: account.id, configFingerprint: 0, trigger: .scheduled, result: result, finishedAt: time)
    }

    @Test func successReplacesSnapshotAndClearsError() {
        var state = AccountState(config: account, lastError: .timeout, isRefreshing: true)
        state.apply(event(.success(ProviderOutcome(snapshot: snapshot("u1")))), wakeGraceUntil: nil)
        #expect(state.lastSnapshot?.identity?.accountUuid == "u1")
        #expect(state.lastError == nil)
        #expect(!state.isRefreshing)
        #expect(state.lastAttemptAt == fixedNow)
    }

    @Test func warningIsKeptAlongsideData() {
        var state = AccountState(config: account)
        state.apply(event(.success(ProviderOutcome(snapshot: snapshot("u1"), warning: .keychainAccessDenied(exitCode: 128)))),
                    wakeGraceUntil: nil)
        #expect(state.lastSnapshot != nil)
        #expect(state.lastError == .keychainAccessDenied(exitCode: 128))
    }

    @Test func failureKeepsTheLastSnapshot() {
        var state = AccountState(config: account, lastSnapshot: snapshot("u1"))
        state.apply(event(.failure(.timeout)), wakeGraceUntil: nil)
        #expect(state.lastSnapshot != nil)
        #expect(state.lastError == .timeout)
    }

    @Test func networkErrorDuringWakeGraceIsIgnoredWhenHealthy() {
        var state = AccountState(config: account, lastSnapshot: snapshot("u1"))
        state.apply(event(.failure(.network(urlErrorCode: -1009))), wakeGraceUntil: fixedNow + 30)
        #expect(state.lastError == nil)
        state.apply(event(.failure(.network(urlErrorCode: -1009)), at: fixedNow + 31), wakeGraceUntil: fixedNow + 30)
        #expect(state.lastError == .network(urlErrorCode: -1009))
    }

    @Test func accountChangedDropsTheSnapshot() {
        var state = AccountState(config: account, lastSnapshot: snapshot("u1"))
        state.apply(event(.failure(.accountChanged)), wakeGraceUntil: nil)
        #expect(state.lastSnapshot == nil)
        #expect(state.lastError == .accountChanged)
    }

    @Test func storedStateNeverContainsEmail() throws {
        var snap = snapshot("u1")
        snap.identity?.email = "canary-secret@example.com"
        let data = try JSONEncoder().encode(StoredAccountState(lastSnapshot: snap))
        #expect(!String(decoding: data, as: UTF8.self).contains("canary-secret"))
    }
}

@Suite("LocalFileSystem")
struct LocalFileSystemTests {
    private let fs = LocalFileSystem()

    @Test func atomicWriteAppliesPermissions() throws {
        let temp = try TempDir()
        let file = temp.url.appendingPathComponent("state.json")
        try fs.writeFileAtomically(Data("one".utf8), to: file, permissions: 0o600)
        try fs.writeFileAtomically(Data("two".utf8), to: file, permissions: 0o600)
        #expect(try fs.readFile(file) == Data("two".utf8))
        #expect(fs.stat(file)?.permissions == 0o600)
        #expect(try fs.contentsOfDirectory(temp.url).map(\.lastPathComponent) == ["state.json"])
    }

    @Test func createDirectoryAppliesPermissionsToEveryCreatedLevel() throws {
        let temp = try TempDir()
        let deep = temp.url.appendingPathComponent("a/b/c", isDirectory: true)
        try fs.createDirectory(deep, permissions: 0o700)
        for path in ["a", "a/b", "a/b/c"] {
            #expect(fs.stat(temp.url.appendingPathComponent(path))?.permissions == 0o700)
        }
        #expect(fs.stat(temp.url)?.permissions != nil)
    }

    @Test func tailAndPrefixReads() throws {
        let temp = try TempDir()
        let file = try temp.write("log.txt", "0123456789")
        #expect(try fs.readFileTail(file, maxBytes: 3) == Data("789".utf8))
        #expect(try fs.readFileTail(file, maxBytes: 100) == Data("0123456789".utf8))
        #expect(try fs.readFilePrefix(file, maxBytes: 4) == Data("0123".utf8))
    }

    @Test func statLstatAndRealpathTreatSymlinksCorrectly() throws {
        let temp = try TempDir()
        let target = try temp.write("bin/real", "#!/bin/sh\n", permissions: 0o755)
        let link = temp.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(fs.lstat(link)?.isSymlink == true)
        #expect(fs.stat(link)?.isRegularFile == true)
        #expect(fs.stat(link)?.isExecutable == true)
        #expect(fs.realpath(link)?.path == target.path)
        #expect(fs.stat(temp.url.appendingPathComponent("missing")) == nil)
    }

    @Test func exclusiveLockRunsTheBody() throws {
        let temp = try TempDir()
        let lock = temp.url.appendingPathComponent("state.lock")
        let value = try fs.withExclusiveLock(lock) { 42 }
        #expect(value == 42)
        #expect(fs.stat(lock)?.permissions == 0o600)
    }
}
