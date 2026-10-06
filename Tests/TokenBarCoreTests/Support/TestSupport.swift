import Darwin
import Foundation
@testable import TokenBarCore

// Shared test helpers (plan Task 1). Every test runs against a fresh temp dir, the real LocalFileSystem,
// and fakes for processes, HTTP, code signatures, process inspection and the clock. Nothing here
// touches the real ~/.claude, ~/.codex, ~/Library or the keychain.

/// A value guarded by a lock; lets fakes record calls from concurrent tasks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}

// MARK: - Temp dirs and fixtures

/// A unique, realpath-resolved directory under the system temp dir; removed when released.
final class TempDir: @unchecked Sendable {
    let url: URL

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        url = LocalFileSystem().realpath(raw) ?? raw
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Writes `contents` at `relativePath` (creating parents) and returns the file URL.
    @discardableResult
    func write(_ relativePath: String, _ contents: String, permissions: UInt16 = 0o644) throws -> URL {
        try write(relativePath, Data(contents.utf8), permissions: permissions)
    }

    @discardableResult
    func write(_ relativePath: String, _ data: Data, permissions: UInt16 = 0o644) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        chmod(file.path, mode_t(permissions))
        return file
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let directory = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Files under Tests/TokenBarCoreTests/Fixtures (excluded from the target, read from disk).
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func url(_ relativePath: String) -> URL { directory.appendingPathComponent(relativePath) }
    static func data(_ relativePath: String) throws -> Data { try Data(contentsOf: url(relativePath)) }
    static func string(_ relativePath: String) throws -> String { String(decoding: try data(relativePath), as: UTF8.self) }
}

// MARK: - Clock

/// A manual clock: `now` only moves through `advance`, `set` or `sleep`. `sleep` returns at once.
final class TestClock: @unchecked Sendable {
    private struct State {
        var now: Date
        var sleeps: [Duration] = []
    }

    private let state: Locked<State>

    init(start: Date = Date(timeIntervalSince1970: 1_791_300_000)) {
        state = Locked(State(now: start))
    }

    var now: Date { state.withLock { $0.now } }
    var sleeps: [Duration] { state.withLock { $0.sleeps } }

    func advance(by seconds: TimeInterval) { state.withLock { $0.now = $0.now.addingTimeInterval(seconds) } }
    func set(_ date: Date) { state.withLock { $0.now = date } }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        state.withLock {
            $0.sleeps.append(duration)
            $0.now = $0.now.addingTimeInterval(duration.timeInterval)
        }
        await Task.yield()
    }
}

// MARK: - Processes

final class FakeProcessRunner: ProcessRunning, @unchecked Sendable {
    enum Mode: Sendable, Equatable { case run, streaming, detached }

    struct Call: Sendable, Equatable {
        var mode: Mode
        var request: ProcessRequest
    }

    private let recorded = Locked<[Call]>([])

    // Set these before running the code under test.
    var runHandler: @Sendable (ProcessRequest) async throws -> ProcessResult = { _ in ProcessResult(exitCode: 0) }
    var streamingHandler: @Sendable (ProcessRequest) async throws -> any LineTransport = { _ in
        throw ProcessLaunchError.notFound
    }
    var detachedHandler: @Sendable (ProcessRequest) async throws -> any DetachedProcess = { _ in
        throw ProcessLaunchError.notFound
    }

    var calls: [Call] { recorded.current }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        recorded.withLock { $0.append(Call(mode: .run, request: request)) }
        return try await runHandler(request)
    }

    func startStreaming(_ request: ProcessRequest) async throws -> any LineTransport {
        recorded.withLock { $0.append(Call(mode: .streaming, request: request)) }
        return try await streamingHandler(request)
    }

    func spawnDetached(_ request: ProcessRequest) async throws -> any DetachedProcess {
        recorded.withLock { $0.append(Call(mode: .detached, request: request)) }
        return try await detachedHandler(request)
    }
}

struct FakeDetachedProcess: DetachedProcess {
    var pid: Int32
    /// Exit status reported by every wait; nil means "still running".
    var exitStatus: Int32?

    func waitForExit(timeout: Duration) async -> Int32? { exitStatus }
}

// MARK: - HTTP

final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let recorded = Locked<[HTTPRequest]>([])

    var handler: @Sendable (HTTPRequest) async throws -> HTTPResponse = { _ in
        HTTPResponse(status: 200, body: Data("{}".utf8))
    }

    var requests: [HTTPRequest] { recorded.current }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recorded.withLock { $0.append(request) }
        return try await handler(request)
    }
}

// MARK: - Signatures and process inspection

final class FakeSignatureVerifier: CodeSignatureVerifying, @unchecked Sendable {
    private let trustedFiles = Locked<[String: String]>([:])
    private let trustedPIDs = Locked<[Int32: String]>([:])
    private let checked = Locked<[String]>([])

    /// Marks the file (by realpath) as signed by `teamID`.
    func trust(_ url: URL, teamID: String) { trustedFiles.withLock { $0[Self.key(url)] = teamID } }
    func trust(pid: Int32, teamID: String) { trustedPIDs.withLock { $0[pid] = teamID } }

    /// realpaths passed to `verify`, in call order.
    var verifiedPaths: [String] { checked.current }

    func verify(_ url: URL, teamID: String) async -> Bool {
        let key = Self.key(url)
        checked.withLock { $0.append(key) }
        return trustedFiles.withLock { $0[key] } == teamID
    }

    func verifyRunningProcess(pid: Int32, teamID: String) async -> Bool {
        trustedPIDs.withLock { $0[pid] } == teamID
    }

    private static func key(_ url: URL) -> String { (LocalFileSystem().realpath(url) ?? url).path }
}

final class FakeProcessInspector: ProcessInspecting, @unchecked Sendable {
    private let alive = Locked<[Int32: Date?]>([:])

    func setAlive(_ pid: Int32, startTime: Date?) { alive.withLock { $0[pid] = .some(startTime) } }
    func setDead(_ pid: Int32) { alive.withLock { $0[pid] = nil } }

    func isAlive(pid: Int32) -> Bool { alive.withLock { $0[pid] != nil } }
    func startTime(pid: Int32) -> Date? { alive.withLock { $0[pid] ?? nil } }
}

// MARK: - Harness

/// A `CoreEnvironment` rooted in a fresh temp dir (home at `<temp>/home`), with fakes for every external effect.
final class TestHarness: @unchecked Sendable {
    let temp: TempDir
    let clock: TestClock
    let processes: FakeProcessRunner
    let http: FakeHTTPClient
    let verifier: FakeSignatureVerifier
    let inspector: FakeProcessInspector
    let home: URL
    let env: CoreEnvironment

    init(userName: String = "tester", proxy: ProxySettings? = nil) throws {
        let temp = try TempDir()
        let clock = TestClock()
        let processes = FakeProcessRunner()
        let http = FakeHTTPClient()
        let verifier = FakeSignatureVerifier()
        let inspector = FakeProcessInspector()
        let home = try temp.makeDirectory("home")
        let tmp = try temp.makeDirectory("tmp")
        self.temp = temp
        self.clock = clock
        self.processes = processes
        self.http = http
        self.verifier = verifier
        self.inspector = inspector
        self.home = home
        self.env = CoreEnvironment(
            now: { clock.now },
            sleep: { try await clock.sleep($0) },
            homeDirectory: home,
            appSupportDirectory: home.appendingPathComponent("Library/Application Support/TokenBar", isDirectory: true),
            temporaryDirectory: tmp,
            userName: userName,
            processRunner: processes,
            fileSystem: LocalFileSystem(),
            http: http,
            signatureVerifier: verifier,
            processInspector: inspector,
            systemProxy: { proxy })
    }

    /// Writes a file relative to the fake home dir.
    @discardableResult
    func writeHome(_ relativePath: String, _ contents: String, permissions: UInt16 = 0o644) throws -> URL {
        try temp.write("home/" + relativePath, contents, permissions: permissions)
    }
}
