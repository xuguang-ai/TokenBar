# TokenBar

> **See how much quota every AI coding account has left, at a glance.**

TokenBar is a small tool that lives in the macOS menu bar. It shows:

- the 5-hour quota, weekly quota and per-model weekly limits of several **Claude** accounts and **Codex** (ChatGPT) accounts, each with its reset countdown;
- the **Claude Code sessions** currently running: which are running a task (busy), which are idle, and how long each has been in that state.

You don't need to open a web page or switch accounts, and all credentials stay on this machine. For design details see [docs/superpowers/specs/2026-10-05-tokenbar-mvp-design.md](docs/superpowers/specs/2026-10-05-tokenbar-mvp-design.md); for the feasibility study conclusions see [docs/phase0/findings.md](docs/phase0/findings.md).

## Requirements

- macOS 14 or later (developed and verified on macOS 26)
- Xcode Command Line Tools (Swift 6.2). Full Xcode is not required
- At least one logged-in Claude Code (≥ 2.1.289 can refresh dedicated logins automatically) and/or Codex (the ChatGPT extension for VS Code or the `codex` CLI)

## Build and install

```bash
cd ~/Desktop/TokenBar
scripts/bundle.sh     # release build → dist/TokenBar.app (ad-hoc signed)
scripts/install.sh    # copy to ~/Applications/TokenBar.app and launch (quits the old instance first)
```

All scripts automatically set `DEVELOPER_DIR` to the Command Line Tools. Xcode 27 on this machine has not had its license accepted yet, so running the `swift` command directly fails.

## First use: create a dedicated login for each Claude account

If you switch accounts back and forth with `/login` inside the same `~/.claude`, TokenBar cannot treat `~/.claude` as the data source for any one fixed account. The fix is to create a **TokenBar dedicated login directory** for each account and log in to each once:

1. Click the TokenBar icon in the menu bar → ⚙ → **Accounts** → `+` → **Add Claude dedicated login…**
2. Enter a name, for example `Work`. TokenBar creates `~/.tokenbar/claude/work` (permissions 0700) and gives you a login command:

   ```bash
   env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_CUSTOM_OAUTH_URL CLAUDE_CONFIG_DIR='/Users/<you>/.tokenbar/claude/work' '<claude path>' auth login
   ```

3. Click **Open in Terminal** (or Copy it and paste it into a terminal yourself), and in the browser that opens, log in to the **matching** claude.ai account.
4. Within about 5 seconds TokenBar detects that the login has finished, then adds the account automatically and starts refreshing it.
5. Repeat the steps above for the second account (for example `Personal`). After the first dedicated login is done, TokenBar suggests disabling the default "Claude" card so the same account isn't shown twice.

You keep working in `~/.claude` day to day and switching with `/login`; the two don't interfere. The dedicated directory is only used by TokenBar to read usage; when its token expires, TokenBar runs `claude -p "/usage"` once in the background, and Claude Code performs the refresh itself.

Codex reads `~/.codex` by default and usually needs no configuration.

## Daily use

**Menu bar**

- The menu bar follows the Claude account you are **working in** (the one `~/.claude` is logged in to) and shows its 5-hour window; the icon still turns into a warning when any of that account's limits is nearly used up. Hover it to see which account and window the number is. If no account matches, it shows the tightest percentage across all accounts.
- Settings › General › Display › **Menu bar shows** switches between the active Claude account, the most constrained account, or one fixed account. Percentages show used by default (matching Claude `/usage` and Codex `/status`); switch to remaining in the same section.
- Suffix meanings: `?` means the data is stale or the refresh failed; `!` means the refresh failed and there is no data at all; `–` means there is no data yet.
- **Click** the percentage to open or close the TokenBar window.
- **Right-click** (or Control-click) it for a small menu: Refresh, Settings…, Quit TokenBar.

**The TokenBar window**

Clicking the menu bar item opens a floating window right under it:

- One card per account, with one row per window (5h / Week / Sonnet / model limits); each row has a progress bar, a percentage and the reset time (for example `Wed 11:00 PM`; hover it for the countdown).
- Prefer countdowns (`1d 12h`)? Settings › General › Display › **Reset times** › Countdown. `tokenbar status` follows the same setting.
- Progress bars change color by remaining quota:
  - above 50% is green;
  - 20–50% is yellow;
  - below 20% is orange;
  - below 5% is red.
- When needed, a card gets an extra status line, for example that the data comes from the cache, `Paused until …`, or `Not logged in` (with the login command and a Copy button).
- Under the Claude card, running sessions are listed: busy ones first, idle ones collapsed into a single "N idle ▸" row.
- It stays on top, is visible on all desktops (Spaces), and never steals focus from the app you are using.
- Drag it anywhere; its position is remembered from then on. Until you move it, it opens under the menu bar item.
- Close it by clicking the menu bar item again, or with the ✕ that appears at the top-right when the pointer is over the window.
- If you leave it open when you quit, it opens again at the next launch.

**⚙ Settings**

- **Accounts**:
  - add and remove accounts, rename them, drag to reorder, enable or disable;
  - edit the config directory or `CODEX_HOME`;
  - view the live-detected email and plan.
- **General**:
  - refresh interval (at least 5 minutes for Codex);
  - show remaining or used;
  - show reset times as clock times (`Wed 11:00 PM`, default) or countdowns (`1d 12h`);
  - launch at login (requires the app to be in `~/Applications` or `/Applications`);
  - whether Claude Code is allowed to refresh dedicated logins;
  - manually specify the claude/codex paths;
  - the proxy used by subprocesses.

**When it refreshes**

Every 5 minutes by default, and also when:

- you click Refresh;
- the app launches;
- the Mac wakes from sleep (10 seconds after waking);
- settings change.

When a refresh fails, the last successful data is kept and marked with its update time.

## Command line: `tokenbar`

```bash
swift build                              # produces .build/debug/tokenbar
.build/debug/tokenbar status             # table
.build/debug/tokenbar status --json      # JSON (the format defined in Phase 1 of the plan)
.build/debug/tokenbar status --account Codex --account Work
.build/debug/tokenbar sessions [--json]  # running Claude Code sessions
.build/debug/tokenbar --help | --version
```

- By default it does **not** let Claude Code refresh expired dedicated logins; add `--allow-claude-refresh` when you need that. The reason is that pressing Ctrl-C in the terminal could interrupt a refresh in progress.
- Exit codes:
  - `0`: all succeeded;
  - `1`: at least one account failed (whatever data could be fetched is still printed);
  - `2`: configuration error or argument error.
- The CLI only reads `config.json` (written by the app) and never modifies it. The output does not include emails or accountUuid.

## Privacy and security

- **No credentials are stored.**
  - TokenBar reads the Claude access token from Claude Code's own Keychain item via `/usr/bin/security`. It lives only briefly in memory and is sent only to `https://api.anthropic.com` (no caching, no following redirects).
  - Codex data is read by the official `codex app-server`; TokenBar never sees the Codex token at any point.
- **Your logins are left alone.**
  - TokenBar never calls the OAuth refresh endpoint and never writes to `~/.claude*`, `~/.codex` or the Keychain.
  - Token refresh is left entirely to Claude Code, and only happens in dedicated login directories, so it never logs out your everyday Claude Code.
- **Only programs that pass signature verification are run.**
  - claude must be signed by Anthropic (Q6L2SF6YDW), and codex must be signed by OpenAI (2DC432GLL2).
  - Subprocesses get only a minimal set of environment variables and do not inherit API keys from your shell.
- **Local files.**
  - All local files live in `~/Library/Application Support/TokenBar/`:
    - `config.json`: accounts and settings;
    - `snapshots.json`: the last usage;
    - `state.json`: backoff state.
  - Permissions are 0600, and the containing directory is 0700.
  - Emails are never written to disk.

## Development

```bash
scripts/test.sh                                           # full swift-testing suite (don't use swift test directly)
scripts/test.sh --filter ClaudeProvider                   # run only a subset
swift build -c release && scripts/bundle.sh \
  && dist/TokenBar.app/Contents/MacOS/TokenBar --selftest # selftest the UI with fake data, prints SELFTEST PASS
bash scripts/probe-claude-usage.sh                        # one-off probe: read the Claude Keychain item and call the usage endpoint, prints numbers only
```

- Code layout:
  - `Sources/TokenBarCore`: all logic, no UI;
  - `Sources/TokenBarCLI`: the command line;
  - `Sources/TokenBarApp`: the SwiftUI/AppKit interface.
- All side effects in Core (clock, files, subprocesses, network, signature checks) are injected through `CoreEnvironment`.
- `scripts/test.sh` has a guard: if Core code outside `Live*.swift` calls these APIs directly, the tests fail.
- Implementation plan: [docs/superpowers/plans/2026-10-06-tokenbar-mvp.md](docs/superpowers/plans/2026-10-06-tokenbar-mvp.md).

## Items you still need to verify on your machine (spec §13)

| # | Item | Status |
|---|---|---|
| V1 | Does reading the Claude Keychain item show a prompt | ✅ No prompt (0.08 s) |
| V2 | Does `claude -p "/usage"` call the model, can it refresh an expired token, which files does it write | To verify: do this after creating the first dedicated login |
| V3 | Real usage endpoint format | ✅ Matches the parser |
| V4 | Is launch at login allowed by the school's management policy | To verify: try turning on the switch in Settings |
| V5 | Do older claude versions in the terminal (2.1.123 / 2.1.174) write the session registry | To verify |
| V6 | Are all codex launch arguments accepted by newer versions | To verify |
| V7 | Does logging in to the same account in a dedicated directory kick out the login in your everyday `~/.claude` | To verify: after logging in, wait 8+ hours and check whether your everyday Claude Code is still logged in |
