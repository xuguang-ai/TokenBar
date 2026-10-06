import Foundation
import Testing
@testable import TokenBarCore

@Suite("CodexProvider")
struct CodexProviderTests {
    private struct StubLocator: BinaryLocating {
        var binary: LocatedBinary?
        func locate(_ kind: BinaryKind, settings: AppSettings) async -> LocatedBinary? { kind == .codex ? binary : nil }
        func candidates(_ kind: BinaryKind, settings: AppSettings) async -> [BinaryCandidate] { [] }
    }

    /// One provider wired to a harness, with sleeps that never fire unless asked to.
    private final class Rig: @unchecked Sendable {
        let harness: TestHarness
        let binary: LocatedBinary
        let transports = Locked<[CodexTestKit.ScriptedTransport]>([])
        var env: CoreEnvironment

        init(fires: Set<Duration> = []) throws {
            harness = try TestHarness()
            binary = LocatedBinary(
                url: harness.temp.url.appendingPathComponent("bin/codex"), version: SemVer("0.160.0"), kind: .codex)
            env = harness.env
            env.sleep = CodexTestKit.sleep(fires: fires)
        }

        func provider(binary: LocatedBinary?? = .none) -> CodexProvider {
            CodexProvider(env: env, binaryLocator: StubLocator(binary: binary ?? self.binary), clientVersion: "9.9.9")
        }

        /// Each spawn gets the next transport from `make(callIndex)`; its pid is trusted unless `trusted` says no.
        func serve(trusted: @escaping @Sendable (Int) -> Bool = { _ in true },
                   _ make: @escaping @Sendable (Int) throws -> CodexTestKit.ScriptedTransport) {
            let verifier = harness.verifier
            let transports = self.transports
            harness.processes.streamingHandler = { _ in
                let index = transports.withLock { $0.count }
                let transport = try make(index)
                transports.withLock { $0.append(transport) }
                if trusted(index) { verifier.trust(pid: transport.pid, teamID: "2DC432GLL2") }
                return transport
            }
        }

        func profile(_ relative: String = "codex-work") throws -> AccountConfig {
            try harness.writeHome(relative + "/config.toml", "model = \"x\"\n")
            return AccountConfig(provider: .codex, displayName: "Codex", codexHome: "~/" + relative)
        }

        func writeRollout(_ relative: String = "codex-work") throws {
            try harness.writeHome(relative + "/sessions/2026/10/05/rollout-a.jsonl",
                                  String(decoding: try Fixtures.data("codex/rollout_mixed.jsonl"), as: UTF8.self))
        }

        var context: RefreshContext {
            RefreshContext(trigger: .manual, deadline: harness.clock.now.addingTimeInterval(60), allowClaudeCodeRefresh: false)
        }
        var streamingCalls: [ProcessRequest] { harness.processes.calls.filter { $0.mode == .streaming }.map(\.request) }
    }

    private static let settings = AppSettings(accounts: [])

    // MARK: CODEX_HOME validation

    @Test func missingEmptyOrForeignDirectoryIsNotAProfile() async throws {
        let rig = try Rig()
        let missing = AccountConfig(provider: .codex, displayName: "C", codexHome: "~/nope")
        try rig.harness.temp.makeDirectory("home/empty")
        let empty = AccountConfig(provider: .codex, displayName: "C", codexHome: "~/empty")
        try rig.harness.writeHome("other/notes.txt", "x")
        let foreign = AccountConfig(provider: .codex, displayName: "C", codexHome: "~/other")
        for account in [missing, empty, foreign] {
            await #expect(throws: ProviderError.notACodexProfile) {
                try await rig.provider().fetchUsage(for: account, settings: Self.settings, context: rig.context)
            }
        }
        #expect(rig.streamingCalls.isEmpty)
    }

    @Test func authJSONIsOnlyStatted() throws {
        let rig = try Rig()
        // auth.json as a directory: any attempt to read it would fail, and the recorder sees every read.
        try rig.harness.temp.makeDirectory("home/.codex/auth.json")
        let fs = CodexTestKit.RecordingFileSystem()
        let home = CodexProvider.codexHomeURL(nil, home: rig.harness.home)
        #expect(home.path == rig.harness.home.appendingPathComponent(".codex").path)
        #expect(CodexProvider.isCodexProfile(home, fileSystem: fs))
        #expect(fs.readPaths.isEmpty)
    }

    // MARK: App-server path

    @Test func spawnsTheExactArgvWithAMinimalEnvAndMapsTheResult() async throws {
        let rig = try Rig()
        let account = try rig.profile()
        rig.serve { _ in CodexTestKit.ScriptedTransport(pid: 501, respond: try CodexTestKit.fixtureResponder()) }
        rig.harness.clock.set(Date(timeIntervalSince1970: 1_791_251_178))

        let outcome = try await rig.provider().fetchUsage(for: account, settings: Self.settings, context: rig.context)

        let request = try #require(rig.streamingCalls.first)
        #expect(rig.streamingCalls.count == 1)
        #expect(request.executable == rig.binary.url)
        #expect(request.arguments == ["-c", "features.plugins=false", "-c", "memories.generate_memories=false",
                                      "-c", "memories.use_memories=false", "app-server", "--listen", "stdio://"])
        #expect(request.environment["CODEX_HOME"] == rig.harness.home.appendingPathComponent("codex-work").path)
        #expect(request.environment["RUST_LOG"] == "error")
        #expect(request.environment["HOME"] == rig.harness.home.path)
        #expect(request.environment["PATH"] == MinimalEnv.path)
        #expect(Set(request.environment.keys) == ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "CODEX_HOME", "RUST_LOG"])

        #expect(outcome.warning == nil)
        let snapshot = outcome.snapshot
        #expect(snapshot.accountID == account.id)
        #expect(snapshot.source == .codexAppServer)
        #expect(snapshot.identity == AccountIdentity(plan: "Plus"))
        #expect(snapshot.identity?.email == nil)
        #expect(snapshot.windows.map(\.kind) == [.fiveHour, .weekly])
        #expect(snapshot.windows.map(\.isStarted) == [false, true])
        #expect(snapshot.limitReached == false)
        let transport = try #require(rig.transports.current.first)
        #expect(transport.events.last == "close")
        #expect(!transport.events.contains("terminate"))
    }

    @Test func defaultHomeLeavesCodexHomeUnset() async throws {
        let rig = try Rig()
        try rig.harness.writeHome(".codex/config.toml", "")
        rig.serve { _ in CodexTestKit.ScriptedTransport(respond: try CodexTestKit.fixtureResponder()) }
        let account = AccountConfig(provider: .codex, displayName: "Codex")
        _ = try await rig.provider().fetchUsage(for: account, settings: Self.settings, context: rig.context)
        #expect(rig.streamingCalls.first?.environment["CODEX_HOME"] == nil)
    }

    @Test func proxySettingReachesTheChild() async throws {
        let rig = try Rig()
        let account = try rig.profile()
        rig.serve { _ in CodexTestKit.ScriptedTransport(respond: try CodexTestKit.fixtureResponder()) }
        var settings = Self.settings
        settings.subprocessProxy = "http://proxy.example:8080"
        _ = try await rig.provider().fetchUsage(for: account, settings: settings, context: rig.context)
        #expect(rig.streamingCalls.first?.environment["HTTPS_PROXY"] == "http://proxy.example:8080")
    }

    // MARK: Signature

    @Test func untrustedRunningProcessIsKilled() async throws {
        let rig = try Rig()
        let account = try rig.profile()
        rig.serve(trusted: { _ in false }) { _ in CodexTestKit.ScriptedTransport(pid: 777, respond: try CodexTestKit.fixtureResponder()) }
        rig.harness.inspector.setAlive(777, startTime: nil)

        await #expect(throws: ProviderError.binarySignatureInvalid(.codex)) {
            try await rig.provider().fetchUsage(for: account, settings: Self.settings, context: rig.context)
        }
        let transport = try #require(rig.transports.current.first)
        #expect(transport.events == ["terminate"])  // nothing was sent to it
        #expect(rig.streamingCalls.count == 1)

        try rig.writeRollout()
        let outcome = try await rig.provider().fetchUsage(for: account, settings: Self.settings, context: rig.context)
        #expect(outcome.warning == .binarySignatureInvalid(.codex))
        #expect(outcome.snapshot.source.isCached)
    }

    // MARK: Argument fallback

    @Test func earlyExitRetriesWithAppServerOnlyAndRemembersIt() async throws {
        let rig = try Rig()
        let account = try rig.profile()
        let responder = try CodexTestKit.fixtureResponder()
        // The full argv makes the child exit at once; the legacy argv works.
        rig.serve { index in
            CodexTestKit.ScriptedTransport(pid: Int32(index + 1)) { server, message in
                if index == 0 { server.exit(); return }
                responder(server, message)
            }
        }
        let provider = rig.provider()
        let outcome = try await provider.fetchUsage(for: account, settings: Self.settings, context: rig.context)
        #expect(outcome.warning == nil)
        #expect(rig.streamingCalls.map(\.arguments) == [CodexProvider.launchArguments, ["app-server"]])

        // Remembered for this binary version: the next refresh goes straight to the legacy argv.
        _ = try await provider.fetchUsage(for: account, settings: Self.settings, context: rig.context)
        #expect(rig.streamingCalls.map(\.arguments).last == ["app-server"])
        #expect(rig.streamingCalls.count == 3)
    }

    @Test func childDeadBeforeTheSignatureCheckCountsAsEarlyExit() async throws {
        let rig = try Rig()
        let account = try rig.profile()
        // First child: untrusted and already gone (inspector says dead). Second child works.
        rig.serve(trusted: { $0 == 1 }) { index in
            CodexTestKit.ScriptedTransport(pid: Int32(100 + index), respond: try CodexTestKit.fixtureResponder())
        }
        let outcome = try await rig.provider().fetchUsage(for: account, settings: Self.settings, context: rig.context)
        #expect(outcome.warning == nil)
        #expect(rig.streamingCalls.map(\.arguments) == [CodexProvider.launchArguments, ["app-server"]])
    }

    @Test func slowHandshakeFailureDoesNotRetry() async throws {
        let rig = try Rig()
        let account = try rig.profile()
        try rig.writeRollout()
        let clock = rig.harness.clock
        rig.serve { _ in
            CodexTestKit.ScriptedTransport { server, _ in
                clock.advance(by: 5)
                server.exit()
            }
        }
        let outcome = try await rig.provider().fetchUsage(for: account, settings: Self.settings, context: rig.context)
        #expect(rig.streamingCalls.count == 1)
        #expect(outcome.warning == .protocolError(.handshakeFailed))
        #expect(outcome.snapshot.source == .codexRollout(eventAt: try #require(DateParsing.iso8601("2026-10-05T20:50:00.123Z"))))
    }

    @Test func bothArgvFailingFallsBack() async throws {
        let rig = try Rig()
        let account = try rig.profile()
        rig.serve { _ in CodexTestKit.ScriptedTransport { server, _ in server.exit() } }
        await #expect(throws: ProviderError.protocolError(.handshakeFailed)) {
            try await rig.provider().fetchUsage(for: account, settings: Self.settings, context: rig.context)
        }
        #expect(rig.streamingCalls.count == 2)
    }

    // MARK: Not logged in

    @Test func loggedOutProfileIsNotLoggedInEvenWithRolloutData() async throws {
        let rig = try Rig()
        let account = try rig.profile()
        try rig.writeRollout()
        rig.serve { _ in
            CodexTestKit.ScriptedTransport { server, message in
                switch message["method"] as? String {
                case "initialize": server.emit(#"{"id":0,"result":{}}"#)
                case "account/rateLimits/read":
                    server.emit(#"{"id":2,"error":{"code":-32600,"message":"codex account authentication required to read rate limits"}}"#)
                    server.emit(#"{"id":1,"result":{"account":null,"requiresOpenaiAuth":true,"workspaceRouting":null}}"#)
                default: break
                }
            }
        }
        await #expect(throws: ProviderError.notLoggedIn(hint: .codex(home: "~/codex-work"))) {
            try await rig.provider().fetchUsage(for: account, settings: Self.settings, context: rig.context)
        }
    }

    @Test func authenticationRequiredOnRateLimitsAloneIsNotLoggedIn() async throws {
        let rig = try Rig()
        let account = try rig.profile()
        rig.serve { _ in
            CodexTestKit.ScriptedTransport { server, message in
                switch message["method"] as? String {
                case "initialize": server.emit(#"{"id":0,"result":{}}"#)
                case "account/rateLimits/read":
                    server.emit(#"{"id":1,"result":{"account":{"type":"apiKey"}}}"#)
                    server.emit(#"{"id":2,"error":{"code":-32600,"message":"Authentication required"}}"#)
                default: break
                }
            }
        }
        await #expect(throws: ProviderError.notLoggedIn(hint: .codex(home: "~/codex-work"))) {
            try await rig.provider().fetchUsage(for: account, settings: Self.settings, context: rig.context)
        }
    }

    // MARK: Fallbacks

    @Test func missingBinaryUsesRolloutWithWarning() async throws {
        let rig = try Rig()
        let account = try rig.profile()
        await #expect(throws: ProviderError.codexBinaryNotFound) {
            try await rig.provider(binary: .some(nil)).fetchUsage(for: account, settings: Self.settings, context: rig.context)
        }
        try rig.writeRollout()
        let outcome = try await rig.provider(binary: .some(nil)).fetchUsage(for: account, settings: Self.settings, context: rig.context)
        let eventAt = try #require(DateParsing.iso8601("2026-10-05T20:50:00.123Z"))
        #expect(outcome.warning == .codexBinaryNotFound)
        #expect(outcome.snapshot.source == .codexRollout(eventAt: eventAt))
        #expect(outcome.snapshot.dataAsOf == eventAt)
        #expect(outcome.snapshot.fetchedAt == rig.harness.clock.now)
        #expect(outcome.snapshot.identity?.plan == "Plus")
        #expect(outcome.snapshot.windows.map(\.usedPercent) == [98, 15])
        #expect(rig.streamingCalls.isEmpty)
    }

    @Test func timeoutFallsBackToRollout() async throws {
        let rig = try Rig(fires: [.seconds(20)])
        let account = try rig.profile()
        try rig.writeRollout()
        rig.serve { _ in
            CodexTestKit.ScriptedTransport { server, message in
                if message["method"] as? String == "initialize" { server.emit(#"{"id":0,"result":{}}"#) }
            }
        }
        let outcome = try await rig.provider().fetchUsage(for: account, settings: Self.settings, context: rig.context)
        #expect(outcome.warning == .timeout)
        #expect(rig.transports.current.first?.events.contains("terminate") == true)
    }

    @Test func launchFailureFallsBack() async throws {
        let rig = try Rig()
        let account = try rig.profile()
        rig.harness.processes.streamingHandler = { _ in throw ProcessLaunchError.notExecutable }
        await #expect(throws: ProviderError.protocolError(.launchFailed)) {
            try await rig.provider().fetchUsage(for: account, settings: Self.settings, context: rig.context)
        }
    }

    @Test func protocolErrorOnRateLimitsFallsBack() async throws {
        let rig = try Rig()
        let account = try rig.profile()
        try rig.writeRollout()
        rig.serve { _ in
            CodexTestKit.ScriptedTransport { server, message in
                switch message["method"] as? String {
                case "initialize": server.emit(#"{"id":0,"result":{}}"#)
                case "account/rateLimits/read":
                    server.emit(#"{"id":1,"result":{"account":{"type":"chatgpt"}}}"#)
                    server.emit(#"{"id":2,"error":{"code":-32603,"message":"upstream failed sk-canary"}}"#)
                default: break
                }
            }
        }
        let outcome = try await rig.provider().fetchUsage(for: account, settings: Self.settings, context: rig.context)
        #expect(outcome.warning == .protocolError(.unexpected))
        let encoded = String(decoding: try JSONEncoder().encode(outcome.snapshot), as: UTF8.self)
            + String(describing: outcome.warning)
        #expect(!encoded.contains("canary"))
    }
}
