import Foundation

/// Why `config.json` could not be used. Carries no file contents (spec §9.3).
public enum ConfigLoadError: Error, Sendable, Equatable {
    case missing
    /// Unreadable, not JSON, or not decodable as `AppSettings`.
    case corrupt
    /// Written by a newer TokenBar: the App shows a read-only error, the CLI exits 2 (spec §5.8).
    case tooNew(Int)
}

/// Something the App should surface after `loadOrDefault(forApp: true)` fell back to defaults.
public enum ConfigLoadWarning: Sendable, Equatable {
    /// The corrupt file was moved aside to this name inside the app support directory.
    case corruptFileRenamed(backupFileName: String)
    /// The corrupt file could not be moved aside; it was left untouched and nothing was written.
    case corruptFileNotRenamed
    /// Defaults are in use but could not be written to `config.json`.
    case defaultsNotSaved
}

public struct ConfigLoadOutcome: Sendable, Equatable {
    public var settings: AppSettings
    public var warning: ConfigLoadWarning?

    public init(settings: AppSettings, warning: ConfigLoadWarning? = nil) {
        self.settings = settings
        self.warning = warning
    }
}

/// `<appSupport>/config.json` (spec §5.8). Only the App creates or writes it; the CLI only reads (spec §7).
public struct ConfigStore: Sendable {
    public static let fileName = "config.json"

    public let env: CoreEnvironment
    public var fileURL: URL { env.appSupportDirectory.appendingPathComponent(Self.fileName) }

    public init(env: CoreEnvironment) {
        self.env = env
    }

    /// First-launch settings (`AppSettings.makeDefault()`) with fixed account IDs, so that a CLI running
    /// without `config.json` keys `state.json` the same way on every run and the same way as the App.
    public static func defaultSettings() -> AppSettings {
        var settings = AppSettings.makeDefault()
        for index in settings.accounts.indices {
            switch settings.accounts[index].provider {
            case .claude: settings.accounts[index].id = defaultClaudeAccountID
            case .codex: settings.accounts[index].id = defaultCodexAccountID
            }
        }
        return settings
    }

    public static let defaultClaudeAccountID = UUID(uuidString: "7B0C1A0D-E000-4000-8000-000000000001")!
    public static let defaultCodexAccountID = UUID(uuidString: "7B0C0DE5-E000-4000-8000-000000000002")!

    // MARK: Reading

    public func load() throws(ConfigLoadError) -> AppSettings {
        let fs = env.fileSystem
        guard fs.fileExists(fileURL) else { throw .missing }
        let data: Data
        do {
            data = try fs.readFile(fileURL)
        } catch {
            throw .corrupt
        }
        return try Self.decode(data)
    }

    /// - App (`forApp: true`): a missing file yields defaults that are saved; a corrupt file is renamed
    ///   to `config.json.corrupt-<epoch>` and defaults are saved and returned with a warning.
    /// - CLI (`forApp: false`): a missing file yields in-memory defaults; nothing is ever written.
    /// - Throws `.tooNew` in both modes, and `.corrupt` in CLI mode. Never throws `.missing`.
    public func loadOrDefault(forApp: Bool) throws(ConfigLoadError) -> ConfigLoadOutcome {
        do {
            return ConfigLoadOutcome(settings: try load())
        } catch .missing {
            let defaults = Self.defaultSettings()
            guard forApp else { return ConfigLoadOutcome(settings: defaults) }
            return ConfigLoadOutcome(settings: defaults, warning: saveDefaults(defaults))
        } catch .corrupt {
            guard forApp else { throw .corrupt }
            let defaults = Self.defaultSettings()
            guard let backup = moveCorruptFileAside() else {
                return ConfigLoadOutcome(settings: defaults, warning: .corruptFileNotRenamed)
            }
            let warning = saveDefaults(defaults) ?? .corruptFileRenamed(backupFileName: backup)
            return ConfigLoadOutcome(settings: defaults, warning: warning)
        } catch {
            throw error
        }
    }

    /// The mtime of `config.json`, or nil when it does not exist. The App reloads when it changes.
    /// (The space before `)` keeps scripts/test.sh's `Date\(\)` clock guard from matching the declaration.
    /// Code inside TokenBarCore should use `fileModificationTime` for the same reason.)
    public func modificationDate( ) -> Date? {
        fileModificationTime
    }

    /// Same value as `modificationDate( )`.
    public var fileModificationTime: Date? {
        env.fileSystem.stat(fileURL)?.modificationTime
    }

    // MARK: Writing

    /// Atomic write: the file gets 0600 and the app support directory 0700 (spec §9.8).
    public func save(_ settings: AppSettings) throws {
        var settings = settings
        settings.schemaVersion = AppSettings.currentSchemaVersion
        let data = try StoresDirectory.encoder().encode(settings)
        try StoresDirectory.prepare(env)
        try env.fileSystem.writeFileAtomically(data, to: fileURL, permissions: StoresDirectory.filePermissions)
    }

    // MARK: Decoding and migration

    public static func decode(_ data: Data) throws(ConfigLoadError) -> AppSettings {
        let version: Int
        do {
            version = try JSONDecoder().decode(VersionProbe.self, from: data).schemaVersion
                ?? AppSettings.currentSchemaVersion
        } catch {
            throw .corrupt
        }
        var current = data
        if version != AppSettings.currentSchemaVersion {
            let migrated = try migrate(try jsonObject(data), fromVersion: version)
            do {
                current = try JSONSerialization.data(withJSONObject: migrated)
            } catch {
                throw .corrupt
            }
        }
        do {
            var settings = try JSONDecoder().decode(AppSettings.self, from: current)
            settings.schemaVersion = AppSettings.currentSchemaVersion
            return settings
        } catch {
            throw .corrupt
        }
    }

    /// Applies the pure `vN -> vN+1` steps until the object is at `AppSettings.currentSchemaVersion`.
    /// v1 is the first schema, so for now this is the identity.
    public static func migrate(_ object: [String: Any], fromVersion version: Int) throws(ConfigLoadError) -> [String: Any] {
        guard version >= 1 else { throw .corrupt }
        guard version <= AppSettings.currentSchemaVersion else { throw .tooNew(version) }
        var object = object
        var step = version
        while step < AppSettings.currentSchemaVersion {
            // Future steps go here, e.g. `case 1: object = migrateV1toV2(object)`.
            step += 1
            object["schemaVersion"] = step
        }
        return object
    }

    // MARK: Private

    private struct VersionProbe: Decodable {
        var schemaVersion: Int?
    }

    private static func jsonObject(_ data: Data) throws(ConfigLoadError) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw .corrupt }
        return object
    }

    private func saveDefaults(_ settings: AppSettings) -> ConfigLoadWarning? {
        do {
            try save(settings)
            return nil
        } catch {
            return .defaultsNotSaved
        }
    }

    /// Renames the corrupt file to `config.json.corrupt-<epoch>` (adding `-1`, `-2`, ... so an earlier
    /// backup is never overwritten) and returns the new file name.
    private func moveCorruptFileAside() -> String? {
        let fs = env.fileSystem
        let base = "\(Self.fileName).corrupt-\(Int(env.now().timeIntervalSince1970))"
        for attempt in 0..<100 {
            let name = attempt == 0 ? base : "\(base)-\(attempt)"
            let destination = env.appSupportDirectory.appendingPathComponent(name)
            if fs.fileExists(destination) { continue }
            do {
                try fs.moveItem(fileURL, to: destination)
                try? fs.setPermissions(destination, StoresDirectory.filePermissions)
                return name
            } catch {
                return nil
            }
        }
        return nil
    }
}

/// The app support directory shared by `ConfigStore`, `SnapshotStore` and `StateStore` (spec §9.8).
enum StoresDirectory {
    static let directoryPermissions: UInt16 = 0o700
    static let filePermissions: UInt16 = 0o600

    /// Creates the app support directory if needed and (re)applies 0700 to it.
    static func prepare(_ env: CoreEnvironment) throws {
        try env.fileSystem.createDirectory(env.appSupportDirectory, permissions: directoryPermissions)
        try env.fileSystem.setPermissions(env.appSupportDirectory, directoryPermissions)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
