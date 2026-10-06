import Foundation

// Protocols for every side effect TokenBarCore performs (spec §4.2). Live implementations live in
// files named Live*.swift (plus LocalFileSystem); tests substitute fakes.

// MARK: - Processes

public struct ProcessRequest: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    /// The child's exact environment. Build it with `CoreEnvironment.childEnvironment`; nothing is
    /// inherited from the parent (spec §5.7).
    public var environment: [String: String]
    public var currentDirectory: URL?
    public var stdin: Data?
    public var timeout: Duration
    public var maxOutputBytes: Int

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        stdin: Data? = nil,
        timeout: Duration,
        maxOutputBytes: Int = 4 << 20
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.stdin = stdin
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }
}

public struct ProcessResult: Sendable, Equatable {
    /// Exit status, or the signal number when `terminatedBySignal` is true.
    public var exitCode: Int32
    public var terminatedBySignal: Bool
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    /// True when the child exited but its pipes did not reach EOF within 2 s (a grandchild held them).
    public var pipesTruncated: Bool

    public init(
        exitCode: Int32,
        terminatedBySignal: Bool = false,
        stdout: Data = Data(),
        stderr: Data = Data(),
        timedOut: Bool = false,
        pipesTruncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.terminatedBySignal = terminatedBySignal
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.pipesTruncated = pipesTruncated
    }
}

public enum ProcessLaunchError: Error, Sendable, Equatable {
    case notFound
    case notExecutable
    case spawnFailed(errno: Int32)
}

/// Line-oriented bidirectional pipe to a long-running child (`codex app-server`, spec §5.4 step 3).
public protocol LineTransport: Sendable {
    /// Child process id, used for the post-spawn signature check.
    var pid: Int32 { get }
    /// Writes one line; "\n" is appended. Throws (EPIPE) instead of raising SIGPIPE.
    func send(_ line: Data) async throws
    /// One element per received line. Finishes by throwing `ProviderError.protocolError(.serverExited)`
    /// on EOF or child exit.
    var incoming: AsyncThrowingStream<Data, any Error> { get }
    func closeInput() async
    /// SIGTERM, then SIGKILL after 2 s.
    func terminate() async
}

/// A child started by `spawnDetached`: its own process group, stdio on /dev/null, never signalled (spec §5.3 step ②).
public protocol DetachedProcess: Sendable {
    var pid: Int32 { get }
    /// Waits up to `timeout`. Returns the exit status, or nil if the child is still running.
    /// The child is NOT killed when this returns nil.
    func waitForExit(timeout: Duration) async -> Int32?
}

public protocol ProcessRunning: Sendable {
    /// One-shot run with captured output. Returns within `timeout + 5 s` whatever the pipes do.
    /// Throws `ProcessLaunchError` only when the child cannot be started.
    func run(_ request: ProcessRequest) async throws -> ProcessResult
    /// Long-running child with line-based stdio. `request.stdin` and `request.timeout` are ignored.
    func startStreaming(_ request: ProcessRequest) async throws -> any LineTransport
    /// Detached child for step ②: posix_spawn with POSIX_SPAWN_SETPGROUP, stdio on /dev/null.
    /// `request.stdin`, `request.timeout` and `request.maxOutputBytes` are ignored.
    func spawnDetached(_ request: ProcessRequest) async throws -> any DetachedProcess
}

// MARK: - Files

public struct FileStat: Sendable, Hashable {
    public var device: UInt64
    public var inode: UInt64
    public var size: Int64
    public var modificationTime: Date
    public var changeTime: Date
    public var isRegularFile: Bool
    public var isDirectory: Bool
    public var isSymlink: Bool
    /// Permission bits (`st_mode & 0o7777`).
    public var permissions: UInt16
    /// Any execute bit set.
    public var isExecutable: Bool

    public init(
        device: UInt64, inode: UInt64, size: Int64, modificationTime: Date, changeTime: Date,
        isRegularFile: Bool, isDirectory: Bool, isSymlink: Bool, permissions: UInt16, isExecutable: Bool
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modificationTime = modificationTime
        self.changeTime = changeTime
        self.isRegularFile = isRegularFile
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.permissions = permissions
        self.isExecutable = isExecutable
    }
}

public protocol FileSystemAccess: Sendable {
    func readFile(_ url: URL) throws -> Data
    /// At most the first `maxBytes` bytes (e.g. Mach-O magic checks).
    func readFilePrefix(_ url: URL, maxBytes: Int) throws -> Data
    /// At most the last `maxBytes` bytes (rollout tails).
    func readFileTail(_ url: URL, maxBytes: Int) throws -> Data
    /// Atomic write (temp file + rename). The final file gets `permissions`.
    func writeFileAtomically(_ data: Data, to url: URL, permissions: UInt16) throws
    /// Creates `url` and any missing parents. Every directory this call creates gets `permissions`.
    func createDirectory(_ url: URL, permissions: UInt16) throws
    func setPermissions(_ url: URL, _ permissions: UInt16) throws
    /// Entries of a directory, hidden files included.
    func contentsOfDirectory(_ url: URL) throws -> [URL]
    /// stat(2), following symlinks; nil if the path does not exist.
    func stat(_ url: URL) -> FileStat?
    /// lstat(2), not following symlinks; nil if the path does not exist.
    func lstat(_ url: URL) -> FileStat?
    /// realpath(3); nil if the path cannot be resolved.
    func realpath(_ url: URL) -> URL?
    func fileExists(_ url: URL) -> Bool
    func moveItem(_ source: URL, to destination: URL) throws
    func removeItem(_ url: URL) throws
    /// Runs `body` while holding an exclusive flock on `lockFile` (created with mode 0600 if missing).
    func withExclusiveLock<T>(_ lockFile: URL, _ body: () throws -> T) throws -> T
}

// MARK: - Network

public struct HTTPRequest: Sendable, Equatable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var timeout: Duration

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], timeout: Duration) {
        self.url = url
        self.method = method
        self.headers = headers
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public enum HTTPClientError: Error, Sendable, Equatable {
    case transport(urlErrorCode: Int)
    case timeout
    case redirectRefused
}

public protocol HTTPClient: Sendable {
    /// Throws `HTTPClientError`. The live client is ephemeral, cacheless, and refuses redirects (spec §9.1).
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

// MARK: - Code signatures and processes

public protocol CodeSignatureVerifying: Sendable {
    /// Static check of the file at `url` against
    /// `anchor apple generic and certificate leaf[subject.OU] = "<teamID>"`. Never executes the file.
    func verify(_ url: URL, teamID: String) async -> Bool
    /// The same requirement, checked against a running process.
    func verifyRunningProcess(pid: Int32, teamID: String) async -> Bool
}

public protocol ProcessInspecting: Sendable {
    /// `kill(pid, 0) == 0` or `errno == EPERM`.
    func isAlive(pid: Int32) -> Bool
    /// Process start time from `proc_pidinfo(PROC_PIDTBSDINFO)`; nil if unavailable.
    func startTime(pid: Int32) -> Date?
}

public struct ProxySettings: Sendable, Equatable {
    public var httpsProxy: String?
    public var httpProxy: String?
    public var noProxy: String?

    public init(httpsProxy: String? = nil, httpProxy: String? = nil, noProxy: String? = nil) {
        self.httpsProxy = httpsProxy
        self.httpProxy = httpProxy
        self.noProxy = noProxy
    }
}
