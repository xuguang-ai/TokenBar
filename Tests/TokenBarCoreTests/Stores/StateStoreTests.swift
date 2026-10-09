import Foundation
import Testing
@testable import TokenBarCore

@Suite("StoresStateStore")
struct StoresStateStoreTests {
    private let harness: TestHarness

    init() throws {
        harness = try TestHarness()
    }

    private var dir: URL { harness.env.appSupportDirectory }
    private var stateURL: URL { dir.appendingPathComponent("state.json") }
    private var lockURL: URL { dir.appendingPathComponent("state.lock") }
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func conformsToStateStoring() {
        let store: any StateStoring = StateStore(env: harness.env)
        #expect(store is StateStore)
    }

    @Test func missingFileReadsEmptyWithoutCreatingAnything() async {
        let store = StateStore(env: harness.env)
        #expect(await store.readAll().isEmpty)
        #expect(await store.read(UUID()) == AccountRuntimeState())
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func updatePersistsAcrossInstances() async {
        let id = UUID()
        let other = UUID()
        let until = harness.clock.now.addingTimeInterval(600)
        let returned = await StateStore(env: harness.env).update(id) {
            $0.backoffUntil = until
            $0.backoffReason = .unauthorized
            $0.backoffTokenExpiresAt = 1_791_300_000_123
            $0.step2InFlight = Step2InFlight(pid: 4242, startedAt: until)
            $0.keychainAccess = .deniedOrPrompting
        }
        await StateStore(env: harness.env).update(other) { $0.lastStep2At = until }
        let fresh = StateStore(env: harness.env)
        #expect(await fresh.read(id) == returned)
        #expect(returned.backoffReason == .unauthorized)
        #expect(await fresh.read(other).lastStep2At == until)
        #expect(await fresh.readAll().count == 2)
    }

    @Test func permissions() async {
        await StateStore(env: harness.env).update(UUID()) { $0.lastHTTPAt = Self.base }
        let fs = LocalFileSystem()
        #expect(fs.stat(stateURL)?.permissions == 0o600)
        #expect(fs.stat(lockURL)?.permissions == 0o600)
        #expect(fs.stat(dir)?.permissions == 0o700)
    }

    @Test(arguments: ["", "{ nope", "[1,2]", #"{"version": 1, "accounts": {"bad-key": {}}}"#])
    func corruptFileReadsEmptyAndUpdateRecovers(_ text: String) async throws {
        try LocalFileSystem().createDirectory(dir, permissions: 0o700)
        try Data(text.utf8).write(to: stateURL)
        let store = StateStore(env: harness.env)
        let id = UUID()
        #expect(await store.readAll().isEmpty)
        #expect(await store.read(id) == AccountRuntimeState())
        await store.update(id) { $0.lastHTTPAt = Self.base }
        #expect(await store.readAll() == [id: AccountRuntimeState(lastHTTPAt: Self.base)])
    }

    @Test func oldFileWithoutRateLimitFieldsStillDecodes() async throws {
        let id = UUID()
        let old = #"{"version": 1, "accounts": {"\#(id.uuidString)": {"backoffReason": "rateLimited", "#
            + #""backoffUntil": 1000, "lastHTTPAt": 900, "keychainAccess": "ok"}}}"#
        try LocalFileSystem().createDirectory(dir, permissions: 0o700)
        try Data(old.utf8).write(to: stateURL)
        let state = await StateStore(env: harness.env).read(id)
        #expect(state.backoffReason == .rateLimited)
        #expect(state.lastHTTPAt == Date(timeIntervalSinceReferenceDate: 900))
        #expect(state.consecutiveRateLimits == 0)
        #expect(state.lastRetryAfterSeconds == nil)

        let updated = await StateStore(env: harness.env).update(id) {
            $0.consecutiveRateLimits = 2
            $0.lastRetryAfterSeconds = 0
        }
        #expect(await StateStore(env: harness.env).read(id) == updated)
    }

    @Test func concurrentUpdatesFromTwoInstancesLoseNothing() async {
        let first = StateStore(env: harness.env)
        let second = StateStore(env: harness.env)
        let id = UUID()
        let bystander = UUID()
        await first.update(bystander) { $0.keychainAccess = .deniedOrPrompting }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                let store = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    await store.update(id) { state in
                        state.lastHTTPAt = (state.lastHTTPAt ?? Self.base).addingTimeInterval(1)
                    }
                }
            }
        }
        #expect(await first.read(id).lastHTTPAt == Self.base.addingTimeInterval(100))
        #expect(await second.read(bystander).keychainAccess == .deniedOrPrompting)
    }

    @Test func updateWaitsForAnotherHolderOfTheFileLock() async throws {
        try LocalFileSystem().createDirectory(dir, permissions: 0o700)
        let lockURL = self.lockURL
        let held = DispatchSemaphore(value: 0)
        let released = Locked(false)
        // Another "process": a different file descriptor holding the flock for a moment.
        let holder = Thread {
            _ = try? LocalFileSystem().withExclusiveLock(lockURL) {
                held.signal()
                usleep(200_000)
                released.withLock { $0 = true }
            }
        }
        holder.start()
        Self.wait(held)
        let observed = Locked(false)
        await StateStore(env: harness.env).update(UUID()) { _ in
            observed.withLock { $0 = released.current }
        }
        #expect(observed.current)
    }

    private static func wait(_ semaphore: DispatchSemaphore) {
        semaphore.wait()
    }
}
