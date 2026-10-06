import Foundation

/// A JSON-RPC error from the app-server, reduced to what TokenBar needs. The server's message text is
/// classified on the spot and dropped (spec §9.3).
public struct CodexRPCError: Error, Sendable, Hashable {
    public var code: Int
    /// The message mentioned "authentication required" (spec §5.4 step 5).
    public var authenticationRequired: Bool
    /// The message mentioned "invalid type" (old servers rejecting params, spec §5.4 step 3).
    public var invalidType: Bool

    public init(code: Int, authenticationRequired: Bool = false, invalidType: Bool = false) {
        self.code = code
        self.authenticationRequired = authenticationRequired
        self.invalidType = invalidType
    }

    init(code: Int, message: String?) {
        let lowered = message?.lowercased() ?? ""
        self.init(
            code: code,
            authenticationRequired: lowered.contains("authentication required"),
            invalidType: lowered.contains("invalid type"))
    }
}

/// Both replies of one app-server conversation.
public struct CodexAppServerReadout: Sendable {
    public var account: Result<CodexAccountReadResult, CodexRPCError>
    public var rateLimits: Result<CodexRateLimitsReadResult, CodexRPCError>

    public init(
        account: Result<CodexAccountReadResult, CodexRPCError>,
        rateLimits: Result<CodexRateLimitsReadResult, CodexRPCError>
    ) {
        self.account = account
        self.rateLimits = rateLimits
    }
}

/// Talks to one `codex app-server` over a `LineTransport` (spec §5.4 step 3):
/// `initialize` → `initialized` → `account/read` (id 1) and `account/rateLimits/read` (id 2), pipelined.
/// Responses are matched by id, notifications are ignored, server requests get -32601. stdin is closed
/// only after every response has arrived; the server then has `shutdownGrace` to exit before
/// `terminate()`. The whole conversation is bounded by `timeout`.
///
/// Every method throws `ProviderError` only. On any failure the transport is terminated.
public struct CodexAppServerClient: Sendable {
    /// The only methods TokenBar may send (spec §5.4 step 3, §9.5).
    public static let allowedMethods: Set<String> = ["initialize", "initialized", "account/read", "account/rateLimits/read"]

    public static let defaultTimeout: Duration = .seconds(20)
    public static let defaultShutdownGrace: Duration = .seconds(3)

    static let initializeID = 0
    static let accountID = 1
    static let rateLimitsID = 2
    static let rateLimitsRetryID = 3

    private let transport: any LineTransport
    private let clientVersion: String
    private let sleep: @Sendable (Duration) async throws -> Void
    private let timeout: Duration
    private let shutdownGrace: Duration

    public init(
        transport: any LineTransport,
        clientVersion: String,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        timeout: Duration = CodexAppServerClient.defaultTimeout,
        shutdownGrace: Duration = CodexAppServerClient.defaultShutdownGrace
    ) {
        self.transport = transport
        self.clientVersion = clientVersion
        self.sleep = sleep
        self.timeout = timeout
        self.shutdownGrace = shutdownGrace
    }

    /// Encodes one outgoing request or notification. Throws `.protocolError(.methodNotAllowed)` for any
    /// method outside the allowlist, and for `account/read` with `refreshToken: true`.
    public static func encodeMessage(method: String, id: Int?, params: [String: Any]?) throws -> Data {
        guard allowedMethods.contains(method) else { throw ProviderError.protocolError(.methodNotAllowed) }
        if method == "account/read", let refresh = params?["refreshToken"] as? Bool, refresh {
            throw ProviderError.protocolError(.methodNotAllowed)
        }
        var message: [String: Any] = ["method": method]
        if let id { message["id"] = id }
        if let params { message["params"] = params }
        return try serialize(message)
    }

    /// Runs the whole conversation.
    public func readUsage() async throws -> CodexAppServerReadout {
        do {
            let readout = try await withThrowingTaskGroup(of: CodexAppServerReadout?.self) { group in
                group.addTask { try await self.conversation() }
                group.addTask {
                    try await self.sleep(self.timeout)
                    return nil
                }
                guard let first = try await group.next() else { throw ProviderError.timeout }
                group.cancelAll()
                guard let readout = first else { throw ProviderError.timeout }
                return readout
            }
            return readout
        } catch {
            await transport.terminate()
            if let error = error as? ProviderError { throw error }
            if error is CancellationError { throw ProviderError.timeout }
            throw ProviderError.protocolError(.unexpected)
        }
    }

    // MARK: - Conversation

    private enum Reply {
        case success(Any?)
        case failure(CodexRPCError)
    }

    private func conversation() async throws -> CodexAppServerReadout {
        var lines = transport.incoming.makeAsyncIterator()

        // 1. initialize. If the server goes away before answering, the handshake failed.
        let initParams: [String: Any] = [
            "clientInfo": ["name": "tokenbar", "title": "TokenBar", "version": clientVersion],
            "capabilities": ["experimentalApi": false],
        ]
        do {
            try await send(method: "initialize", id: Self.initializeID, params: initParams)
            let replies = try await collect([Self.initializeID], from: &lines)
            guard case .success(let result)? = replies[Self.initializeID], result is [String: Any] else {
                throw ProviderError.protocolError(.handshakeFailed)
            }
        } catch ProviderError.protocolError(.methodNotAllowed) {
            throw ProviderError.protocolError(.methodNotAllowed)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProviderError.protocolError(.handshakeFailed)
        }

        // 2. initialized, then the two pipelined requests.
        try await send(method: "initialized", id: nil, params: nil)
        try await send(method: "account/read", id: Self.accountID, params: ["refreshToken": false])
        try await send(method: "account/rateLimits/read", id: Self.rateLimitsID, params: ["excludeResetCreditDetails": true])
        var replies = try await collect([Self.accountID, Self.rateLimitsID], from: &lines)

        // 3. Old servers reject the params with -32600 "invalid type": retry once without them.
        if case .failure(let error)? = replies[Self.rateLimitsID], error.code == -32600, error.invalidType {
            try await send(method: "account/rateLimits/read", id: Self.rateLimitsRetryID, params: nil)
            let retry = try await collect([Self.rateLimitsRetryID], from: &lines)
            replies[Self.rateLimitsID] = retry[Self.rateLimitsRetryID]
        }

        let account: Result<CodexAccountReadResult, CodexRPCError>
        switch replies[Self.accountID] {
        case .success(let result)?:
            guard let decoded = CodexRateLimitMapper.decodeAccountResult(result) else {
                throw ProviderError.protocolError(.malformedResponse)
            }
            account = .success(decoded)
        case .failure(let error)?:
            account = .failure(error)
        case nil:
            throw ProviderError.protocolError(.unexpected)
        }

        let rateLimits: Result<CodexRateLimitsReadResult, CodexRPCError>
        switch replies[Self.rateLimitsID] {
        case .success(let result)?:
            guard let decoded = CodexRateLimitMapper.decodeRateLimitsResult(result) else {
                throw ProviderError.protocolError(.malformedResponse)
            }
            rateLimits = .success(decoded)
        case .failure(let error)?:
            rateLimits = .failure(error)
        case nil:
            throw ProviderError.protocolError(.unexpected)
        }

        // 4. Every response is in: close stdin, give the server `shutdownGrace` to exit, then terminate.
        await shutdown(&lines)
        return CodexAppServerReadout(account: account, rateLimits: rateLimits)
    }

    private func shutdown(_ lines: inout AsyncThrowingStream<Data, any Error>.Iterator) async {
        await transport.closeInput()
        let transport = self.transport
        let sleep = self.sleep
        let grace = shutdownGrace
        let watchdog = Task {
            try await sleep(grace)
            await transport.terminate()
        }
        do {
            while try await lines.next() != nil {}
        } catch {}
        watchdog.cancel()
    }

    /// Reads lines until every id in `ids` has a reply. Replies to other ids are dropped.
    private func collect(
        _ ids: Set<Int>, from lines: inout AsyncThrowingStream<Data, any Error>.Iterator
    ) async throws -> [Int: Reply] {
        var replies: [Int: Reply] = [:]
        while !ids.isSubset(of: Set(replies.keys)) {
            let line: Data?
            do {
                line = try await lines.next()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ProviderError.protocolError(.serverExited)
            }
            guard let line else {
                try Task.checkCancellation()
                throw ProviderError.protocolError(.serverExited)
            }
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                continue  // not a JSON object: ignore, like the server does
            }
            if message["method"] != nil {
                // A notification, or a server request (it has an id) that we refuse.
                if let id = message["id"], !(id is NSNull) {
                    try? await replyNotSupported(id: id)
                }
                continue
            }
            guard let id = Self.integerID(message["id"]), ids.contains(id) else { continue }
            if let error = message["error"] as? [String: Any] {
                let code = CodexRateLimitMapper.int(error["code"]) ?? 0
                replies[id] = .failure(CodexRPCError(code: code, message: error["message"] as? String))
            } else {
                replies[id] = .success(message["result"])
            }
        }
        return replies
    }

    private func send(method: String, id: Int?, params: [String: Any]?) async throws {
        let data = try Self.encodeMessage(method: method, id: id, params: params)
        do {
            try await transport.send(data)
        } catch {
            throw ProviderError.protocolError(.serverExited)
        }
    }

    private func replyNotSupported(id: Any) async throws {
        let message: [String: Any] = ["id": id, "error": ["code": -32601, "message": "not supported"]]
        try await transport.send(try Self.serialize(message))
    }

    static func serialize(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw ProviderError.protocolError(.unexpected)
        }
    }

    /// Integer ids only; floats and booleans are not ids.
    static func integerID(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !CodexRateLimitMapper.isBool(number), !CFNumberIsFloatType(number) else {
            return nil
        }
        return number.intValue
    }
}
