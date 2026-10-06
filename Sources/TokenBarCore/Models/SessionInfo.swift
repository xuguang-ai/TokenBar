import Foundation

public enum SessionStatus: String, Codable, Sendable {
    case busy, idle, unknown
}

/// One running Claude Code session from `<configDir>/sessions/<pid>.json` (spec §5.5).
public struct SessionInfo: Codable, Sendable, Hashable, Identifiable {
    public var pid: Int32
    public var sessionId: String?
    public var cwd: String?
    public var name: String?
    public var status: SessionStatus
    public var statusUpdatedAt: Date?
    public var startedAt: Date?
    public var procStart: String?
    public var kind: String?
    public var entrypoint: String?
    public var version: String?
    /// The watched config directory the registry file came from (absolute path string).
    public var configDir: String

    public init(
        pid: Int32,
        sessionId: String? = nil,
        cwd: String? = nil,
        name: String? = nil,
        status: SessionStatus,
        statusUpdatedAt: Date? = nil,
        startedAt: Date? = nil,
        procStart: String? = nil,
        kind: String? = nil,
        entrypoint: String? = nil,
        version: String? = nil,
        configDir: String
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.status = status
        self.statusUpdatedAt = statusUpdatedAt
        self.startedAt = startedAt
        self.procStart = procStart
        self.kind = kind
        self.entrypoint = entrypoint
        self.version = version
        self.configDir = configDir
    }

    public var id: String { "\(configDir)#\(pid)" }

    /// `name`, else the last path component of `cwd`, else the pid.
    public var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        if let cwd, !cwd.isEmpty { return URL(fileURLWithPath: cwd).lastPathComponent }
        return "pid \(pid)"
    }
}

/// Sessions attributed to one account card, or to "Other Claude sessions" when `accountID` is nil.
public struct SessionGroup: Sendable, Hashable {
    public var accountID: UUID?
    /// Busy sessions first (longest-running first), then idle and unknown ones (spec §5.5).
    public var sessions: [SessionInfo]

    public init(accountID: UUID?, sessions: [SessionInfo]) {
        self.accountID = accountID
        self.sessions = sessions
    }

    public var busy: [SessionInfo] { sessions.filter { $0.status == .busy } }
    public var notBusy: [SessionInfo] { sessions.filter { $0.status != .busy } }
}
