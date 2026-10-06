import Foundation

/// `<appSupport>/snapshots.json` (spec §5.8): each account's last successful snapshot and last error,
/// so the UI has data immediately at launch. Only the App writes it. Emails are never persisted (spec §9.7).
public struct SnapshotStore: Sendable {
    public static let fileName = "snapshots.json"
    static let formatVersion = 1

    public let env: CoreEnvironment
    public var fileURL: URL { env.appSupportDirectory.appendingPathComponent(Self.fileName) }

    public init(env: CoreEnvironment) {
        self.env = env
    }

    /// Missing, unreadable or corrupt files load as empty: this is only a cache.
    public func load() -> [UUID: StoredAccountState] {
        guard let data = try? env.fileSystem.readFile(fileURL),
              let file = try? JSONDecoder().decode(SnapshotsFile.self, from: data) else { return [:] }
        var result: [UUID: StoredAccountState] = [:]
        for (key, state) in file.accounts {
            guard let id = UUID(uuidString: key) else { return [:] }
            result[id] = state
        }
        return result
    }

    /// Atomically replaces the file (0600, directory 0700).
    public func save(_ states: [UUID: StoredAccountState]) throws {
        var accounts: [String: StoredAccountState] = [:]
        for (id, var state) in states {
            // `AccountIdentity` never encodes `email`; clear it anyway so it cannot leak by accident.
            state.lastSnapshot?.identity?.email = nil
            accounts[id.uuidString] = state
        }
        let data = try StoresDirectory.encoder().encode(SnapshotsFile(version: Self.formatVersion, accounts: accounts))
        try StoresDirectory.prepare(env)
        try env.fileSystem.writeFileAtomically(data, to: fileURL, permissions: StoresDirectory.filePermissions)
    }

    private struct SnapshotsFile: Codable {
        var version: Int
        var accounts: [String: StoredAccountState]
    }
}
