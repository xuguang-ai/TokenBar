import Foundation

/// File-backed `StateStoring`: `<appSupport>/state.json` (0600), shared by the App and the CLI (spec §5.8).
///
/// Every `update` is a read-modify-write done while holding `flock` on `<appSupport>/state.lock`
/// (cross-process) and a process-wide lock (in-process). Writes are atomic renames, so `read` and
/// `readAll` need no lock. A missing or corrupt `state.json` reads as empty state; the next `update`
/// replaces a corrupt file. Write failures are not reported: this is best-effort runtime state.
public struct StateStore: StateStoring {
    public static let fileName = "state.json"
    public static let lockFileName = "state.lock"
    static let formatVersion = 1

    public let env: CoreEnvironment
    public var fileURL: URL { env.appSupportDirectory.appendingPathComponent(Self.fileName) }
    public var lockURL: URL { env.appSupportDirectory.appendingPathComponent(Self.lockFileName) }

    /// flock is per open file description, so it would also serialize two stores in one process;
    /// this lock keeps in-process callers off the file lock's blocking wait as well.
    private static let processLock = NSLock()

    public init(env: CoreEnvironment) {
        self.env = env
    }

    public func read(_ accountID: UUID) async -> AccountRuntimeState {
        readFile()[accountID] ?? AccountRuntimeState()
    }

    public func readAll() async -> [UUID: AccountRuntimeState] {
        readFile()
    }

    @discardableResult
    public func update(_ accountID: UUID, _ body: @Sendable (inout AccountRuntimeState) -> Void) async -> AccountRuntimeState {
        updateLocked(accountID, body)
    }

    // MARK: Private

    private struct StateFile: Codable {
        var version: Int
        var accounts: [String: AccountRuntimeState]
    }

    private func updateLocked(_ accountID: UUID, _ body: (inout AccountRuntimeState) -> Void) -> AccountRuntimeState {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let apply = { () -> AccountRuntimeState in
            var all = readFile()
            var state = all[accountID] ?? AccountRuntimeState()
            body(&state)
            all[accountID] = state
            try? writeFile(all)
            return state
        }
        do {
            try StoresDirectory.prepare(env)
            return try env.fileSystem.withExclusiveLock(lockURL, apply)
        } catch {
            // No directory or no lock file: still hand the caller the updated value.
            var state = readFile()[accountID] ?? AccountRuntimeState()
            body(&state)
            return state
        }
    }

    private func readFile() -> [UUID: AccountRuntimeState] {
        guard let data = try? env.fileSystem.readFile(fileURL),
              let file = try? JSONDecoder().decode(StateFile.self, from: data) else { return [:] }
        var result: [UUID: AccountRuntimeState] = [:]
        for (key, state) in file.accounts {
            guard let id = UUID(uuidString: key) else { return [:] }
            result[id] = state
        }
        return result
    }

    private func writeFile(_ states: [UUID: AccountRuntimeState]) throws {
        let accounts = Dictionary(uniqueKeysWithValues: states.map { ($0.key.uuidString, $0.value) })
        let data = try StoresDirectory.encoder().encode(StateFile(version: Self.formatVersion, accounts: accounts))
        try env.fileSystem.writeFileAtomically(data, to: fileURL, permissions: StoresDirectory.filePermissions)
    }
}
