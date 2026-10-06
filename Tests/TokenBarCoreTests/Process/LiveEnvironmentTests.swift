import Darwin
import Foundation
import Testing
@testable import TokenBarCore

@Suite("LiveEnvironment")
struct LiveEnvironmentTests {
    // MARK: HTTP client (no network)

    @Test func sessionConfigurationIsEphemeralAndCacheless() {
        let configuration = LiveHTTPClient.makeConfiguration()
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.urlCredentialStorage == nil)
    }

    @Test func clientUsesTheRedirectRefusingDelegate() {
        let client = LiveHTTPClient()
        #expect(client.session.delegate is LiveRedirectRefusingDelegate)
        #expect(client.session !== URLSession.shared)
    }

    @Test func delegateRefusesEveryRedirect() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let origin = try #require(URL(string: "https://api.anthropic.com/api/oauth/usage"))
        let target = try #require(URL(string: "https://elsewhere.invalid/"))
        let task = session.dataTask(with: origin)  // never resumed: no network
        defer { task.cancel() }
        let response = try #require(HTTPURLResponse(
            url: origin, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString]))
        let decision = Locked<URLRequest??>(.none)
        LiveRedirectRefusingDelegate().urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: target)
        ) { request in decision.withLock { $0 = .some(request) } }
        let recorded = try #require(decision.current)
        #expect(recorded == nil)
    }

    @Test func redirectResponseMapsToRedirectRefused() throws {
        let url = try #require(URL(string: "https://api.anthropic.com/x"))
        let redirect = try #require(HTTPURLResponse(
            url: url, statusCode: 301, httpVersion: nil, headerFields: ["Location": "https://elsewhere.invalid/"]))
        #expect(throws: HTTPClientError.redirectRefused) {
            _ = try LiveHTTPClient.makeResponse(data: Data(), response: redirect)
        }
        let ok = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Retry-After": "5"]))
        let mapped = try LiveHTTPClient.makeResponse(data: Data("{}".utf8), response: ok)
        #expect(mapped.status == 200)
        #expect(mapped.headers["retry-after"] == "5")
    }

    // MARK: Process inspector

    @Test func currentProcessIsAliveWithARecentStartTime() throws {
        let inspector = LiveProcessInspector()
        let pid = getpid()
        #expect(inspector.isAlive(pid: pid))
        let start = try #require(inspector.startTime(pid: pid))
        let now = Date()
        #expect(start <= now.addingTimeInterval(1))
        // The test process started at most the system uptime ago, and certainly within the last day.
        #expect(start >= now.addingTimeInterval(-min(ProcessInfo.processInfo.systemUptime, 86_400) - 1))
    }

    @Test func unusedPidIsNotAlive() {
        let inspector = LiveProcessInspector()
        #expect(!inspector.isAlive(pid: 999_999))
        #expect(inspector.startTime(pid: 999_999) == nil)
        #expect(!inspector.isAlive(pid: 0))
        #expect(!inspector.isAlive(pid: -1))
    }

    // MARK: System proxy

    @Test func proxyParsingBuildsURLsAndExceptions() {
        let parsed = LiveSystemProxy.parse([
            "HTTPSEnable": NSNumber(value: 1), "HTTPSProxy": "proxy.example", "HTTPSPort": NSNumber(value: 8443),
            "HTTPEnable": NSNumber(value: 1), "HTTPProxy": "plain.example", "HTTPPort": NSNumber(value: 8080),
            "ExceptionsList": ["*.local", "169.254/16", " "],
        ])
        #expect(parsed == ProxySettings(
            httpsProxy: "http://proxy.example:8443",
            httpProxy: "http://plain.example:8080",
            noProxy: "*.local,169.254/16"))
    }

    @Test func proxyParsingIgnoresDisabledEntries() {
        #expect(LiveSystemProxy.parse([:]) == nil)
        #expect(LiveSystemProxy.parse([
            "HTTPSEnable": NSNumber(value: 0), "HTTPSProxy": "proxy.example", "HTTPSPort": NSNumber(value: 8443),
        ]) == nil)
        #expect(LiveSystemProxy.parse([
            "HTTPEnable": NSNumber(value: 1), "HTTPProxy": "plain.example",
        ]) == ProxySettings(httpsProxy: nil, httpProxy: "http://plain.example", noProxy: nil))
    }

    // MARK: User name and live()

    @Test func userNameRules() {
        #expect(LiveUserName.resolve(environmentUser: "alice") == "alice")
        #expect(LiveUserName.resolve(environmentUser: "bad name") == ClaudePaths.fallbackKeychainAccount)
        let fallback = LiveUserName.resolve(environmentUser: nil)
        #expect(fallback == ClaudePaths.keychainAccount(userName: LiveUserName.passwdName() ?? ""))
        #expect(LiveUserName.resolve(environmentUser: "") == fallback)
    }

    @Test func liveEnvironmentWiring() {
        let env = CoreEnvironment.live()
        #expect(env.appSupportDirectory.path.hasSuffix("/Library/Application Support/TokenBar"))
        #expect(env.appSupportDirectory.path.hasPrefix(env.homeDirectory.path))
        #expect(env.processRunner is LiveProcessRunner)
        #expect(env.http is LiveHTTPClient)
        #expect(env.signatureVerifier is LiveCodeSignatureVerifier)
        #expect(env.processInspector is LiveProcessInspector)
        #expect(!env.userName.isEmpty)
        #expect(ClaudePaths.keychainAccount(userName: env.userName) == env.userName)
    }
}
