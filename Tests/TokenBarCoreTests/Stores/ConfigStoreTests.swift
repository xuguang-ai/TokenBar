import Foundation
import Testing
@testable import TokenBarCore

@Suite("StoresConfigStore")
struct StoresConfigStoreTests {
    private let harness: TestHarness
    private let store: ConfigStore

    init() throws {
        harness = try TestHarness()
        store = ConfigStore(env: harness.env)
    }

    private var dir: URL { harness.env.appSupportDirectory }
    private var configURL: URL { dir.appendingPathComponent("config.json") }

    private func writeConfig(_ text: String) throws {
        try LocalFileSystem().createDirectory(dir, permissions: 0o700)
        try Data(text.utf8).write(to: configURL)
    }

    private func directoryNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private static let validJSON = """
        {
          "schemaVersion": 1,
          "accounts": [
            {"id": "11111111-1111-4111-8111-111111111111", "provider": "claude", "displayName": "Work",
             "claudeConfigDir": "~/.claude-work", "isDedicatedLogin": true, "isEnabled": false},
            {"id": "22222222-2222-4222-8222-222222222222", "provider": "codex"}
          ],
          "refreshIntervalMinutes": 10,
          "displayMode": "used",
          "allowClaudeCodeRefresh": false,
          "subprocessProxy": "http://proxy.example:8080",
          "someFutureKey": {"nested": [1, 2, 3]}
        }
        """

    // MARK: load()

    @Test func loadMissingThrowsMissing() {
        #expect(throws: ConfigLoadError.missing) { try store.load() }
    }

    @Test func loadDecodesAndIgnoresUnknownKeys() throws {
        try writeConfig(Self.validJSON)
        let settings = try store.load()
        #expect(settings.schemaVersion == 1)
        #expect(settings.refreshIntervalMinutes == 10)
        #expect(settings.displayMode == .used)
        #expect(settings.allowClaudeCodeRefresh == false)
        #expect(settings.subprocessProxy == "http://proxy.example:8080")
        #expect(settings.accounts.count == 2)
        #expect(settings.accounts[0].displayName == "Work")
        #expect(settings.accounts[0].claudeConfigDir == "~/.claude-work")
        #expect(settings.accounts[0].isDedicatedLogin)
        #expect(!settings.accounts[0].isEnabled)
        // Missing account fields fall back to defaults.
        #expect(settings.accounts[1].displayName == "Codex")
        #expect(settings.accounts[1].isEnabled)
        #expect(settings.accounts[1].codexHome == nil)
    }

    @Test func loadDefaultsMissingFields() throws {
        try writeConfig(#"{"accounts": []}"#)
        let settings = try store.load()
        #expect(settings.schemaVersion == AppSettings.currentSchemaVersion)
        #expect(settings.refreshIntervalMinutes == AppSettings.defaultRefreshIntervalMinutes)
        #expect(settings.displayMode == .used)
        #expect(settings.allowClaudeCodeRefresh)
        #expect(settings.accounts.isEmpty)
    }

    @Test(arguments: [
        "", "not json", "[]", "{", #"{"schemaVersion": 1}"#, #"{"accounts": "nope"}"#,
        #"{"schemaVersion": "one", "accounts": []}"#, #"{"schemaVersion": 0, "accounts": []}"#,
        #"{"accounts": [{"provider": "claude"}]}"#,
    ])
    func loadCorruptThrowsCorrupt(_ text: String) throws {
        try writeConfig(text)
        #expect(throws: ConfigLoadError.corrupt) { try store.load() }
    }

    @Test func loadTooNewThrowsTooNew() throws {
        try writeConfig(#"{"schemaVersion": 7, "accounts": "a shape we don't know"}"#)
        #expect(throws: ConfigLoadError.tooNew(7)) { try store.load() }
    }

    @Test func migrateV1IsIdentity() throws {
        let object: [String: Any] = ["schemaVersion": 1, "accounts": [], "x": "y"]
        let migrated = try ConfigStore.migrate(object, fromVersion: 1)
        #expect(NSDictionary(dictionary: migrated).isEqual(to: object))
        #expect(throws: ConfigLoadError.corrupt) { try ConfigStore.migrate(object, fromVersion: 0) }
        #expect(throws: ConfigLoadError.tooNew(2)) { try ConfigStore.migrate(object, fromVersion: 2) }
    }

    // MARK: save()

    @Test func saveRoundTripsWithPermissions() throws {
        var settings = ConfigStore.defaultSettings()
        settings.refreshIntervalMinutes = 15
        settings.codexBinaryOverride = "/opt/codex"
        try store.save(settings)
        #expect(try store.load() == settings)
        let fs = LocalFileSystem()
        #expect(fs.stat(configURL)?.permissions == 0o600)
        #expect(fs.stat(dir)?.permissions == 0o700)
        #expect(directoryNames() == ["config.json"])
    }

    @Test func saveTightensExistingPermissions() throws {
        let fs = LocalFileSystem()
        try fs.createDirectory(dir, permissions: 0o755)
        try Data("{}".utf8).write(to: configURL)
        try fs.setPermissions(configURL, 0o644)
        try store.save(ConfigStore.defaultSettings())
        #expect(fs.stat(configURL)?.permissions == 0o600)
        #expect(fs.stat(dir)?.permissions == 0o700)
    }

    @Test func modificationDateTracksTheFile() throws {
        #expect(store.modificationDate() == nil)
        try store.save(ConfigStore.defaultSettings())
        let first = try #require(store.modificationDate())
        let earlier = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: configURL.path)
        #expect(store.modificationDate() == earlier)
        #expect(first != earlier)
    }

    // MARK: loadOrDefault(forApp: true)

    @Test func appMissingSavesDefaults() throws {
        let outcome = try store.loadOrDefault(forApp: true)
        #expect(outcome.warning == nil)
        #expect(outcome.settings == ConfigStore.defaultSettings())
        #expect(try store.load() == outcome.settings)
        #expect(LocalFileSystem().stat(configURL)?.permissions == 0o600)
    }

    @Test func appCorruptRenamesAndStartsWithDefaults() throws {
        try writeConfig("{ broken")
        let epoch = Int(harness.clock.now.timeIntervalSince1970)
        let outcome = try store.loadOrDefault(forApp: true)
        let backup = "config.json.corrupt-\(epoch)"
        #expect(outcome.warning == .corruptFileRenamed(backupFileName: backup))
        #expect(outcome.settings == ConfigStore.defaultSettings())
        #expect(directoryNames() == ["config.json", backup])
        #expect(try String(contentsOf: dir.appendingPathComponent(backup), encoding: .utf8) == "{ broken")
        #expect(try store.load() == outcome.settings)
    }

    @Test func appCorruptTwiceInOneSecondKeepsBothBackups() throws {
        try writeConfig("{ broken 1")
        _ = try store.loadOrDefault(forApp: true)
        try writeConfig("{ broken 2")
        let outcome = try store.loadOrDefault(forApp: true)
        let epoch = Int(harness.clock.now.timeIntervalSince1970)
        #expect(outcome.warning == .corruptFileRenamed(backupFileName: "config.json.corrupt-\(epoch)-1"))
        #expect(directoryNames().count == 3)
    }

    @Test func appTooNewThrowsAndWritesNothing() throws {
        try writeConfig(#"{"schemaVersion": 99, "accounts": []}"#)
        #expect(throws: ConfigLoadError.tooNew(99)) { try store.loadOrDefault(forApp: true) }
        #expect(directoryNames() == ["config.json"])
        #expect(try String(contentsOf: configURL, encoding: .utf8) == #"{"schemaVersion": 99, "accounts": []}"#)
    }

    @Test func appValidFileLoadsUnchanged() throws {
        try writeConfig(Self.validJSON)
        let outcome = try store.loadOrDefault(forApp: true)
        #expect(outcome.warning == nil)
        #expect(outcome.settings.refreshIntervalMinutes == 10)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == Self.validJSON)
    }

    // MARK: loadOrDefault(forApp: false) — the CLI never writes

    @Test func cliMissingUsesInMemoryDefaultsWithoutWriting() throws {
        let outcome = try store.loadOrDefault(forApp: false)
        #expect(outcome.warning == nil)
        #expect(outcome.settings == ConfigStore.defaultSettings())
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func cliCorruptThrowsAndLeavesFile() throws {
        try writeConfig("{ broken")
        #expect(throws: ConfigLoadError.corrupt) { try store.loadOrDefault(forApp: false) }
        #expect(directoryNames() == ["config.json"])
        #expect(try String(contentsOf: configURL, encoding: .utf8) == "{ broken")
    }

    @Test func cliTooNewThrows() throws {
        try writeConfig(#"{"schemaVersion": 2, "accounts": []}"#)
        #expect(throws: ConfigLoadError.tooNew(2)) { try store.loadOrDefault(forApp: false) }
        #expect(directoryNames() == ["config.json"])
    }

    @Test func cliValidFileLoads() throws {
        try writeConfig(Self.validJSON)
        let outcome = try store.loadOrDefault(forApp: false)
        #expect(outcome.settings.displayMode == .used)
    }

    // MARK: defaults

    @Test func defaultSettingsHaveStableAccountIDs() {
        let a = ConfigStore.defaultSettings()
        let b = ConfigStore.defaultSettings()
        #expect(a == b)
        #expect(a.accounts.map(\.provider) == [.claude, .codex])
        #expect(Set(a.accounts.map(\.id)).count == 2)
    }
}
