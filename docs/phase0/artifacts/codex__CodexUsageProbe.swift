// CodexUsageProbe.swift - TokenBar Phase 0: Swift proof that a native app can drive
// `codex app-server` (stdio JSON-RPC, newline-delimited) and read plan usage.
// Build: swiftc -O CodexUsageProbe.swift -o codex-usage-probe
// Never touches credentials: the app-server uses Codex's own stored auth.
import Foundation

// MARK: - v2 protocol models (subset of `codex app-server generate-ts` output)
struct RateLimitWindow: Decodable { let usedPercent: Double; let windowDurationMins: Int?; let resetsAt: Int? }
struct CreditsSnapshot: Decodable { let hasCredits: Bool; let unlimited: Bool; let balance: String? }
struct RateLimitSnapshot: Decodable {
    let limitId: String?; let primary: RateLimitWindow?; let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?; let planType: String?; let rateLimitReachedType: String?
}
struct GetAccountRateLimitsResponse: Decodable {
    let ordinaryUsageAllowed: Bool?; let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}
struct Account: Decodable { let type: String; let planType: String? }
struct GetAccountResponse: Decodable { let account: Account?; let requiresOpenaiAuth: Bool }
struct RPCError: Decodable, Error { let code: Int; let message: String }

// MARK: - Binary discovery
enum CodexLocator {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static func isExec(_ p: String) -> Bool { FileManager.default.isExecutableFile(atPath: p) }

    static func versionTuple(_ s: String) -> [Int] {
        s.split(whereSeparator: { !$0.isNumber }).prefix(4).compactMap { Int($0) }
    }

    /// override > PATH-like dirs (GUI apps get a minimal PATH) > editor extensions.
    static func locate(override: String? = ProcessInfo.processInfo.environment["TOKENBAR_CODEX_BIN"]) -> String? {
        if let o = override, isExec(o) { return o }
        let fixed = ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                     "\(home)/.bun/bin/codex", "\(home)/.npm-global/bin/codex",
                     "/Applications/Codex.app/Contents/Resources/codex"]
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        if let hit = (pathDirs + fixed).first(where: isExec) { return hit }
        return editorCandidates().first
    }

    /// Bundled CLI inside the ChatGPT/Codex editor extension; path changes every release.
    static func editorCandidates() -> [String] {
        let fm = FileManager.default
        var found: [(key: [Int], path: String)] = []
        for root in [".vscode", ".vscode-insiders", ".cursor", ".windsurf", ".vscode-oss"].map({ "\(home)/\($0)/extensions" }) {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            var obsolete = Set<String>()
            if let d = fm.contents(atPath: "\(root)/.obsolete"),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { obsolete = Set(o.keys) }
            var active = Set<String>()
            if let d = fm.contents(atPath: "\(root)/extensions.json"),
               let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
                for e in arr where ((e["identifier"] as? [String: Any])?["id"] as? String)?.lowercased() == "openai.chatgpt" {
                    if let p = (e["location"] as? [String: Any])?["path"] as? String { active.insert(p) }
                }
            }
            for dir in entries where dir.hasPrefix("openai.chatgpt-") && !obsolete.contains(dir) {
                let binRoot = "\(root)/\(dir)/bin"
                guard let plats = try? fm.contentsOfDirectory(atPath: binRoot) else { continue }
                for plat in plats.sorted(by: { a, _ in a.contains("aarch64") }) {   // prefer native arm64
                    let exe = "\(binRoot)/\(plat)/codex"
                    guard isExec(exe) else { continue }
                    var cli = ""
                    if let d = fm.contents(atPath: "\(binRoot)/\(plat)/codex-package.json"),
                       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { cli = o["version"] as? String ?? "" }
                    let isActive = active.contains("\(root)/\(dir)") ? 1 : 0
                    let extVer = versionTuple(String(dir.dropFirst("openai.chatgpt-".count)))
                    found.append(([isActive] + versionTuple(cli) + [-1] + extVer, exe))
                }
            }
        }
        return found.sorted { $0.key.lexicographicallyPrecedes($1.key) }.reversed().map(\.path)
    }
}

// MARK: - Minimal JSON-RPC client over the child's stdio
final class AppServerClient: @unchecked Sendable {
    private let proc = Process()
    private let stdin = Pipe(), stdout = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var waiters: [Int: (Result<Data, Error>) -> Void] = [:]
    private var nextId = 0

    init(binary: String, codexHome: String? = nil) throws {
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["-c", "memories.generate_memories=false", "-c", "memories.use_memories=false",
                          "app-server", "--listen", "stdio://"]
        var env = ProcessInfo.processInfo.environment
        env["RUST_LOG"] = "error"
        if let h = codexHome { env["CODEX_HOME"] = h }
        proc.environment = env
        proc.standardInput = stdin; proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in self?.ingest(h.availableData) }
        try proc.run()
    }

    private func ingest(_ chunk: Data) {
        lock.lock(); buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["method"] == nil, let id = obj["id"] as? Int else { continue }   // skip notifications
            lock.lock(); let w = waiters.removeValue(forKey: id); lock.unlock()
            if let err = obj["error"], let d = try? JSONSerialization.data(withJSONObject: err),
               let e = try? JSONDecoder().decode(RPCError.self, from: d) { w?(.failure(e)); continue }
            let result = (try? JSONSerialization.data(withJSONObject: obj["result"] ?? NSNull(), options: .fragmentsAllowed)) ?? Data()
            w?(.success(result))
        }
    }

    private func send(_ obj: [String: Any]) throws {
        var d = try JSONSerialization.data(withJSONObject: obj); d.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: d)
    }

    func notify(_ method: String) throws { try send(["method": method]) }

    func request<T: Decodable>(_ method: String, _ params: [String: Any]?, as: T.Type, timeout: TimeInterval = 20) async throws -> T {
        let data: Data = try await withCheckedThrowingContinuation { cont in
            lock.lock(); let id = nextId; nextId += 1; waiters[id] = { cont.resume(with: $0) }; lock.unlock()
            var msg: [String: Any] = ["method": method, "id": id]
            if let p = params { msg["params"] = p }
            do { try send(msg) } catch {
                lock.lock(); waiters[id] = nil; lock.unlock(); cont.resume(throwing: error); return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let w = self.waiters.removeValue(forKey: id); self.lock.unlock()
                w?(.failure(RPCError(code: -1, message: "timeout: \(method)")))
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Close stdin (server exits on EOF), then escalate if it lingers.
    func shutdown() {
        try? stdin.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(3)
        while proc.isRunning && Date() < deadline { usleep(20_000) }
        if proc.isRunning { proc.terminate() }
        stdout.fileHandleForReading.readabilityHandler = nil
    }
}

// MARK: - main
struct InitializeResponse: Decodable { let userAgent: String; let codexHome: String }

func fmt(_ w: RateLimitWindow?) -> String {
    guard let w else { return "n/a" }
    let reset = w.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    let mins = reset.map { Int($0.timeIntervalSinceNow / 60) }
    return String(format: "%.0f%% used of %@-min window, resets in %@ min",
                  w.usedPercent, w.windowDurationMins.map(String.init) ?? "?", mins.map(String.init) ?? "?")
}

guard let bin = CodexLocator.locate() else { print("codex binary not found"); exit(2) }
print("binary:", bin)
let t0 = Date()
do {
    let client = try AppServerClient(binary: bin, codexHome: CommandLine.arguments.dropFirst().first)
    defer { client.shutdown() }
    let initResp = try await client.request("initialize",
        ["clientInfo": ["name": "tokenbar", "title": "TokenBar", "version": "0.0.1"],
         "capabilities": ["experimentalApi": false]], as: InitializeResponse.self)
    try client.notify("initialized")
    print("codexHome:", initResp.codexHome, "| userAgent:", initResp.userAgent)
    async let acct = client.request("account/read", ["refreshToken": false], as: GetAccountResponse.self)
    async let rl = client.request("account/rateLimits/read", ["excludeResetCreditDetails": true], as: GetAccountRateLimitsResponse.self)
    let (a, r) = try await (acct, rl)
    print("account:", a.account?.type ?? "none", "plan:", a.account?.planType ?? "-", "requiresOpenaiAuth:", a.requiresOpenaiAuth)
    let s = r.rateLimitsByLimitId?["codex"] ?? r.rateLimits
    print("limitId:", s.limitId ?? "-", "| plan:", s.planType ?? "-", "| ordinaryUsageAllowed:", r.ordinaryUsageAllowed.map { "\($0)" } ?? "nil")
    print("primary  :", fmt(s.primary))
    print("secondary:", fmt(s.secondary))
    print("credits  :", s.credits.map { "hasCredits=\($0.hasCredits) unlimited=\($0.unlimited) balance=\($0.balance ?? "-")" } ?? "n/a")
    print(String(format: "elapsed: %.0f ms", Date().timeIntervalSince(t0) * 1000))
} catch {
    print("error:", error)
    exit(1)
}
