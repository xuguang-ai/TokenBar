import CFNetwork
import Darwin
import Foundation

// The only place that wires the real clock, home directory, user name, network and process APIs (spec §4.2).

extension CoreEnvironment {
    public static func live() -> CoreEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CoreEnvironment(
            now: { Date() },
            sleep: { try await Task.sleep(for: $0) },
            homeDirectory: home,
            appSupportDirectory: home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("TokenBar", isDirectory: true),
            temporaryDirectory: FileManager.default.temporaryDirectory,
            userName: LiveUserName.resolve(environmentUser: ProcessInfo.processInfo.environment["USER"]),
            processRunner: LiveProcessRunner(),
            fileSystem: LocalFileSystem(),
            http: LiveHTTPClient(),
            signatureVerifier: LiveCodeSignatureVerifier(),
            processInspector: LiveProcessInspector(),
            systemProxy: { LiveSystemProxy.current() })
    }
}

// MARK: - User name

/// Spec §2.1: `$USER`, else the `getpwuid` name; anything outside `^[a-zA-Z0-9._-]+$` becomes `claude-code-user`.
public enum LiveUserName {
    public static func resolve(environmentUser: String?) -> String {
        if let user = environmentUser, !user.isEmpty {
            return ClaudePaths.keychainAccount(userName: user)
        }
        return ClaudePaths.keychainAccount(userName: passwdName() ?? "")
    }

    static func passwdName() -> String? {
        guard let entry = getpwuid(getuid()), let name = entry.pointee.pw_name else { return nil }
        return String(cString: name)
    }
}

// MARK: - HTTP

/// Ephemeral, cacheless, cookieless, and refuses every redirect (spec §9.1). Never `URLSession.shared`.
public final class LiveHTTPClient: HTTPClient, @unchecked Sendable {
    let session: URLSession

    public init() {
        session = URLSession(
            configuration: Self.makeConfiguration(),
            delegate: LiveRedirectRefusingDelegate(),
            delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return configuration
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: max(request.timeout.timeInterval, 0.001))
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let session = self.session
        let prepared = urlRequest
        let timeout = request.timeout
        do {
            // URLRequest.timeoutInterval is an idle timeout; the race below bounds the whole request.
            let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse)?.self) { group in
                group.addTask { try await session.data(for: prepared) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let value = first else { throw HTTPClientError.timeout }
                return value
            }
            return try Self.makeResponse(data: data, response: response)
        } catch let error as HTTPClientError {
            throw error
        } catch let error as URLError {
            if Task.isCancelled { throw CancellationError() }
            throw error.code == .timedOut
                ? HTTPClientError.timeout
                : HTTPClientError.transport(urlErrorCode: error.code.rawValue)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HTTPClientError.transport(urlErrorCode: URLError.Code.unknown.rawValue)
        }
    }

    static func makeResponse(data: Data, response: URLResponse) throws -> HTTPResponse {
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.transport(urlErrorCode: URLError.Code.badServerResponse.rawValue)
        }
        // The delegate refused to follow; URLSession hands back the 3xx itself.
        if (300..<400).contains(http.statusCode), http.value(forHTTPHeaderField: "Location") != nil {
            throw HTTPClientError.redirectRefused
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String else { continue }
            headers[name.lowercased()] = value as? String ?? String(describing: value)
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

/// Refuses every redirect, so credentials are never forwarded to another origin.
final class LiveRedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Process inspection

public struct LiveProcessInspector: ProcessInspecting {
    public init() {}

    public func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }  // kill(0, …) and kill(-1, …) address groups
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public func startTime(pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard read >= size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }
}

// MARK: - System proxy

/// HTTP(S) proxy from System Settings via `CFNetworkCopySystemProxySettings` (spec §5.7).
public enum LiveSystemProxy {
    public static func current() -> ProxySettings? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return parse(settings)
    }

    /// Pure mapping of the CFNetwork dictionary (keys `HTTPSEnable`, `HTTPSProxy`, `HTTPSPort`, the HTTP
    /// equivalents and `ExceptionsList`). nil when no HTTP(S) proxy is enabled.
    public static func parse(_ settings: [String: Any]) -> ProxySettings? {
        func proxy(_ prefix: String) -> String? {
            guard (settings["\(prefix)Enable"] as? NSNumber)?.boolValue == true,
                  let host = settings["\(prefix)Proxy"] as? String,
                  !host.trimmingCharacters(in: .whitespaces).isEmpty
            else { return nil }
            let trimmed = host.trimmingCharacters(in: .whitespaces)
            if let port = (settings["\(prefix)Port"] as? NSNumber)?.intValue, port > 0 {
                return "http://\(trimmed):\(port)"
            }
            return "http://\(trimmed)"
        }
        let https = proxy("HTTPS")
        let http = proxy("HTTP")
        guard https != nil || http != nil else { return nil }
        let exceptions = (settings["ExceptionsList"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ProxySettings(
            httpsProxy: https,
            httpProxy: http,
            noProxy: exceptions.isEmpty ? nil : exceptions.joined(separator: ","))
    }
}
