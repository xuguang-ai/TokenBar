import Foundation
import Testing
@testable import TokenBarCore

/// A ClaudeProvider wired to fakes: keychain via FakeProcessRunner.run, usage API via FakeHTTPClient,
/// step ② via FakeProcessRunner.spawnDetached, config JSON in the temp home.
private final class ClaudeProviderRig: @unchecked Sendable {
    static let otherUuid = "00000000-0000-4000-8000-0000000000ff"

    let h: TestHarness
    let store = InMemoryStateStore()
    let keychain = Locked(ProcessResult(exitCode: 44))
    let liveSessions = Locked(false)
    let liveChecks = Locked<[String]>([])
    let account: AccountConfig
    var settings: AppSettings
    let provider: ClaudeProvider
    /// The expanded config dir, nil for the default login.
    let configDir: String?

    init(dedicated: Bool = false, binary: String? = "/opt/claude/versions/2.1.289") throws {
        h = try TestHarness()
        configDir = dedicated ? h.home.appendingPathComponent(".tokenbar/claude/work").path : nil
        account = AccountConfig(
            provider: .claude, displayName: dedicated ? "Work" : "Claude", claudeConfigDir: configDir,
            isDedicatedLogin: dedicated)
        settings = AppSettings(accounts: [account])
        let keychain = self.keychain
        h.processes.runHandler = { request in
            precondition(request.executable.path == "/usr/bin/security")
            return keychain.current
        }
        let liveSessions = self.liveSessions
        let liveChecks = self.liveChecks
        provider = ClaudeProvider(
            env: h.env, stateStore: store, binaryLocator: ClaudeTestKit.StubBinaryLocator(binary),
            liveSessionChecker: { dir in
                liveChecks.withLock { $0.append(dir) }
                return liveSessions.current
            })
        setToken()
        writeConfig()
        respond(status: 200, body: try Fixtures.string("claude/usage-response.json"))
    }

    var now: Date { h.clock.now }

    func expiresAtMs(in seconds: TimeInterval) -> Double { (now.timeIntervalSince1970 + seconds) * 1000 }

    /// Keychain value with the given token; it always carries other secrets that must be dropped.
    func setToken(
        _ token: String = ClaudeTestKit.accessToken, expiresIn: TimeInterval = 3600,
        scopes: [String] = ["user:inference", "user:profile"], subscriptionType: String = "max"
    ) {
        let object: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": token, "refreshToken": "CANARY-refreshToken-synthetic-5e5e",
                "expiresAt": expiresAtMs(in: expiresIn), "scopes": scopes, "subscriptionType": subscriptionType,
            ],
            "mcpOAuth": ["x": ["accessToken": "CANARY-mcpOAuth-synthetic-3c3c"]],
            "pluginSecrets": ["x": "CANARY-pluginSecrets-synthetic-d00d"],
            "trustedDeviceToken": "CANARY-trustedDeviceToken-synthetic-beef",
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        keychain.withLock { $0 = ProcessResult(exitCode: 0, stdout: data + Data("\n".utf8)) }
    }

    func setKeychain(_ result: ProcessResult) { keychain.withLock { $0 = result } }

    /// The global config JSON, with secrets beside the two keys TokenBar may read.
    func writeConfig(
        uuid: String? = ClaudeTestKit.accountUuid, cacheFetchedAt: Date? = nil, cacheUuid: String? = nil,
        cachedFiveHour: Double = 11, includeCache: Bool = true
    ) {
        var object: [String: Any] = [
            "userID": "CANARY-userID-synthetic-0b1d",
            "primaryApiKey": "CANARY-primaryApiKey-synthetic-77e2",
            "mcpServers": ["x": ["env": ["X_API_KEY": "CANARY-mcpServersEnv-synthetic-4f9c"]]],
        ]
        if let uuid {
            object["oauthAccount"] = [
                "accountUuid": uuid, "emailAddress": "someone@example.invalid", "organizationName": "Example Org",
                "organizationType": "claude_team", "displayName": "CANARY-displayName-synthetic-91aa",
            ]
        }
        if includeCache {
            let fetched = cacheFetchedAt ?? now.addingTimeInterval(-600)
            object["cachedUsageUtilization"] = [
                "fetchedAtMs": fetched.timeIntervalSince1970 * 1000,
                "accountUuid": cacheUuid ?? uuid ?? "none",
                "utilization": ["five_hour": ["utilization": cachedFiveHour, "resets_at": "2026-10-07T00:00:00Z"]],
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: object)
        let path = configDir.map { $0 + "/.claude.json" } ?? h.home.appendingPathComponent(".claude.json").path
        try! FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: URL(fileURLWithPath: path))
    }

    func removeConfig() {
        let path = configDir.map { $0 + "/.claude.json" } ?? h.home.appendingPathComponent(".claude.json").path
        try? FileManager.default.removeItem(atPath: path)
    }

    func respond(status: Int, body: String = "", headers: [String: String] = [:]) {
        h.http.handler = { _ in HTTPResponse(status: status, headers: headers, body: Data(body.utf8)) }
    }

    func fetch(
        _ trigger: RefreshTrigger = .scheduled, deadlineIn: TimeInterval = 120, allowStep2: Bool = true,
        previous: AccountIdentity? = nil, wakeGraceUntil: Date? = nil
    ) async -> Result<ProviderOutcome, ProviderError> {
        let context = RefreshContext(
            trigger: trigger, deadline: now.addingTimeInterval(deadlineIn), allowClaudeCodeRefresh: allowStep2,
            previousIdentity: previous, wakeGraceUntil: wakeGraceUntil)
        do {
            return .success(try await provider.fetchUsage(for: account, settings: settings, context: context))
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            Issue.record("unexpected error type")
            return .failure(.timeout)
        }
    }

    var securityCalls: Int { h.processes.calls.filter { $0.mode == .run }.count }
    var spawns: [FakeProcessRunner.Call] { h.processes.calls.filter { $0.mode == .detached } }
    var httpCalls: Int { h.http.requests.count }
    func state() async -> AccountRuntimeState { await store.read(account.id) }
}

private extension Result where Success == ProviderOutcome, Failure == ProviderError {
    var outcome: ProviderOutcome? { try? get() }
    var error: ProviderError? {
        if case .failure(let error) = self { return error }
        return nil
    }
    var source: SnapshotSource? { outcome?.snapshot.source }
    var warning: ProviderError? { outcome?.warning }
    var isCache: Bool {
        if case .claudeCache = source { return true }
        return false
    }
}

@Suite("ClaudeProvider")
struct ClaudeProviderTests {
    // MARK: Step ①

    @Test func liveDataFromTheUsageAPI() async throws {
        let rig = try ClaudeProviderRig()
        let result = await rig.fetch()
        let outcome = try result.get()
        #expect(outcome.warning == nil)
        #expect(outcome.snapshot.source == .claudeAPI)
        #expect(outcome.snapshot.accountID == rig.account.id)
        #expect(outcome.snapshot.windows.count == 4)
        #expect(outcome.snapshot.dataAsOf == rig.now)
        #expect(outcome.snapshot.identity == AccountIdentity(
            accountUuid: ClaudeTestKit.accountUuid, plan: "Max", organization: "Example Org"))
        #expect(outcome.snapshot.identity?.email == nil)
        #expect(rig.h.http.requests.first?.headers["Authorization"] == "Bearer " + ClaudeTestKit.accessToken)
        #expect(rig.h.processes.calls.first?.request.arguments.last == ClaudePaths.keychainService(configDir: nil))
        #expect(await rig.state().lastHTTPAt == rig.now)
    }

    @Test func httpSpacingServesTheCacheWithoutRequest() async throws {
        let rig = try ClaudeProviderRig()
        await rig.store.update(rig.account.id) { $0.lastHTTPAt = rig.now.addingTimeInterval(-30) }
        let result = await rig.fetch()
        #expect(rig.httpCalls == 0)
        #expect(result.isCache)
        #expect(result.warning == nil)
        // A manual refresh ignores the spacing.
        #expect(await rig.fetch(.manual).source == .claudeAPI)
        #expect(rig.httpCalls == 1)
    }

    @Test func httpSpacingToleratesKeychainJitter() async throws {
        let rig = try ClaudeProviderRig()
        let start = rig.now
        let delay = Locked<TimeInterval>(0.5)
        rig.h.processes.runHandler = { [rig] _ in
            rig.h.clock.advance(by: delay.current)
            return rig.keychain.current
        }
        #expect(await rig.fetch().source == .claudeAPI)
        // The next 1-minute tick reads the keychain faster, so only 59.6 s pass between the two requests.
        rig.h.clock.set(start.addingTimeInterval(60))
        delay.withLock { $0 = 0.1 }
        let second = await rig.fetch()
        #expect(second.source == .claudeAPI)
        #expect(second.error == nil)
        #expect(rig.httpCalls == 2)
    }

    @Test func httpSpacingWithoutCacheMakesTheRequest() async throws {
        let rig = try ClaudeProviderRig()
        rig.writeConfig(includeCache: false)
        await rig.store.update(rig.account.id) { $0.lastHTTPAt = rig.now.addingTimeInterval(-30) }
        let result = await rig.fetch()
        #expect(result.source == .claudeAPI)
        #expect(result.error == nil)
        #expect(rig.httpCalls == 1)
    }

    @Test func unauthorizedRereadsTheKeychainAndRetriesOnceWithANewToken() async throws {
        let rig = try ClaudeProviderRig()
        let body = try Fixtures.string("claude/usage-response.json")
        let count = Locked(0)
        rig.h.http.handler = { _ in
            let n = count.withLock { $0 += 1; return $0 }
            return n == 1 ? HTTPResponse(status: 401) : HTTPResponse(status: 200, body: Data(body.utf8))
        }
        rig.h.processes.runHandler = { [rig] _ in
            if rig.securityCalls >= 2 { rig.setToken("token-two", expiresIn: 7200) }
            return rig.keychain.current
        }
        let result = await rig.fetch()
        #expect(result.source == .claudeAPI)
        #expect(rig.h.http.requests.map { $0.headers["Authorization"] } == ["Bearer " + ClaudeTestKit.accessToken, "Bearer token-two"])
    }

    @Test func unauthorizedNonDedicatedBacksOffBoundToTheToken() async throws {
        let rig = try ClaudeProviderRig()
        rig.respond(status: 401)
        let first = await rig.fetch()
        #expect(first.isCache)
        #expect(first.warning == .waitingForClaudeCode)
        #expect(rig.spawns.isEmpty)
        let state = await rig.state()
        #expect(state.backoffReason == .unauthorized)
        #expect(state.backoffUntil == rig.now.addingTimeInterval(3600))
        #expect(state.backoffTokenExpiresAt == rig.expiresAtMs(in: 3600))

        // Same token: no request, even a minute later and manually.
        rig.h.clock.advance(by: 61)
        rig.setToken(expiresIn: 3600 - 61)
        #expect(await rig.fetch(.manual).warning == .waitingForClaudeCode)
        #expect(rig.httpCalls == 1)

        // A new token clears the backoff.
        rig.setToken("token-two", expiresIn: 7200)
        rig.respond(status: 200, body: try Fixtures.string("claude/usage-response.json"))
        #expect(await rig.fetch(.manual).source == .claudeAPI)
        #expect(await rig.state().backoffReason == nil)
    }

    @Test func forbiddenWithErrorBodyBacksOffOneHour() async throws {
        let rig = try ClaudeProviderRig()
        rig.respond(status: 403, body: #"{"type": "error", "error": {"type": "permission_error"}}"#)
        let result = await rig.fetch()
        #expect(result.warning == .unauthorized(until: rig.now.addingTimeInterval(3600)))
        #expect(await rig.state().backoffTokenExpiresAt == rig.expiresAtMs(in: 3600))
    }

    @Test(arguments: [
        (429, ["retry-after": "120"], TimeInterval(300)),
        (429, ["retry-after": "900"], TimeInterval(900)),
        (429, ["retry-after": "0"], TimeInterval(300)),
        (429, [:], TimeInterval(300)),
        (429, ["retry-after": "99999"], TimeInterval(3600)),
        (403, [:], TimeInterval(300)),
    ] as [(Int, [String: String], TimeInterval)])
    func rateLimitBacksOffPerAccount(status: Int, headers: [String: String], seconds: TimeInterval) async throws {
        let rig = try ClaudeProviderRig()
        rig.respond(status: status, headers: headers)
        let until = rig.now.addingTimeInterval(seconds)
        #expect(await rig.fetch().warning == .rateLimited(until: until))
        let state = await rig.state()
        #expect(state.backoffReason == .rateLimited)
        #expect(state.backoffTokenExpiresAt == nil)

        // Step 0: even a manual refresh does not read the keychain or call the API during the backoff.
        let securityBefore = rig.securityCalls
        let again = await rig.fetch(.manual)
        #expect(again.warning == .rateLimited(until: until))
        #expect(again.isCache)
        #expect(rig.securityCalls == securityBefore)
        #expect(rig.httpCalls == 1)
    }

    @Test func consecutiveRateLimitsBackOffExponentially() async throws {
        let rig = try ClaudeProviderRig()
        for (n, minutes) in [5, 10, 20, 40, 60, 60].enumerated() {
            rig.setToken()  // a fresh token each round, so only the backoff decides
            rig.respond(status: 429, headers: n == 2 ? ["retry-after": "0"] : [:])
            let until = rig.now.addingTimeInterval(TimeInterval(minutes * 60))
            #expect(await rig.fetch().warning == .rateLimited(until: until))
            let state = await rig.state()
            #expect(state.consecutiveRateLimits == n + 1)
            #expect(state.lastRetryAfterSeconds == (n == 2 ? 0 : nil))
            rig.h.clock.set(until)
        }
        #expect(rig.httpCalls == 6)
    }

    @Test func largerRetryAfterWinsOverTheExponentialValue() async throws {
        let rig = try ClaudeProviderRig()
        await rig.store.update(rig.account.id) { $0.consecutiveRateLimits = 1 }
        rig.respond(status: 429, headers: ["retry-after": "1500"])
        #expect(await rig.fetch().warning == .rateLimited(until: rig.now.addingTimeInterval(1500)))
        #expect(await rig.state().lastRetryAfterSeconds == 1500)
        rig.h.clock.advance(by: 1500)
        // Third in a row: 20 min beats a Retry-After of 2 min.
        rig.respond(status: 429, headers: ["retry-after": "120"])
        #expect(await rig.fetch().warning == .rateLimited(until: rig.now.addingTimeInterval(1200)))
    }

    @Test func successResetsTheRateLimitCounterButACacheHitDoesNot() async throws {
        let rig = try ClaudeProviderRig()
        await rig.store.update(rig.account.id) {
            $0.consecutiveRateLimits = 3
            $0.lastHTTPAt = rig.now.addingTimeInterval(-30)
        }
        // HTTP spacing serves the cache: the counter stays.
        #expect(await rig.fetch().isCache)
        #expect(await rig.state().consecutiveRateLimits == 3)
        rig.h.clock.advance(by: 60)
        #expect(await rig.fetch().source == .claudeAPI)
        #expect(await rig.state().consecutiveRateLimits == 0)
        // The next rate limit starts again at 5 min.
        rig.h.clock.advance(by: 60)
        rig.respond(status: 429)
        #expect(await rig.fetch().warning == .rateLimited(until: rig.now.addingTimeInterval(300)))
    }

    // MARK: Fresh Claude Code cache first

    @Test func freshClaudeCodeCacheIsUsedWithoutRequest() async throws {
        let rig = try ClaudeProviderRig()
        await rig.store.update(rig.account.id) { $0.lastHTTPAt = rig.now.addingTimeInterval(-600) }
        rig.writeConfig(cacheFetchedAt: rig.now.addingTimeInterval(-270), cachedFiveHour: 42)
        let result = await rig.fetch()
        #expect(rig.h.http.requests.isEmpty)
        #expect(result.source == .claudeCache(fetchedAt: rig.now.addingTimeInterval(-270)))
        #expect(result.warning == nil)
        #expect(result.outcome?.snapshot.windows.first?.usedPercent == 42)
        #expect(await rig.state().lastHTTPAt == rig.now.addingTimeInterval(-600))

        // Also without any earlier request.
        let fresh = try ClaudeProviderRig()
        fresh.writeConfig(cacheFetchedAt: fresh.now.addingTimeInterval(-10))
        #expect(await fresh.fetch(.wake).isCache)
        #expect(fresh.h.http.requests.isEmpty)
        #expect(await fresh.state().lastHTTPAt == nil)
    }

    @Test(arguments: ["olderThanInterval", "olderThanLastHTTP", "otherAccount", "manual"])
    func freshClaudeCodeCacheShortcutIsSkipped(_ variant: String) async throws {
        let rig = try ClaudeProviderRig()
        await rig.store.update(rig.account.id) { $0.lastHTTPAt = rig.now.addingTimeInterval(-900) }
        var trigger = RefreshTrigger.scheduled
        switch variant {
        case "olderThanInterval":
            rig.writeConfig(cacheFetchedAt: rig.now.addingTimeInterval(-301))
        case "olderThanLastHTTP":
            await rig.store.update(rig.account.id) { $0.lastHTTPAt = rig.now.addingTimeInterval(-100) }
            rig.writeConfig(cacheFetchedAt: rig.now.addingTimeInterval(-120))
        case "otherAccount":
            rig.writeConfig(cacheFetchedAt: rig.now.addingTimeInterval(-60), cacheUuid: ClaudeProviderRig.otherUuid)
        default:
            rig.writeConfig(cacheFetchedAt: rig.now.addingTimeInterval(-60))
            trigger = .manual
        }
        let result = await rig.fetch(trigger)
        #expect(result.source == .claudeAPI)
        #expect(rig.httpCalls == 1)
    }

    @Test func networkErrorFallsBackToTheCache() async throws {
        let rig = try ClaudeProviderRig()
        rig.h.http.handler = { _ in throw HTTPClientError.transport(urlErrorCode: -1009) }
        let result = await rig.fetch()
        #expect(result.isCache)
        #expect(result.warning == .network(urlErrorCode: -1009))
        #expect(result.outcome?.snapshot.dataAsOf == rig.now.addingTimeInterval(-600))
        #expect(result.outcome?.snapshot.windows.first?.usedPercent == 11)
    }

    @Test func networkErrorDuringWakeGraceIsReportedAsIs() async throws {
        let rig = try ClaudeProviderRig()
        rig.h.http.handler = { _ in throw HTTPClientError.timeout }
        let result = await rig.fetch(.wake, wakeGraceUntil: rig.now.addingTimeInterval(30))
        #expect(result.error == .network(urlErrorCode: URLError.Code.timedOut.rawValue))
    }

    @Test func failureWithoutCacheThrowsTheError() async throws {
        let rig = try ClaudeProviderRig()
        rig.writeConfig(includeCache: false)
        rig.respond(status: 500)
        #expect(await rig.fetch().error == .httpStatus(500))
    }

    @Test func cacheOfAnotherAccountIsNotUsed() async throws {
        let rig = try ClaudeProviderRig()
        rig.writeConfig(cacheUuid: ClaudeProviderRig.otherUuid)
        rig.respond(status: 500)
        #expect(await rig.fetch().error == .httpStatus(500))
    }

    // MARK: Step 1

    @Test func notLoggedInWithoutKeychainItemFileOrConfig() async throws {
        let rig = try ClaudeProviderRig()
        rig.setKeychain(ProcessResult(exitCode: 44))
        rig.removeConfig()
        #expect(await rig.fetch().error == .notLoggedIn(hint: .claude(configDir: nil)))
        #expect(rig.httpCalls == 0)
    }

    @Test func emptyTokenIsNotLoggedIn() async throws {
        let rig = try ClaudeProviderRig()
        rig.setToken("")
        let result = await rig.fetch()
        #expect(result.warning == .notLoggedIn(hint: .claude(configDir: nil)))
        #expect(rig.httpCalls == 0)
    }

    @Test func tokenWithoutProfileScopeOnlyUsesTheCache() async throws {
        let rig = try ClaudeProviderRig()
        rig.setToken(scopes: ["user:inference"])
        let result = await rig.fetch()
        #expect(result.isCache)
        #expect(result.warning == .tokenLacksProfileScope)
        #expect(rig.httpCalls == 0)
    }

    @Test func lockedKeychainFallsBack() async throws {
        let rig = try ClaudeProviderRig()
        rig.setKeychain(ProcessResult(exitCode: 36))
        let result = await rig.fetch()
        #expect(result.warning == .keychainLocked)
        #expect(await rig.state().keychainAccess == .ok)
    }

    @Test func otherExitCodeIsAReadFailure() async throws {
        let rig = try ClaudeProviderRig()
        rig.setKeychain(ProcessResult(exitCode: 7))
        #expect(await rig.fetch().warning == .keychainReadFailed(exitCode: 7))
    }

    @Test func deniedKeychainIsNotReadAgainByScheduledRefreshes() async throws {
        let rig = try ClaudeProviderRig()
        rig.setKeychain(ProcessResult(exitCode: 128))
        let first = await rig.fetch()
        #expect(first.warning == .keychainAccessDenied(exitCode: 128))
        #expect(first.isCache)
        #expect(await rig.state().keychainAccess == .deniedOrPrompting)
        #expect(rig.securityCalls == 1)

        for trigger in [RefreshTrigger.scheduled, .wake, .launch] {
            #expect(await rig.fetch(trigger).warning == .keychainAccessDenied(exitCode: -1))
        }
        #expect(rig.securityCalls == 1)

        // Manual refresh retries; success clears the mark.
        rig.setToken()
        #expect(await rig.fetch(.manual).source == .claudeAPI)
        #expect(rig.securityCalls == 2)
        #expect(rig.h.processes.calls.last?.request.timeout == .seconds(60))
        #expect(await rig.state().keychainAccess == .ok)
    }

    @Test func fullLengthKeychainTimeoutCountsAsDenied() async throws {
        let rig = try ClaudeProviderRig()
        rig.setKeychain(ProcessResult(exitCode: 15, terminatedBySignal: true, timedOut: true))
        #expect(await rig.fetch().warning == .keychainAccessDenied(exitCode: -1))
        #expect(await rig.state().keychainAccess == .deniedOrPrompting)
    }

    // MARK: Deadline

    @Test func noBudgetForTheKeychainFallsBackToTheCache() async throws {
        let rig = try ClaudeProviderRig()
        let result = await rig.fetch(deadlineIn: 2.5)
        #expect(result.isCache)
        #expect(result.warning == .timeout)
        #expect(rig.securityCalls == 0)
        #expect(await rig.state().keychainAccess == .ok)
    }

    @Test func keychainUsingUpTheBudgetSkipsTheRequest() async throws {
        let rig = try ClaudeProviderRig()
        rig.h.processes.runHandler = { [rig] _ in
            rig.h.clock.advance(by: 117.5)
            return rig.keychain.current
        }
        let result = await rig.fetch()
        #expect(result.isCache)
        #expect(result.warning == .timeout)
        #expect(rig.httpCalls == 0)
    }

    @Test func requestTimeoutIsClippedToTheDeadline() async throws {
        let rig = try ClaudeProviderRig()
        _ = await rig.fetch(deadlineIn: 6)
        #expect(rig.h.http.requests.first?.timeout == .seconds(4))
    }

    // MARK: Step ②

    @Test func expiredNonDedicatedTokenWaitsForClaudeCode() async throws {
        let rig = try ClaudeProviderRig()
        rig.setToken(expiresIn: 120)  // inside the 5-minute margin
        let result = await rig.fetch(.manual)
        #expect(result.isCache)
        #expect(result.warning == .waitingForClaudeCode)
        #expect(rig.httpCalls == 0)
        #expect(rig.spawns.isEmpty)
    }

    @Test func dedicatedExpiredTokenRunsStep2AndPrefersTheFreshCache() async throws {
        let rig = try ClaudeProviderRig(dedicated: true)
        rig.setToken(expiresIn: -10)
        rig.h.processes.detachedHandler = { [rig] _ in
            rig.writeConfig(cacheFetchedAt: rig.now.addingTimeInterval(1), cachedFiveHour: 55)
            rig.setToken("rotated", expiresIn: 3600)
            return FakeDetachedProcess(pid: 4321, exitStatus: 0)
        }
        let start = rig.now
        let result = await rig.fetch()
        #expect(result.source == .claudeAPIAfterCLIRefresh)
        #expect(result.warning == nil)
        #expect(result.outcome?.snapshot.windows.first?.usedPercent == 55)
        #expect(rig.httpCalls == 0)
        let spawn = try #require(rig.spawns.first)
        #expect(spawn.request.arguments == ["-p", "/usage"])
        #expect(spawn.request.environment["CLAUDE_CONFIG_DIR"] == rig.configDir)
        #expect(rig.liveChecks.current == [rig.configDir!])
        let state = await rig.state()
        #expect(state.lastStep2At == start)
        #expect(state.step2InFlight == nil)
    }

    @Test func step2WithoutFreshCacheRereadsAndCallsTheAPIOnce() async throws {
        let rig = try ClaudeProviderRig(dedicated: true)
        rig.setToken(expiresIn: -10)
        rig.h.processes.detachedHandler = { [rig] _ in
            rig.setToken("rotated", expiresIn: 3600)
            return FakeDetachedProcess(pid: 4321, exitStatus: 0)
        }
        let result = await rig.fetch()
        #expect(result.source == .claudeAPI)
        #expect(rig.h.http.requests.map { $0.headers["Authorization"] } == ["Bearer rotated"])
    }

    @Test func step2LeavingTheTokenExpiredMarksStep2Failed() async throws {
        let rig = try ClaudeProviderRig(dedicated: true)
        rig.setToken(expiresIn: -10)
        let expiredKey = rig.expiresAtMs(in: -10)
        rig.h.processes.detachedHandler = { _ in FakeDetachedProcess(pid: 4321, exitStatus: 1) }
        let hint = LoginHint.claude(configDir: rig.configDir)
        #expect(await rig.fetch().warning == .notLoggedIn(hint: hint))
        #expect(await rig.state().step2FailedForTokenExpiresAt == expiredKey)
        #expect(rig.spawns.count == 1)

        // No automatic retry for this token, even after 15 minutes.
        rig.h.clock.advance(by: 16 * 60)
        #expect(await rig.fetch().warning == .notLoggedIn(hint: hint))
        #expect(rig.spawns.count == 1)

        // A manual refresh retries.
        _ = await rig.fetch(.manual)
        #expect(rig.spawns.count == 2)
    }

    @Test func step2RunsAtMostEveryFifteenMinutesUnlessManual() async throws {
        let rig = try ClaudeProviderRig(dedicated: true)
        rig.setToken(expiresIn: -10)
        rig.h.processes.detachedHandler = { _ in FakeDetachedProcess(pid: 4321, exitStatus: nil) }
        rig.h.inspector.setAlive(4321, startTime: nil)
        await rig.store.update(rig.account.id) { $0.lastStep2At = rig.now.addingTimeInterval(-5 * 60) }
        let result = await rig.fetch()
        #expect(result.warning == .waitingForClaudeCode)
        #expect(rig.spawns.isEmpty)

        let manual = await rig.fetch(.manual)
        #expect(rig.spawns.count == 1)
        // Still running at the end of the wait: fall back, never kill.
        #expect(manual.warning == .timeout)
        #expect(manual.isCache)
        #expect(rig.h.processes.calls.filter { $0.mode == .detached }.count == 1)
        #expect(await rig.state().step2InFlight?.pid == 4321)

        // A second manual refresh sees the live registration and does not spawn again.
        _ = await rig.fetch(.manual)
        #expect(rig.spawns.count == 1)
    }

    @Test func step2WaitIsClippedToTheDeadline() async throws {
        let rig = try ClaudeProviderRig(dedicated: true)
        rig.setToken(expiresIn: -10)
        let waits = Locked<[Duration]>([])
        rig.h.processes.detachedHandler = { request in
            struct Recording: DetachedProcess {
                let waits: Locked<[Duration]>
                var pid: Int32 { 99 }
                func waitForExit(timeout: Duration) async -> Int32? {
                    waits.withLock { $0.append(timeout) }
                    return 0
                }
            }
            return Recording(waits: waits)
        }
        _ = await rig.fetch(deadlineIn: 30)
        #expect(waits.current.first == .seconds(28))
    }

    @Test func liveSessionsBlockStep2() async throws {
        let rig = try ClaudeProviderRig(dedicated: true)
        rig.setToken(expiresIn: -10)
        rig.liveSessions.withLock { $0 = true }
        let result = await rig.fetch(.manual)
        #expect(result.warning == .waitingForClaudeCode)
        #expect(rig.spawns.isEmpty)
        #expect(rig.liveChecks.current == [rig.configDir!])
    }

    @Test func registeredStep2BlocksAnother() async throws {
        let rig = try ClaudeProviderRig(dedicated: true)
        rig.setToken(expiresIn: -10)
        rig.h.inspector.setAlive(555, startTime: nil)
        await rig.store.update(rig.account.id) { $0.step2InFlight = Step2InFlight(pid: 555, startedAt: rig.now) }
        #expect(await rig.fetch(.manual).warning == .waitingForClaudeCode)
        #expect(rig.spawns.isEmpty)
    }

    @Test func callerOrSettingCanForbidStep2() async throws {
        let rig = try ClaudeProviderRig(dedicated: true)
        rig.setToken(expiresIn: -10)
        #expect(await rig.fetch(.manual, allowStep2: false).warning == .waitingForClaudeCode)
        rig.settings.allowClaudeCodeRefresh = false
        #expect(await rig.fetch(.manual).warning == .waitingForClaudeCode)
        #expect(rig.spawns.isEmpty)
    }

    @Test func dedicatedUnauthorizedRunsStep2() async throws {
        let rig = try ClaudeProviderRig(dedicated: true)
        rig.respond(status: 401)
        rig.h.processes.detachedHandler = { [rig] _ in
            rig.writeConfig(cacheFetchedAt: rig.now.addingTimeInterval(1), cachedFiveHour: 60)
            return FakeDetachedProcess(pid: 4321, exitStatus: 0)
        }
        let result = await rig.fetch()
        #expect(rig.spawns.count == 1)
        #expect(result.source == .claudeAPIAfterCLIRefresh)
        #expect(await rig.state().backoffReason == nil)
    }

    @Test func dedicatedUnauthorizedBackoffStillAllowsStep2() async throws {
        let rig = try ClaudeProviderRig(dedicated: true)
        rig.respond(status: 401)
        rig.h.processes.detachedHandler = { _ in FakeDetachedProcess(pid: 4321, exitStatus: 0) }
        await rig.store.update(rig.account.id) { $0.lastStep2At = rig.now.addingTimeInterval(-5 * 60) }
        let until = rig.now.addingTimeInterval(3600)
        // Step ② ran 5 minutes ago: the 401 sets the token backoff and step ② waits.
        #expect(await rig.fetch().warning == .unauthorized(until: until))
        #expect(rig.spawns.isEmpty)
        #expect(await rig.state().backoffReason == .unauthorized)
        #expect(rig.httpCalls == 1)

        // A scheduled refresh inside the 15 minutes: no request with the rejected token, no step ②.
        rig.h.clock.advance(by: 120)
        #expect(await rig.fetch().warning == .unauthorized(until: until))
        #expect(rig.httpCalls == 1)
        #expect(rig.spawns.isEmpty)

        // A manual refresh is not stuck behind the backoff: step ② runs.
        _ = await rig.fetch(.manual)
        #expect(rig.spawns.count == 1)

        // Once the 15 minutes allow it, a scheduled refresh runs step ② too.
        rig.h.clock.advance(by: 16 * 60)
        _ = await rig.fetch()
        #expect(rig.spawns.count == 2)
    }

    @Test func missingClaudeBinary() async throws {
        let rig = try ClaudeProviderRig(dedicated: true, binary: nil)
        rig.setToken(expiresIn: -10)
        let result = await rig.fetch()
        #expect(result.warning == .claudeBinaryNotFound)
        #expect(rig.spawns.isEmpty)
    }

    @Test func trailingSlashVariantIsUsedForStep2() async throws {
        let rig = try ClaudeProviderRig(dedicated: true)
        rig.setToken(expiresIn: -10)
        let value = rig.keychain.current
        let variant = rig.configDir! + "/"
        rig.h.processes.runHandler = { request in
            request.arguments.last == ClaudePaths.keychainService(configDir: variant) ? value : ProcessResult(exitCode: 44)
        }
        rig.h.processes.detachedHandler = { _ in FakeDetachedProcess(pid: 1, exitStatus: nil) }
        _ = await rig.fetch()
        #expect(rig.spawns.first?.request.environment["CLAUDE_CONFIG_DIR"] == variant)
    }

    // MARK: Step 5

    @Test func accountChangeAgainstThePreviousSnapshot() async throws {
        let rig = try ClaudeProviderRig()
        await rig.store.update(rig.account.id) { state in
            state.backoffUntil = rig.now.addingTimeInterval(600)
            state.backoffReason = .rateLimited
        }
        let previous = AccountIdentity(accountUuid: ClaudeProviderRig.otherUuid, plan: "Pro")
        let result = await rig.fetch(previous: previous)
        // The old account's backoff is dropped, so live data arrives, flagged as a changed account.
        #expect(result.source == .claudeAPI)
        #expect(result.warning == .accountChanged)
        #expect(result.outcome?.snapshot.identity?.accountUuid == ClaudeTestKit.accountUuid)
        #expect(await rig.state().backoffReason == nil)
    }

    @Test func accountChangeWithoutDataThrowsAccountChanged() async throws {
        let rig = try ClaudeProviderRig()
        rig.writeConfig(includeCache: false)
        rig.respond(status: 500)
        let previous = AccountIdentity(accountUuid: ClaudeProviderRig.otherUuid)
        #expect(await rig.fetch(previous: previous).error == .accountChanged)
    }

    @Test func accountChangeDuringTheRequestDiscardsTheResult() async throws {
        let rig = try ClaudeProviderRig()
        let body = try Fixtures.data("claude/usage-response.json")
        rig.h.http.handler = { [rig] _ in
            rig.writeConfig(uuid: ClaudeProviderRig.otherUuid)
            return HTTPResponse(status: 200, body: body)
        }
        #expect(await rig.fetch().error == .accountChanged)
    }

    @Test func unreadableConfigAfterTheRequestIsNotAnAccountChange() async throws {
        let rig = try ClaudeProviderRig()
        let body = try Fixtures.data("claude/usage-response.json")
        let path = rig.h.home.appendingPathComponent(".claude.json")
        rig.h.http.handler = { _ in
            try! Data(#"{"oauthAccount":"#.utf8).write(to: path)
            return HTTPResponse(status: 200, body: body)
        }
        let result = await rig.fetch()
        #expect(result.source == .claudeAPI)
        #expect(result.outcome?.snapshot.identity?.accountUuid == ClaudeTestKit.accountUuid)

        // A missing file says nothing about the account either.
        rig.h.http.handler = { [rig] _ in
            rig.removeConfig()
            return HTTPResponse(status: 200, body: body)
        }
        rig.writeConfig()
        #expect(await rig.fetch(.manual).source == .claudeAPI)
    }

    @Test func parsedConfigWithoutAccountAfterTheRequestIsAnAccountChange() async throws {
        let rig = try ClaudeProviderRig()
        let body = try Fixtures.data("claude/usage-response.json")
        rig.h.http.handler = { [rig] _ in
            rig.writeConfig(uuid: nil)
            return HTTPResponse(status: 200, body: body)
        }
        #expect(await rig.fetch().error == .accountChanged)
    }

    @Test func unreadableConfigInTheFallbackKeepsTheOriginalError() async throws {
        let rig = try ClaudeProviderRig()
        let path = rig.h.home.appendingPathComponent(".claude.json")
        rig.h.http.handler = { _ in
            try! Data(#"{"oauthAccount":"#.utf8).write(to: path)
            return HTTPResponse(status: 429, headers: ["retry-after": "600"])
        }
        #expect(await rig.fetch().error == .rateLimited(until: rig.now.addingTimeInterval(600)))
    }

    @Test func planNames() {
        #expect(ClaudeProvider.planName(subscriptionType: "max", organizationType: "claude_pro") == "Max")
        #expect(ClaudeProvider.planName(subscriptionType: "pro", organizationType: nil) == "Pro")
        #expect(ClaudeProvider.planName(subscriptionType: nil, organizationType: "claude_max") == "Max")
        #expect(ClaudeProvider.planName(subscriptionType: "team", organizationType: "claude_team") == "Team")
        #expect(ClaudeProvider.planName(subscriptionType: nil, organizationType: "claude_enterprise") == "Enterprise")
        #expect(ClaudeProvider.planName(subscriptionType: nil, organizationType: "api") == nil)
    }

    // MARK: Canary (spec §9.3)

    @Test func secretsNeverSurface() async throws {
        var texts: [String] = []
        func collect(_ rig: ClaudeProviderRig, _ result: Result<ProviderOutcome, ProviderError>) async throws {
            texts.append(String(describing: result))
            texts.append(String(reflecting: result))
            var dumped = ""
            dump(result, to: &dumped)
            texts.append(dumped)
            let encoder = JSONEncoder()
            if let outcome = result.outcome {
                texts.append(String(decoding: try encoder.encode(outcome.snapshot), as: UTF8.self))
                if let warning = outcome.warning {
                    texts.append(String(decoding: try encoder.encode(warning), as: UTF8.self))
                    texts.append(warning.userMessage)
                }
            }
            if let error = result.error {
                texts.append(String(decoding: try encoder.encode(error), as: UTF8.self))
                texts.append(error.userMessage)
                texts.append(error.localizedDescription)
            }
            texts.append(String(decoding: try encoder.encode(await rig.state()), as: UTF8.self))
        }

        let success = try ClaudeProviderRig()
        try await collect(success, await success.fetch())

        let unauthorized = try ClaudeProviderRig()
        unauthorized.respond(status: 401, body: #"{"error": "CANARY-body-synthetic"}"#)
        try await collect(unauthorized, await unauthorized.fetch())

        let denied = try ClaudeProviderRig()
        let secretStdout = denied.keychain.current.stdout
        denied.setKeychain(ProcessResult(exitCode: 128, stdout: secretStdout, stderr: Data("User canceled CANARY-stderr".utf8)))
        try await collect(denied, await denied.fetch())

        let garbled = try ClaudeProviderRig()
        garbled.respond(status: 200, body: "CANARY-garbled-body")
        try await collect(garbled, await garbled.fetch())

        let step2 = try ClaudeProviderRig(dedicated: true)
        step2.setToken(expiresIn: -10)
        step2.h.processes.detachedHandler = { _ in FakeDetachedProcess(pid: 1, exitStatus: 0) }
        try await collect(step2, await step2.fetch())

        let noCache = try ClaudeProviderRig()
        noCache.writeConfig(includeCache: false)
        noCache.setKeychain(ProcessResult(exitCode: 0, stdout: Data("CANARY-not-json".utf8)))
        try await collect(noCache, await noCache.fetch())

        let joined = texts.joined(separator: "\n")
        #expect(!joined.isEmpty)
        for canary in ClaudeTestKit.canaries + ["CANARY-body-synthetic", "CANARY-stderr", "CANARY-garbled-body", "CANARY-not-json"] {
            #expect(!joined.contains(canary), "a secret surfaced")
        }
        #expect(!joined.contains("CANARY"))
    }
}
