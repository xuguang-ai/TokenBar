import Darwin
import Foundation
import TokenBarCore

// A closed pipe (`tokenbar status | head -1`) must not kill the process; writes just fail with EPIPE.
signal(SIGPIPE, SIG_IGN)

/// Writes with stdio, which reports EPIPE as an error instead of raising like `FileHandle.write(_:)`.
func cliWrite(_ text: String, to stream: UnsafeMutablePointer<FILE>) {
    guard !text.isEmpty else { return }
    fputs(text, stream)
    fflush(stream)
}

let cliResult = await CLIRunner.run(arguments: Array(CommandLine.arguments.dropFirst()),
                                    makeRuntime: { TokenBarRuntime.live() })
cliWrite(cliResult.stdout, to: stdout)
cliWrite(cliResult.stderr, to: stderr)
exit(cliResult.exitCode)
