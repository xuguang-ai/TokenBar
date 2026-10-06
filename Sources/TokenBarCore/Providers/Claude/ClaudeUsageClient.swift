import Foundation

/// Why a usage request did not produce data (spec §5.3 step ①). Carries no header, token or body.
public enum ClaudeUsageClientError: Error, Sendable, Equatable {
    /// 401.
    case unauthorized
    /// 403 with an API error body: a token-bound 1 h backoff.
    case forbidden
    /// 429 or a bare 403: a per-account backoff of Retry-After seconds (nil when absent or unparseable).
    case rateLimited(retryAfter: TimeInterval?)
    /// Transport failure, timeout (`URLError.timedOut`) or refused redirect (`URLError.httpTooManyRedirects`).
    case network(urlErrorCode: Int)
    /// Any other non-2xx status.
    case httpStatus(Int)
    /// A 2xx body that is not a JSON object.
    case decoding
}

/// `GET https://api.anthropic.com/api/oauth/usage` (spec §2.1, §5.3 step ①). The bearer token only goes
/// into the request header; the response body is parsed in place and dropped.
public struct ClaudeUsageClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let defaultUserAgent = "TokenBar/0.1.0"
    public static let requestTimeout: Duration = .seconds(10)

    private let http: any HTTPClient
    private let userAgent: String
    private let now: @Sendable () -> Date

    public init(http: any HTTPClient, userAgent: String = ClaudeUsageClient.defaultUserAgent, now: @escaping @Sendable () -> Date) {
        self.http = http
        self.userAgent = userAgent
        self.now = now
    }

    public init(env: CoreEnvironment, userAgent: String = ClaudeUsageClient.defaultUserAgent) {
        self.init(http: env.http, userAgent: userAgent, now: env.now)
    }

    public func fetchUsage(accessToken: String, timeout: Duration = ClaudeUsageClient.requestTimeout) async
        throws(ClaudeUsageClientError) -> ClaudeMappedUsage
    {
        let request = HTTPRequest(
            url: Self.endpoint,
            method: "GET",
            headers: [
                "Authorization": "Bearer " + accessToken,
                "anthropic-beta": "oauth-2025-04-20",
                "Content-Type": "application/json",
                "User-Agent": userAgent,
            ],
            timeout: timeout)
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch let error as HTTPClientError {
            switch error {
            case .transport(let code): throw .network(urlErrorCode: code)
            case .timeout: throw .network(urlErrorCode: URLError.Code.timedOut.rawValue)
            case .redirectRefused: throw .network(urlErrorCode: URLError.Code.httpTooManyRedirects.rawValue)
            }
        } catch {
            throw .network(urlErrorCode: URLError.Code.unknown.rawValue)
        }

        switch response.status {
        case 200..<300:
            do {
                return try ClaudeUsageMapper.map(data: response.body)
            } catch {
                throw .decoding
            }
        case 401:
            throw .unauthorized
        case 403 where Self.isAPIErrorBody(response.body):
            throw .forbidden
        case 403, 429:
            throw .rateLimited(retryAfter: Self.retryAfter(response.headers["retry-after"], now: now()))
        default:
            throw .httpStatus(response.status)
        }
    }

    /// An Anthropic API error body: a JSON object with an `error` member, e.g.
    /// `{"type": "error", "error": {...}}`. Only the structure is inspected.
    static func isAPIErrorBody(_ body: Data) -> Bool {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
        return object["error"] != nil
    }

    /// Delay-seconds or an HTTP-date, as seconds from `now`. nil when absent or unparseable.
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
