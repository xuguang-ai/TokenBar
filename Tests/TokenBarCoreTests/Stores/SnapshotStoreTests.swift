import Foundation
import Testing
@testable import TokenBarCore

@Suite("StoresSnapshotStore")
struct StoresSnapshotStoreTests {
    private let harness: TestHarness
    private let store: SnapshotStore

    init() throws {
        harness = try TestHarness()
        store = SnapshotStore(env: harness.env)
    }

    private var fileURL: URL { harness.env.appSupportDirectory.appendingPathComponent("snapshots.json") }

    private static let canaryEmail = "canary.person+tokenbar@example.invalid"

    private func sampleStates() -> [UUID: StoredAccountState] {
        let now = harness.clock.now
        let claudeID = UUID()
        let codexID = UUID()
        let claude = UsageSnapshot(
            accountID: claudeID,
            fetchedAt: now,
            dataAsOf: now.addingTimeInterval(-30),
            source: .claudeCache(fetchedAt: now.addingTimeInterval(-30)),
            identity: AccountIdentity(accountUuid: "acct-1", plan: "Max", organization: "Org", email: Self.canaryEmail),
            windows: [
                UsageWindow(kind: .weekly, usedPercent: 41.5, resetsAt: now.addingTimeInterval(86_400)),
                UsageWindow(kind: .fiveHour, usedPercent: 12, resetsAt: nil, isStarted: false),
                UsageWindow(kind: .model(name: "Fable"), usedPercent: 3, resetsAt: now),
            ],
            limitReached: false)
        let codex = UsageSnapshot(
            accountID: codexID,
            fetchedAt: now,
            dataAsOf: now,
            source: .codexAppServer,
            identity: nil,
            windows: [UsageWindow(kind: .other(minutes: 90), usedPercent: 100, resetsAt: now)],
            limitReached: true)
        return [
            claudeID: StoredAccountState(lastSnapshot: claude, lastError: .waitingForClaudeCode, lastAttemptAt: now),
            codexID: StoredAccountState(lastSnapshot: codex, lastError: nil, lastAttemptAt: now.addingTimeInterval(-5)),
            UUID(): StoredAccountState(lastSnapshot: nil, lastError: .network(urlErrorCode: -1009), lastAttemptAt: nil),
        ]
    }

    @Test func missingFileLoadsEmptyWithoutCreatingAnything() {
        #expect(store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.env.appSupportDirectory.path))
    }

    @Test func roundTrip() throws {
        var states = sampleStates()
        try store.save(states)
        let loaded = store.load()
        // Email is not persisted, so compare against the same states with the email removed.
        for id in states.keys { states[id]?.lastSnapshot?.identity?.email = nil }
        #expect(loaded == states)
        #expect(loaded.values.compactMap(\.lastSnapshot?.identity?.plan) == ["Max"])
    }

    @Test func emailIsNeverWritten() throws {
        try store.save(sampleStates())
        let bytes = try Data(contentsOf: fileURL)
        #expect(!bytes.isEmpty)
        #expect(bytes.range(of: Data(Self.canaryEmail.utf8)) == nil)
        #expect(bytes.range(of: Data("email".utf8)) == nil)
    }

    @Test func permissions() throws {
        try store.save(sampleStates())
        let fs = LocalFileSystem()
        #expect(fs.stat(fileURL)?.permissions == 0o600)
        #expect(fs.stat(harness.env.appSupportDirectory)?.permissions == 0o700)
    }

    @Test func saveReplacesPreviousContents() throws {
        try store.save(sampleStates())
        let only = UUID()
        try store.save([only: StoredAccountState(lastError: .tokenLacksProfileScope)])
        #expect(Array(store.load().keys) == [only])
    }

    @Test(arguments: ["", "garbage", "[]", #"{"version": 1, "accounts": {"not-a-uuid": {}}}"#, #"{"accounts": 3}"#])
    func corruptFileLoadsEmpty(_ text: String) throws {
        try LocalFileSystem().createDirectory(harness.env.appSupportDirectory, permissions: 0o700)
        try Data(text.utf8).write(to: fileURL)
        #expect(store.load().isEmpty)
    }
}
