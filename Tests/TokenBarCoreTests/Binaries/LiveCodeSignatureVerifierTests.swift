import Foundation
import Testing
@testable import TokenBarCore

/// Static checks only: nothing here is executed.
@Suite("LiveCodeSignatureVerifier")
struct LiveCodeSignatureVerifierTests {
    private let verifier = LiveCodeSignatureVerifier()

    /// A real OpenAI-signed codex from the VS Code extension, if this machine has one (never executed).
    private static func installedCodex() -> URL? {
        let extensions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vscode/extensions", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: extensions.path)) ?? []
        return names
            .filter { $0.hasPrefix("openai.chatgpt-") }
            .sorted(by: >)
            .map { extensions.appendingPathComponent("\($0)/bin/macos-aarch64/codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @Test func appleBinaryFailsAThirdPartyTeamRequirement() async {
        #expect(await verifier.verify(URL(fileURLWithPath: "/bin/ls"), teamID: BinaryKind.codex.teamID) == false)
        #expect(await verifier.verify(URL(fileURLWithPath: "/bin/ls"), teamID: BinaryKind.claude.teamID) == false)
    }

    @Test func nonMachOFileFails() async throws {
        let temp = try TempDir()
        let script = try temp.write("codex", "#!/bin/sh\nexit 0\n", permissions: 0o755)
        #expect(await verifier.verify(script, teamID: BinaryKind.codex.teamID) == false)
    }

    @Test func missingFileFails() async {
        #expect(await verifier.verify(URL(fileURLWithPath: "/nonexistent/codex"), teamID: "2DC432GLL2") == false)
    }

    @Test func malformedTeamIDIsRejected() async {
        #expect(LiveCodeSignatureVerifier.requirementText(teamID: "X\" or anchor apple") == nil)
        #expect(LiveCodeSignatureVerifier.requirementText(teamID: "") == nil)
        #expect(LiveCodeSignatureVerifier.requirementText(teamID: "2DC432GLL2")
            == "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\"")
        #expect(await verifier.verify(URL(fileURLWithPath: "/bin/ls"), teamID: "\"") == false)
    }

    @Test func runningProcessChecks() async {
        #expect(await verifier.verifyRunningProcess(pid: getpid(), teamID: BinaryKind.codex.teamID) == false)
        #expect(await verifier.verifyRunningProcess(pid: 0, teamID: BinaryKind.codex.teamID) == false)
        #expect(await verifier.verifyRunningProcess(pid: 999_999, teamID: BinaryKind.codex.teamID) == false)
    }

    @Test(.enabled(if: installedCodex() != nil, "no VS Code codex on this machine"))
    func installedCodexPassesForOpenAITeam() async throws {
        let codex = try #require(Self.installedCodex())
        #expect(await verifier.verify(codex, teamID: BinaryKind.codex.teamID))
        #expect(await verifier.verify(codex, teamID: BinaryKind.claude.teamID) == false)
    }
}
