# TokenBar

**Claude Code and Codex usage limits, right in your Mac's menu bar.**

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

TokenBar shows how much of your Claude and Codex plan limits you have used (5-hour, weekly and per model), when
each one resets, and which Claude Code agents are running, for several accounts at once.

![TokenBar's Accounts settings next to its floating window, which shows two Claude accounts and a Codex account with their limits, and the Claude Code agents running on the first account](docs/images/screenshot.png)

## Features

- **All your accounts in one place:** several Claude accounts (for example, work and personal) plus Codex, each with
  its 5-hour, weekly and per-model limits and their reset times.
- **A number in the menu bar:** the 5-hour usage of the Claude account you are working in. It follows you when you
  switch accounts with `/login`.
- **Running agents:** which Claude Code sessions are busy and for how long, and how many are idle.
- **A floating window:** one click away. It stays on top and never steals focus.
- **Safe to run:** it uses none of your quota, never refreshes or stores your tokens, and only runs `claude` and
  `codex` binaries signed by Anthropic and OpenAI.
- **A command-line tool:** `tokenbar status` and `tokenbar sessions`, with `--json` for scripts.

## Install

You need macOS 14 or later, Swift 6.2 (from Xcode 26, or the Command Line Tools via `xcode-select --install`), and
Claude Code or Codex signed in with a Claude or ChatGPT plan.

```bash
git clone https://github.com/xuguang-ai/TokenBar.git
cd TokenBar
scripts/bundle.sh && scripts/install.sh   # builds in about a minute, then starts TokenBar
```

Look for a percentage in the menu bar. On a MacBook with a notch, a full menu bar can hide it: quit a few menu bar
apps until it appears, then hold ⌘ and drag it toward the clock.

To update, run `git pull` and the same two scripts. To uninstall, quit TokenBar and delete
`~/Applications/TokenBar.app`.

## Use

- **Click** the number to open or close the window. **Right-click** it for **Refresh**, **Settings…** and **Quit TokenBar**.
- Hover over the number to see which account it belongs to. To show a different account, change Settings › General ›
  **Menu bar shows**.
- A `?` after the number means it may be out of date. A `!` means TokenBar could not get any data.

### Add more Claude accounts

`~/.claude` holds one login at a time, so TokenBar gives each additional account a **dedicated login**:

1. In the window, click ⚙ → **Accounts** → `+` → **Add Dedicated Login…**, and enter a name such as `Work`.
2. Click **Open in Terminal** and sign in in the browser.
3. TokenBar shows the new account a few seconds later.

> [!IMPORTANT]
> The browser signs in with whichever claude.ai account it is already logged in to. Sign out of claude.ai first, or
> use a private window, so that each login gets the right account.

You keep using `~/.claude` and `/login` as usual. When a dedicated login's token expires, TokenBar has Claude Code
renew it.

### Command line

```bash
swift build -c release --product tokenbar   # then copy .build/release/tokenbar onto your PATH
tokenbar status                             # usage for every account (add --json for JSON)
tokenbar sessions                           # running Claude Code sessions
```

## License

MIT. TokenBar is an independent project and is not affiliated with Anthropic or OpenAI.
