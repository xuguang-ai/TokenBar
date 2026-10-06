import Foundation

/// A Claude config dir whose `sessions/` registry is watched (spec §3.2).
public struct SessionWatchedDirectory: Sendable, Hashable {
    /// Absolute path, `~` expanded, no trailing slash.
    public var path: String
    /// The config dir string as configured: nil for the default `~/.claude`.
    public var configDir: String?
    /// `oauthAccount.accountUuid` of this dir's global config, if known.
    public var accountUuid: String?

    public init(path: String, configDir: String?, accountUuid: String?) {
        self.path = path
        self.configDir = configDir
        self.accountUuid = accountUuid
    }
}

/// Lists running interactive Claude Code sessions and attributes them to accounts (spec §3.2, §5.5).
///
/// Only `sessions/*.json` regular files are opened. `*.key` files (and anything else) are never read.
public struct SessionMonitor: Sendable {
    /// Same process when the start times differ by at most this much.
    public static let startTimeTolerance: TimeInterval = 2
    /// A whole number of 15-minute steps, up to 14 h, is a timezone change.
    public static let timezoneStep: TimeInterval = 15 * 60
    public static let maxTimezoneShift: TimeInterval = 14 * 3_600
    static let maxRegistryFileSize: Int64 = 1 << 20

    private let env: CoreEnvironment
    private let configReader: any ClaudeConfigReading

    public init(env: CoreEnvironment, configReader: any ClaudeConfigReading) {
        self.env = env
        self.configReader = configReader
    }

    // MARK: Watched directories

    /// `~/.claude` first, then every Claude account's `claudeConfigDir`, deduplicated by expanded path.
    /// Returns `(path, configDir)` pairs; `configDir` is nil for the default dir.
    public static func watchedDirectoryPaths(settings: AppSettings, home: URL) -> [(path: String, configDir: String?)] {
        var result: [(path: String, configDir: String?)] = []
        var seen: Set<String> = []
        let configured = settings.accounts.filter { $0.provider == .claude }.compactMap(\.claudeConfigDir)
        let entries: [String?] = [nil] + configured.map(Optional.some)
        for configDir in entries {
            let path = normalizedPath(configDir, home: home)
            guard seen.insert(path).inserted else { continue }
            result.append((path, configDir))
        }
        return result
    }

    /// The watched directories with each one's accountUuid from the config reader.
    public func watchedDirectories(settings: AppSettings) async -> [SessionWatchedDirectory] {
        var result: [SessionWatchedDirectory] = []
        for entry in Self.watchedDirectoryPaths(settings: settings, home: env.homeDirectory) {
            let uuid = await configReader.accountUUID(
                configDir: entry.configDir.map { ClaudePaths.expandTilde($0, home: env.homeDirectory) })
            result.append(SessionWatchedDirectory(path: entry.path, configDir: entry.configDir, accountUuid: uuid))
        }
        return result
    }

    /// `~` expanded and trailing slashes removed. Purely textual: no symlink resolution, so the same
    /// string always maps to the same path.
    static func normalizedPath(_ configDir: String?, home: URL) -> String {
        var path = configDir.map { ClaudePaths.expandTilde($0, home: home) }
            ?? home.appendingPathComponent(".claude").path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: Scanning

    /// Live interactive sessions grouped by account. Enabled Claude accounts come first in settings
    /// order, then "Other Claude sessions" (`accountID == nil`). Empty groups are left out.
    public func scan(settings: AppSettings, identities: [UUID: AccountIdentity], excludePIDs: Set<Int32>) async -> [SessionGroup] {
        let accounts = settings.accounts.filter { $0.provider == .claude && $0.isEnabled }
        var byAccount: [UUID: [SessionInfo]] = [:]
        var other: [SessionInfo] = []
        var seen: Set<String> = []
        for directory in await watchedDirectories(settings: settings) {
            let sessions = liveSessions(inDirectory: directory.path, excludePIDs: excludePIDs)
                .filter { seen.insert($0.id).inserted }
            guard !sessions.isEmpty else { continue }
            if let owner = Self.owner(of: directory, accounts: accounts, identities: identities, home: env.homeDirectory) {
                byAccount[owner, default: []].append(contentsOf: sessions)
            } else {
                other.append(contentsOf: sessions)
            }
        }
        var groups: [SessionGroup] = []
        for account in accounts {
            if let sessions = byAccount[account.id], !sessions.isEmpty {
                groups.append(SessionGroup(accountID: account.id, sessions: Self.sorted(sessions)))
            }
        }
        if !other.isEmpty { groups.append(SessionGroup(accountID: nil, sessions: Self.sorted(other))) }
        return groups
    }

    /// Whether `configDir` (a `CLAUDE_CONFIG_DIR` string; `~` is expanded) has a live interactive
    /// session. ClaudeProvider uses this as the step ② precondition (spec §5.3).
    public func hasLiveInteractiveSessions(configDir: String, excludePIDs: Set<Int32> = []) async -> Bool {
        !liveSessions(inDirectory: Self.normalizedPath(configDir, home: env.homeDirectory), excludePIDs: excludePIDs).isEmpty
    }

    /// The account that owns a watched dir: the enabled Claude account whose identity has the dir's
    /// accountUuid. Dedicated accounts (`claudeConfigDir != nil`) win over the default one; among
    /// several dedicated ones, the account configured for this very dir wins, then settings order.
    static func owner(
        of directory: SessionWatchedDirectory, accounts: [AccountConfig], identities: [UUID: AccountIdentity], home: URL
    ) -> UUID? {
        guard let uuid = directory.accountUuid, !uuid.isEmpty else { return nil }
        let matches = accounts.filter { identities[$0.id]?.accountUuid == uuid }
        func rank(_ account: AccountConfig) -> Int {
            guard let configDir = account.claudeConfigDir else { return 2 }
            return normalizedPath(configDir, home: home) == directory.path ? 0 : 1
        }
        return matches.enumerated()
            .min { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }?
            .element.id
    }

    /// Busy first, then idle, then unknown; each by `statusUpdatedAt`, oldest (longest-running) first.
    static func sorted(_ sessions: [SessionInfo]) -> [SessionInfo] {
        func statusRank(_ status: SessionStatus) -> Int {
            switch status {
            case .busy: return 0
            case .idle: return 1
            case .unknown: return 2
            }
        }
        return sessions.sorted { a, b in
            if statusRank(a.status) != statusRank(b.status) { return statusRank(a.status) < statusRank(b.status) }
            let aTime = a.statusUpdatedAt ?? .distantFuture
            let bTime = b.statusUpdatedAt ?? .distantFuture
            if aTime != bTime { return aTime < bTime }
            return a.pid < b.pid
        }
    }

    // MARK: One directory

    /// Live interactive sessions registered under `<directory>/sessions`.
    public func liveSessions(inDirectory directory: String, excludePIDs: Set<Int32> = []) -> [SessionInfo] {
        let sessionsDirectory = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard let entries = try? env.fileSystem.contentsOfDirectory(sessionsDirectory) else { return [] }
        var result: [SessionInfo] = []
        for entry in entries where entry.pathExtension == "json" {
            // lstat: a symlink named *.json could point at a key file, so only plain files are read.
            guard let info = env.fileSystem.lstat(entry), info.isRegularFile, info.size <= Self.maxRegistryFileSize,
                  let data = try? env.fileSystem.readFile(entry),
                  let session = Self.decode(data, configDir: directory)
            else { continue }
            guard Self.isInteractive(session), !excludePIDs.contains(session.pid), isLive(session) else { continue }
            result.append(session)
        }
        return result
    }

    /// `kind == "interactive"` or no kind at all (spec §5.5).
    public static func isInteractive(_ session: SessionInfo) -> Bool {
        session.kind == nil || session.kind == "interactive"
    }

    /// Decodes a registry file. Unknown fields are ignored; an unknown `status` becomes `.unknown`.
    public static func decode(_ data: Data, configDir: String) -> SessionInfo? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pidValue = CodexRateLimitMapper.int(object["pid"]), pidValue > 0, pidValue <= Int(Int32.max)
        else { return nil }
        let status = (object["status"] as? String).flatMap(SessionStatus.init(rawValue:)) ?? .unknown
        return SessionInfo(
            pid: Int32(pidValue),
            sessionId: object["sessionId"] as? String,
            cwd: object["cwd"] as? String,
            name: object["name"] as? String,
            status: status,
            statusUpdatedAt: millisecondsDate(object["statusUpdatedAt"]),
            startedAt: millisecondsDate(object["startedAt"]),
            procStart: object["procStart"] as? String,
            kind: object["kind"] as? String,
            entrypoint: object["entrypoint"] as? String,
            version: object["version"] as? String,
            configDir: configDir)
    }

    /// Epoch milliseconds, or an ISO-8601 string.
    static func millisecondsDate(_ value: Any?) -> Date? {
        if let ms = CodexRateLimitMapper.double(value) { return Date(timeIntervalSince1970: ms / 1000) }
        if let text = value as? String { return DateParsing.iso8601(text) }
        return nil
    }

    // MARK: Liveness

    /// `kill(pid, 0)` says the process exists, and, when `procStart` parses and the real start time is
    /// available, the two agree within 2 s or differ by a timezone shift (spec §5.5).
    func isLive(_ session: SessionInfo) -> Bool {
        guard env.processInspector.isAlive(pid: session.pid) else { return false }
        guard let text = session.procStart, let recorded = DateParsing.procStart(text),
              let actual = env.processInspector.startTime(pid: session.pid)
        else { return true }
        return Self.startTimesMatch(recorded: recorded, actual: actual)
    }

    public static func startTimesMatch(recorded: Date, actual: Date) -> Bool {
        let difference = abs(actual.timeIntervalSince(recorded))
        if difference <= startTimeTolerance { return true }
        let steps = (difference / timezoneStep).rounded()
        guard steps >= 1, steps * timezoneStep <= maxTimezoneShift else { return false }
        return abs(difference - steps * timezoneStep) <= startTimeTolerance
    }
}
