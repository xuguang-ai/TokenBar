import Darwin
import Foundation

/// Step ② children (spec §5.3): own process group, stdio on /dev/null, never signalled. The reaper thread
/// inside `LiveChildProcess` collects the exit status whether or not anyone waits, so no zombie remains.
enum LiveDetachedSpawner {
    static func spawn(_ request: ProcessRequest) throws -> LiveDetachedProcess {
        let pid = try LivePosixSpawn.spawn(request, stdin: nil, stdout: nil, stderr: nil, newProcessGroup: true)
        return LiveDetachedProcess(child: LiveChildProcess(pid: pid))
    }
}

public struct LiveDetachedProcess: DetachedProcess {
    let child: LiveChildProcess

    init(child: LiveChildProcess) {
        self.child = child
    }

    public var pid: Int32 { child.pid }

    /// The exit code, or 128 + signal number if the child was killed by a signal (shell convention).
    /// nil when `timeout` elapses first; the child keeps running and is still reaped later.
    public func waitForExit(timeout: Duration) async -> Int32? {
        guard let raw = await child.waitForExit(timeout: timeout) else { return nil }
        return LiveWaitStatus.shellStatus(raw)
    }
}
