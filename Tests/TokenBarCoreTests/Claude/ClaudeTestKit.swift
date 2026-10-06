import Foundation
@testable import TokenBarCore

/// Helpers shared by the Claude test suites. Nested so no top-level test name can collide with other tasks.
enum ClaudeTestKit {
    struct StubBinaryLocator: BinaryLocating {
        var binary: LocatedBinary?

        init(_ path: String? = "/opt/claude/versions/2.1.289") {
            binary = path.map { LocatedBinary(url: URL(fileURLWithPath: $0), version: SemVer("2.1.289"), kind: .claude) }
        }

        func locate(_ kind: BinaryKind, settings: AppSettings) async -> LocatedBinary? { kind == .claude ? binary : nil }
        func candidates(_ kind: BinaryKind, settings: AppSettings) async -> [BinaryCandidate] { [] }
    }

    static let accountUuid = "00000000-0000-4000-8000-00000000c1a0"
    static let accessToken = "CANARY-accessToken-synthetic-a11c"
    /// Every secret in the fixtures; none may surface anywhere.
    static let canaries = [
        "CANARY-accessToken-synthetic-a11c", "CANARY-refreshToken-synthetic-5e5e", "CANARY-mcpOAuth-synthetic-3c3c",
        "CANARY-pluginSecrets-synthetic-d00d", "CANARY-trustedDeviceToken-synthetic-beef",
        "CANARY-mcpServersEnv-synthetic-4f9c", "CANARY-primaryApiKey-synthetic-77e2", "CANARY-userID-synthetic-0b1d",
        "CANARY-displayName-synthetic-91aa", "someone@example.invalid",
    ]
}
