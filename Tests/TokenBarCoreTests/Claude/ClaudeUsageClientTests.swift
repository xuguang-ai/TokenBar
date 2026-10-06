import Foundation
import Testing
@testable import TokenBarCore

@Suite("ClaudeUsageClient")
struct ClaudeUsageClientTests {
    private static let token = "CANARY-accessToken-synthetic-a11c"

    private func fetch(_ h: TestHarness) async -> Result<ClaudeMappedUsage, ClaudeUsageClientError> {
        do {
            return .success(try await ClaudeUsageClient(env: h.env).fetchUsage(accessToken: Self.token))
        } catch {
            return .failure(error)
        }
    }

    private func harness(status: Int, headers: [String: String] = [:], body: String = "") throws -> TestHarness {
        let h = try TestHarness()
        h.http.handler = { _ in HTTPResponse(status: status, headers: headers, body: Data(body.utf8)) }
        return h
    }

    @Test func sendsTheExactRequest() async throws {
        let h = try TestHarness()
        let body = try Fixtures.data("claude/usage-response.json")
        h.http.handler = { _ in HTTPResponse(status: 200, body: body) }
        let result = await fetch(h)
        #expect(try result.get().windows.count == 4)
        let request = try #require(h.http.requests.first)
        #expect(request.url.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.method == "GET")
        #expect(request.timeout == .seconds(10))
        #expect(request.headers == [
            "Authorization": "Bearer " + Self.token,
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
            "User-Agent": "TokenBar/0.1.0",
        ])
    }

    @Test func status401() async throws {
        let result = await fetch(try harness(status: 401, body: #"{"error": {"message": "CANARY-body"}}"#))
        #expect(result == .failure(.unauthorized))
    }

    @Test func status403WithAPIErrorBody() async throws {
        let result = await fetch(try harness(status: 403, body: #"{"type": "error", "error": {"type": "permission_error"}}"#))
        #expect(result == .failure(.forbidden))
    }

    @Test func bare403IsRateLimited() async throws {
        #expect(await fetch(try harness(status: 403)) == .failure(.rateLimited(retryAfter: nil)))
        #expect(await fetch(try harness(status: 403, body: "<html>")) == .failure(.rateLimited(retryAfter: nil)))
    }

    @Test func status429WithRetryAfter() async throws {
        #expect(await fetch(try harness(status: 429, headers: ["retry-after": "120"])) == .failure(.rateLimited(retryAfter: 120)))
        #expect(await fetch(try harness(status: 429)) == .failure(.rateLimited(retryAfter: nil)))
    }

    @Test func retryAfterHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_791_300_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let value = formatter.string(from: now.addingTimeInterval(600))
        #expect(ClaudeUsageClient.retryAfter(value, now: now) == 600)
        #expect(ClaudeUsageClient.retryAfter("soon", now: now) == nil)
    }

    @Test func otherStatus() async throws {
        #expect(await fetch(try harness(status: 503, body: "CANARY")) == .failure(.httpStatus(503)))
    }

    @Test func malformed200() async throws {
        #expect(await fetch(try harness(status: 200, body: "nope")) == .failure(.decoding))
    }

    @Test func transportErrors() async throws {
        let h = try TestHarness()
        h.http.handler = { _ in throw HTTPClientError.transport(urlErrorCode: -1009) }
        #expect(await fetch(h) == .failure(.network(urlErrorCode: -1009)))
        h.http.handler = { _ in throw HTTPClientError.timeout }
        #expect(await fetch(h) == .failure(.network(urlErrorCode: URLError.Code.timedOut.rawValue)))
        h.http.handler = { _ in throw HTTPClientError.redirectRefused }
        #expect(await fetch(h) == .failure(.network(urlErrorCode: URLError.Code.httpTooManyRedirects.rawValue)))
    }

    @Test func errorsNeverCarryTheTokenOrBody() async throws {
        for status in [401, 403, 429, 500] {
            let result = await fetch(try harness(status: status, body: #"{"error": "CANARY-body-value"}"#))
            for text in [String(describing: result), String(reflecting: result)] {
                #expect(!text.contains(Self.token))
                #expect(!text.contains("CANARY"))
            }
        }
    }
}
