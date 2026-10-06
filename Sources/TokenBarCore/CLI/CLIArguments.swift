import Foundation

/// Process exit codes (spec §7).
public enum CLIExitCode {
    /// Every selected account refreshed (a warning still counts as success).
    public static let success: Int32 = 0
    /// At least one account failed; whatever data could be obtained is still printed.
    public static let accountFailed: Int32 = 1
    /// Configuration or usage error.
    public static let usage: Int32 = 2
}

public struct CLIOptions: Sendable, Equatable {
    public var json: Bool
    /// `--account` values in the order given. Empty means "every enabled account".
    public var accounts: [String]
    public var allowClaudeRefresh: Bool

    public init(json: Bool = false, accounts: [String] = [], allowClaudeRefresh: Bool = false) {
        self.json = json
        self.accounts = accounts
        self.allowClaudeRefresh = allowClaudeRefresh
    }
}

public enum CLICommand: Sendable, Equatable {
    case help
    case version
    case status(CLIOptions)
    case sessions(CLIOptions)
}

/// A usage or configuration problem. `message` is printed on stderr and the process exits 2.
public struct CLIUsageError: Error, Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

public enum CLIArguments {
    public static let helpText = """
        Usage: tokenbar <command> [options]

        Commands:
          status      Refresh and show usage for each account
          sessions    List running Claude Code sessions by account

        Options:
          --json                   Print JSON instead of a table
          --account <name>         Only this account (display name, case-insensitive; repeatable)
          --allow-claude-refresh   status: let Claude Code refresh a dedicated login's token (step 2).
                                   Off by default: Ctrl-C could interrupt Claude Code mid-refresh.
          -h, --help               Show this help
          -V, --version            Show the version

        Exit codes: 0 all accounts succeeded, 1 at least one account failed, 2 configuration or usage error.

        """

    /// Parses the arguments after the executable name.
    public static func parse(_ arguments: [String]) -> Result<CLICommand, CLIUsageError> {
        if arguments.first == "help" || arguments.contains(where: { $0 == "-h" || $0 == "--help" }) {
            return .success(.help)
        }
        if arguments.contains(where: { $0 == "-V" || $0 == "--version" }) {
            return .success(.version)
        }
        guard let subcommand = arguments.first else { return .success(.help) }
        guard subcommand == "status" || subcommand == "sessions" else {
            return .failure(CLIUsageError("unknown command '\(printable(subcommand))'. Run 'tokenbar --help'."))
        }

        var options = CLIOptions()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "--json":
                options.json = true
            case "--allow-claude-refresh":
                guard subcommand == "status" else {
                    return .failure(CLIUsageError("--allow-claude-refresh only applies to 'status'."))
                }
                options.allowClaudeRefresh = true
            case "--account":
                guard index < arguments.count else {
                    return .failure(CLIUsageError("--account needs a name."))
                }
                options.accounts.append(arguments[index])
                index += 1
            default:
                if argument.hasPrefix("--account=") {
                    options.accounts.append(String(argument.dropFirst("--account=".count)))
                } else {
                    return .failure(CLIUsageError("unknown option '\(printable(argument))'. Run 'tokenbar --help'."))
                }
            }
        }
        if options.accounts.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return .failure(CLIUsageError("--account needs a name."))
        }
        return .success(subcommand == "status" ? .status(options) : .sessions(options))
    }

    /// Accounts to work on: every enabled account, or exactly the `--account` ones (in settings order).
    /// An explicitly named account is used even when it is disabled. Unknown names are a usage error
    /// that lists the valid names.
    public static func selectAccounts(_ names: [String], in settings: AppSettings) -> Result<[AccountConfig], CLIUsageError> {
        guard !names.isEmpty else { return .success(settings.accounts.filter(\.isEnabled)) }
        var wanted = Set<UUID>()
        var unknown: [String] = []
        for name in names {
            let key = normalized(name)
            let matches = settings.accounts.filter { normalized($0.displayName) == key }
            if matches.isEmpty { unknown.append(name) }
            wanted.formUnion(matches.map(\.id))
        }
        guard unknown.isEmpty else {
            let valid = settings.accounts.map { "'\(printable($0.displayName))'" }
            let list = valid.isEmpty ? "(none configured)" : valid.joined(separator: ", ")
            let names = unknown.map { "'\(printable($0))'" }.joined(separator: ", ")
            return .failure(CLIUsageError("unknown account \(names). Valid names: \(list)."))
        }
        return .success(settings.accounts.filter { wanted.contains($0.id) })
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func printable(_ text: String) -> String { CLIFormat.printable(text) }
}
