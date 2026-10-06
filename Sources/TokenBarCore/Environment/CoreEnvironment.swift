import Foundation

/// Every side effect TokenBarCore performs enters through this value (spec §4.2): the clock, sleeping,
/// well-known directories, the user name, subprocesses, files, HTTP, signature checks, process
/// inspection and the system proxy. `CoreEnvironment.live()` (LiveEnvironment.swift) is the only
/// place that wires the real APIs; tests build one around a temp dir.
public struct CoreEnvironment: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async throws -> Void
    public var homeDirectory: URL
    /// `~/Library/Application Support/TokenBar` in production.
    public var appSupportDirectory: URL
    public var temporaryDirectory: URL
    /// Keychain account and USER/LOGNAME for children (spec §2.1).
    public var userName: String
    public var processRunner: any ProcessRunning
    public var fileSystem: any FileSystemAccess
    public var http: any HTTPClient
    public var signatureVerifier: any CodeSignatureVerifying
    public var processInspector: any ProcessInspecting
    public var systemProxy: @Sendable () -> ProxySettings?

    public init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        homeDirectory: URL,
        appSupportDirectory: URL,
        temporaryDirectory: URL,
        userName: String,
        processRunner: any ProcessRunning,
        fileSystem: any FileSystemAccess,
        http: any HTTPClient,
        signatureVerifier: any CodeSignatureVerifying,
        processInspector: any ProcessInspecting,
        systemProxy: @escaping @Sendable () -> ProxySettings?
    ) {
        self.now = now
        self.sleep = sleep
        self.homeDirectory = homeDirectory
        self.appSupportDirectory = appSupportDirectory
        self.temporaryDirectory = temporaryDirectory
        self.userName = userName
        self.processRunner = processRunner
        self.fileSystem = fileSystem
        self.http = http
        self.signatureVerifier = signatureVerifier
        self.processInspector = processInspector
        self.systemProxy = systemProxy
    }

    /// Proxy for subprocesses: the user setting wins, then the system proxy (spec §5.7).
    public func subprocessProxy(settings: AppSettings) -> ProxySettings? {
        if let proxy = settings.subprocessProxy?.trimmingCharacters(in: .whitespaces), !proxy.isEmpty {
            return ProxySettings(httpsProxy: proxy, httpProxy: proxy, noProxy: nil)
        }
        return systemProxy()
    }

    /// The only way to build a child environment (spec §5.7). `extra` values that are nil are skipped.
    public func childEnvironment(settings: AppSettings, extra: [String: String?] = [:]) -> [String: String] {
        MinimalEnv.make(
            userName: userName,
            home: homeDirectory,
            temporaryDirectory: temporaryDirectory,
            proxy: subprocessProxy(settings: settings),
            extra: extra)
    }

    /// `~/.tokenbar/claude`: parent of the dedicated Claude login dirs (spec §3.1).
    public var dedicatedClaudeLoginsRoot: URL {
        homeDirectory.appendingPathComponent(".tokenbar/claude", isDirectory: true)
    }
}
