import Darwin
import Dispatch
import Foundation
import os

/// The real `ProcessRunning` (spec §5.7). Every child is started with `posix_spawn` and the exact
/// environment from the request; nothing is inherited from TokenBar's own environment or file descriptors.
public struct LiveProcessRunner: ProcessRunning {
    /// How long `run` waits for pipe EOF after the child exited.
    public static let eofGrace: Duration = .seconds(2)
    /// Delay between SIGTERM and SIGKILL.
    public static let killGrace: Duration = .seconds(2)
    /// `run` always returns within `timeout + hardDeadlineSlack`.
    public static let hardDeadlineSlack: Duration = .seconds(5)

    public init() {}

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let operation = LiveOneShotRun(request: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    public func startStreaming(_ request: ProcessRequest) async throws -> any LineTransport {
        try LiveLineTransport.start(request)
    }

    public func spawnDetached(_ request: ProcessRequest) async throws -> any DetachedProcess {
        try LiveDetachedSpawner.spawn(request)
    }
}

// MARK: - Shared timing helpers

enum LiveTimers {
    static let queue = DispatchQueue(label: "tokenbar.process.timers", attributes: .concurrent)

    static func deadline(after duration: Duration) -> DispatchTime {
        let seconds = max(0, min(duration.timeInterval, 10 * 365 * 24 * 3600))
        return .now() + seconds
    }

    @discardableResult
    static func schedule(after duration: Duration, _ body: @escaping @Sendable () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: body)
        queue.asyncAfter(deadline: deadline(after: duration), execute: item)
        return item
    }
}

/// Decodes a raw `waitpid` status (the W* macros are not imported into Swift).
enum LiveWaitStatus {
    /// `(code, signaled)`: the exit code, or the signal number when the child was killed by a signal.
    /// `-1` means the status could not be collected.
    static func decode(_ raw: Int32) -> (code: Int32, signaled: Bool) {
        if raw == -1 { return (-1, false) }
        let low = raw & 0x7f
        if low == 0 { return ((raw >> 8) & 0xff, false) }
        return (low, true)
    }

    /// Shell convention: the exit code, or 128 + signal number.
    static func shellStatus(_ raw: Int32) -> Int32 {
        let (code, signaled) = decode(raw)
        return signaled ? 128 + code : code
    }
}

// MARK: - posix_spawn

enum LivePosixSpawn {
    /// A pipe whose both ends are close-on-exec, so other concurrent spawns never inherit them.
    static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw ProcessLaunchError.spawnFailed(errno: errno) }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    /// Starts `request.executable` with exactly `request.environment`. A nil stdio fd means /dev/null.
    static func spawn(
        _ request: ProcessRequest,
        stdin: Int32?,
        stdout: Int32?,
        stderr: Int32?,
        newProcessGroup: Bool
    ) throws -> pid_t {
        let path = request.executable.path
        var info = stat()
        guard stat(path, &info) == 0 else { throw ProcessLaunchError.notFound }
        guard (info.st_mode & S_IFMT) == S_IFREG, access(path, X_OK) == 0 else {
            throw ProcessLaunchError.notExecutable
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        func route(_ fd: Int32?, to target: Int32, mode: Int32) {
            if let fd {
                posix_spawn_file_actions_adddup2(&actions, fd, target)
            } else {
                posix_spawn_file_actions_addopen(&actions, target, "/dev/null", mode, 0)
            }
        }
        route(stdin, to: STDIN_FILENO, mode: O_RDONLY)
        route(stdout, to: STDOUT_FILENO, mode: O_WRONLY)
        route(stderr, to: STDERR_FILENO, mode: O_WRONLY)
        if let directory = request.currentDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        }

        // CLOEXEC_DEFAULT: the child gets fds 0-2 only. SETSIGDEF/SETSIGMASK: a parent that ignores SIGPIPE
        // (spec §5.4 step 2) must not pass that disposition on to its children.
        var flags = Int32(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        if newProcessGroup {
            flags |= Int32(POSIX_SPAWN_SETPGROUP)
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGINT, SIGQUIT, SIGHUP, SIGTERM, SIGALRM, SIGUSR1, SIGUSR2, SIGCHLD, SIGTTIN, SIGTTOU] {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + request.arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let pairs = request.environment
            .filter { !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }
            .sorted { $0.key < $1.key }
        let envp: [UnsafeMutablePointer<CChar>?] = pairs.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        switch status {
        case 0: return pid
        case ENOENT: throw ProcessLaunchError.notFound
        case EACCES, ENOEXEC, EPERM: throw ProcessLaunchError.notExecutable
        default: throw ProcessLaunchError.spawnFailed(errno: status)
        }
    }
}

// MARK: - Child processes and reaping

/// One spawned child. A dedicated reaper thread waits for it (`waitid` with `WNOWAIT`), then collects the
/// status under the lock, so `signal` can never hit a recycled pid and no zombie is left behind.
final class LiveChildProcess: @unchecked Sendable {
    private struct State {
        var status: Int32?
        var callbacks: [@Sendable (Int32) -> Void] = []
    }

    let pid: pid_t
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(pid: pid_t) {
        self.pid = pid
        let thread = Thread { [self] in self.reaperLoop() }
        thread.name = "tokenbar.reaper"
        thread.stackSize = 1 << 16
        thread.start()
    }

    private func reaperLoop() {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        let callbacks: [@Sendable (Int32) -> Void]
        let status: Int32
        (status, callbacks) = state.withLockUnchecked { state in
            var raw: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &raw, 0) } while result == -1 && errno == EINTR
            state.status = result == pid ? raw : -1
            let pending = state.callbacks
            state.callbacks = []
            return (state.status ?? -1, pending)
        }
        for callback in callbacks { callback(status) }
    }

    /// Raw wait status once the child has been reaped.
    var exitStatus: Int32? { state.withLockUnchecked { $0.status } }
    var hasExited: Bool { exitStatus != nil }

    /// Sends `signal` only while the child has not been reaped (its pid cannot have been reused).
    func signal(_ signal: Int32) {
        state.withLockUnchecked { state in
            if state.status == nil { _ = kill(pid, signal) }
        }
    }

    /// SIGTERM now, SIGKILL after `LiveProcessRunner.killGrace` if the child is still there.
    func terminateThenKill() {
        signal(SIGTERM)
        LiveTimers.schedule(after: LiveProcessRunner.killGrace) { [self] in self.signal(SIGKILL) }
    }

    /// Calls `callback` with the raw status once the child is reaped (at once if it already was).
    func onExit(_ callback: @escaping @Sendable (Int32) -> Void) {
        let status: Int32? = state.withLockUnchecked { state in
            if let status = state.status { return status }
            state.callbacks.append(callback)
            return nil
        }
        if let status { callback(status) }
    }

    /// Raw status, or nil when `timeout` elapses or the task is cancelled. Never signals the child.
    func waitForExit(timeout: Duration) async -> Int32? {
        let gate = LiveResumeGate<Int32?>()
        let timer = LiveTimers.schedule(after: timeout) { gate.resolve(nil) }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                onExit { gate.resolve($0) }
            }
        } onCancel: {
            gate.resolve(nil)
        }
    }
}

/// Resumes a continuation exactly once, whichever of install/resolve comes first.
final class LiveResumeGate<Value: Sendable>: @unchecked Sendable {
    private enum Phase {
        case idle
        case waiting(CheckedContinuation<Value, Never>)
        case resolved(Value)
        case done
    }

    private let phase = OSAllocatedUnfairLock(uncheckedState: Phase.idle)

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        let ready: Value? = phase.withLockUnchecked { phase in
            switch phase {
            case .idle:
                phase = .waiting(continuation)
                return nil
            case .resolved(let value):
                phase = .done
                return value
            case .waiting, .done:
                return nil
            }
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func resolve(_ value: Value) {
        let waiting: CheckedContinuation<Value, Never>? = phase.withLockUnchecked { phase in
            switch phase {
            case .idle:
                phase = .resolved(value)
                return nil
            case .waiting(let continuation):
                phase = .done
                return continuation
            case .resolved, .done:
                return nil
            }
        }
        if let waiting { waiting.resume(returning: value) }
    }
}

// MARK: - File descriptor I/O

/// Reads a pipe on its own serial queue (the dispatch equivalent of `readabilityHandler`). The fd is
/// closed in the cancel handler, so a read can never race with the close.
final class LiveFDReader: @unchecked Sendable {
    private let source: DispatchSourceRead

    init(
        fd: Int32,
        label: String,
        onData: @escaping @Sendable (Data) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let queue = DispatchQueue(label: label)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let capacity = 1 << 16
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        let bufferAddress = Int(bitPattern: buffer)
        source.setEventHandler { [source] in
            guard let buffer = UnsafeMutableRawPointer(bitPattern: bufferAddress) else { return }
            let count = read(fd, buffer, capacity)
            if count > 0 {
                onData(Data(bytes: buffer, count: count))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                source.cancel()
                onEOF()
            }
        }
        source.setCancelHandler {
            close(fd)
            UnsafeMutableRawPointer(bitPattern: bufferAddress)?.deallocate()
        }
        self.source = source
    }

    func start() { source.activate() }

    /// Stops reading and closes the fd. Idempotent; no callbacks follow except one already running.
    func cancel() { source.cancel() }
}

/// Writes to a pipe without ever raising SIGPIPE (`F_SETNOSIGPIPE`). Writes are serialised on one queue.
final class LiveFDWriter: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let closed = OSAllocatedUnfairLock(initialState: false)

    init(fd: Int32, label: String) {
        self.fd = fd
        self.queue = DispatchQueue(label: label)
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    var isClosed: Bool { closed.withLock { $0 } }

    /// Writes all of `data`; `completion` gets nil or the errno that stopped the write.
    func write(_ data: Data, completion: @escaping @Sendable (Int32?) -> Void) {
        queue.async { [self] in
            completion(writeAll(data))
        }
    }

    private func writeAll(_ data: Data) -> Int32? {
        if isClosed { return EPIPE }
        return data.withUnsafeBytes { raw -> Int32? in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                let code = errno
                switch code {
                case EINTR:
                    continue
                case EAGAIN:
                    if isClosed { return EPIPE }
                    var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&poller, 1, 100)
                default:
                    return code
                }
            }
            return nil
        }
    }

    /// Closes the fd after any queued writes. Idempotent.
    func close() {
        let first = closed.withLock { closed in
            defer { closed = true }
            return !closed
        }
        if first { queue.async { [fd] in _ = Darwin.close(fd) } }
    }
}

// MARK: - One-shot run

/// State machine behind `LiveProcessRunner.run`. Every path ends in `complete`, which resumes the
/// continuation exactly once.
final class LiveOneShotRun: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<ProcessResult, any Error>?
        var finished = false
        var cancelled = false
        var timedOut = false
        var child: LiveChildProcess?
        var waitStatus: Int32?
        var stdout = Data()
        var stderr = Data()
        var stdoutEOF = false
        var stderrEOF = false
        var readers: [LiveFDReader] = []
        var writer: LiveFDWriter?
        var timers: [DispatchWorkItem] = []
    }

    private let request: ProcessRequest
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(request: ProcessRequest) {
        self.request = request
    }

    func start(_ continuation: CheckedContinuation<ProcessResult, any Error>) {
        let cancelled = state.withLockUnchecked { state in
            state.continuation = continuation
            return state.cancelled
        }
        if cancelled {
            complete(.failure(CancellationError()))
            return
        }
        do {
            try launch()
        } catch {
            complete(.failure(error))
        }
    }

    func cancel() {
        let (child, exited) = state.withLockUnchecked { state in
            state.cancelled = true
            return (state.child, state.waitStatus != nil)
        }
        if exited {
            complete(.failure(CancellationError()))
        } else {
            child?.terminateThenKill()
        }
    }

    private func launch() throws {
        let output = try LivePosixSpawn.makePipe()
        let errors: (read: Int32, write: Int32)
        do { errors = try LivePosixSpawn.makePipe() } catch {
            close(output.read); close(output.write)
            throw error
        }
        var input: (read: Int32, write: Int32)?
        if request.stdin != nil {
            do { input = try LivePosixSpawn.makePipe() } catch {
                [output.read, output.write, errors.read, errors.write].forEach { close($0) }
                throw error
            }
        }

        let pid: pid_t
        do {
            pid = try LivePosixSpawn.spawn(
                request, stdin: input?.read, stdout: output.write, stderr: errors.write, newProcessGroup: false)
        } catch {
            [output.read, output.write, errors.read, errors.write].forEach { close($0) }
            if let input { close(input.read); close(input.write) }
            throw error
        }
        close(output.write)
        close(errors.write)
        if let input { close(input.read) }

        let child = LiveChildProcess(pid: pid)
        let outReader = LiveFDReader(
            fd: output.read, label: "tokenbar.run.stdout",
            onData: { [weak self] in self?.append($0, stdout: true) },
            onEOF: { [weak self] in self?.reachedEOF(stdout: true) })
        let errReader = LiveFDReader(
            fd: errors.read, label: "tokenbar.run.stderr",
            onData: { [weak self] in self?.append($0, stdout: false) },
            onEOF: { [weak self] in self?.reachedEOF(stdout: false) })
        let writer = input.map { LiveFDWriter(fd: $0.write, label: "tokenbar.run.stdin") }

        let timeout = LiveTimers.schedule(after: request.timeout) { [weak self] in self?.timeoutFired() }
        let hardDeadline = LiveTimers.schedule(after: request.timeout + LiveProcessRunner.hardDeadlineSlack) {
            [weak self] in self?.complete(nil)
        }
        let cancelled = state.withLockUnchecked { state in
            state.child = child
            state.readers = [outReader, errReader]
            state.writer = writer
            state.timers = [timeout, hardDeadline]
            return state.cancelled
        }
        outReader.start()
        errReader.start()
        if let writer, let data = request.stdin {
            writer.write(data) { _ in writer.close() }
        }
        child.onExit { [weak self] in self?.childExited($0) }
        if cancelled { child.terminateThenKill() }
    }

    private func append(_ data: Data, stdout: Bool) {
        let limit = request.maxOutputBytes
        state.withLockUnchecked { state in
            if stdout {
                if state.stdout.count < limit { state.stdout.append(data.prefix(limit - state.stdout.count)) }
            } else {
                if state.stderr.count < limit { state.stderr.append(data.prefix(limit - state.stderr.count)) }
            }
        }
    }

    private func reachedEOF(stdout: Bool) {
        let done = state.withLockUnchecked { state in
            if stdout { state.stdoutEOF = true } else { state.stderrEOF = true }
            return state.waitStatus != nil && state.stdoutEOF && state.stderrEOF
        }
        if done { complete(nil) }
    }

    private func childExited(_ status: Int32) {
        let (cancelled, drained) = state.withLockUnchecked { state in
            state.waitStatus = status
            return (state.cancelled, state.stdoutEOF && state.stderrEOF)
        }
        if cancelled {
            complete(.failure(CancellationError()))
        } else if drained {
            complete(nil)
        } else {
            let grace = LiveTimers.schedule(after: LiveProcessRunner.eofGrace) { [weak self] in self?.complete(nil) }
            let finished = state.withLockUnchecked { state in
                state.timers.append(grace)
                return state.finished
            }
            if finished { grace.cancel() }
        }
    }

    private func timeoutFired() {
        let child: LiveChildProcess? = state.withLockUnchecked { state in
            guard !state.finished, state.waitStatus == nil else { return nil }
            state.timedOut = true
            return state.child
        }
        child?.terminateThenKill()
    }

    /// `outcome == nil` builds the result from what was collected.
    private func complete(_ outcome: Result<ProcessResult, any Error>?) {
        let taken = state.withLockUnchecked { state -> (CheckedContinuation<ProcessResult, any Error>?, Result<ProcessResult, any Error>, [LiveFDReader], LiveFDWriter?, [DispatchWorkItem], LiveChildProcess?)? in
            guard !state.finished, let continuation = state.continuation else { return nil }
            state.finished = true
            let result: Result<ProcessResult, any Error>
            if let outcome {
                result = outcome
            } else if state.cancelled {
                result = .failure(CancellationError())
            } else {
                let (code, signaled) = state.waitStatus.map(LiveWaitStatus.decode) ?? (-1, false)
                result = .success(ProcessResult(
                    exitCode: code,
                    terminatedBySignal: signaled,
                    stdout: state.stdout,
                    stderr: state.stderr,
                    timedOut: state.timedOut || state.waitStatus == nil,
                    pipesTruncated: !(state.stdoutEOF && state.stderrEOF)))
            }
            state.continuation = nil
            state.stdout = Data()
            state.stderr = Data()
            let still = state.waitStatus == nil ? state.child : nil
            return (continuation, result, state.readers, state.writer, state.timers, still)
        }
        guard let (continuation, result, readers, writer, timers, runningChild) = taken else { return }
        readers.forEach { $0.cancel() }
        writer?.close()
        timers.forEach { $0.cancel() }
        // Only reached at the hard deadline: make sure the child does not outlive the call.
        runningChild?.signal(SIGKILL)
        continuation?.resume(with: result)
    }
}
