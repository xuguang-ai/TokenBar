import Foundation
import Testing
@testable import TokenBarCore

@Suite("ClaudeCodeRefresher")
struct ClaudeCodeRefresherTests {
    private let accountID = UUID()
    private let settings = AppSettings(accounts: [])

    private func make(
        _ h: TestHarness, store: InMemoryStateStore = InMemoryStateStore(), locator: ClaudeTestKit.StubBinaryLocator = .init()
    ) -> ClaudeCodeRefresher {
        ClaudeCodeRefresher(env: h.env, stateStore: store, binaryLocator: locator)
    }

    @Test func spawnsExactlyClaudeDashPUsage() async throws {
        let h = try TestHarness()
        let store = InMemoryStateStore()
        let seenInFlight = Locked<Step2InFlight?>(nil)
        h.processes.detachedHandler = { _ in
            let entry = await store.read(self.accountID).step2InFlight
            seenInFlight.withLock { $0 = entry }
            return FakeDetachedProcess(pid: 4242, exitStatus: 0)
        }
        let refresher = make(h, store: store)
        let start = h.clock.now
        let result = await refresher.refresh(accountID: accountID, configDir: "/d/work", settings: settings, wait: .seconds(60))
        #expect(result == .exited(status: 0, startedAt: start))

        let call = try #require(h.processes.calls.first)
        #expect(h.processes.calls.count == 1)
        #expect(call.mode == .detached)
        #expect(call.request.executable.path == "/opt/claude/versions/2.1.289")
        #expect(call.request.arguments == ["-p", "/usage"])
        #expect(call.request.environment == h.env.childEnvironment(settings: settings, extra: ["CLAUDE_CONFIG_DIR": "/d/work"]))
        #expect(call.request.environment["CLAUDE_CONFIG_DIR"] == "/d/work")
        #expect(call.request.currentDirectory == refresher.workingDirectory)
        #expect(refresher.workingDirectory.path.hasSuffix("Application Support/TokenBar/claude-cwd"))
        #expect(h.env.fileSystem.stat(refresher.workingDirectory)?.permissions == 0o700)

        // Registered before the spawn, cleared after the exit.
        #expect(seenInFlight.current?.startedAt == start)
        let state = await store.read(accountID)
        #expect(state.step2InFlight == nil)
        #expect(state.lastStep2At == start)
    }

    @Test func tightensAnExistingWorkingDirectory() async throws {
        let h = try TestHarness()
        let refresher = make(h)
        try FileManager.default.createDirectory(at: refresher.workingDirectory, withIntermediateDirectories: true)
        try h.env.fileSystem.setPermissions(refresher.workingDirectory, 0o755)
        h.processes.detachedHandler = { _ in FakeDetachedProcess(pid: 1, exitStatus: 0) }
        _ = await refresher.refresh(accountID: accountID, configDir: "/d", settings: settings, wait: .seconds(5))
        #expect(h.env.fileSystem.stat(refresher.workingDirectory)?.permissions == 0o700)
    }

    @Test func noSpawnWhileAnotherIsInFlight() async throws {
        let h = try TestHarness()
        h.inspector.setAlive(777, startTime: nil)
        let store = InMemoryStateStore([accountID: AccountRuntimeState(step2InFlight: Step2InFlight(pid: 777, startedAt: h.clock.now))])
        let refresher = make(h, store: store)
        #expect(await refresher.isInFlight(accountID: accountID))
        let result = await refresher.refresh(accountID: accountID, configDir: "/d", settings: settings, wait: .seconds(60))
        #expect(result == .alreadyInFlight)
        #expect(h.processes.calls.isEmpty)
    }

    @Test func deadRegistrationIsIgnored() async throws {
        let h = try TestHarness()
        let store = InMemoryStateStore([accountID: AccountRuntimeState(step2InFlight: Step2InFlight(pid: 777, startedAt: h.clock.now))])
        h.processes.detachedHandler = { _ in FakeDetachedProcess(pid: 9, exitStatus: 0) }
        let refresher = make(h, store: store)
        #expect(await refresher.isInFlight(accountID: accountID) == false)
        let result = await refresher.refresh(accountID: accountID, configDir: "/d", settings: settings, wait: .seconds(60))
        #expect(result == .exited(status: 0, startedAt: h.clock.now))
    }

    @Test func reusedPidIsIgnored() async throws {
        let h = try TestHarness()
        h.inspector.setAlive(777, startTime: h.clock.now.addingTimeInterval(-3600))
        let store = InMemoryStateStore([accountID: AccountRuntimeState(step2InFlight: Step2InFlight(pid: 777, startedAt: h.clock.now))])
        #expect(await make(h, store: store).isInFlight(accountID: accountID) == false)
    }

    @Test func timeoutReturnsStillRunningWithoutKilling() async throws {
        let h = try TestHarness()
        h.inspector.setAlive(4243, startTime: nil)
        let store = InMemoryStateStore()
        h.processes.detachedHandler = { _ in FakeDetachedProcess(pid: 4243, exitStatus: nil) }
        let refresher = make(h, store: store)
        let start = h.clock.now
        let result = await refresher.refresh(accountID: accountID, configDir: "/d", settings: settings, wait: .seconds(3))
        #expect(result == .stillRunning(pid: 4243, startedAt: start))
        // Only the spawn: no kill, no other process.
        #expect(h.processes.calls.map(\.mode) == [.detached])
        #expect(await store.read(accountID).step2InFlight == Step2InFlight(pid: 4243, startedAt: start))
        #expect(await refresher.isInFlight(accountID: accountID))
    }

    @Test func backgroundWaiterClearsTheRegistrationWhenTheChildDies() async throws {
        let h = try TestHarness()
        let store = InMemoryStateStore()
        h.processes.detachedHandler = { _ in FakeDetachedProcess(pid: 4244, exitStatus: nil) }
        // The pid is not alive in the inspector, so the background waiter clears the entry.
        _ = await make(h, store: store).refresh(accountID: accountID, configDir: "/d", settings: settings, wait: .seconds(1))
        for _ in 0..<200 where await store.read(accountID).step2InFlight != nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await store.read(accountID).step2InFlight == nil)
    }

    @Test func noBinaryNoSpawn() async throws {
        let h = try TestHarness()
        let store = InMemoryStateStore()
        let result = await make(h, store: store, locator: .init(nil))
            .refresh(accountID: accountID, configDir: "/d", settings: settings, wait: .seconds(60))
        #expect(result == .binaryNotFound)
        #expect(h.processes.calls.isEmpty)
        #expect(await store.read(accountID).lastStep2At == nil)
    }

    @Test func spawnFailureReleasesTheRegistration() async throws {
        let h = try TestHarness()
        let store = InMemoryStateStore()
        h.processes.detachedHandler = { _ in throw ProcessLaunchError.spawnFailed(errno: 1) }
        let result = await make(h, store: store).refresh(accountID: accountID, configDir: "/d", settings: settings, wait: .seconds(60))
        #expect(result == .spawnFailed)
        #expect(await store.read(accountID).step2InFlight == nil)
    }
}
