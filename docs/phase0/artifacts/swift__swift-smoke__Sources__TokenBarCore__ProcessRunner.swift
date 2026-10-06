import Foundation
import os

public struct ProcessOutput: Sendable, Equatable {
    public let status: Int32
    public let terminatedBySignal: Bool
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, Sendable, Equatable {
    case launchFailed(String)
    case timedOut(after: Duration)
}

public enum ProcessRunner {
    /// Runs a child process and captures stdout/stderr.
    ///
    /// - Both pipes are drained concurrently via `readabilityHandler` (GCD), so a child that writes
    ///   more than the 64 KB pipe buffer cannot deadlock, and no Swift-concurrency thread is blocked.
    /// - The call completes only after the child exited AND both pipes hit EOF.
    /// - Cancelling the calling Task terminates the child and throws `CancellationError`.
    /// - `timeout` terminates the child and throws `ProcessRunnerError.timedOut`.
    public static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBuffer = OSAllocatedUnfairLock(initialState: Data())
        let errBuffer = OSAllocatedUnfairLock(initialState: Data())
        // .none = still running / finished normally, otherwise why we killed it.
        let killReason = OSAllocatedUnfairLock<KillReason?>(initialState: nil)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, any Error>) in
                let group = DispatchGroup()
                group.enter()  // stdout EOF
                group.enter()  // stderr EOF
                group.enter()  // process exit

                func drain(_ pipe: Pipe, into buffer: OSAllocatedUnfairLock<Data>) {
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {  // EOF
                            handle.readabilityHandler = nil
                            group.leave()
                        } else {
                            buffer.withLock { $0.append(chunk) }
                        }
                    }
                }
                drain(outPipe, into: outBuffer)
                drain(errPipe, into: errBuffer)
                process.terminationHandler = { _ in group.leave() }

                func abandon(_ error: any Error) {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    group.leave(); group.leave(); group.leave()  // keep the group balanced
                    continuation.resume(throwing: error)
                }

                if Task.isCancelled { abandon(CancellationError()); return }
                do {
                    try process.run()
                } catch {
                    abandon(ProcessRunnerError.launchFailed(String(describing: error)))
                    return
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(timeout.nanoseconds)) {
                    if process.isRunning {
                        killReason.withLock { if $0 == nil { $0 = .timeout } }
                        process.terminate()
                    }
                }

                group.notify(queue: .global()) {
                    switch killReason.withLock({ $0 }) {
                    case .timeout?:
                        continuation.resume(throwing: ProcessRunnerError.timedOut(after: timeout))
                    case .cancelled?:
                        continuation.resume(throwing: CancellationError())
                    case nil:
                        continuation.resume(returning: ProcessOutput(
                            status: process.terminationStatus,
                            terminatedBySignal: process.terminationReason == .uncaughtSignal,
                            stdout: outBuffer.withLock { $0 },
                            stderr: errBuffer.withLock { $0 }))
                    }
                }
            }
        } onCancel: {
            killReason.withLock { if $0 == nil { $0 = .cancelled } }
            if process.isRunning { process.terminate() }  // terminate() on a never-launched Process raises
        }
    }

    private enum KillReason: Sendable { case timeout, cancelled }
}

extension Duration {
    var nanoseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000)
    }
}
