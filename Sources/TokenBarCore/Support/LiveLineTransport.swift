import Darwin
import Foundation
import os

/// Line-based stdio to a long-running child (`codex app-server`, spec §5.4 step 3).
public final class LiveLineTransport: LineTransport, @unchecked Sendable {
    private struct State {
        var pending: [UInt8] = []
        var finished = false
        var stderrTail = Data()
    }

    /// How much of the child's stderr is kept in memory (for launch-failure classification only).
    static let stderrTailLimit = 8 * 1024

    public let incoming: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let child: LiveChildProcess
    private let writer: LiveFDWriter
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let maxLineBytes: Int
    private var readers: [LiveFDReader] = []

    public var pid: Int32 { child.pid }

    private init(child: LiveChildProcess, writer: LiveFDWriter, maxLineBytes: Int) {
        self.child = child
        self.writer = writer
        self.maxLineBytes = max(1, maxLineBytes)
        (incoming, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    }

    static func start(_ request: ProcessRequest) throws -> LiveLineTransport {
        let input = try LivePosixSpawn.makePipe()
        var opened = [input.read, input.write]
        do {
            let output = try LivePosixSpawn.makePipe()
            opened += [output.read, output.write]
            let errors = try LivePosixSpawn.makePipe()
            opened += [errors.read, errors.write]
            let pid = try LivePosixSpawn.spawn(
                request, stdin: input.read, stdout: output.write, stderr: errors.write, newProcessGroup: false)
            close(input.read)
            close(output.write)
            close(errors.write)

            let transport = LiveLineTransport(
                child: LiveChildProcess(pid: pid),
                writer: LiveFDWriter(fd: input.write, label: "tokenbar.stream.stdin"),
                maxLineBytes: request.maxOutputBytes)
            let outReader = LiveFDReader(
                fd: output.read, label: "tokenbar.stream.stdout",
                onData: { [weak transport] in transport?.receive($0) },
                onEOF: { [weak transport] in transport?.finish(.serverExited) })
            let errReader = LiveFDReader(
                fd: errors.read, label: "tokenbar.stream.stderr",
                onData: { [weak transport] in transport?.receiveStderr($0) },
                onEOF: {})
            transport.readers = [outReader, errReader]
            outReader.start()
            errReader.start()
            transport.child.onExit { [weak transport] _ in
                // A grandchild may hold stdout open; give the pipe a short grace, then report the exit.
                guard let strong = transport else { return }
                LiveTimers.schedule(after: LiveProcessRunner.eofGrace) { [weak strong] in strong?.finish(.serverExited) }
            }
            return transport
        } catch {
            opened.forEach { close($0) }
            throw error
        }
    }

    deinit {
        writer.close()
        readers.forEach { $0.cancel() }
        continuation.finish(throwing: ProviderError.protocolError(.serverExited))
        if !child.hasExited { child.terminateThenKill() }
    }

    /// Throws `POSIXError` (EPIPE once the child is gone) instead of raising SIGPIPE.
    public func send(_ line: Data) async throws {
        var data = line
        data.append(0x0A)
        let failure: Int32? = await withCheckedContinuation { continuation in
            writer.write(data) { continuation.resume(returning: $0) }
        }
        if let failure { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EPIPE) }
    }

    public func closeInput() async {
        writer.close()
    }

    /// SIGTERM, then SIGKILL after 2 s. Returns once the child is gone (or after the SIGKILL wait).
    public func terminate() async {
        writer.close()
        child.signal(SIGTERM)
        if await child.waitForExit(timeout: LiveProcessRunner.killGrace) == nil {
            child.signal(SIGKILL)
            _ = await child.waitForExit(timeout: LiveProcessRunner.killGrace)
        }
        finish(.serverExited)
    }

    /// The last few KB of the child's stderr. Parse it in place; never log or store it (spec §9.3).
    public func recentStderr() -> Data {
        state.withLockUnchecked { $0.stderrTail }
    }

    private func receive(_ data: Data) {
        let (lines, overflow) = state.withLockUnchecked { state -> ([Data], Bool) in
            guard !state.finished else { return ([], false) }
            var lines: [Data] = []
            state.pending.append(contentsOf: data)
            while let newline = state.pending.firstIndex(of: 0x0A) {
                lines.append(Data(state.pending[..<newline]))
                state.pending.removeSubrange(...newline)
            }
            return (lines, state.pending.count > maxLineBytes)
        }
        for line in lines { continuation.yield(line) }
        if overflow {
            finish(.malformedResponse)
            child.terminateThenKill()
        }
    }

    private func receiveStderr(_ data: Data) {
        state.withLockUnchecked { state in
            state.stderrTail.append(data)
            if state.stderrTail.count > Self.stderrTailLimit {
                state.stderrTail = Data(state.stderrTail.suffix(Self.stderrTailLimit))
            }
        }
    }

    /// Flushes a trailing partial line (EOF only) and finishes the stream exactly once.
    private func finish(_ code: ProtocolErrorCode) {
        let trailing: Data?? = state.withLockUnchecked { state in
            guard !state.finished else { return nil }
            state.finished = true
            defer { state.pending = [] }
            return .some(code == .serverExited && !state.pending.isEmpty ? Data(state.pending) : nil)
        }
        guard let trailing else { return }
        if let trailing { continuation.yield(trailing) }
        continuation.finish(throwing: ProviderError.protocolError(code))
    }
}
