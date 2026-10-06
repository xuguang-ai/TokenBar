import Foundation
import Testing
@testable import TokenBarCore

/// Fake binary trees under a temp HOME and a temp system root; signatures come from FakeSignatureVerifier.
@Suite("BinaryLocator")
struct BinaryLocatorTests {
    private struct LocatorFixture {
        let harness: TestHarness
        let root: URL
        let locator: BinaryLocator

        init() throws {
            harness = try TestHarness()
            root = try harness.temp.makeDirectory("root")
            locator = BinaryLocator(env: harness.env, systemRoot: root)
        }

        static let machO = Data([0xCF, 0xFA, 0xED, 0xFE]) + Data(repeating: 0, count: 60)

        /// A fake Mach-O under the temp HOME, optionally trusted for `team`.
        @discardableResult
        func binary(_ relativePath: String, team: String?, permissions: UInt16 = 0o755) throws -> URL {
            let url = try harness.temp.write("home/" + relativePath, Self.machO, permissions: permissions)
            if let team { harness.verifier.trust(url, teamID: team) }
            return url
        }

        @discardableResult
        func systemBinary(_ relativePath: String, team: String?) throws -> URL {
            let url = try harness.temp.write("root/" + relativePath, Self.machO, permissions: 0o755)
            if let team { harness.verifier.trust(url, teamID: team) }
            return url
        }

        func symlink(_ relativePath: String, to destination: URL) throws -> URL {
            let link = harness.home.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            return link
        }

        func real(_ url: URL) -> URL { LocalFileSystem().realpath(url) ?? url }
    }

    private static let claudeTeam = BinaryKind.claude.teamID
    private static let codexTeam = BinaryKind.codex.teamID
    private static let claudeExt = "anthropic.claude-code-%@-darwin-arm64/resources/native-binary/claude"
    private static let codexExt = "openai.chatgpt-%@-darwin-arm64/bin/macos-aarch64/codex"
    private static let npmVendor =
        "lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"

    private static func v(_ text: String) -> SemVer? { SemVer(text) }

    // MARK: Claude

    @Test func claudeSkipsObsoleteExtensionFolders() async throws {
        let f = try LocatorFixture()
        try f.binary(".vscode/extensions/" + String(format: Self.claudeExt, "2.1.300"), team: Self.claudeTeam)
        try f.binary(".vscode/extensions/" + String(format: Self.claudeExt, "2.1.400"), team: Self.claudeTeam)
        try f.harness.writeHome(".vscode/extensions/.obsolete", #"{"anthropic.claude-code-2.1.400-darwin-arm64": true}"#)

        let located = try #require(await f.locator.locate(.claude, settings: AppSettings(accounts: [])))
        #expect(located.version == Self.v("2.1.300"))
        #expect(located.kind == .claude)
        let listed = await f.locator.candidates(.claude, settings: AppSettings(accounts: []))
        #expect(listed.count == 1)
        #expect(listed.first?.status == .usable)
        #expect(f.harness.processes.calls.isEmpty)
    }

    @Test func claudePicksHighestVersionAcrossSources() async throws {
        let f = try LocatorFixture()
        try f.binary(".local/share/claude/versions/2.1.290", team: Self.claudeTeam)
        try f.binary(".local/share/claude/versions/2.1.310", team: Self.claudeTeam)
        try f.binary(".cursor/extensions/" + String(format: Self.claudeExt, "2.1.305"), team: Self.claudeTeam)
        try f.binary(".local/share/claude/versions/2.1.200", team: Self.claudeTeam)

        let located = try #require(await f.locator.locate(.claude, settings: AppSettings(accounts: [])))
        #expect(located.version == Self.v("2.1.310"))
        let statuses = await f.locator.candidates(.claude, settings: AppSettings(accounts: []))
            .reduce(into: [String: BinaryCandidate.Status]()) { $0[$1.version?.description ?? "?"] = $1.status }
        #expect(statuses["2.1.200"] == .versionTooOld)
        #expect(statuses["2.1.305"] == .usable)
        #expect(f.harness.processes.calls.isEmpty)  // claude is never executed
    }

    @Test func claudeOverrideWithUnknownVersionIsUsed() async throws {
        let f = try LocatorFixture()
        try f.binary(".local/share/claude/versions/2.1.300", team: Self.claudeTeam)
        let custom = try f.binary("custom/claude", team: Self.claudeTeam)
        let settings = AppSettings(accounts: [], claudeBinaryOverride: "~/custom/claude")

        let located = try #require(await f.locator.locate(.claude, settings: settings))
        #expect(located.url == f.real(custom))
        #expect(located.version == nil)
        let first = try #require(await f.locator.candidates(.claude, settings: settings).first)
        #expect(first.isOverride)
        #expect(first.status == .versionUnknown)
        #expect(f.harness.processes.calls.isEmpty)
    }

    @Test func claudeOverrideBelowMinimumIsRejected() async throws {
        let f = try LocatorFixture()
        let old = try f.binary(".local/share/claude/versions/2.1.200", team: Self.claudeTeam)
        try f.binary(".local/share/claude/versions/2.1.300", team: Self.claudeTeam)
        let settings = AppSettings(accounts: [], claudeBinaryOverride: old.path)

        #expect(await f.locator.locate(.claude, settings: settings) == nil)
        let first = try #require(await f.locator.candidates(.claude, settings: settings).first)
        #expect(first.isOverride)
        #expect(first.status == .versionTooOld)
    }

    @Test func missingOverrideIsListedAsMissing() async throws {
        let f = try LocatorFixture()
        let settings = AppSettings(accounts: [], claudeBinaryOverride: "/nonexistent/claude")
        #expect(await f.locator.locate(.claude, settings: settings) == nil)
        #expect(await f.locator.candidates(.claude, settings: settings).first?.status == .missing)
    }

    @Test func verifierRejectionExcludesTheBinary() async throws {
        let f = try LocatorFixture()
        try f.binary(".local/share/claude/versions/2.1.300", team: nil)
        try f.binary(".local/share/claude/versions/2.1.301", team: Self.codexTeam)  // wrong team

        #expect(await f.locator.locate(.claude, settings: AppSettings(accounts: [])) == nil)
        let statuses = await f.locator.candidates(.claude, settings: AppSettings(accounts: [])).map(\.status)
        #expect(statuses == [.signatureInvalid, .signatureInvalid])
    }

    @Test func nonExecutableIsExcluded() async throws {
        let f = try LocatorFixture()
        try f.binary(".local/share/claude/versions/2.1.300", team: Self.claudeTeam, permissions: 0o644)
        #expect(await f.locator.locate(.claude, settings: AppSettings(accounts: [])) == nil)
        #expect(await f.locator.candidates(.claude, settings: AppSettings(accounts: [])).first?.status == .notExecutable)
    }

    @Test func systemLocationsAreSearched() async throws {
        let f = try LocatorFixture()
        let brew = try f.harness.temp.write(
            "root/opt/homebrew/Caskroom/claude-code/versions/2.1.320/claude", LocatorFixture.machO, permissions: 0o755)
        f.harness.verifier.trust(brew, teamID: Self.claudeTeam)
        let bin = f.root.appendingPathComponent("opt/homebrew/bin/claude")
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: brew)

        let located = try #require(await f.locator.locate(.claude, settings: AppSettings(accounts: [])))
        #expect(located.url == f.real(brew))
        #expect(located.version == Self.v("2.1.320"))
    }

    // MARK: Codex

    @Test func codexShebangScriptIsExcluded() async throws {
        let f = try LocatorFixture()
        let script = try f.harness.writeHome(".local/bin/codex", "#!/bin/sh\nexit 0\n", permissions: 0o755)
        f.harness.verifier.trust(script, teamID: Self.codexTeam)

        #expect(await f.locator.locate(.codex, settings: AppSettings(accounts: [])) == nil)
        #expect(await f.locator.candidates(.codex, settings: AppSettings(accounts: [])).first?.status == .notMachO)
        #expect(f.harness.processes.calls.isEmpty)
    }

    @Test func npmShimWithoutVendorBinaryIsExcluded() async throws {
        let f = try LocatorFixture()
        let shim = try f.harness.writeHome(
            ".npm-global/lib/node_modules/@openai/codex/bin/codex.js", "#!/usr/bin/env node\n", permissions: 0o755)
        _ = try f.symlink(".npm-global/bin/codex", to: shim)

        #expect(await f.locator.locate(.codex, settings: AppSettings(accounts: [])) == nil)
        let listed = await f.locator.candidates(.codex, settings: AppSettings(accounts: []))
        #expect(listed.map(\.status) == [.notMachO])
        #expect(f.harness.processes.calls.isEmpty)
    }

    @Test func npmShimResolvesToTheVendorBinary() async throws {
        let f = try LocatorFixture()
        let shim = try f.harness.writeHome(
            "miniconda3/lib/node_modules/@openai/codex/bin/codex.js", "#!/usr/bin/env node\n", permissions: 0o755)
        try f.harness.writeHome("miniconda3/lib/node_modules/@openai/codex/package.json", #"{"version": "0.138.0"}"#)
        let vendor = try f.binary("miniconda3/" + Self.npmVendor, team: Self.codexTeam)
        let link = try f.symlink(".local/bin/codex", to: shim)

        let located = try #require(await f.locator.locate(.codex, settings: AppSettings(accounts: [])))
        #expect(located.url == f.real(vendor))
        #expect(located.version == Self.v("0.138.0"))
        let listed = await f.locator.candidates(.codex, settings: AppSettings(accounts: []))
        #expect(listed.count == 1)  // the shim and the direct vendor path share one realpath
        #expect(listed.first?.path == link)
        #expect(listed.first?.realpath == f.real(vendor))
        #expect(f.harness.processes.calls.isEmpty)
    }

    @Test func codexVersionOrderingHandlesPrereleases() async throws {
        let f = try LocatorFixture()
        try f.binary(".vscode/extensions/" + String(format: Self.codexExt, "26.930.1"), team: Self.codexTeam)
        try f.harness.writeHome(
            ".vscode/extensions/openai.chatgpt-26.930.1-darwin-arm64/bin/macos-aarch64/codex-package.json",
            #"{"version": "0.160.0a4"}"#)
        try f.binary(".nvm/versions/node/v22.1.0/" + Self.npmVendor, team: Self.codexTeam)
        try f.harness.writeHome(".nvm/versions/node/v22.1.0/lib/node_modules/@openai/codex/package.json", #"{"version": "0.160.0"}"#)
        try f.binary(".windsurf/extensions/" + String(format: Self.codexExt, "26.900.1"), team: Self.codexTeam)
        try f.harness.writeHome(
            ".windsurf/extensions/openai.chatgpt-26.900.1-darwin-arm64/bin/macos-aarch64/codex-package.json",
            #"{"version": "0.159.9"}"#)

        let located = try #require(await f.locator.locate(.codex, settings: AppSettings(accounts: [])))
        #expect(located.version == Self.v("0.160.0"))
        #expect(located.url.path.contains("/.nvm/"))
        let versions = await f.locator.candidates(.codex, settings: AppSettings(accounts: [])).compactMap(\.version)
        #expect(Set(versions) == Set([Self.v("0.160.0-alpha.4"), Self.v("0.160.0"), Self.v("0.159.9")].compactMap { $0 }))
    }

    @Test func codexSkipsObsoleteExtensionFolders() async throws {
        let f = try LocatorFixture()
        try f.binary(".vscode/extensions/" + String(format: Self.codexExt, "26.930.2"), team: Self.codexTeam)
        try f.binary(".vscode/extensions/" + String(format: Self.codexExt, "26.930.1"), team: Self.codexTeam)
        try f.harness.writeHome(".vscode/extensions/.obsolete", #"{"openai.chatgpt-26.930.2-darwin-arm64": true}"#)

        let located = try #require(await f.locator.locate(.codex, settings: AppSettings(accounts: [])))
        #expect(located.version == Self.v("26.930.1"))  // folder version when codex-package.json is absent
        #expect(await f.locator.candidates(.codex, settings: AppSettings(accounts: [])).count == 1)
    }

    @Test func codexSymlinkResolvesToRealpath() async throws {
        let f = try LocatorFixture()
        let target = try f.binary("opt/codex-0.150.0/codex", team: Self.codexTeam)
        try f.harness.writeHome("opt/codex-0.150.0/codex-package.json", #"{"version": "0.150.0"}"#)
        _ = try f.symlink(".bun/bin/codex", to: target)

        let located = try #require(await f.locator.locate(.codex, settings: AppSettings(accounts: [])))
        #expect(located.url == f.real(target))
        #expect(f.harness.verifier.verifiedPaths.allSatisfy { $0 == f.real(target).path })
    }

    @Test func codexVersionIsProbedOnlyAfterVerification() async throws {
        let f = try LocatorFixture()
        let unsigned = try f.systemBinary("usr/local/bin/codex", team: nil)
        #expect(await f.locator.locate(.codex, settings: AppSettings(accounts: [])) == nil)
        #expect(f.harness.processes.calls.isEmpty)

        let app = try f.systemBinary("Applications/Codex.app/Contents/Resources/codex", team: Self.codexTeam)
        f.harness.processes.runHandler = { _ in ProcessResult(exitCode: 0, stdout: Data("codex-cli 0.150.1\n".utf8)) }
        let located = try #require(await f.locator.locate(.codex, settings: AppSettings(accounts: [])))
        #expect(located.url == f.real(app))
        #expect(located.version == Self.v("0.150.1"))

        let calls = f.harness.processes.calls
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.mode == .run)
        #expect(call.request.executable == f.real(app))
        #expect(call.request.arguments == ["--version"])
        #expect(call.request.environment == f.harness.env.childEnvironment(settings: AppSettings(accounts: [])))
        #expect(call.request.timeout == .seconds(5))
        #expect(f.harness.verifier.verifiedPaths.contains(f.real(app).path))
        #expect(!calls.contains { $0.request.executable == f.real(unsigned) })

        // Cached: neither verified nor probed again while the file is unchanged.
        let verifications = f.harness.verifier.verifiedPaths.count
        _ = await f.locator.locate(.codex, settings: AppSettings(accounts: []))
        #expect(f.harness.processes.calls.count == 1)
        #expect(f.harness.verifier.verifiedPaths.count == verifications)
    }

    @Test func codexWithUnparseableVersionIsNotSelected() async throws {
        let f = try LocatorFixture()
        try f.systemBinary("opt/homebrew/bin/codex", team: Self.codexTeam)
        f.harness.processes.runHandler = { _ in ProcessResult(exitCode: 0, stdout: Data("garbage".utf8)) }
        #expect(await f.locator.locate(.codex, settings: AppSettings(accounts: [])) == nil)
        #expect(await f.locator.candidates(.codex, settings: AppSettings(accounts: [])).first?.status == .versionUnknown)
    }

    @Test func codexOverrideWinsButMustVerify() async throws {
        let f = try LocatorFixture()
        try f.binary(".vscode/extensions/" + String(format: Self.codexExt, "26.930.1"), team: Self.codexTeam)
        let custom = try f.binary("tools/codex", team: nil)
        try f.harness.writeHome("tools/codex-package.json", #"{"version": "0.100.0"}"#)
        let settings = AppSettings(accounts: [], codexBinaryOverride: custom.path)

        #expect(await f.locator.locate(.codex, settings: settings) == nil)
        f.harness.verifier.trust(custom, teamID: Self.codexTeam)
        // A new locator: the old verdict for the unchanged file is cached per instance.
        let fresh = BinaryLocator(env: f.harness.env, systemRoot: f.root)
        let located = try #require(await fresh.locate(.codex, settings: settings))
        #expect(located.url == f.real(custom))
        #expect(located.version == Self.v("0.100.0"))
    }

    @Test func changedFileIsVerifiedAgain() async throws {
        let f = try LocatorFixture()
        let binary = try f.binary(".local/share/claude/versions/2.1.300", team: Self.claudeTeam)
        _ = try #require(await f.locator.locate(.claude, settings: AppSettings(accounts: [])))
        let before = f.harness.verifier.verifiedPaths.count

        try (LocatorFixture.machO + Data([1, 2, 3])).write(to: binary)  // size and mtime change
        _ = try #require(await f.locator.locate(.claude, settings: AppSettings(accounts: [])))
        #expect(f.harness.verifier.verifiedPaths.count == before + 1)
    }

    // MARK: Pure helpers

    @Test func versionParsingHelpers() {
        #expect(BinaryLocator.extensionFolderVersion("openai.chatgpt-26.930.61225-darwin-arm64", prefix: "openai.chatgpt-")
            == Self.v("26.930.61225"))
        #expect(BinaryLocator.extensionFolderVersion("anthropic.claude-code-2.1.289", prefix: "anthropic.claude-code-")
            == Self.v("2.1.289"))
        #expect(BinaryLocator.firstVersion(in: "codex-cli 0.160.1") == Self.v("0.160.1"))
        #expect(BinaryLocator.firstVersion(in: "codex-cli 0.131.0a4") == Self.v("0.131.0-alpha.4"))
        #expect(BinaryLocator.firstVersion(in: "nothing") == nil)
        #expect(BinaryLocator.claudePathVersion(URL(fileURLWithPath: "/h/.local/share/claude/versions/2.1.174"))
            == Self.v("2.1.174"))
    }
}
