import Darwin
import Foundation
import Testing
@testable import TokenBarCore

/// Real children, limited to /bin/sh, /bin/echo, /bin/cat, /bin/sleep and /usr/bin/env.
@Suite("LiveProcessRunner")
struct LiveProcessRunnerTests {
    private let runner = LiveProcessRunner()
    private static let env = ["PATH": "/usr/bin:/bin", "HOME": "/tmp"]

    private static func request(
        _ path: String, _ arguments: [String] = [], stdin: Data? = nil, timeout: Duration = .seconds(10),
        environment: [String: String] = env, maxOutputBytes: Int = 4 << 20
    ) -> ProcessRequest {
        ProcessRequest(
            executable: URL(fileURLWithPath: path), arguments: arguments, environment: environment,
            stdin: stdin, timeout: timeout, maxOutputBytes: maxOutputBytes)
    }

    private static func elapsed(_ body: () async throws -> Void) async rethrows -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        try await body()
        return clock.now - start
    }

    @Test func capturesStdoutAndStderr() async throws {
        let result = try await runner.run(Self.request("/bin/sh", ["-c", "/bin/echo out; /bin/echo err 1>&2"]))
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
        #expect(!result.pipesTruncated)
        #expect(!result.terminatedBySignal)
    }

    @Test func reportsExitCode() async throws {
        let result = try await runner.run(Self.request("/bin/sh", ["-c", "exit 7"]))
        #expect(result.exitCode == 7)
        #expect(!result.terminatedBySignal)
    }

    @Test func writesStdinThenClosesIt() async throws {
        let result = try await runner.run(Self.request("/bin/cat", stdin: Data("piped\n".utf8)))
        #expect(String(decoding: result.stdout, as: UTF8.self) == "piped\n")
        #expect(result.exitCode == 0)
    }

    @Test func capsOutput() async throws {
        let result = try await runner.run(
            Self.request("/bin/sh", ["-c", "/bin/echo 0123456789"], maxOutputBytes: 4))
        #expect(result.stdout == Data("0123".utf8))
    }

    @Test func passesExactlyTheGivenEnvironment() async throws {
        let environment = ["ONLY_THIS": "1", "PATH": "/usr/bin:/bin"]
        let result = try await runner.run(Self.request("/usr/bin/env", environment: environment))
        let lines = Set(String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init))
        #expect(lines == ["ONLY_THIS=1", "PATH=/usr/bin:/bin"])
    }

    @Test func missingExecutableThrowsNotFound() async {
        await #expect(throws: ProcessLaunchError.notFound) {
            _ = try await runner.run(Self.request("/nonexistent/tokenbar-binary"))
        }
    }

    @Test func nonExecutableThrows() async throws {
        let temp = try TempDir()
        let file = try temp.write("plain.txt", "x", permissions: 0o644)
        await #expect(throws: ProcessLaunchError.notExecutable) {
            _ = try await runner.run(Self.request(file.path))
        }
    }

    @Test func timeoutKillsTheChild() async throws {
        var result: ProcessResult?
        let took = try await Self.elapsed {
            result = try await runner.run(Self.request("/bin/sleep", ["30"], timeout: .seconds(1)))
        }
        let value = try #require(result)
        #expect(value.timedOut)
        #expect(value.terminatedBySignal)
        #expect(value.exitCode == SIGTERM)
        #expect(took < .seconds(6))
    }

    @Test func grandchildHoldingStdoutDoesNotBlock() async throws {
        var result: ProcessResult?
        let took = try await Self.elapsed {
            result = try await runner.run(
                Self.request("/bin/sh", ["-c", "/bin/sleep 30 & /bin/echo started; exit 0"], timeout: .seconds(20)))
        }
        let value = try #require(result)
        #expect(value.exitCode == 0)
        #expect(value.pipesTruncated)
        #expect(!value.timedOut)
        #expect(String(decoding: value.stdout, as: UTF8.self) == "started\n")
        #expect(took < .seconds(5))
    }

    @Test func cancellationKillsTheChildAndThrows() async throws {
        let runner = self.runner
        let task = Task {
            try await runner.run(Self.request("/bin/sleep", ["30"], timeout: .seconds(60)))
        }
        try await Task.sleep(for: .milliseconds(300))
        let took = await Self.elapsed {
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
        #expect(took < .seconds(4))
    }

    @Test func streamingEchoesLinesAndFinishesOnEOF() async throws {
        let transport = try await runner.startStreaming(Self.request("/bin/cat"))
        #expect(transport.pid > 0)
        try await transport.send(Data("hello".utf8))
        try await transport.send(Data("world".utf8))
        var iterator = transport.incoming.makeAsyncIterator()
        #expect(try await iterator.next() == Data("hello".utf8))
        #expect(try await iterator.next() == Data("world".utf8))
        await transport.closeInput()
        await #expect(throws: ProviderError.protocolError(.serverExited)) {
            _ = try await iterator.next()
        }
    }

    @Test func sendAfterExitThrowsInsteadOfSIGPIPE() async throws {
        let transport = try await runner.startStreaming(Self.request("/bin/sh", ["-c", "exit 0"]))
        do {
            for try await _ in transport.incoming {}
        } catch {
            #expect(error as? ProviderError == .protocolError(.serverExited))
        }
        await #expect(throws: POSIXError.self) {
            try await transport.send(Data("late".utf8))
        }
    }

    @Test func terminateStopsAStreamingChild() async throws {
        let transport = try await runner.startStreaming(Self.request("/bin/sleep", ["30"]))
        let pid = transport.pid
        let took = await Self.elapsed { await transport.terminate() }
        #expect(took < .seconds(3))
        #expect(LiveProcessInspector().isAlive(pid: pid) == false)
    }

    @Test func detachedChildReportsItsExit() async throws {
        let child = try await runner.spawnDetached(Self.request("/bin/sleep", ["1"]))
        #expect(getpgid(child.pid) == child.pid)  // its own process group
        #expect(await child.waitForExit(timeout: .seconds(10)) == 0)
    }

    @Test func detachedWaitTimesOutWithoutKilling() async throws {
        let child = try await runner.spawnDetached(Self.request("/bin/sleep", ["2"]))
        #expect(await child.waitForExit(timeout: .milliseconds(200)) == nil)
        #expect(kill(child.pid, 0) == 0)
        // It finishes on its own and is reaped; a later wait sees the exit.
        #expect(await child.waitForExit(timeout: .seconds(10)) == 0)
        #expect(kill(child.pid, 0) == -1)  // reaped: no zombie left
    }

    @Test func detachedChildUsesDevNullAndExactEnvironment() async throws {
        let temp = try TempDir()
        let marker = temp.url.appendingPathComponent("env.txt")
        let child = try await runner.spawnDetached(Self.request(
            "/bin/sh", ["-c", "/usr/bin/env > \"$OUT\"; read line; /bin/echo \"rc=$?\" >> \"$OUT\""],
            environment: ["OUT": marker.path]))
        #expect(await child.waitForExit(timeout: .seconds(10)) == 0)
        let lines = String(decoding: try Data(contentsOf: marker), as: UTF8.self).split(separator: "\n")
        #expect(lines.contains("OUT=\(marker.path)"[...]))
        #expect(lines.contains("rc=1"))  // stdin is /dev/null: `read` hits EOF at once
    }

    @Test func waitStatusDecoding() {
        #expect(LiveWaitStatus.decode(0x0300) == (3, false))
        #expect(LiveWaitStatus.decode(SIGKILL) == (SIGKILL, true))
        #expect(LiveWaitStatus.shellStatus(SIGTERM) == 128 + SIGTERM)
    }
}
