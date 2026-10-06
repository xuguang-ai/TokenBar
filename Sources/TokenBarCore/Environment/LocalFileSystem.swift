import Darwin
import Foundation

/// The real `FileSystemAccess`. Tests use it too, always inside a per-test temp dir.
public struct LocalFileSystem: FileSystemAccess {
    public init() {}

    public func readFile(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func readFilePrefix(_ url: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: maxBytes) ?? Data()
    }

    public func readFileTail(_ url: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try handle.seek(toOffset: start)
        return try handle.readToEnd() ?? Data()
    }

    public func writeFileAtomically(_ data: Data, to url: URL, permissions: UInt16) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(permissions))
        guard fd >= 0 else { throw Self.posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temp.path, url.path) == 0 else { throw Self.posixError() }
        } catch {
            unlink(temp.path)
            throw error
        }
        guard chmod(url.path, mode_t(permissions)) == 0 else { throw Self.posixError() }
    }

    public func createDirectory(_ url: URL, permissions: UInt16) throws {
        var missing: [URL] = []
        var current = url.standardizedFileURL
        while !fileExists(current) {
            missing.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        for directory in missing.reversed() {
            if mkdir(directory.path, mode_t(permissions)) != 0, errno != EEXIST { throw Self.posixError() }
            guard chmod(directory.path, mode_t(permissions)) == 0 else { throw Self.posixError() }
        }
    }

    public func setPermissions(_ url: URL, _ permissions: UInt16) throws {
        guard chmod(url.path, mode_t(permissions)) == 0 else { throw Self.posixError() }
    }

    public func contentsOfDirectory(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
    }

    public func stat(_ url: URL) -> FileStat? {
        var info = Darwin.stat()
        // fstatat, because `Darwin.stat(path, &buf)` resolves to the `stat` struct initializer.
        guard fstatat(AT_FDCWD, url.path, &info, 0) == 0 else { return nil }
        return Self.fileStat(info)
    }

    public func lstat(_ url: URL) -> FileStat? {
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else { return nil }
        return Self.fileStat(info)
    }

    public func realpath(_ url: URL) -> URL? {
        guard let resolved = Darwin.realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    public func fileExists(_ url: URL) -> Bool {
        lstat(url) != nil
    }

    public func moveItem(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else { throw Self.posixError() }
    }

    public func removeItem(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func withExclusiveLock<T>(_ lockFile: URL, _ body: () throws -> T) throws -> T {
        let fd = open(lockFile.path, O_RDWR | O_CREAT, mode_t(0o600))
        guard fd >= 0 else { throw Self.posixError() }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw Self.posixError() }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    // MARK: - Helpers

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func date(_ spec: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1_000_000_000)
    }

    private static func fileStat(_ info: Darwin.stat) -> FileStat {
        let type = info.st_mode & S_IFMT
        return FileStat(
            device: UInt64(bitPattern: Int64(info.st_dev)),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modificationTime: date(info.st_mtimespec),
            changeTime: date(info.st_ctimespec),
            isRegularFile: type == S_IFREG,
            isDirectory: type == S_IFDIR,
            isSymlink: type == S_IFLNK,
            permissions: UInt16(info.st_mode & 0o7777),
            isExecutable: info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0)
    }
}
