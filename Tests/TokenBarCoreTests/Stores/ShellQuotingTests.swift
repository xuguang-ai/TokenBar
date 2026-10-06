import Foundation
import Testing
@testable import TokenBarCore

@Suite("StoresShellQuoting")
struct StoresShellQuotingTests {
    /// POSIX sh word splitting for the subset `ShellQuoting` emits: single-quoted spans and
    /// backslash escapes outside quotes. Lets the tests check round trips without running a shell.
    private static func shellWords(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var inQuotes = false
        var escaping = false
        for ch in line {
            if inQuotes {
                if ch == "'" { inQuotes = false } else { current.append(ch) }
            } else if escaping {
                current.append(ch)
                escaping = false
            } else if ch == "\\" {
                escaping = true
                inWord = true
            } else if ch == "'" {
                inQuotes = true
                inWord = true
            } else if ch == " " {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(ch)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    @Test(arguments: [
        "plain",
        "",
        "with space",
        "it's",
        "''",
        "line1\nline2",
        "$(rm -rf ~) `id` $HOME",
        "caf\u{E9} \u{1F600} \u{4E2D}\u{6587}",
        "back\\slash \"dq\"",
    ])
    func quoteRoundTrips(_ value: String) {
        let quoted = ShellQuoting.quote(value)
        #expect(quoted.hasPrefix("'"))
        #expect(quoted.hasSuffix("'"))
        #expect(Self.shellWords(quoted) == [value])
    }

    @Test func quoteEscapesSingleQuote() {
        #expect(ShellQuoting.quote("it's") == "'it'\\''s'")
        #expect(ShellQuoting.quote("a b") == "'a b'")
        #expect(ShellQuoting.quote("") == "''")
    }

    @Test func claudeLoginCommandIsExact() {
        let command = ShellQuoting.claudeLoginCommand(
            configDir: "/Users/me/.tokenbar/claude/work",
            claudePath: "/Users/me/.local/share/claude/versions/2.1.300")
        #expect(command == "env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_CUSTOM_OAUTH_URL "
            + "CLAUDE_CONFIG_DIR='/Users/me/.tokenbar/claude/work' "
            + "'/Users/me/.local/share/claude/versions/2.1.300' auth login")
    }

    @Test func claudeLoginCommandQuotesHostileValues() {
        let dir = "/tmp/it's $(id)\nx"
        let path = "/Apps/My Claude/claude"
        let command = ShellQuoting.claudeLoginCommand(configDir: dir, claudePath: path)
        #expect(Self.shellWords(command) == [
            "env", "-u", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "-u", "CLAUDE_CODE_CUSTOM_OAUTH_URL",
            "CLAUDE_CONFIG_DIR=" + dir, path, "auth", "login",
        ])
    }

    @Test func codexLoginCommandWithHome() {
        #expect(ShellQuoting.codexLoginCommand(home: "/Users/me/.codex-work", codexPath: "/opt/homebrew/bin/codex")
            == "CODEX_HOME='/Users/me/.codex-work' '/opt/homebrew/bin/codex' login")
        let hostile = "/x/it's here"
        #expect(Self.shellWords(ShellQuoting.codexLoginCommand(home: hostile, codexPath: "/c x"))
            == ["CODEX_HOME=" + hostile, "/c x", "login"])
    }

    @Test func codexLoginCommandWithoutHome() {
        #expect(ShellQuoting.codexLoginCommand(home: nil, codexPath: "/opt/homebrew/bin/codex")
            == "'/opt/homebrew/bin/codex' login")
    }

    @Test(arguments: [
        ("Work", "work"),
        ("My Work Account", "my-work-account"),
        ("  --Hello__World!!  ", "hello-world"),
        ("Caf\u{E9} \u{C9}t\u{E9}", "cafe-ete"),
        ("abc123", "abc123"),
        ("a-b", "a-b"),
        ("x", "x"),
        ("\u{4E2D}\u{6587} team", "team"),
        (String(repeating: "a", count: 40), String(repeating: "a", count: 32)),
        (String(repeating: "a", count: 31) + " b", String(repeating: "a", count: 31)),
    ])
    func slugValid(_ input: String, _ expected: String) {
        #expect(ShellQuoting.slug(from: input) == expected)
    }

    @Test(arguments: ["", "   ", "---", "!!!", "\u{4E2D}\u{6587}", "\u{1F600}", "../.."])
    func slugRejects(_ input: String) {
        #expect(ShellQuoting.slug(from: input) == nil)
    }

    @Test func slugOutputAlwaysMatchesPattern() {
        for input in ["A.B.C", "x/y\\z", "Tab\there", "Ünïcödé", "a b c d e f g h i j k l m n o p q r s t"] {
            guard let slug = ShellQuoting.slug(from: input) else { continue }
            #expect((1...32).contains(slug.count))
            #expect(slug.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
            #expect(!slug.hasPrefix("-") && !slug.hasSuffix("-"))
        }
    }
}
