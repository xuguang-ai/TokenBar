import Foundation

public enum ClaudeCodeRefreshResult: Sendable, Equatable {
    /// The child exited within the wait. `startedAt` is when step ② was registered, just before the spawn.
    case exited(status: Int32, startedAt: Date)
    /// Still running when the wait ended. It is not signalled; a background task keeps waiting and clears
    /// the registration when it exits.
    case stillRunning(pid: Int32, startedAt: Date)
    /// Another live step ② is registered for this account; nothing was spawned.
    case alreadyInFlight
    /// No signed claude ≥ 2.1.289; nothing was spawned.
    case binaryNotFound
    /// The working directory could not be prepared, the verified binary changed before the spawn,
    /// or the spawn failed.
    case spawnFailed
}

/// Step ② mechanics (spec §5.3): `claude -p /usage` in a dedicated config dir so Claude Code refreshes its
/// own token and rewrites `cachedUsageUtilization`. The child gets its own process group, stdio on
/// /dev/null, `MinimalEnv` plus `CLAUDE_CONFIG_DIR`, and a fixed cwd. TokenBar never signals it.
/// Whether step ② should run at all is the provider's decision.
public struct ClaudeCodeRefresher: Sendable {
    /// Single-step cap on waiting for the child (spec §5.3).
    public static let maxWait: Duration = .seconds(60)
    /// A registration made before the spawn (pid 0) counts as live for this long.
    static let reservationLifetime: TimeInterval = 120
    /// A live pid whose start time differs from the registration by more than this was reused.
    static let startTimeTolerance: TimeInterval = 60
    /// The background waiter gives up after this many 30 s waits; the registration then stays until
    /// the pid is found dead.
    static let backgroundWaitRounds = 120

    private let env: CoreEnvironment
    private let stateStore: any StateStoring
    private let binaryLocator: any BinaryLocating

    public init(env: CoreEnvironment, stateStore: any StateStoring, binaryLocator: any BinaryLocating) {
        self.env = env
        self.stateStore = stateStore
        self.binaryLocator = binaryLocator
    }

    /// `<appSupport>/claude-cwd`, mode 0700. A fixed cwd keeps Claude Code from adding a projects/ entry per run.
    public var workingDirectory: URL {
        env.appSupportDirectory.appendingPathComponent("claude-cwd", isDirectory: true)
    }

    /// True when a registration exists and is still live. A dead pid (e.g. after an App restart) does not count.
    public func isInFlight(accountID: UUID) async -> Bool {
        guard let entry = await stateStore.read(accountID).step2InFlight else { return false }
        return Self.isLive(entry, now: env.now(), inspector: env.processInspector)
    }

    /// Runs step ② for `configDir` (the exact `CLAUDE_CONFIG_DIR` string) and waits up to `wait`
    /// (capped at 60 s) for the child to exit.
    public func refresh(accountID: UUID, configDir: String, settings: AppSettings, wait: Duration) async
        -> ClaudeCodeRefreshResult
    {
        guard await binaryLocator.locate(.claude, settings: settings) != nil else { return .binaryNotFound }

        // Register before spawning, atomically with the in-flight check.
        let startedAt = env.now()
        let reservation = Step2InFlight(pid: 0, startedAt: startedAt)
        let inspector = env.processInspector
        let claimed = ClaudeStep2ClaimFlag()
        await stateStore.update(accountID) { state in
            if let existing = state.step2InFlight, Self.isLive(existing, now: startedAt, inspector: inspector) { return }
            state.step2InFlight = reservation
            state.lastStep2At = startedAt
            claimed.set()
        }
        guard claimed.isSet else { return .alreadyInFlight }

        let process: any DetachedProcess
        do {
            try env.fileSystem.createDirectory(workingDirectory, permissions: 0o700)
            try env.fileSystem.setPermissions(workingDirectory, 0o700)
            // Registering can wait on the state file lock, so resolve and verify the binary again right
            // before the spawn, then make sure the verified file is still the one on disk (spec §5.6, §9.4).
            guard let verified = await binaryLocator.locate(.claude, settings: settings) else {
                await clear(accountID, matching: reservation)
                return .binaryNotFound
            }
            guard verified.isUnchanged(env.fileSystem.stat(verified.url)) else { throw ClaudeStep2BinaryChanged() }
            process = try await env.processRunner.spawnDetached(ProcessRequest(
                executable: verified.url,
                arguments: ["-p", "/usage"],
                environment: env.childEnvironment(settings: settings, extra: ["CLAUDE_CONFIG_DIR": configDir]),
                currentDirectory: workingDirectory,
                timeout: Self.maxWait))
        } catch {
            await clear(accountID, matching: reservation)
            return .spawnFailed
        }

        let pid = process.pid
        let registered = Step2InFlight(pid: pid, startedAt: startedAt)
        await stateStore.update(accountID) { state in
            if state.step2InFlight == reservation { state.step2InFlight = registered }
        }

        let capped = min(wait, Self.maxWait)
        if let status = await process.waitForExit(timeout: capped) {
            await clear(accountID, matching: registered)
            return .exited(status: status, startedAt: startedAt)
        }

        // Stop waiting but never kill: an interrupted token refresh would log the directory out.
        let stateStore = self.stateStore
        Task.detached {
            for _ in 0..<Self.backgroundWaitRounds {
                if await process.waitForExit(timeout: .seconds(30)) != nil || !inspector.isAlive(pid: pid) {
                    await stateStore.update(accountID) { state in
                        if state.step2InFlight == registered { state.step2InFlight = nil }
                    }
                    return
                }
            }
        }
        return .stillRunning(pid: pid, startedAt: startedAt)
    }

    private func clear(_ accountID: UUID, matching entry: Step2InFlight) async {
        await stateStore.update(accountID) { state in
            if state.step2InFlight == entry { state.step2InFlight = nil }
        }
    }

    static func isLive(_ entry: Step2InFlight, now: Date, inspector: any ProcessInspecting) -> Bool {
        if entry.pid <= 0 {
            return now.timeIntervalSince(entry.startedAt) < reservationLifetime
        }
        guard inspector.isAlive(pid: entry.pid) else { return false }
        if let started = inspector.startTime(pid: entry.pid),
           abs(started.timeIntervalSince(entry.startedAt)) > startTimeTolerance {
            return false
        }
        return true
    }
}

/// The verified claude binary changed between verification and the spawn.
private struct ClaudeStep2BinaryChanged: Error {}

/// Set inside a `StateStoring.update` closure to report whether the claim succeeded.
private final class ClaudeStep2ClaimFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
