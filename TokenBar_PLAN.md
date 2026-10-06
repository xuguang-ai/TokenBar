# TokenBar — Project Plan

> **Your AI usage at a glance.**

## 1. Project goals

TokenBar is a lightweight macOS menu bar / top-right floating Dashboard for viewing the usage and quota of several AI coding assistant accounts in one place.

The first version mainly addresses:

- Viewing the usage of **2 Claude accounts** at the same time
- Viewing the usage of **1 Codex / ChatGPT account**
- No need to keep opening web pages, switching accounts, or running `/status` separately
- Quickly seeing the remaining quota and reset time in the top-right corner of macOS

Longer term, it can be extended to services such as Gemini, GitHub Copilot, and Cursor.

---

## 2. MVP

### 2.1 Menu Bar

A TokenBar icon stays in the menu bar; clicking it opens a small Dashboard.

Example:

```text
TokenBar

Claude · Work       ███████░░░  68%
  5h reset                     2h 14m

Claude · Personal   ███░░░░░░░  31%
  5h reset                     3h 42m

Codex                █████░░░░░  53%
  reset                        1h 47m

Last updated: 12:08 PM
                         ↻ Refresh
```

### 2.2 Core features

- Multiple Claude account support
- Codex account support
- Usage percentage
- Remaining quota (if the data source provides it)
- Reset time / countdown
- Manual Refresh
- Automatic scheduled Refresh
- Custom names per account, e.g. `Work` / `Personal`

### 2.3 Status alerts

Provide a simple status based on the remaining quota:

```text
> 50%      Normal
20–50%     Getting low
< 20%      Low
< 5%       Critical
```

macOS notifications can be added later.

---

## 3. Technical approach

### App

Prefer native macOS:

- **Swift**
- **SwiftUI**
- `MenuBarExtra`
- macOS Keychain
- macOS Notification Center

Reason: the app is small, a native implementation uses few resources, and it gives the best Menu Bar experience.

### Architecture

```text
              ┌──────────────┐
              │   TokenBar   │
              │   SwiftUI    │
              └──────┬───────┘
                     │
              UsageAggregator
               /           \
              /             \
     ClaudeProvider     CodexProvider
          │                  │
    Account A / B         Account C
```

Define a unified data structure:

```text
UsageProvider
├── getUsage()
├── getResetTime()
├── refresh()
└── accountName
```

This makes it easy to add in the future:

```text
GeminiProvider
CursorProvider
CopilotProvider
OpenAIAPIProvider
```

---

## 4. Fetching usage data

This is the most critical part of the project; validate it first, before development.

### Claude

Goal: investigate the authentication / usage information Claude Code stores locally, and the available official interfaces, to determine whether the following can be obtained without opening a web page:

- Current account
- 5-hour usage
- weekly usage
- reset time

In particular, we need to solve **how to isolate and read multiple Claude account sessions**.

Principles:

- Prefer official data sources, or those the local CLI already uses
- Never upload passwords/tokens to any server
- Store credentials only in the local Keychain

### Codex

Investigate the data source used by Codex CLI `/status`, preferably reusing the local Codex authentication/session, to obtain locally:

- usage
- allowance
- reset time

Avoid asking the user to log in again.

---

## 5. Account Management

Settings page:

```text
Accounts

Claude
  ● Work
  ● Personal
  + Add Account

OpenAI / Codex
  ● Personal
  + Add Account
```

Account configuration stores only:

- Provider
- Display name
- Local credential reference
- Refresh preference

Sensitive authentication information goes into the macOS Keychain.

---

## 6. Refresh Strategy

By default, refresh every **5 minutes**.

Also refresh when:

- The user clicks Refresh
- The app launches
- The Mac wakes from sleep
- The account configuration changes

If a provider errors, keep the last successful result and show:

```text
Claude · Work
68%
Last updated 14 min ago
⚠ Unable to refresh
```

---

## 7. Development phases

### Phase 0 — Feasibility

Write a CLI prototype first, no UI.

Goal: prove that we can obtain:

```text
Claude A → usage
Claude B → usage
Codex    → usage
```

This is the Go / No-Go checkpoint for the whole project.

### Phase 1 — CLI Prototype

Implement:

```bash
tokenbar status
```

Output unified JSON:

```json
{
  "accounts": [
    {
      "provider": "claude",
      "name": "Work",
      "usage": 0.68,
      "reset_at": "..."
    }
  ]
}
```

### Phase 2 — macOS Menu Bar MVP

Implement:

- MenuBarExtra
- Usage cards
- Progress bars
- Reset countdown
- Manual refresh
- Auto refresh

The goal is to reach the point where "I actually want to keep it running every day."

### Phase 3 — Multi-account UX

Implement:

- Add/remove account
- Rename account
- Reorder account
- Keychain storage
- Login/session error handling

### Phase 4 — Polish

Add:

- Low quota notification
- Launch at Login
- Refresh interval setting
- Dark / Light Mode
- Better icons
- Usage history

---

## 8. Recommended project structure

```text
TokenBar/
├── TokenBarApp/
│   ├── App/
│   ├── Views/
│   │   ├── MenuBarView.swift
│   │   ├── UsageCard.swift
│   │   └── SettingsView.swift
│   ├── Models/
│   │   ├── Account.swift
│   │   └── UsageSnapshot.swift
│   ├── Providers/
│   │   ├── UsageProvider.swift
│   │   ├── ClaudeProvider.swift
│   │   └── CodexProvider.swift
│   └── Services/
│       ├── UsageAggregator.swift
│       ├── KeychainService.swift
│       └── RefreshService.swift
│
├── TokenBarCLI/
├── Tests/
├── README.md
└── docs/
    └── architecture.md
```

---

## 9. Explicitly out of scope for the first version

To avoid scope creep, the MVP will not do the following for now:

- AI API cost accounting
- Team usage dashboard
- Cloud account sync
- Web dashboard
- iOS app
- Windows/Linux GUI
- Automatic switching between Claude/Codex accounts

The first version of TokenBar solves exactly one problem:

> **See at a glance how much quota every AI coding account has left, without switching accounts.**

---

## 10. Success Criteria

MVP success criteria:

1. TokenBar can stay in the macOS Menu Bar all day.
2. A single view shows 2 Claude + 1 Codex account at the same time.
3. Usage data is obtained without manually opening Claude/Codex pages.
4. From clicking TokenBar to seeing all usage takes < 1 second (using a cache).
5. Background refresh does not noticeably increase CPU / memory usage.
6. All authentication credentials are stored only on the local machine.

---

## 11. Next steps

**The first task is not writing the Swift UI, but verifying whether Claude and Codex usage data can actually be read reliably.**

Suggested development order:

```text
Claude usage exploration
       ↓
Codex usage exploration
       ↓
CLI prototype
       ↓
Unified UsageProvider interface
       ↓
SwiftUI Menu Bar
       ↓
Multi-account + Keychain
       ↓
Notifications / Polish
```

If Phase 0 can reliably read the data for all three accounts, implementing the Dashboard itself afterwards is not hard.
