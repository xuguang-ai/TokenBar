import Foundation

// `tokenbar sessions [--json]`: running Claude Code sessions grouped by account (spec §7, §5.5).

public struct CLISessionsJSON: Encodable, Sendable, Hashable {
    public var generatedAt: String
    public var groups: [CLISessionGroupJSON]

    public init(generatedAt: String, groups: [CLISessionGroupJSON]) {
        self.generatedAt = generatedAt
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case groups
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(groups, forKey: .groups)
    }
}

public struct CLISessionGroupJSON: Encodable, Sendable, Hashable {
    /// `nil` for the "Other" group (sessions not attributed to a configured account).
    public var accountID: String?
    /// The account's display name, or "Other".
    public var accountName: String
    public var sessions: [CLISessionJSON]

    public init(accountID: String?, accountName: String, sessions: [CLISessionJSON]) {
        self.accountID = accountID
        self.accountName = accountName
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case accountName = "account_name"
        case sessions
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accountID, forKey: .accountID)
        try c.encode(accountName, forKey: .accountName)
        try c.encode(sessions, forKey: .sessions)
    }
}

public struct CLISessionJSON: Encodable, Sendable, Hashable {
    public var pid: Int32
    /// `SessionInfo.displayName`.
    public var name: String
    /// "busy", "idle" or "unknown".
    public var status: String
    /// When the current status began (else when the session started), ISO-8601.
    public var since: String?
    public var configDir: String

    public init(pid: Int32, name: String, status: String, since: String?, configDir: String) {
        self.pid = pid
        self.name = name
        self.status = status
        self.since = since
        self.configDir = configDir
    }

    private enum CodingKeys: String, CodingKey {
        case pid, name, status, since
        case configDir = "config_dir"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pid, forKey: .pid)
        try c.encode(name, forKey: .name)
        try c.encode(status, forKey: .status)
        try c.encode(since, forKey: .since)
        try c.encode(configDir, forKey: .configDir)
    }
}

public enum CLISessionsRenderer {
    public static let otherGroupName = "Other"
    public static let maxNameWidth = 32

    /// The moment the duration counts from: the status change, else the session start.
    public static func since(_ session: SessionInfo) -> Date? {
        session.statusUpdatedAt ?? session.startedAt
    }

    public static func json(groups: [SessionGroup], accounts: [AccountConfig], now: Date) -> CLISessionsJSON {
        let names = Dictionary(accounts.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        return CLISessionsJSON(generatedAt: CLIFormat.iso8601(now), groups: groups.map { group in
            CLISessionGroupJSON(
                accountID: group.accountID?.uuidString,
                accountName: group.accountID.flatMap { names[$0] } ?? otherGroupName,
                sessions: group.sessions.map { session in
                    CLISessionJSON(pid: session.pid, name: session.displayName, status: session.status.rawValue,
                                   since: since(session).map(CLIFormat.iso8601), configDir: session.configDir)
                })
        })
    }

    /// ```text
    /// Claude · Work
    ///   ● TokenBar   busy  3m
    ///   ○ NIW        idle  1h 2m
    /// Other
    ///   ○ scratch    idle  2d 1h
    /// ```
    public static func table(groups: [SessionGroup], accounts: [AccountConfig], now: Date) -> String {
        let nonEmpty = groups.filter { !$0.sessions.isEmpty }
        guard !nonEmpty.isEmpty else { return "No Claude Code sessions running.\n" }
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var blocks: [String] = []
        for group in nonEmpty {
            var lines: [String] = []
            if let id = group.accountID, let account = byID[id] {
                lines.append(CLIFormat.accountTitle(account))
            } else {
                lines.append(otherGroupName)
            }
            let names = group.sessions.map { CLIFormat.truncate(CLIFormat.printable($0.displayName), to: maxNameWidth) }
            let nameWidth = names.map(\.count).max() ?? 0
            for (session, name) in zip(group.sessions, names) {
                let dot = session.status == .busy ? "●" : "○"
                var line = "  \(dot) " + CLIFormat.pad(name, to: nameWidth) + "  "
                    + CLIFormat.pad(session.status.rawValue, to: 7)
                if let start = since(session) {
                    line += Formatting.countdown(to: now, now: start)
                }
                lines.append(trimTrailing(line))
            }
            blocks.append(lines.joined(separator: "\n") + "\n")
        }
        return blocks.joined(separator: "\n")
    }

    static func trimTrailing(_ text: String) -> String {
        var text = text
        while text.last == " " { text.removeLast() }
        return text
    }
}
