import Foundation
import os

/// Finds verified claude (spec §5.3.2) and codex (spec §5.4 step 1) binaries.
///
/// Every candidate is resolved to its realpath, must be a regular Mach-O file with an execute bit, and must
/// pass the Team ID signature check. claude is never executed; codex may be run with `--version` only after
/// its signature has been verified. Verification results are cached by
/// (realpath, dev, ino, size, mtime, ctime), and the chosen file is stat'ed again right before it is returned.
public final class BinaryLocator: BinaryLocating, @unchecked Sendable {
    public static let minimumClaudeVersion = SemVer(major: 2, minor: 1, patch: 289)
    /// Editor homes whose `extensions` folders may bundle claude or codex.
    public static let editorDirectories = [".vscode", ".vscode-insiders", ".cursor", ".windsurf"]

    private struct CacheKey: Hashable {
        var path: String
        var device: UInt64
        var inode: UInt64
        var size: Int64
        var modificationTime: Date
        var changeTime: Date

        init(path: String, stat: FileStat) {
            self.path = path
            device = stat.device
            inode = stat.inode
            size = stat.size
            modificationTime = stat.modificationTime
            changeTime = stat.changeTime
        }
    }

    private struct CacheEntry {
        var verified: Bool
        /// Result of `codex --version`, once it has been run for this exact file.
        var probedVersion: SemVer??
    }

    private struct RawCandidate {
        var path: URL
        var isOverride: Bool
    }

    private struct Evaluation {
        var candidate: BinaryCandidate
        var key: CacheKey?
        var selectable: Bool
    }

    private let env: CoreEnvironment
    /// Prefix for absolute system locations (`/opt/homebrew`, `/usr/local`, `/Applications`); tests point it
    /// at a temp dir.
    private let systemRoot: URL
    private let cache = OSAllocatedUnfairLock(uncheckedState: [CacheKey: CacheEntry]())

    public convenience init(env: CoreEnvironment) {
        self.init(env: env, systemRoot: URL(fileURLWithPath: "/", isDirectory: true))
    }

    init(env: CoreEnvironment, systemRoot: URL) {
        self.env = env
        self.systemRoot = systemRoot
    }

    // MARK: BinaryLocating

    public func locate(_ kind: BinaryKind, settings: AppSettings) async -> LocatedBinary? {
        if let override = overridePath(kind, settings: settings) {
            // The override always wins, but it must pass the same checks; there is no silent fallback.
            return await finalize(RawCandidate(path: override, isOverride: true), kind: kind, settings: settings)
        }
        var best: (evaluation: Evaluation, raw: RawCandidate)?
        var seen = Set<String>()
        for raw in collect(kind) {
            let evaluation = await evaluate(raw, kind: kind, settings: settings)
            guard evaluation.selectable, let real = evaluation.candidate.realpath,
                  seen.insert(real.path).inserted
            else { continue }
            if let current = best {
                if (evaluation.candidate.version ?? SemVer(major: -1, minor: 0, patch: 0))
                    > (current.evaluation.candidate.version ?? SemVer(major: -1, minor: 0, patch: 0)) {
                    best = (evaluation, raw)
                }
            } else {
                best = (evaluation, raw)
            }
        }
        guard let best else { return nil }
        return await finalize(best.raw, kind: kind, settings: settings, first: best.evaluation)
    }

    public func candidates(_ kind: BinaryKind, settings: AppSettings) async -> [BinaryCandidate] {
        var raws: [RawCandidate] = []
        if let override = overridePath(kind, settings: settings) {
            raws.append(RawCandidate(path: override, isOverride: true))
        }
        raws += collect(kind)
        var result: [BinaryCandidate] = []
        var seen = Set<String>()
        for raw in raws {
            let evaluation = await evaluate(raw, kind: kind, settings: settings)
            if let real = evaluation.candidate.realpath, !seen.insert(real.path).inserted { continue }
            result.append(evaluation.candidate)
        }
        return result
    }

    // MARK: Selection

    /// Re-stats the chosen file; if anything changed since it was verified, evaluates it once more.
    private func finalize(
        _ raw: RawCandidate, kind: BinaryKind, settings: AppSettings, first: Evaluation? = nil
    ) async -> LocatedBinary? {
        var evaluation: Evaluation
        if let first { evaluation = first } else { evaluation = await evaluate(raw, kind: kind, settings: settings) }
        for attempt in 0..<2 {
            guard evaluation.selectable, let real = evaluation.candidate.realpath, let key = evaluation.key else {
                return nil
            }
            if let stat = env.fileSystem.stat(real), CacheKey(path: real.path, stat: stat) == key {
                return LocatedBinary(url: real, version: evaluation.candidate.version, kind: kind, verifiedStat: stat)
            }
            cache.withLockUnchecked { _ = $0.removeValue(forKey: key) }
            if attempt == 0 { evaluation = await evaluate(raw, kind: kind, settings: settings) }
        }
        return nil
    }

    private func overridePath(_ kind: BinaryKind, settings: AppSettings) -> URL? {
        let raw = kind == .claude ? settings.claudeBinaryOverride : settings.codexBinaryOverride
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let expanded = ClaudePaths.expandTilde(trimmed, home: env.homeDirectory)
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded)
    }

    // MARK: Evaluation

    private func evaluate(_ raw: RawCandidate, kind: BinaryKind, settings: AppSettings) async -> Evaluation {
        let fs = env.fileSystem
        func result(_ status: BinaryCandidate.Status, real: URL?, version: SemVer? = nil, key: CacheKey? = nil,
                    selectable: Bool = false) -> Evaluation {
            Evaluation(
                candidate: BinaryCandidate(
                    path: raw.path, realpath: real, version: version, status: status, isOverride: raw.isOverride),
                key: key, selectable: selectable)
        }

        guard var real = fs.realpath(raw.path), var stat = fs.stat(real) else {
            return result(.missing, real: nil)
        }
        if !(stat.isRegularFile && isMachO(real)) {
            // An npm launcher (bin/codex -> codex.js) is never executed; use the vendored native binary.
            guard kind == .codex, let native = npmNativeBinary(forShim: real),
                  let nativeReal = fs.realpath(native), let nativeStat = fs.stat(nativeReal)
            else { return result(.notMachO, real: real) }
            real = nativeReal
            stat = nativeStat
            guard stat.isRegularFile, isMachO(real) else { return result(.notMachO, real: real) }
        }
        guard stat.isExecutable else { return result(.notExecutable, real: real) }

        var version = fileVersion(kind, raw: raw.path, real: real)
        if kind == .claude, let known = version, known < Self.minimumClaudeVersion {
            return result(.versionTooOld, real: real, version: known)
        }

        let key = CacheKey(path: real.path, stat: stat)
        var entry = cache.withLockUnchecked { $0[key] }
        if entry == nil {
            let verified = await env.signatureVerifier.verify(real, teamID: kind.teamID)
            entry = CacheEntry(verified: verified, probedVersion: nil)
            cache.withLockUnchecked { $0[key] = entry }
        }
        guard var entry, entry.verified else { return result(.signatureInvalid, real: real, version: version) }

        if version == nil, kind == .codex {
            // Only reached after the signature check passed (spec §5.4 step 1).
            if let probed = entry.probedVersion {
                version = probed
            } else {
                let probed = await probeCodexVersion(real, settings: settings)
                entry.probedVersion = .some(probed)
                cache.withLockUnchecked { $0[key] = entry }
                version = probed
            }
        }

        guard let version else {
            // Unknown version: listed, but only an explicit override may be used (spec §5.3.2).
            return result(.versionUnknown, real: real, key: key, selectable: raw.isOverride)
        }
        return result(.usable, real: real, version: version, key: key, selectable: true)
    }

    /// Mach-O thin (`FEEDFACF`/`FEEDFACE`) or fat (`CAFEBABE`/`CAFEBABF`) in either byte order. Scripts and
    /// shebang files fail this check.
    private func isMachO(_ url: URL) -> Bool {
        guard let prefix = try? env.fileSystem.readFilePrefix(url, maxBytes: 4), prefix.count == 4 else { return false }
        let bytes = [UInt8](prefix)
        let littleEndian = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let magics: Set<UInt32> = [
            0xFEED_FACF, 0xCFFA_EDFE, 0xFEED_FACE, 0xCEFA_EDFE,
            0xCAFE_BABE, 0xBEBA_FECA, 0xCAFE_BABF, 0xBFBA_FECA,
        ]
        return magics.contains(littleEndian)
    }

    private func probeCodexVersion(_ binary: URL, settings: AppSettings) async -> SemVer? {
        let request = ProcessRequest(
            executable: binary,
            arguments: ["--version"],
            environment: env.childEnvironment(settings: settings),
            timeout: .seconds(5),
            maxOutputBytes: 4096)
        guard let result = try? await env.processRunner.run(request),
              result.exitCode == 0, !result.terminatedBySignal, !result.timedOut
        else { return nil }
        // Parsed in place and discarded (spec §9.3).
        return Self.firstVersion(in: String(decoding: result.stdout, as: UTF8.self))
    }

    static func firstVersion(in text: String) -> SemVer? {
        let pattern = #"\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+|(?:a|b|rc)\d+)?"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return SemVer(String(text[range]))
    }

    // MARK: Versions

    private func fileVersion(_ kind: BinaryKind, raw: URL, real: URL) -> SemVer? {
        switch kind {
        case .claude:
            return Self.claudePathVersion(real) ?? Self.claudePathVersion(raw)
        case .codex:
            return jsonVersion(real.deletingLastPathComponent().appendingPathComponent("codex-package.json"))
                ?? Self.codexExtensionVersion(real) ?? Self.codexExtensionVersion(raw)
                ?? npmPackageVersion(real)
        }
    }

    /// `versions/<ver>` or an `anthropic.claude-code-<ver>-<platform>` folder.
    static func claudePathVersion(_ url: URL) -> SemVer? {
        let components = url.pathComponents
        for (index, component) in components.enumerated() {
            if component == "versions", index + 1 < components.count, let version = SemVer(components[index + 1]) {
                return version
            }
            if let version = extensionFolderVersion(component, prefix: "anthropic.claude-code-") { return version }
        }
        return nil
    }

    static func codexExtensionVersion(_ url: URL) -> SemVer? {
        for component in url.pathComponents {
            if let version = extensionFolderVersion(component, prefix: "openai.chatgpt-") { return version }
        }
        return nil
    }

    /// `<prefix><version>[-<platform>-<arch>]` → version.
    static func extensionFolderVersion(_ name: String, prefix: String) -> SemVer? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = String(name.dropFirst(prefix.count))
        if let match = rest.range(of: #"-(darwin|universal|linux|win32|alpine|web)(-[A-Za-z0-9_]+)?$"#, options: .regularExpression) {
            return SemVer(String(rest[..<match.lowerBound]))
        }
        return SemVer(rest)
    }

    /// The `version` of the outermost `node_modules/@openai/codex/package.json` above `binary`.
    private func npmPackageVersion(_ binary: URL) -> SemVer? {
        guard let package = Self.npmPackageDirectory(binary) else { return nil }
        return jsonVersion(package.appendingPathComponent("package.json"))
    }

    static func npmPackageDirectory(_ url: URL) -> URL? {
        let components = url.pathComponents
        guard components.count >= 3 else { return nil }
        for index in 0..<(components.count - 2)
        where components[index] == "node_modules" && components[index + 1] == "@openai" && components[index + 2] == "codex" {
            return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...(index + 2)])), isDirectory: true)
        }
        return nil
    }

    private func jsonVersion(_ url: URL) -> SemVer? {
        guard let stat = env.fileSystem.stat(url), stat.isRegularFile, stat.size < 1 << 20,
              let data = try? env.fileSystem.readFile(url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String
        else { return nil }
        return SemVer(version)
    }

    // MARK: Candidates

    private static var nativeExtensionPlatform: String {
        #if arch(arm64)
        "darwin-arm64"
        #else
        "darwin-x64"
        #endif
    }

    private static var codexExtensionArchDirectory: String {
        #if arch(arm64)
        "macos-aarch64"
        #else
        "macos-x86_64"
        #endif
    }

    /// `@openai/codex-darwin-<arch>/vendor/<triple>/bin/codex` relative to a `node_modules` dir.
    private static var codexVendorSuffix: String {
        #if arch(arm64)
        "@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
        #else
        "@openai/codex-darwin-x64/vendor/x86_64-apple-darwin/bin/codex"
        #endif
    }

    private func home(_ relative: String) -> URL { env.homeDirectory.appendingPathComponent(relative) }
    private func system(_ relative: String) -> URL { systemRoot.appendingPathComponent(relative) }

    /// Auto-discovered candidates in spec order, existing paths only (the override is handled separately).
    private func collect(_ kind: BinaryKind) -> [RawCandidate] {
        let paths: [URL]
        switch kind {
        case .claude: paths = claudePaths()
        case .codex: paths = codexPaths()
        }
        return paths.filter { env.fileSystem.lstat($0) != nil }.map { RawCandidate(path: $0, isOverride: false) }
    }

    private func claudePaths() -> [URL] {
        var paths: [URL] = []
        let versions = home(".local/share/claude/versions")
        paths += listing(versions).filter { !$0.lastPathComponent.hasPrefix(".") }
        paths += extensionFolders(prefix: "anthropic.claude-code-").map {
            $0.appendingPathComponent("resources/native-binary/claude")
        }
        paths += [system("opt/homebrew/bin/claude"), system("usr/local/bin/claude")]
        return paths
    }

    private func codexPaths() -> [URL] {
        var paths: [URL] = [
            system("opt/homebrew/bin/codex"), system("usr/local/bin/codex"),
            home(".local/bin/codex"), home(".bun/bin/codex"), home(".npm-global/bin/codex"),
        ]
        var prefixes = [home("miniconda3"), home("anaconda3"), system("opt/homebrew"), system("usr/local"), home(".npm-global")]
        prefixes += listing(home(".nvm/versions/node"))
        paths += prefixes.map {
            $0.appendingPathComponent("lib/node_modules/@openai/codex/node_modules").appendingPathComponent(Self.codexVendorSuffix)
        }
        paths += [system("Applications/Codex.app/Contents/Resources/codex"), home("Applications/Codex.app/Contents/Resources/codex")]
        paths += extensionFolders(prefix: "openai.chatgpt-").map {
            $0.appendingPathComponent("bin").appendingPathComponent(Self.codexExtensionArchDirectory).appendingPathComponent("codex")
        }
        return paths
    }

    /// Extension folders with `prefix` in every editor's extensions dir, minus those listed in its `.obsolete`
    /// file (a JSON object keyed by folder name) and those built for another architecture.
    private func extensionFolders(prefix: String) -> [URL] {
        var folders: [URL] = []
        for editor in Self.editorDirectories {
            let extensions = home(editor).appendingPathComponent("extensions", isDirectory: true)
            let obsolete = obsoleteFolders(extensions)
            for folder in listing(extensions) {
                let name = folder.lastPathComponent
                guard name.hasPrefix(prefix), !obsolete.contains(name) else { continue }
                if name.contains("-darwin-"), !name.hasSuffix(Self.nativeExtensionPlatform) { continue }
                folders.append(folder)
            }
        }
        return folders
    }

    private func obsoleteFolders(_ extensions: URL) -> Set<String> {
        let file = extensions.appendingPathComponent(".obsolete")
        guard let stat = env.fileSystem.stat(file), stat.isRegularFile, stat.size < 4 << 20,
              let data = try? env.fileSystem.readFile(file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Set(object.keys)
    }

    private func listing(_ directory: URL) -> [URL] {
        ((try? env.fileSystem.contentsOfDirectory(directory)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// For an npm launcher inside `node_modules/@openai/codex/…`, the vendored native binary, nested or hoisted.
    private func npmNativeBinary(forShim shim: URL) -> URL? {
        guard let package = Self.npmPackageDirectory(shim) else { return nil }
        let nested = package.appendingPathComponent("node_modules").appendingPathComponent(Self.codexVendorSuffix)
        let hoisted = package.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(Self.codexVendorSuffix)
        return [nested, hoisted].first { env.fileSystem.fileExists($0) }
    }
}
