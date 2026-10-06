import Foundation

/// The newest usable rate-limit snapshot found in Codex rollout logs.
public struct CodexRolloutSnapshot: Sendable, Hashable {
    /// Timestamp of the `token_count` event.
    public var eventAt: Date
    public var windows: [UsageWindow]
    public var limitReached: Bool
    /// Display form, e.g. "Plus".
    public var plan: String?

    public init(eventAt: Date, windows: [UsageWindow], limitReached: Bool, plan: String?) {
        self.eventAt = eventAt
        self.windows = windows
        self.limitReached = limitReached
        self.plan = plan
    }
}

/// Passive fallback (spec §5.4 step 6): the tails of the newest `rollout-*.jsonl` files under
/// `$CODEX_HOME/sessions` and `archived_sessions`. Only those files are opened; Codex's SQLite
/// databases, `auth.json` and everything else are never read.
public struct CodexRolloutReader: Sendable {
    public static let maxFiles = 3
    public static let tailBytes = 512 * 1024
    static let maxDepth = 6

    private let fileSystem: any FileSystemAccess

    public init(fileSystem: any FileSystemAccess) {
        self.fileSystem = fileSystem
    }

    /// The newest `token_count` event with `limit_id == "codex"` (or no `limit_id`) that has at least
    /// one non-null window. nil when there is none.
    public func latestSnapshot(codexHome: URL) -> CodexRolloutSnapshot? {
        var best: (date: Date, limits: [String: Any])?
        for file in newestRolloutFiles(codexHome: codexHome) {
            guard let stat = fileSystem.stat(file), let data = try? fileSystem.readFileTail(file, maxBytes: Self.tailBytes) else {
                continue
            }
            var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            if stat.size > Int64(Self.tailBytes), !lines.isEmpty {
                lines.removeFirst()  // the first line of a tail is probably partial
            }
            for line in lines {
                guard let event = Self.rateLimitEvent(Data(line)) else { continue }
                if let current = best, current.date >= event.0 { continue }
                best = (event.0, event.1)
            }
        }
        guard let best else { return nil }
        let windows = ["primary", "secondary"].compactMap { Self.window(best.limits[$0], eventAt: best.date) }
        let reachedType = CodexRateLimitMapper.string(best.limits["rate_limit_reached_type"])
        return CodexRolloutSnapshot(
            eventAt: best.date,
            windows: windows.sortedForDisplay(),
            limitReached: reachedType != nil,
            plan: CodexRateLimitMapper.displayPlan(CodexRateLimitMapper.string(best.limits["plan_type"])))
    }

    /// Up to `maxFiles` rollout files, newest modification time first.
    func newestRolloutFiles(codexHome: URL) -> [URL] {
        var found: [(url: URL, mtime: Date)] = []
        for name in ["sessions", "archived_sessions"] {
            collect(codexHome.appendingPathComponent(name, isDirectory: true), depth: 0, into: &found)
        }
        return found.sorted { $0.mtime > $1.mtime }.prefix(Self.maxFiles).map(\.url)
    }

    private func collect(_ directory: URL, depth: Int, into found: inout [(url: URL, mtime: Date)]) {
        guard depth <= Self.maxDepth, let entries = try? fileSystem.contentsOfDirectory(directory) else { return }
        for entry in entries {
            guard let info = fileSystem.lstat(entry) else { continue }  // symlinks are not followed
            if info.isDirectory {
                collect(entry, depth: depth + 1, into: &found)
            } else if info.isRegularFile, Self.isRolloutFileName(entry.lastPathComponent) {
                found.append((entry, info.modificationTime))
            }
        }
    }

    static func isRolloutFileName(_ name: String) -> Bool {
        name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    /// `(timestamp, rate_limits)` of a `token_count` event line that passes the limit_id filter and has
    /// at least one non-null window.
    static func rateLimitEvent(_ line: Data) -> (Date, [String: Any])? {
        // Cheap pre-filter before JSON parsing.
        guard line.range(of: Data("rate_limits".utf8)) != nil,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              let date = (object["timestamp"] as? String).flatMap(DateParsing.iso8601)
        else { return nil }
        if let limitID = limits["limit_id"], !(limitID is NSNull), limitID as? String != "codex" { return nil }
        guard limits["primary"] is [String: Any] || limits["secondary"] is [String: Any] else { return nil }
        return (date, limits)
    }

    /// A rollout window: `{used_percent, window_minutes, resets_at | resets_in_seconds}`.
    static func window(_ object: Any?, eventAt: Date) -> UsageWindow? {
        guard let dict = object as? [String: Any], let used = CodexRateLimitMapper.double(dict["used_percent"]) else {
            return nil
        }
        var resetsAt = DateParsing.flexible(dict["resets_at"])
        if resetsAt == nil, let seconds = CodexRateLimitMapper.double(dict["resets_in_seconds"]) {
            resetsAt = eventAt.addingTimeInterval(seconds)
        }
        let window = CodexRateLimitWindow(
            usedPercent: used, windowDurationMins: CodexRateLimitMapper.int(dict["window_minutes"]), resetsAt: resetsAt)
        return CodexRateLimitMapper.window(window, reference: eventAt)
    }
}
