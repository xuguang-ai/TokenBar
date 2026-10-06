import Foundation
import Testing
@testable import TokenBarCore

/// Test-only helpers shared by the Codex test files.
enum CodexTestKit {
    /// A scripted app-server: `respond` sees every decoded message the client sends and may emit lines
    /// or end the stream. Everything is recorded in `events` ("send:<method or reply>", "close", "terminate").
    final class ScriptedTransport: LineTransport, @unchecked Sendable {
        typealias Responder = @Sendable (ScriptedTransport, [String: Any]) -> Void

        let pid: Int32
        let incoming: AsyncThrowingStream<Data, any Error>
        private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
        private let state = Locked<(events: [String], sent: [[String: Any]], finished: Bool)>(([], [], false))
        private let respond: Responder
        /// The server exits (stream ends) when stdin closes. False simulates a server that hangs.
        let exitsOnClose: Bool

        init(pid: Int32 = 4242, exitsOnClose: Bool = true, respond: @escaping Responder) {
            self.pid = pid
            self.exitsOnClose = exitsOnClose
            self.respond = respond
            (incoming, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
        }

        var events: [String] { state.withLock { $0.events } }
        var sent: [[String: Any]] { state.withLock { $0.sent } }

        func emit(_ line: String) { continuation.yield(Data(line.utf8)) }

        func exit() {
            state.withLock { $0.finished = true }
            continuation.finish(throwing: ProviderError.protocolError(.serverExited))
        }

        func send(_ line: Data) async throws {
            if state.withLock({ $0.finished }) { throw ProcessLaunchError.spawnFailed(errno: EPIPE) }
            let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
            state.withLock {
                $0.sent.append(object)
                $0.events.append("send:" + ((object["method"] as? String) ?? "reply"))
            }
            respond(self, object)
        }

        func closeInput() async {
            state.withLock { $0.events.append("close") }
            if exitsOnClose { exit() }
        }

        func terminate() async {
            state.withLock { $0.events.append("terminate") }
            exit()
        }
    }

    /// Sleeps that never return unless the duration is listed in `fires` (then they return at once).
    static func sleep(fires: Set<Duration> = []) -> @Sendable (Duration) async throws -> Void {
        { duration in
            if fires.contains(duration) { return }
            try await Task.sleep(for: .seconds(3_600))
        }
    }

    /// A well-behaved server that replies from the Phase 0 fixture lines, rate limits before account.
    static func fixtureResponder() throws -> ScriptedTransport.Responder {
        let lines = try Fixtures.string("codex/appserver_server_lines.jsonl").split(separator: "\n").map(String.init)
        return { server, message in
            switch message["method"] as? String {
            case "initialize": server.emit(lines[0]); server.emit(lines[1])
            case "account/rateLimits/read": server.emit(lines[2]); server.emit(lines[3]); server.emit(lines[4])
            default: break
            }
        }
    }
}

@Suite("CodexAppServerClient")
struct CodexAppServerClientTests {
    func client(_ transport: CodexTestKit.ScriptedTransport, fires: Set<Duration> = []) -> CodexAppServerClient {
        CodexAppServerClient(transport: transport, clientVersion: "1.2.3", sleep: CodexTestKit.sleep(fires: fires))
    }

    @Test func handshakeOutOfOrderResponsesAndNotifications() async throws {
        let transport = CodexTestKit.ScriptedTransport(respond: try CodexTestKit.fixtureResponder())
        let readout = try await client(transport).readUsage()

        #expect(try readout.account.get() == CodexAccountReadResult(isLoggedIn: true, accountType: "chatgpt", planType: "plus"))
        let limits = try readout.rateLimits.get()
        #expect(limits.effectiveSnapshot?.secondary?.usedPercent == 16)
        #expect(transport.events == [
            "send:initialize", "send:initialized", "send:account/read", "send:account/rateLimits/read", "close",
        ])

        let sent = transport.sent
        #expect(sent[0]["id"] as? Int == 0)
        let initParams = try #require(sent[0]["params"] as? [String: Any])
        let clientInfo = try #require(initParams["clientInfo"] as? [String: Any])
        #expect(clientInfo["name"] as? String == "tokenbar")
        #expect(clientInfo["title"] as? String == "TokenBar")
        #expect(clientInfo["version"] as? String == "1.2.3")
        #expect((initParams["capabilities"] as? [String: Any])?["experimentalApi"] as? Bool == false)
        #expect(sent[1]["id"] == nil)
        #expect(sent[2]["id"] as? Int == 1)
        #expect((sent[2]["params"] as? [String: Any])?["refreshToken"] as? Bool == false)
        #expect(sent[3]["id"] as? Int == 2)
        #expect((sent[3]["params"] as? [String: Any])?["excludeResetCreditDetails"] as? Bool == true)
    }

    @Test func closesInputOnlyAfterEveryResponse() async throws {
        // The account reply comes only after a later notification; close must wait for it.
        let transport = CodexTestKit.ScriptedTransport { server, message in
            switch message["method"] as? String {
            case "initialize": server.emit(#"{"id":0,"result":{}}"#)
            case "account/rateLimits/read":
                server.emit(#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":300}}}}"#)
                server.emit(#"{"method":"account/updated","params":{},"emittedAtMs":1}"#)
                server.emit(#"{"id":1,"result":{"account":{"type":"chatgpt","planType":"pro"}}}"#)
            default: break
            }
        }
        _ = try await client(transport).readUsage()
        #expect(transport.events.last == "close")
        #expect(transport.events.filter { $0 == "close" }.count == 1)
    }

    @Test func serverRequestsGetMethodNotFound() async throws {
        let transport = CodexTestKit.ScriptedTransport { server, message in
            switch message["method"] as? String {
            case "initialize":
                server.emit(#"{"id":"srv-1","method":"item/commandExecution/requestApproval","params":{}}"#)
                server.emit(#"{"id":0,"result":{}}"#)
            case "account/read":
                server.emit(#"{"id":77,"method":"account/chatgptAuthTokens/refresh","params":{}}"#)
                server.emit(#"{"id":1,"result":{"account":{"type":"chatgpt"}}}"#)
            case "account/rateLimits/read":
                server.emit(#"{"id":2,"result":{"rateLimits":null}}"#)
            default: break
            }
        }
        _ = try await client(transport).readUsage()
        let replies = transport.sent.filter { $0["method"] == nil }
        #expect(replies.count == 2)
        #expect(replies[0]["id"] as? String == "srv-1")
        #expect(replies[1]["id"] as? Int == 77)
        for reply in replies {
            let error = try #require(reply["error"] as? [String: Any])
            #expect(error["code"] as? Int == -32601)
            #expect(error["message"] as? String == "not supported")
        }
    }

    @Test func invalidTypeRetriesWithoutParams() async throws {
        let transport = CodexTestKit.ScriptedTransport { server, message in
            switch (message["method"] as? String, message["id"] as? Int) {
            case ("initialize", _): server.emit(#"{"id":0,"result":{}}"#)
            case ("account/read", _): server.emit(#"{"id":1,"result":{"account":{"type":"chatgpt"}}}"#)
            case ("account/rateLimits/read", 2?):
                server.emit(#"{"id":2,"error":{"code":-32600,"message":"Invalid request: invalid type: map, expected unit"}}"#)
            case ("account/rateLimits/read", _):
                server.emit(#"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":9,"windowDurationMins":300}}}}"#)
            default: break
            }
        }
        let readout = try await client(transport).readUsage()
        #expect(try readout.rateLimits.get().rateLimits?.primary?.usedPercent == 9)
        let retry = try #require(transport.sent.last { $0["method"] as? String == "account/rateLimits/read" })
        #expect(retry["id"] as? Int == 3)
        #expect(retry["params"] == nil)
    }

    @Test func otherErrorsDoNotRetry() async throws {
        let transport = CodexTestKit.ScriptedTransport { server, message in
            switch message["method"] as? String {
            case "initialize": server.emit(#"{"id":0,"result":{}}"#)
            case "account/read": server.emit(#"{"id":1,"result":{"account":null,"requiresOpenaiAuth":true}}"#)
            case "account/rateLimits/read":
                server.emit(#"{"id":2,"error":{"code":-32600,"message":"codex account authentication required to read rate limits"}}"#)
            default: break
            }
        }
        let readout = try await client(transport).readUsage()
        #expect(try readout.account.get().isLoggedIn == false)
        #expect(throws: CodexRPCError(code: -32600, authenticationRequired: true)) { try readout.rateLimits.get() }
        #expect(transport.sent.filter { $0["method"] as? String == "account/rateLimits/read" }.count == 1)
    }

    @Test func timeoutTerminates() async throws {
        let transport = CodexTestKit.ScriptedTransport { server, message in
            if message["method"] as? String == "initialize" { server.emit(#"{"id":0,"result":{}}"#) }
        }
        await #expect(throws: ProviderError.timeout) {
            try await client(transport, fires: [CodexAppServerClient.defaultTimeout]).readUsage()
        }
        #expect(transport.events.contains("terminate"))
        #expect(!transport.events.contains("close"))
    }

    @Test func serverExitsBeforeResponses() async throws {
        let transport = CodexTestKit.ScriptedTransport { server, message in
            switch message["method"] as? String {
            case "initialize": server.emit(#"{"id":0,"result":{}}"#)
            case "account/rateLimits/read": server.emit(#"{"id":1,"result":{"account":null}}"#); server.exit()
            default: break
            }
        }
        await #expect(throws: ProviderError.protocolError(.serverExited)) { try await client(transport).readUsage() }
        #expect(transport.events.contains("terminate"))
    }

    @Test func serverExitsBeforeInitializeIsAHandshakeFailure() async throws {
        let transport = CodexTestKit.ScriptedTransport { server, _ in server.exit() }
        await #expect(throws: ProviderError.protocolError(.handshakeFailed)) { try await client(transport).readUsage() }
    }

    @Test func initializeErrorIsAHandshakeFailure() async throws {
        let transport = CodexTestKit.ScriptedTransport { server, _ in
            server.emit(#"{"id":0,"error":{"code":-32600,"message":"Already initialized"}}"#)
        }
        await #expect(throws: ProviderError.protocolError(.handshakeFailed)) { try await client(transport).readUsage() }
    }

    @Test func sendAfterExitFails() async throws {
        // The server answers initialize and then dies; the next write fails with EPIPE.
        let transport = CodexTestKit.ScriptedTransport { server, message in
            if message["method"] as? String == "initialize" {
                server.emit(#"{"id":0,"result":{}}"#)
                server.exit()
            }
        }
        await #expect(throws: ProviderError.protocolError(.serverExited)) { try await client(transport).readUsage() }
    }

    @Test func hungServerIsTerminatedAfterTheGrace() async throws {
        let transport = CodexTestKit.ScriptedTransport(exitsOnClose: false, respond: try CodexTestKit.fixtureResponder())
        let readout = try await client(transport, fires: [CodexAppServerClient.defaultShutdownGrace]).readUsage()
        #expect(try readout.account.get().isLoggedIn)
        #expect(Array(transport.events.suffix(2)) == ["close", "terminate"])
    }

    @Test func malformedLinesAndForeignIdsAreIgnored() async throws {
        let transport = CodexTestKit.ScriptedTransport { server, message in
            switch message["method"] as? String {
            case "initialize":
                server.emit("not json at all")
                server.emit("[1,2,3]")
                server.emit(#"{"id":0.5,"result":{}}"#)
                server.emit(#"{"id":0,"result":{"userAgent":"x","extra":{"emittedAtMs":1}}}"#)
            case "account/rateLimits/read":
                server.emit(#"{"id":99,"result":{}}"#)
                server.emit(#"{"id":true,"result":{}}"#)
                server.emit(#"{"id":1,"result":{"account":{"type":"apiKey"}}}"#)
                server.emit(#"{"id":2,"result":{"rateLimits":null,"unknown":[1]}}"#)
            default: break
            }
        }
        let readout = try await client(transport).readUsage()
        #expect(try readout.account.get().accountType == "apiKey")
    }

    @Test func nonObjectResultIsMalformed() async throws {
        let transport = CodexTestKit.ScriptedTransport { server, message in
            switch message["method"] as? String {
            case "initialize": server.emit(#"{"id":0,"result":{}}"#)
            case "account/rateLimits/read":
                server.emit(#"{"id":1,"result":{"account":null}}"#)
                server.emit(#"{"id":2,"result":"nope"}"#)
            default: break
            }
        }
        await #expect(throws: ProviderError.protocolError(.malformedResponse)) { try await client(transport).readUsage() }
    }

    @Test func allowlistRejectsEverythingElse() throws {
        for method in ["account/rateLimitResetCredit/consume", "account/sendAddCreditsNudgeEmail", "account/logout",
                       "account/login/start", "thread/start", "account/usage/read"] {
            #expect(throws: ProviderError.protocolError(.methodNotAllowed)) {
                try CodexAppServerClient.encodeMessage(method: method, id: 9, params: nil)
            }
        }
        #expect(throws: ProviderError.protocolError(.methodNotAllowed)) {
            try CodexAppServerClient.encodeMessage(method: "account/read", id: 1, params: ["refreshToken": true])
        }
        for method in CodexAppServerClient.allowedMethods {
            #expect(throws: Never.self) { try CodexAppServerClient.encodeMessage(method: method, id: 1, params: [:]) }
        }
    }

    @Test func rpcErrorMessagesAreNotKept() throws {
        let error = CodexRPCError(code: -32600, message: "authentication required sk-canary-123")
        #expect(error.authenticationRequired)
        #expect(!String(describing: error).contains("canary"))
    }
}
