import Foundation
import Testing
@testable import TokenBarCore

@Suite("ClaudeCredentialReader")
struct ClaudeCredentialReaderTests {
    private static let otherSecrets = [
        "CANARY-refreshToken-synthetic-5e5e", "CANARY-mcpOAuth-synthetic-3c3c",
        "CANARY-pluginSecrets-synthetic-d00d", "CANARY-trustedDeviceToken-synthetic-beef",
    ]
    private static let token = "CANARY-accessToken-synthetic-a11c"

    private func harness(_ handler: @escaping @Sendable (ProcessRequest) async throws -> ProcessResult) throws -> TestHarness {
        let h = try TestHarness()
        h.processes.runHandler = handler
        return h
    }

    private func read(_ h: TestHarness, dir: String? = nil, manual: Bool = false, deadlineIn: TimeInterval = 120) async
        -> ClaudeCredentialReadResult
    {
        await ClaudeCredentialReader(env: h.env, gate: ClaudeKeychainGate())
            .read(configDir: dir, manual: manual, deadline: h.clock.now.addingTimeInterval(deadlineIn))
    }

    @Test func exitZeroKeepsOnlyFourFields() async throws {
        let value = try Fixtures.data("claude/keychain-value.json")
        let h = try harness { _ in ProcessResult(exitCode: 0, stdout: value + Data("\n".utf8)) }
        let result = await read(h)
        guard case .found(let credentials, let source) = result else { Issue.record("expected found"); return }
        #expect(source == .keychain(configDir: nil))
        #expect(credentials.accessToken == Self.token)
        #expect(credentials.expiresAtMs == 1_791_400_000_000)
        #expect(credentials.scopes == ["user:inference", "user:profile"])
        #expect(credentials.subscriptionType == "max")
        #expect(Mirror(reflecting: credentials).children.compactMap(\.label)
            == ["accessToken", "expiresAtMs", "scopes", "subscriptionType"])
        var dumped = ""
        dump(credentials, to: &dumped)
        for text in [String(describing: result), String(reflecting: result), dumped] {
            #expect(!text.contains(Self.token))
            for secret in Self.otherSecrets { #expect(!text.contains(secret)) }
        }
    }

    @Test func runsSecurityWithTheExactArguments() async throws {
        let h = try harness { _ in ProcessResult(exitCode: 44) }
        _ = await read(h, dir: "/d/work")
        let first = try #require(h.processes.calls.first)
        #expect(first.mode == .run)
        #expect(first.request.executable.path == "/usr/bin/security")
        #expect(first.request.arguments == [
            "find-generic-password", "-a", "tester", "-w", "-s", ClaudePaths.keychainService(configDir: "/d/work"),
        ])
        #expect(first.request.timeout == .seconds(10))
        #expect(first.request.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(first.request.environment["USER"] == "tester")
    }

    @Test func manualReadsGetSixtySeconds() async throws {
        let h = try harness { _ in ProcessResult(exitCode: 44) }
        _ = await read(h, manual: true)
        #expect(h.processes.calls.first?.request.timeout == .seconds(60))
    }

    @Test func timeoutIsClippedToTheDeadline() async throws {
        let h = try harness { _ in ProcessResult(exitCode: 44) }
        _ = await read(h, manual: true, deadlineIn: 7)
        #expect(h.processes.calls.first?.request.timeout == .seconds(5))
    }

    @Test func noBudgetSkipsTheRead() async throws {
        let h = try harness { _ in ProcessResult(exitCode: 0) }
        #expect(await read(h, deadlineIn: 2.5) == .timedOut(truncated: true))
        #expect(h.processes.calls.isEmpty)
    }

    @Test func exit44TriesTheTrailingSlashVariantThenTheFile() async throws {
        let h = try harness { _ in ProcessResult(exitCode: 44) }
        let dir = h.home.appendingPathComponent("work").path
        #expect(await read(h, dir: dir) == .notFound)
        #expect(h.processes.calls.map { $0.request.arguments.last } == [
            ClaudePaths.keychainService(configDir: dir), ClaudePaths.keychainService(configDir: dir + "/"),
        ])

        try h.writeHome("work/.credentials.json", try Fixtures.string("claude/keychain-value.json"), permissions: 0o600)
        guard case .found(let credentials, .credentialsFile) = await read(h, dir: dir) else {
            Issue.record("expected the file"); return
        }
        #expect(credentials.accessToken == Self.token)
    }

    @Test func variantHitReportsTheMatchedString() async throws {
        let value = try Fixtures.data("claude/keychain-value.json")
        let variantService = ClaudePaths.keychainService(configDir: "/d/work/")
        let h = try harness { request in
            request.arguments.last == variantService ? ProcessResult(exitCode: 0, stdout: value) : ProcessResult(exitCode: 44)
        }
        guard case .found(_, let source) = await read(h, dir: "/d/work") else { Issue.record("expected found"); return }
        #expect(source == .keychain(configDir: "/d/work/"))
    }

    @Test func defaultDirHasNoVariant() async throws {
        let h = try harness { _ in ProcessResult(exitCode: 44) }
        #expect(await read(h) == .notFound)
        #expect(h.processes.calls.count == 1)
    }

    @Test(arguments: [
        (Int32(36), ProviderError.keychainLocked),
        (Int32(128), ProviderError.keychainAccessDenied(exitCode: 128)),
        (Int32(51), ProviderError.keychainAccessDenied(exitCode: 51)),
        (Int32(1), ProviderError.keychainReadFailed(exitCode: 1)),
        (Int32(25), ProviderError.keychainReadFailed(exitCode: 25)),
    ])
    func exitCodes(code: Int32, expected: ProviderError) async throws {
        let h = try harness { _ in ProcessResult(exitCode: code, stdout: Data("CANARY-stdout".utf8)) }
        let result = await read(h)
        #expect(result == .failed(expected))
        #expect(!String(describing: result).contains("CANARY"))
    }

    @Test func stderrUserCanceledIsDenied() async throws {
        let h = try harness { _ in
            ProcessResult(exitCode: 1, stderr: Data("security: SecKeychainSearchCopyNext: User canceled the operation.".utf8))
        }
        #expect(await read(h) == .failed(.keychainAccessDenied(exitCode: 1)))
    }

    @Test func stderrAuthFailedIsDenied() async throws {
        let h = try harness { _ in ProcessResult(exitCode: 2, stderr: Data("auth failed".utf8)) }
        #expect(await read(h) == .failed(.keychainAccessDenied(exitCode: 2)))
    }

    @Test func timeoutIsReported() async throws {
        let h = try harness { _ in ProcessResult(exitCode: 15, terminatedBySignal: true, timedOut: true) }
        #expect(await read(h) == .timedOut(truncated: false))
        #expect(await read(h, deadlineIn: 8) == .timedOut(truncated: true))
    }

    @Test func launchFailureIsAReadFailure() async throws {
        let h = try harness { _ in throw ProcessLaunchError.notFound }
        #expect(await read(h) == .failed(.keychainReadFailed(exitCode: -1)))
    }

    @Test func hexOutputIsDecoded() async throws {
        let value = try Fixtures.data("claude/keychain-value.json")
        let hex = value.map { String(format: "%02x", $0) }.joined()
        let h = try harness { _ in ProcessResult(exitCode: 0, stdout: Data((hex + "\n").utf8)) }
        guard case .found(let credentials, _) = await read(h) else { Issue.record("expected found"); return }
        #expect(credentials.accessToken == Self.token)
    }

    @Test func garbageOutputIsADecodingError() async throws {
        let h = try harness { _ in ProcessResult(exitCode: 0, stdout: Data("CANARY-not-json".utf8)) }
        let result = await read(h)
        #expect(result == .failed(.decoding(codingPath: [])))
    }

    @Test func emptyTokenIsReportedAsFoundWithoutToken() async throws {
        let h = try harness { _ in
            ProcessResult(exitCode: 0, stdout: Data(#"{"claudeAiOauth": {"accessToken": "", "scopes": []}}"#.utf8))
        }
        guard case .found(let credentials, _) = await read(h) else { Issue.record("expected found"); return }
        #expect(!credentials.hasToken)
        let missing = try harness { _ in ProcessResult(exitCode: 0, stdout: Data(#"{"mcpOAuth": {}}"#.utf8)) }
        guard case .found(let none, _) = await read(missing) else { Issue.record("expected found"); return }
        #expect(!none.hasToken)
    }

    @Test func expiryUsesAFiveMinuteMargin() {
        let now = Date(timeIntervalSince1970: 1000)
        let credentials = { (ms: Double) in ClaudeCredentials(accessToken: "t", expiresAtMs: ms, scopes: [], subscriptionType: nil) }
        #expect(credentials(1_301_000).isExpired(at: now) == false)
        #expect(credentials(1_300_000).isExpired(at: now))
        #expect(ClaudeCredentials(accessToken: "t", expiresAtMs: nil, scopes: [], subscriptionType: nil).isExpired(at: now) == false)
    }

    @Test func gateRunsOneSecurityAtATime() async throws {
        let active = Locked((now: 0, peak: 0))
        let h = try harness { _ in
            active.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
            for _ in 0..<20 { await Task.yield() }
            active.withLock { $0.now -= 1 }
            return ProcessResult(exitCode: 36)
        }
        let reader = ClaudeCredentialReader(env: h.env, gate: ClaudeKeychainGate())
        let deadline = h.clock.now.addingTimeInterval(120)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask { _ = await reader.read(configDir: "/d/\(index)", manual: false, deadline: deadline) }
            }
        }
        #expect(h.processes.calls.count == 6)
        #expect(active.current.peak == 1)
    }
}
