# TokenBar MVP Design Spec

- Version: v2 (2026-10-06). v1 went through a three-way adversarial review (factual consistency, implementability, security and logic) that produced 49 comments, all of which have been incorporated; see §15 for a summary of the changes
- Status: awaiting your review
- Based on: [TokenBar_PLAN.md](../../../TokenBar_PLAN.md); Phase 0 research findings [docs/phase0/findings.md](../../phase0/findings.md); verified scripts and samples in [docs/phase0/artifacts/](../../phase0/artifacts/)
- Confirmed decisions:
  - Presentation: a menu bar dropdown panel that can be "📌 pinned" as an always-on-top floating window in the top-right corner
  - Each Claude account card shows the running Claude Code sessions. Per-session token statistics are deferred to the next phase
  - Claude data uses Option A (hybrid): Keychain token straight to the official endpoint → when the token has expired, let Claude Code refresh it itself (only in a dedicated login directory) → finally fall back to the cache
  - You switch between two accounts with `/login` in Claude Code, so each account gets its own TokenBar dedicated login directory (§3.1)

---

## 1. Goals and Scope

The MVP covers: the plan's Phase 1 (CLI), Phase 2 (menu bar MVP), the most basic account management from Phase 3, plus the two requirements confirmed earlier (floating window, session list). Success criteria follow plan §10.

### 1.1 In the MVP

- Persistent menu bar icon that opens a dropdown panel (`MenuBarExtra`, `.window` style)
- 2 Claude accounts + 1 Codex account (the data model supports any number)
- Per account: the 5-hour window, the weekly window, and for Claude the Sonnet weekly window and per-model weekly limits. Shown: usage, reset time, status tier
- Refresh timing: manual; scheduled (every 5 minutes by default); on launch, wake, and account configuration changes
- On refresh failure, keep the last successful result and mark it as such
- 📌 Always-on-top floating window
- Claude session list: busy/idle status and duration
- Settings:
  - Add, remove, rename, reorder, and enable accounts
  - Refresh interval
  - Display mode (remaining or used)
  - Launch at login
  - claude/codex path overrides, subprocess proxy
  - Guided flow for adding a Claude dedicated login
- CLI: `tokenbar status [--json]`, `tokenbar sessions [--json]`

### 1.2 Not in the MVP

- Per-session token statistics (next phase)
- Codex session list (no verified data source yet)
- Low-quota notifications, usage history, custom icons (plan Phase 4)
- Everything listed as "not in the first version" in plan §9

---

## 2. Phase 0 Findings (Facts the Design Depends On)

Status markers: ✅ tested on this machine; 🔍 reverse-engineered from the installed binaries and independently cross-checked; ⚠️ still needs verification on this machine (see §13). Full evidence is in [docs/phase0/findings.md](../../phase0/findings.md).

### 2.1 Claude Code

| Fact | Status |
|---|---|
| The config directory defaults to `~/.claude` and can be overridden with `CLAUDE_CONFIG_DIR`. One config directory is one independent login | 🔍 |
| Location of the global config JSON: if `<config dir>/.config.json` exists, use it; otherwise `~/.claude.json` when the env var is not set, and `$CLAUDE_CONFIG_DIR/.claude.json` when it is. The file contains `oauthAccount` (identity) and `cachedUsageUtilization` (usage cache), **and may also contain other fields holding secrets**, such as MCP environment variables | 🔍 |
| Credentials are stored as a generic password in the macOS Keychain. Service name: `Claude Code-credentials` when the env var is not set; when it is set, `Claude Code-credentials-` followed by the first 8 hex digits of `sha256(NFC(CLAUDE_CONFIG_DIR raw string))`. The hash input is the **raw string**: no realpath, no stripping of a trailing `/`. The account is `$USER`, falling back to the `getpwuid` user name; if it does not match `^[a-zA-Z0-9._-]+$`, `claude-code-user` is used. Claude Code itself reads and writes the Keychain through a `/usr/bin/security` subprocess | 🔍 |
| Besides `claudeAiOauth`, the Keychain value contains many other secrets (designOauth, mcpOAuth, pluginSecrets, trustedDeviceToken...) and may exceed 4KB | 🔍 |
| When there is no Keychain item (exit code 44), Claude Code falls back to reading `<config dir>/.credentials.json` (plaintext, mode 0600) | 🔍 |
| Structure of `claudeAiOauth`: `{accessToken, refreshToken, expiresAt (ms), scopes[], subscriptionType, rateLimitTier, ...}` | 🔍 |
| `security` exit codes: 0 = success; 44 = not found; 36 = Keychain locked. User cancel or authorization failure may be 128 or 51 (inferred, unverified); Claude Code additionally classifies by keywords in stderr | 🔍 ⚠️ |
| `CLAUDE_SECURESTORAGE_CONFIG_DIR` and `CLAUDE_CODE_CUSTOM_OAUTH_URL` are not supported, because they change the storage location or the service name. TokenBar assumes these two variables are unset, and strips them when invoking subprocesses | 🔍 |
| The usage endpoint is `GET https://api.anthropic.com/api/oauth/usage`. Headers: `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`, `Content-Type: application/json`. The token needs the `user:profile` scope. **Observed 2026-10-08**: the server rate-limits frequent usage checks (429, sometimes with `Retry-After: 0`), apparently per token and/or per account and shared with Claude Code's own checks: a TokenBar request 4.5 minutes after Claude Code's own successful fetch got 429, and a fixed 5-minute retry kept hitting the limit for 8 hours | 🔍 |
| Top-level windows in the response include `five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus`, etc., each `{utilization: 0-100 (may exceed 100) or null, resets_at: ISO-8601 or null}`. The whole window object may also be null. `limits[]` holds per-model rows, where `resets_at` may be epoch seconds. There is also `extra_usage` | 🔍 |
| A token counts as expired when it is less than 5 minutes from `expiresAt` | 🔍 |
| **Refresh tokens rotate**: if another process refreshes the token, the refresh token Claude Code has stored becomes invalid. Its next refresh fails and it then clears the credentials, which amounts to being logged out | 🔍 |
| Backend backoff rules (tracked per token by Claude Code): 401 or 403 with an error body → 1 hour; 429 → per Retry-After, or 5 minutes if absent, at most 1 hour. Claude Code itself reads usage at most once every 60 seconds | 🔍 |
| `cachedUsageUtilization = {fetchedAtMs, accountUuid, utilization:{...}}` is a snapshot of the last successful read of the usage endpoint. **Only versions ≥ 2.1.287 write it**, and only when reading usage: the /usage panel, `claude -p "/usage"`, SDK get_usage; the VS Code extension also triggers it after login and on panel requests. It is written at most once every 60 seconds per account, and is deleted on logout or account switch. The terminal versions on this machine, 2.1.123 and 2.1.174, never write it | 🔍 |
| `claude -p "/usage"` (≥ 2.1.289) runs locally without calling the model; Claude Code refreshes the token itself (with a lock, writing back via compare-and-swap) and also updates `cachedUsageUtilization`. If the cache is less than 60 seconds old, it uses the cache directly without going to the network | 🔍 ⚠️ |
| The `claude auth login` and `claude auth status` subcommands exist. `status` is read-only and outputs JSON by default | ✅ |
| The session registry is at `<config dir>/sessions/<pid>.json`, with fields `{pid, sessionId, cwd, name, status: busy\|idle, statusUpdatedAt (ms), startedAt (ms), procStart (e.g. "Tue Oct  6 05:33:53 2026"), kind, entrypoint, version, ...}`. The `*.key` files in the same directory are secret files and **must never be read**. Confirmed that 2.1.289 writes this file; whether 2.1.123 and 2.1.174 do is unverified | ✅ ⚠️ |
| claude binaries on this machine: 2.1.289 bundled with the VS Code extension (old version folders are listed in `.obsolete`), `~/.local/bin/claude` → `~/.local/share/claude/versions/2.1.174`, and 2.1.123 under nvm. All are signed `Developer ID Application: Anthropic PBC (Q6L2SF6YDW)` | ✅ |
| Another process reading Claude Code's Keychain item via `/usr/bin/security` **does not trigger a prompt**: V1 measured exit code 0 in 0.08 seconds. The Keychain value on this machine has only two top-level keys, `claudeAiOauth` and `organizationUuid`; the token is valid for about 8 hours | ✅ |
| Whether logging the same account in again in a dedicated directory kicks out the everyday `~/.claude` login | ⚠️ |

### 2.2 Codex

| Fact | Status |
|---|---|
| `codex app-server` runs over stdio, one JSON object per line, with no `jsonrpc` field. The stable v2 methods `account/read` and `account/rateLimits/read` use Codex's own login | ✅ (0.160.0) |
| Handshake order: `initialize` (with clientInfo) → `initialized` notification → send requests. Responses are matched by id and may arrive out of order, interleaved with notifications (0.160 notifications carry an extra `emittedAtMs` field). **Wait until all responses have arrived before closing stdin**; after it is closed, the process exits with code 0 in about 10ms | ✅ |
| Verified launch arguments: `-c memories.generate_memories=false -c memories.use_memories=false app-server --listen stdio://`. Without disabling plugins (`-c features.plugins=false`, equivalent to `--disable plugins`), every launch requests plugins/featured; a brand-new home also clones a 136MB plugin repository | ✅ (disabling plugins was only tested in a temp directory) |
| Measured from launch to all results: 0.42 seconds, peak RSS 134MB, CPU 0.11 seconds. Every launch writes log lines, models_cache.json and tmp as usual | ✅ |
| Result structure: under `rateLimitsByLimitId["codex"]` (or `rateLimits`) there is `primary/secondary: {usedPercent: Int, windowDurationMins, resetsAt: unix seconds}`, plus `rateLimitReachedType`, `ordinaryUsageAllowed`, `planType`, `credits` | ✅ |
| When a window has not started yet, `usedPercent == 0` and `resetsAt ≈ now + windowDurationMins×60`, moving later with every read. `usedPercent` is an integer, so usage under 1% also shows as 0 | ✅ |
| Windows must be classified by `windowDurationMins` (300 = 5 hours, 10080 = weekly, 43200 = 30 days), not by primary/secondary position. Some plans have only a weekly window, or only a 30-day window | ✅ |
| One CODEX_HOME corresponds to one account. If the directory does not exist, it fails cleanly; **if the directory exists but is empty, it is silently initialized as a new configuration** | ✅ |
| The binary path changes as the VS Code extension updates (it auto-updated from 0.160.0 to 0.160.1 just last night), and old version folders get listed in `.obsolete`. This machine also has an npm build 0.138.0, for which `~/miniconda3/bin/codex` is its JS launcher script. All usable native binaries are signed `OpenAI OpCo, LLC (2DC432GLL2)` | ✅ |
| Passive fallback data: `rate_limits` carried by `token_count` events in `$CODEX_HOME/sessions/**/rollout-*.jsonl`. This data is sparse and easily stale | ✅ |
| Methods that must never be called: `account/rateLimitResetCredit/consume` (consumes reset credit), `sendAddCreditsNudgeEmail`, login/logout, `account/read{refreshToken:true}` | 🔍 |

### 2.3 Build Environment

| Fact | Status |
|---|---|
| Only Command Line Tools (Swift 6.2.4, macOS 26.2 SDK). Xcode 27 is installed but its license has not been accepted, so `DEVELOPER_DIR=/Library/Developer/CommandLineTools` must be set | ✅ |
| swift-tools-version 6.2, minimum macOS 14, Swift 6 language mode. The App target uses `.defaultIsolation(MainActor.self)` and compiles with zero concurrency errors | ✅ |
| `swift test` needs 3 extra arguments (see `scripts/test.sh`). If these arguments only live in Package.swift, you get "no tests ran, yet it returns 0", so the script must check for that case | ✅ |
| The product names `TokenBar` and `tokenbar` collide on a case-insensitive disk, so the App product is named `TokenBarApp` and renamed at bundling time | ✅ |
| A menu bar label using only `Label` shows only the icon; use `HStack { Image; Text }` | ✅ |
| Opening the Settings window requires `openSettings` plus `NSApp.activate(ignoringOtherApps: true)`; `showSettingsWindow:` does nothing on macOS 14 and later | ✅ |
| In a hand-bundled .app, `Bundle.module` cannot find resources, so SwiftPM's resource mechanism is not used | ✅ |
| A GUI process has a very short PATH and none of the shell's proxy variables | ✅ |
| Ad-hoc signing changes the cdhash on every build, so nothing may rely on TCC grants, nor on a Keychain "Always Allow" grant to TokenBar itself | ✅ |
| This is a university-managed Mac (Jamf, Microsoft Defender, CyberArk EPM); suspicious binaries may be killed outright | ✅ |

---

## 3. Account Model

### 3.1 One Claude account per config directory

```swift
public struct AccountConfig {
    …
    public var claudeConfigDir: String?   // nil means the default directory
    public var isDedicatedLogin: Bool     // only the "Add Dedicated Login" flow in §6.5 sets this to true (there is also an explicit toggle in Settings)
}
```

- `claudeConfigDir == nil` means the default directory: `CLAUDE_CONFIG_DIR` is not set, the Keychain service name has no hash, and the config JSON is `~/.claude.json`.
- Path rules: only a leading `~` is expanded; all other characters are **stored as is**, with no stripping of a trailing `/` and no realpath. This raw string is used both to set `CLAUDE_CONFIG_DIR` and to compute the hash, and it also appears in the login command shown to you.
  - Dedicated directories created by TokenBar itself always use an absolute path with no trailing `/`.
  - An existing directory you enter manually: if reading the Keychain returns exit code 44, add or remove the trailing `/` and try once more; if that matches, tell you and save the spelling that matched.
  - If the entry is exactly `$HOME/.claude`, warn you: this is not the same as the "default login (nil)", because the two have different Keychain service names. Also offer a "Change to default" option.

**Dedicated login directory (recommended when you switch back and forth with /login)**:

- Which account is logged in to `~/.claude` changes over time, so it cannot serve as the data source for any fixed account.
- Create a TokenBar dedicated directory `~/.tokenbar/claude/<slug>` for each Claude account. Both `~/.tokenbar` and `~/.tokenbar/claude` get mode 0700. Log each directory in once with Claude Code (§6.5).
- These directories exist only for TokenBar to read usage. You keep working in `~/.claude` day to day and keep switching with /login. Logging an account in once in each of two directories means two independent OAuth sessions, the same as logging in on two devices (⚠️ see V7).
- A dedicated directory is otherwise unused, so its access token will expire; in that case step ② of §5.3 lets Claude Code refresh it itself. Only TokenBar uses this login, so it never competes with your everyday Claude Code for the refresh token.

**Default account handling**:

- On first launch, two accounts are created: a Claude account (`claudeConfigDir = nil`, display name "Claude", `isDedicatedLogin = false`) and a Codex account (`codexHome = nil`, display name "Codex").
- After the first dedicated login completes, TokenBar suggests disabling the default account (disabling is the default choice).
- If you choose to keep it, the default account is still shown as "Claude", with content from whichever account is currently logged in to `~/.claude` (on 2026-10-06, per user feedback, the "(current /login)" suffix was dropped and card titles were unified as "provider name + account name + plan"). The default account can never be a dedicated login (`isEffectiveDedicatedLogin` requires a non-nil directory).

### 3.2 Which account a session belongs to

- The session registry lives in the config directory you use for **everyday work** (usually `~/.claude/sessions/`).
- Watched directories = `~/.claude` (the default directory) plus the `claudeConfigDir` of every Claude account, deduplicated.
- For each watched directory, read `oauthAccount.accountUuid` from its config JSON and assign that directory's sessions to the TokenBar account with the same `identity.accountUuid`. If several accounts match, a dedicated account (`claudeConfigDir != nil`) takes precedence over the default account. Each session appears under exactly one card.
- Sessions that match no account go into an "Other Claude sessions" group at the bottom of the panel.
- After you switch with /login in `~/.claude`, the session list automatically follows to the corresponding card.

### 3.3 One Codex account per CODEX_HOME

- `codexHome: String?`; `nil` means `~/.codex`.
- Before launching app-server, require that the directory exists and contains `config.toml` or `auth.json`. Only a stat check, **the contents are not read**. If the check fails, show ⚠ "Not a Codex profile — run `CODEX_HOME=<dir> codex login`", so that app-server does not initialize an empty directory as a new configuration.

---

## 4. Architecture

### 4.1 Package structure (SwiftPM)

Mapping to plan §8: Models, Providers and Services all live in `TokenBarCore`; Views live in `TokenBarApp`; the CLI is `TokenBarCLI`.

```text
TokenBar/
├── Package.swift
├── Sources/
│   ├── TokenBarCore/            # no UI; nonisolated; Sendable value types + async API
│   │   ├── Models/              # AccountConfig, AppSettings, UsageSnapshot, UsageWindow, UsageStatus, DisplayDerivation, SessionInfo, ProviderError
│   │   ├── Environment/         # CoreEnvironment (all side effects enter here) + LiveEnvironment
│   │   ├── Providers/           # UsageProvider; Claude/*; Codex/*
│   │   ├── Services/            # UsageAggregator, RefreshScheduler, ConfigStore, SnapshotStore, StateStore, SessionMonitor, BackoffPolicy
│   │   └── Support/             # ProcessRunner, MinimalEnv, BinaryLocator, CodeSignatureVerifier, DateParsing, Formatting, ShellQuoting
│   ├── TokenBarCLI/             # executable product `tokenbar`
│   └── TokenBarApp/             # executable product `TokenBarApp` (bundled as TokenBar.app)
│       ├── App/                 # @main App, AppModel, SystemEventsBridge (sleep/wake), SelfTest
│       ├── Views/               # MenuBarLabel, PanelView, WindowObserver, AccountCard, UsageRow, SessionList, Settings/*
│       └── Floating/            # FloatingPanel, FloatingPanelController
├── Tests/TokenBarCoreTests/     # includes Fixtures/ (sample JSON, rollout lines, old-version configs)
├── scripts/                     # test.sh, bundle.sh, install.sh
├── docs/
└── README.md
```

### 4.2 CoreEnvironment (test injection point)

No type in Core may **call directly** `Date()`, `FileManager.default.homeDirectoryForCurrentUser`, `NSHomeDirectory()`, `Process`, `URLSession`, or `ProcessInfo.processInfo.environment`. All side effects are injected through this struct:

```swift
public struct CoreEnvironment: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async throws -> Void
    public var homeDirectory: URL
    public var appSupportDirectory: URL           // ~/Library/Application Support/TokenBar
    public var temporaryDirectory: URL
    public var userName: String                   // Keychain account derivation rule from §2.1
    public var processRunner: any ProcessRunning
    public var fileSystem: any FileSystemAccess   // read/write, stat, directory listing, permissions, file locks
    public var http: any HTTPClient
    public var signatureVerifier: any CodeSignatureVerifying
    public var processInspector: any ProcessInspecting   // kill(pid,0), process start time
    public var systemProxy: @Sendable () -> ProxySettings?
    public static func live() -> CoreEnvironment       // the only place allowed to use real APIs
}
```

In tests, all paths are created under each test's own temporary directory. `scripts/test.sh` checks that, apart from `LiveEnvironment.swift`, any occurrence of `Date()`, `homeDirectoryForCurrentUser`, `NSHomeDirectory()`, `URLSession.shared` or `Process()` in `Sources/TokenBarCore` is a failure.

### 4.3 Data flow

```text
App: SystemEventsBridge (willSleep / didWake), buttons, settings changes ─┐
CLI: single invocation ───────────────────────────────────────────────────┤
                                                             ▼
                 RefreshScheduler (actor, in Core) ──► UsageAggregator (actor)
                                                             │ one child task per account, each with its own deadline; results emitted in arrival order
                       ┌─────────────────────────────────────┴────────────────────────┐
                ClaudeProvider                                                  CodexProvider
   CredentialReader(/usr/bin/security) → UsageClient(HTTPS)          BinaryLocator + Verifier
   ClaudeCodeRefresher(claude -p "/usage", dedicated dirs only)      AppServerClient(LineTransport)
   ConfigReader(oauthAccount / cachedUsageUtilization)              RolloutReader (passive fallback)
                       └───────────────► StateStore (backoff, step ②, Keychain authorization; shared by App and CLI)
AsyncStream<(UUID, Result)> ──► AppModel (@MainActor @Observable) ──► SnapshotStore (written only by the App)
SessionMonitor (independent polling, rate depends on panel visibility) ──► AppModel.sessions
```

---

## 5. Data Layer Detailed Design (TokenBarCore)

### 5.1 Models

```swift
public enum ProviderKind: String, Codable, Sendable { case claude, codex }
public enum DisplayMode: String, Codable, Sendable { case remaining, used }

public struct AccountConfig: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var provider: ProviderKind
    public var displayName: String
    public var claudeConfigDir: String?
    public var isDedicatedLogin: Bool        // Claude only; step ② applies only to accounts where this is true
    public var codexHome: String?
    public var isEnabled: Bool
}

public struct AppSettings: Codable, Sendable {
    public var schemaVersion: Int            // currently = 1
    public var accounts: [AccountConfig]     // array order is display order
    public var refreshIntervalMinutes: Int   // default 5, choices 1/2/5/10/15/30; Codex actually uses max(this value, 5)
    public var displayMode: DisplayMode      // default .used (user request 2026-10-06, consistent with Claude /usage and Codex /status)
    public var resetTimeStyle: ResetTimeStyle // .clock | .countdown; default .clock (user request 2026-10-16); missing in an old config.json → .clock
    public var allowClaudeCodeRefresh: Bool  // default true; affects dedicated logins only
    public var claudeBinaryOverride: String?
    public var codexBinaryOverride: String?
    public var subprocessProxy: String?      // e.g. "http://proxy:8080"; nil means use the system proxy settings
}

public struct UsageWindow: Codable, Sendable, Hashable {
    public enum Kind: Codable, Sendable, Hashable {
        case fiveHour, weekly, weeklySonnet, weeklyOpus, monthly
        case model(name: String)             // per-model weekly limit from Claude limits[]
        case other(minutes: Int)
    }
    public var kind: Kind
    public var usedPercent: Double           // 0…100, may exceed 100
    public var resetsAt: Date?
    public var isStarted: Bool               // false = window not started yet; data-layer rules in §5.3.1 and §5.4, display-layer rules below
}

public struct AccountIdentity: Codable, Sendable, Hashable {
    public var accountUuid: String?          // Claude oauthAccount.accountUuid; persisted (used for session assignment)
    public var plan: String?                 // "Max" / "Pro" / "Plus" …
    public var organization: String?
    public var email: String?                // excluded from Codable (custom CodingKeys), never persisted, only read live and shown in Settings
}

public enum SnapshotSource: Codable, Sendable, Hashable {
    case claudeAPI, claudeAPIAfterCLIRefresh, claudeCache(fetchedAt: Date), codexAppServer, codexRollout(eventAt: Date)
}

public struct UsageSnapshot: Codable, Sendable {
    public var accountID: UUID
    public var fetchedAt: Date               // when TokenBar obtained the data
    public var dataAsOf: Date                // when the data itself is from (may be earlier when it comes from a cache or log)
    public var source: SnapshotSource
    public var identity: AccountIdentity?
    public var windows: [UsageWindow]        // order: fiveHour, weekly, weeklySonnet, weeklyOpus, model…, monthly, other
    public var limitReached: Bool
}
```

**ProviderError is a closed set and carries no raw text** (to prevent leaks, see §9):

```swift
public enum ProviderError: Error, Codable, Sendable, Hashable {
    case notLoggedIn(hint: LoginHint)                 // LoginHint = .claude(configDir: String?) | .codex(home: String?); the text is generated by the UI
    case waitingForClaudeCode                         // a non-dedicated account's token expired; waiting for the everyday Claude Code to refresh it
    case tokenLacksProfileScope
    case keychainLocked
    case keychainAccessDenied(exitCode: Int32)        // user denied, cancelled, or timed out
    case keychainReadFailed(exitCode: Int32)
    case unauthorized(until: Date)
    case rateLimited(until: Date)
    case network(URLErrorCode)                        // stores only the raw value of URLError.Code
    case httpStatus(Int)
    case claudeBinaryNotFound                         // no validly signed claude ≥ 2.1.289 found
    case codexBinaryNotFound
    case binarySignatureInvalid(BinaryKind)
    case notACodexProfile
    case protocolError(ProtocolErrorCode)             // closed enum: serverExited, malformedResponse, unexpectedMessage, methodNotAllowed, …
    case decoding(codingPath: [String])               // records key names only, never values
    case timeout
    case accountChanged
}
```

**AccountState** (handed to the UI):

```swift
public struct AccountState: Sendable {
    public var config: AccountConfig
    public var lastSnapshot: UsageSnapshot?          // most recent successful result
    public var lastError: ProviderError?             // why the most recent attempt failed; nil on success
    public var lastAttemptAt: Date?
    public var isRefreshing: Bool
    public var pausedUntil: Date?                    // in backoff
}
```

**Display derivation** (`DisplayDerivation`, pure functions that the App and CLI call on every render):

1. Regardless of where the snapshot came from, any window with `resetsAt ≤ now` is treated as usedPercent = 0, isStarted = false, with no countdown (labelled `reset`), and does not count toward limitReached.
2. The App triggers a re-render at the earliest `resetsAt`.
3. UsageStatus is tiered by the remaining percentage r (plan §2.3): `r > 50` is `.normal`; `20 ≤ r ≤ 50` is `.gettingLow`; `5 ≤ r < 20` is `.low`; `r < 5`, or when limitReached, is `.critical`.
4. An account's status is the worst among all of its **started** windows. If none of its windows have started, the status is `.normal` and it shows 100% left.
5. The menu bar considers only enabled accounts that have a snapshot, and shows the value of the worst window of the worst account. If that account's snapshot is older than 2× the refresh interval, or its `lastError != nil`, a `?` is appended to the number (e.g. `31%?`). If no enabled account has a snapshot and all of them are failing, it shows `!`.
6. Reset time format, chosen by `AppSettings.resetTimeStyle` (panel, floating window and CLI table):
   - `.clock` (default): the local clock time of the reset (`Formatting.resetClock`), localized with `DateFormatter.setLocalizedDateFormatFromTemplate` in the calendar's time zone. On the same calendar day as now: the time only, template `j:mm` (`6:10 PM` in en_US, `18:10` in en_GB). One to six calendar days later: template `EEE j:mm` (`Wed 11:00 PM`). Seven or more calendar days later: template `MMM d` (`Oct 23`), since a weekday would repeat today's. Days are counted in the calendar's time zone, so 23:59 → 00:30 the next day is not the same day. A reset that has passed shows `now` (rule 1 normally shows `reset` first).
   - `.countdown`: 1 day or more shows `3d 4h`; 1 hour or more shows `2h 14m`; 1 minute or more shows `45m`; under 1 minute shows `<1m`.
   - The panel shows the other format as a tooltip (`Resets in 1d 12h` or `Resets Wed 11:00 PM`); VoiceOver always reads the countdown (`resets in 1 day 12 hours`). The CLI `--json` output is unaffected (ISO 8601 timestamps).

### 5.2 UsageProvider

```swift
public enum RefreshTrigger: Sendable { case scheduled, manual, launch, wake, configChange }
public protocol UsageProvider: Sendable {
    func fetchUsage(for account: AccountConfig, settings: AppSettings,
                    trigger: RefreshTrigger, deadline: Date) async throws(ProviderError) -> UsageSnapshot
}
```

The plan's interface was `getUsage()/getResetTime()/refresh()/accountName`; here it becomes a single call that returns a full snapshot: the reset times are in the snapshot, and the account name comes from `AccountConfig`. If the compiler does not support typed throws, fall back to plain `throws` and convert to ProviderError at the boundary.

### 5.3 ClaudeProvider

Made up of these components: `ClaudePaths` (derives the directory, config JSON path and service name), `ClaudeCredentialReader`, `ClaudeConfigReader`, `ClaudeUsageClient`, `ClaudeCodeRefresher`, `ClaudeBinaryLocator` (§5.3.2), plus the shared `StateStore` and `BackoffPolicy`. Each component is injected through a protocol.

**Time budget**: the provider receives `deadline = start time + 120 seconds`. The effective timeout of each step is the smaller of "that step's own timeout" and "deadline − now − 2 seconds". If there is not enough time left to start a step, or a step gets cut short, skip straight to step ③.

**Per-account flow**:

0. **Preflight checks** (read StateStore)
   - If this account is in a 429 or bare-403 backoff period, go straight to step ③. The card shows `Anthropic is rate-limiting usage checks · next try HH:MM`. A manual refresh **cannot** bypass this backoff either.
   - If this service is marked `keychainAccess = deniedOrPrompting` and this is not a manual refresh, skip the Keychain and go straight to step ③, with error `.keychainAccessDenied`.

1. **Read credentials**: run `/usr/bin/security find-generic-password -a <userName> -w -s <service>`.
   - Timeout is 10 seconds when triggered automatically and 60 seconds when triggered manually, leaving time for you to click "Always Allow".
   - Only one `security` process runs at a time globally; multiple accounts queue.
   - Exit code 0: parse the JSON, keep only `claudeAiOauth.{accessToken, expiresAt, scopes, subscriptionType}`, and discard everything else. stdout is never logged and never ends up in an error.
     - If `accessToken` is empty or missing → `.notLoggedIn(.claude(configDir))`.
     - If scopes lacks `user:profile` → `.tokenLacksProfileScope`, step ③ only.
   - Exit code 44: first try the "trailing `/` added or removed" variant (§3.1). If still not found, read `<config dir>/.credentials.json` instead, which has the same structure. If still nothing, and the config JSON has no `oauthAccount` either → `.notLoggedIn`.
   - Exit code 36 → `.keychainLocked`, go to step ③.
   - Timeout, exit code 128 or 51, or "User canceled" or "auth failed" in stderr:
     - record `.keychainAccessDenied(code)`;
     - mark this service `deniedOrPrompting` in StateStore, so only a manual refresh will read it again;
     - go to step ③.
   - Any other exit code → `.keychainReadFailed(code)`, go to step ③.

2. **Step ①: call the usage endpoint directly**
   - Precondition: `now + 5 minutes < expiresAt`.
   - Backoff rules use the token's `expiresAt` to identify "the same token": if StateStore has a 401 backoff and `backoffTokenExpiresAt == expiresAt`, it is still the rejected token, so skip to step ③. As soon as the token changes, the backoff is cleared.
   - **Fresh Claude Code cache first** (not for manual refreshes): before the request, re-read the config JSON. If its `cachedUsageUtilization` belongs to this account (same `accountUuid` rule as step ③), was fetched within the last `refreshIntervalMinutes` and is newer than `lastHTTPAt` (or there is no `lastHTTPAt`), use it without any request: source `.claudeCache(fetchedAt:)`, no warning, `lastHTTPAt` unchanged. Claude Code has just fetched the same data (via step ② or the VS Code extension), and a second request seconds later only spends the rate limit both share. A manual refresh always makes the request, unless a backoff is active, in which case the rules above apply.
   - When not manually triggered, two HTTP calls for the same account are at least 60 seconds apart.
   - Request: `GET /api/oauth/usage`, 10-second timeout, headers as in §2.1, `User-Agent: TokenBar/<version>`. The URLSession used must be ephemeral, with no URLCache and no cookies, and must refuse redirects (see §9).
   - 200: parse per §5.3.1, source `.claudeAPI`, and reset `consecutiveRateLimits` to 0 (only a 200 of our own does that; using a cache does not). Then **read `oauthAccount.accountUuid` again**; if it changed during the refresh, discard this result and record `.accountChanged`.
   - 401: re-read the Keychain. If the token changed, retry once. If it did not:
     - dedicated accounts go to step ②;
     - non-dedicated accounts get a 1-hour backoff (bound to this token), record `.waitingForClaudeCode`, and go to step ③.
   - 403 with an API error body: likewise a 1-hour backoff (bound to the token), go to step ③.
   - 429 or bare 403: increment `consecutiveRateLimits` (n) and back off `max(Retry-After when > 0, 5 minutes × 2^(n−1))`, at most 1 hour: 5, 10, 20, 40, 60, 60 … minutes. A missing Retry-After or `Retry-After: 0` uses the exponential value. This backoff is per account; record `.rateLimited` (and the Retry-After in `lastRetryAfterSeconds`, for diagnostics) and go to step ③.
   - Network error → `.network`, go to step ③. A network error within 30 seconds after wake is treated as transient: keep the existing state and do not overwrite lastError.

3. **Step ②: let Claude Code refresh it itself**
   - **Applies only to dedicated logins**: requires `isDedicatedLogin == true` and `claudeConfigDir != nil`.
   - **All** of the following must hold:
     - the token has expired, or re-reading the Keychain after a step ① 401 did not help;
     - `allowClaudeCodeRefresh` is true;
     - there are no live sessions in this directory's `sessions/` (do not touch the directory while someone is using it);
     - StateStore has no step ② currently in progress for this directory;
     - this token is not marked `step2Failed` (meaning described below);
     - at least 15 minutes have passed since this account's last step ② (manual refresh is exempt from this rule);
     - the caller allows step ② (the CLI does not by default, see §7).
   - A non-dedicated account's token has expired: do not run step ②; record `.waitingForClaudeCode` and go to step ③.
   - Choosing the claude binary: use `ClaudeBinaryLocator` (§5.3.2). If none is found, record `.claudeBinaryNotFound`; both the card and Settings show "Claude Code ≥ 2.1.289 not found — dedicated logins can't refresh".
   - **How it is launched**: `posix_spawn` with `POSIX_SPAWN_SETPGROUP`, so claude gets its own process group and is not taken down by a Ctrl-C in the terminal or by TokenBar being killed.
     - argv: `[<realpath>, "-p", "/usage"]`.
     - stdin, stdout and stderr all go to `/dev/null`. Its output is not parsed, so pipe deadlocks and SIGPIPE cannot happen.
     - env is `MinimalEnv.make(extra: ["CLAUDE_CONFIG_DIR": dir])`.
     - cwd is fixed at `<appSupport>/claude-cwd`, mode 0700. A fixed directory avoids creating a new entry in projects/ on every run.
   - **TokenBar never sends any signal to this subprocess**. If it is killed in the middle of refreshing the token, the directory gets logged out.
     - Before starting, register `step2InFlight = {pid, startedAt}` in StateStore.
     - Wait for it to exit with `DispatchSource.makeProcessSource(.exit)`, at most until the deadline (60-second cap for this step).
     - If it has not exited by then, stop waiting and go to step ③, but do not kill the process. Keep `waitpid`-ing in the background, reap it when it exits, and clear the `step2InFlight` registration.
     - If the registered pid no longer exists (the App was restarted), treat the registration as void.
   - **After it finishes**:
     - Read the config JSON first. If `cachedUsageUtilization.fetchedAtMs` is later than the start of step ② and the accountUuid matches, use this cache directly with source `.claudeAPIAfterCLIRefresh`, without calling the endpoint.
     - Otherwise re-read the Keychain and call the endpoint again (once only).
     - If the token is still empty or expired: record `.notLoggedIn` and mark `step2Failed` in StateStore (bound to this token's expiresAt). Step ② will not run automatically again until the token changes or you refresh manually.

4. **Step ③: read the cache**
   - Read `cachedUsageUtilization` from the config JSON, requiring `accountUuid == oauthAccount.accountUuid`.
   - Source `.claudeCache(fetchedAt)`. Windows whose reset time has passed are handled uniformly by display derivation.
   - If there is no cache, throw the error recorded by the earlier steps.

5. **Identity**
   - Derived from the config JSON's `oauthAccount.{accountUuid, organizationName, organizationType}` plus the credentials' `subscriptionType`. The plan name prefers `subscriptionType`: `max → Max`, `pro → Pro`; otherwise it maps from organizationType: `claude_max → Max`, `claude_pro → Pro`, `claude_team → Team`, `claude_enterprise → Enterprise`.
   - If the accountUuid read this time differs from `lastSnapshot.identity.accountUuid`, the account has changed: discard this account's lastSnapshot and backoff state, and the card shows `Account changed`.

**Rules for reading the config JSON**: parse with `JSONSerialization` and take **only** the two keys `oauthAccount` and `cachedUsageUtilization`. The file contents are never logged, cached, or passed on.

#### 5.3.1 Mapping the Claude usage response

- Top-level windows: `five_hour → .fiveHour`, `seven_day → .weekly`, `seven_day_sonnet → .weeklySonnet`, `seven_day_opus → .weeklyOpus`.
  - Windows whose value is not an object, is entirely null, or has `utilization == null` are skipped.
  - All other keys are ignored, so keys added in the future do not cause parse failures.
- Rows in `limits[]` with a non-null `scope.model` map to `.model(name: scope.model.display_name)`, with usage taken from `percent` (0-100).
- `resets_at` is parsed with `DateParsing.flexible`:
  - for a string, first try `ISO8601DateFormatter` with fractional seconds (`.withInternetDateTime` + `.withFractionalSeconds`); on failure, try without fractional seconds;
  - for a number, treat it as epoch seconds;
  - if all fail, return nil, meaning no countdown is shown; **this is not a parse error**.
  - The formatter is created fresh on each call, or used under a lock, because it is not Sendable.
- In the data layer `isStarted` is always true, because Claude has no notion of "window not started". Display derivation may change it to false.
- `limitReached` is true when usage of any window or `limits[]` row is ≥ 100.

#### 5.3.2 Candidate locations for the Claude binary (ClaudeBinaryLocator)

Candidates are collected in this order:

1. `claudeBinaryOverride`.
2. `~/.local/share/claude/versions/<ver>` (`~/.local/bin/claude` points here). The version is the file name.
3. `{~/.vscode, ~/.vscode-insiders, ~/.cursor, ~/.windsurf}/extensions/anthropic.claude-code-<ver>-darwin-arm64/resources/native-binary/claude`. Skip folders listed in `.obsolete` in the corresponding extensions directory. The version comes from the folder name.
4. `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`.

Filtering rules:

- Every candidate is realpath'd first; what gets verified and executed is the actual path from realpath, not the symlink itself.
- It must be a regular file, Mach-O (checked via the magic in the file header; scripts and shebang files are excluded outright), executable, and signed with Team ID `Q6L2SF6YDW` (§5.6).
- **Never run `--version` on claude**:
  - the version can only come from the path; if it cannot be derived, the binary is not used for step ②;
  - an override with an unknown version is allowed, but Settings shows "version unknown"; one with a known version below 2.1.289 is rejected.
- Pick the highest version that is ≥ 2.1.289. Resolve again before every step ②, and re-verify before launching.

### 5.4 CodexProvider

Made up of these components: `CodexBinaryLocator` (shares the BinaryLocator framework), `CodeSignatureVerifier`, `AppServerClient`, `CodexRateLimitMapper`, `RolloutReader`.

1. **Locate the binary**: resolve again on every refresh, caching the last usable path.
   - Candidate locations (all collected, then filtered):
     - `codexBinaryOverride`;
     - `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, `~/.local/bin/codex`, `~/.bun/bin/codex`, `~/.npm-global/bin/codex`;
     - the native binary inside the global npm package, `<prefix>/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`, where prefix ∈ {`~/miniconda3`, `~/anaconda3`, `/opt/homebrew`, `/usr/local`, `~/.npm-global`, `~/.nvm/versions/node/*`}. The npm JS launcher script (e.g. `~/miniconda3/bin/codex → codex.js`) **must not be executed directly**; it must first be resolved to the native binary above;
     - `/Applications/Codex.app/Contents/Resources/codex`, `~/Applications/Codex.app/Contents/Resources/codex`;
     - `{~/.vscode, ~/.vscode-insiders, ~/.cursor, ~/.windsurf}/extensions/openai.chatgpt-*/bin/macos-aarch64/codex`, skipping folders listed in `.obsolete`.
   - Filtering: realpath first; it must be a regular file, Mach-O, executable, and signed with Team ID `2DC432GLL2`.
   - The version is taken, in order, from: the `version` in `codex-package.json` in the same directory; the extension folder name; npm's `package.json`. If none is available, run `--version` after signature verification passes (5-second timeout, env from MinimalEnv).
   - Pick the highest version, sorting prereleases (`-alpha.N`) correctly. An override always wins, but must still pass signature verification.
2. **Launch app-server**:
   - argv: `["-c","features.plugins=false","-c","memories.generate_memories=false","-c","memories.use_memories=false","app-server","--listen","stdio://"]`.
   - If the process exits with a non-zero code within 1 second and stderr mentions an unknown or unexpected argument, retry once with `["app-server"]`. Remember the outcome per binary version (V6 will confirm these arguments).
   - env is `MinimalEnv.make(extra: ["CODEX_HOME": home?, "RUST_LOG": "error"])`.
   - After launch, verify again with `SecCodeCreateWithPID` and the same signature requirement; if it fails, kill it immediately. codex is not subject to the "never kill the subprocess" rule.
   - Before any process is launched (at the very start of the App's and CLI's main), call `signal(SIGPIPE, SIG_IGN)`.
3. **JSON-RPC** (`AppServerClient`):
   - Sends and receives through `LineTransport`:

     ```swift
     public protocol LineTransport: Sendable {
         func send(_ line: Data) async throws               // writes one line, appending "\n" internally; a failed write throws (EPIPE) rather than the process receiving SIGPIPE
         var incoming: AsyncThrowingStream<Data, Error> { get }  // one element per line; when the child process exits or EOF is read, finishes with .protocolError(.serverExited)
         func closeInput() async
         func terminate() async                             // SIGTERM, then SIGKILL if still running after 2 seconds
     }
     ```

     The production implementation splits lines in `readabilityHandler` and feeds them into the stream. As soon as incoming finishes, all pending request ids fail immediately.
   - **Request flow**:
     1. Send `initialize` with params `{clientInfo:{name:"tokenbar", title:"TokenBar", version}, capabilities:{experimentalApi:false}}` and wait for it to return.
     2. Send the `initialized` notification.
     3. Send `account/read {refreshToken:false}` (id 1) and `account/rateLimits/read {excludeResetCreditDetails:true}` (id 2). If id 2 returns `-32600` and the error message contains "invalid type", resend once without params.
   - **Message handling**: responses are matched by id; notifications are always ignored (an extra or missing field makes no difference). Requests from the server always get the reply `{"id":…,"error":{"code":-32601,"message":"not supported"}}`.
   - **Method allowlist**: only `initialize`, `initialized`, `account/read`, `account/rateLimits/read` are allowed. Any other method throws `.protocolError(.methodNotAllowed)` before it is sent.
   - **Shutdown**: `closeInput()` only after all responses have arrived. If it has not exited 3 seconds later, `terminate()`. The whole flow times out after 20 seconds.
4. **Mapping**:
   - `limits = rateLimitsByLimitId["codex"] ?? rateLimits`.
   - `primary` and `secondary` are classified by `windowDurationMins`: 300 → `.fiveHour`, 10080 → `.weekly`, 43200 → `.monthly`, anything else → `.other`. Either may be null. `resetsAt` is unix seconds.
   - `isStarted = !(usedPercent == 0 && |resetsAt − now − duration×60| ≤ 120 seconds)`.
   - `limitReached = rateLimitReachedType != nil || ordinaryUsageAllowed == false`.
   - Identity: `plan` comes from `planType`, capitalized. `email` is only shown live in Settings.
   - All fields are decoded as optional; unknown keys are ignored.
5. **Not logged in**: `account == null`, or an error message containing "authentication required", is recorded as `.notLoggedIn(.codex(home))`.
6. **Passive fallback**: used when no usable binary is found, on timeout, or on a protocol error.
   - In `$CODEX_HOME/sessions` and `archived_sessions`, take the 3 newest `rollout-*.jsonl` by modification time, reading only the last 512KB of each.
   - Parse the `token_count` events that carry `rate_limits`, **keeping only** events with `limit_id == "codex"` or with no `limit_id` field.
   - Take the newest snapshot that has at least one non-empty window. Windows are classified by `window_minutes`. The reset time prefers `resets_at` (epoch); otherwise use "event time + `resets_in_seconds`".
   - Source `.codexRollout(eventAt)`. **The Codex SQLite database is never opened.**

### 5.5 SessionMonitor (Claude sessions)

- Watched directories are as in §3.2. For each directory only `sessions/*.json` is listed; **`.key` files are never read**.
- Decoded into `SessionInfo {pid, sessionId, cwd, name, status(busy|idle|unknown), statusUpdatedAt, startedAt, procStart, kind, entrypoint, version, configDir}`. Unknown fields are ignored; an unrecognized `status` value is recorded as `.unknown`.
- **Only interactive sessions are shown**: `kind == "interactive"` or no `kind` field. Step ② subprocesses launched by TokenBar itself are also excluded; the aggregator publishes their pids.
- **Determining whether the process is alive**:
  - If `kill(pid, 0)` succeeds or returns `EPERM`, the process is considered to exist.
  - When `procStart` can be parsed (first collapse runs of spaces into one, then parse with `EEE MMM d HH:mm:ss yyyy`, `en_US_POSIX`, local time zone), compare it with `pbi_start_tvsec` from `proc_pidinfo(PROC_PIDTBSDINFO)`. A difference within 2 seconds means the same process.
  - If the difference is an exact multiple of 15 minutes and no more than 14 hours, it also counts as the same process. This usually means the time zone changed.
  - When `procStart` is missing or unparseable, only check that the process exists. When `proc_pidinfo` returns too short a length, also only check existence.
  - Only when `procStart` can be parsed and the times do not match is the file treated as stale. Stale files are only ignored, never deleted.
- **Polling rate**: every 3 seconds while the panel or floating window is visible; otherwise every 30 seconds. When the rate changes, the timer restarts immediately, so opening the panel triggers an immediate poll (see §6.1 for how visibility is determined).
- **Display**: busy sessions come first, ordered by `statusUpdatedAt` from earliest to latest, so the longest-running is at the top. Idle sessions are collapsed into a single expandable "N idle" row. Each row shows the name (`name`, or the last path component of `cwd` if absent), the status, and the duration (now − statusUpdatedAt).

### 5.6 CodeSignatureVerifier

- Implemented with Security.framework:
  1. `SecStaticCodeCreateWithPath(realpath)`;
  2. build the requirement with `SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"<TEAM>\"")`;
  3. call `SecStaticCodeCheckValidityWithErrors` with flags `kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode`.
- Verification runs on a dedicated `DispatchQueue` and is bridged to the caller through a continuation, so it does not occupy the Swift cooperative thread pool. **The file being verified is never executed during the process.**
- Team IDs: codex is `2DC432GLL2`, claude is `Q6L2SF6YDW`.
- Results are cached by `(realpath, st_dev, st_ino, st_size, st_mtimespec, st_ctimespec)`. Before launching a subprocess, stat once more; if any of these changed, verify again.

### 5.7 ProcessRunner and MinimalEnv

- `environment` is a required parameter with no default. Every caller builds the environment with `MinimalEnv.make(extra:)`, which contains only:
  - HOME, USER, LOGNAME (all from `userName`);
  - `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, TMPDIR;
  - the proxy variables HTTPS_PROXY, HTTP_PROXY, NO_PROXY, taken first from the `subprocessProxy` setting, then from the system proxy settings (`CFNetworkCopySystemProxySettings`).
  - It **never** carries any `*_API_KEY`, `*_TOKEN`, `ANTHROPIC_*`, `CLAUDE_CODE_*`, `CLAUDE_SECURESTORAGE_CONFIG_DIR`, `OPENAI_*`, `CODEX_API_KEY`, `CODEX_ACCESS_TOKEN` (guaranteed by unit tests).
- One-shot execution (`security`, `codex --version`):
  - stdin is closed after writing; stdout and stderr each collect at most 4MB.
  - On timeout or Task cancellation: SIGTERM first, SIGKILL after 2 seconds. Regardless of process state, the continuation resumes **exactly once** (`OSAllocatedUnfairLock<Bool>` prevents double resumption).
  - After the child process exits, wait at most 2 more seconds for EOF; on timeout, close the read ends, return the data received so far, and mark `pipesTruncated`.
  - In every case, the whole call returns within "timeout + 5 seconds".
- Streaming execution: provides the production `LineTransport` implementation for `codex app-server`.
- Detached execution: used for the step ② claude, see §5.3; based on `posix_spawn`, I/O to /dev/null, never signalled.

### 5.8 Aggregator, Scheduler and Storage

**UsageAggregator (actor)**

- Interface: `refresh(accounts:settings:trigger:) -> AsyncStream<(UUID, Result<UsageSnapshot, ProviderError>)>`. Each account's result is emitted as soon as it is ready, without waiting for the slowest one.
- Each account has an `inFlight[accountID] = (task, configFingerprint, trigger)`, which **must be written synchronously before the first await**. configFingerprint is a hash computed from the AccountConfig plus the relevant settings fields.
- When a new refresh request is merged directly into the one in progress: the fingerprint is the same, and either of these holds:
  - the one in progress is a manual refresh;
  - the new request is not a manual refresh.
- Otherwise, record `pendingRerun[accountID] = new trigger` and run once more after the current one finishes. Requests arriving in the meantime are all merged into this rerun.
- When a result arrives, if its fingerprint no longer matches the current settings, the result is discarded.
- There is also an outer 130-second safety timeout, recorded as `.timeout` when it fires. Normally the provider's internal deadline ends things earlier.

**RefreshScheduler (actor, in Core)**

- Accepts all refresh triggers and implements the periodic loop through the injected `sleep`, so it is testable. The App only forwards NSWorkspace sleep and wake events and button actions to it.
- Intervals: Claude uses `refreshIntervalMinutes`, Codex uses `max(refreshIntervalMinutes, 5)`.
- `willSleep`: cancel the periodic loop.
- `didWake`: wait 10 seconds, run one `.wake` refresh, then restart the periodic loop from that moment.
- On launch: load SnapshotStore first so the UI has data immediately, then run one `.launch` refresh.
- Within 60 seconds after an account has just refreshed successfully, further non-manual triggers are dropped.

**ConfigStore**

- File: `<appSupport>/config.json`, mode 0600, directory mode 0700, atomic writes.
- **Only the App creates and writes this file**. If the file does not exist, the CLI uses the default configuration in memory and does not write to disk.
- Decoding rules: every field except `accounts` uses `decodeIfPresent ?? default`; unknown keys are ignored.
  - `schemaVersion` higher than supported: the App shows a read-only error and does not write the file; the CLI exits with code 2.
  - Decoding failure: the App renames the file to `config.json.corrupt-<epoch>`, starts with the default configuration, and shows a warning; the CLI exits with code 2 without touching the file.
- Migrations are pure functions `migrate(vN) -> vN+1`, unit tested with fixture files.
- On every scheduled refresh and whenever the panel opens, the App checks the mtime of config.json; if it changed, it reloads, so hand edits also take effect.

**SnapshotStore**

- File: `<appSupport>/snapshots.json`, mode 0600, atomic writes. Only the App writes it.
- Contents: each account's most recent successful snapshot, and its most recent error. Emails are never persisted.

**StateStore**

- File: `<appSupport>/state.json`, mode 0600, atomic writes. Every read-modify-write first takes a `flock` on `state.lock`. **Both the App and the CLI read and write it.**
- Per-account records:
  - `backoffUntil`, `backoffReason`, `backoffTokenExpiresAt`;
  - `lastStep2At`, `step2InFlight{pid,startedAt}`, `step2FailedForTokenExpiresAt`;
  - `lastHTTPAt`;
  - `consecutiveRateLimits` (429s / bare 403s in a row, reset by a 200; default 0) and `lastRetryAfterSeconds` (diagnostic only);
  - `keychainAccess` (ok or deniedOrPrompting).
- Fields missing from an older `state.json` take their defaults.
- **Apart from `expiresAt`, no value derived from the token is stored.**

---

## 6. App (TokenBarApp)

### 6.1 Lifecycle, refresh and panel visibility

- `@main struct TokenBarApp: App` has two parts:
  - `MenuBarExtra(content: PanelView, label: MenuBarLabel).menuBarExtraStyle(.window)`;
  - `Settings { SettingsView }`.
- `AppModel` (`@MainActor @Observable`) holds this state: `accounts: [AccountState]`, `sessions`, `settings`, `lastRefreshAt`, `isPinned`, `isPanelVisible`. It consumes the aggregator's results one by one and writes them to SnapshotStore.
- **Whether the panel is visible**: SwiftUI has no ready-made API, so it works like this.
  1. `PanelView` embeds a zero-size `NSViewRepresentable` called `WindowObserver`.
  2. In `viewDidMoveToWindow` it gets the hosting NSWindow, then observes `NSWindow.didChangeOcclusionStateNotification`, `didBecomeKeyNotification`, `didResignKeyNotification`.
  3. Set `isPanelVisible = window.isVisible && window.occlusionState.contains(.visible)`.
  4. The floating window's visibility simply equals `isPinned`.
  5. SessionMonitor's polling rate is determined by `isPanelVisible || isPinned`.
- The panel's Refresh button sends a `.manual` trigger. It can bypass step ②'s 15-minute limit and the Keychain denied mark, but not a 429 backoff (in that case the button shows `Paused until HH:MM`).
- When the App is killed with SIGTERM, `applicationWillTerminate` does not run. So all state is persisted as soon as it changes, rather than saved at exit.

### 6.2 Menu bar label

- The content is `HStack(spacing: 3) { Image(systemName: …); Text(…) }`. The rules for the displayed number and the `?` and `!` suffixes are in rule 5 of display derivation in §5.1. Before there is any data, it shows `–`.
- The icon picks a different SF Symbol (gauge family) by status; `.critical` uses `exclamationmark.triangle.fill`.

### 6.3 Dropdown panel (340pt wide)

```text
TokenBar                                    📌  ⚙
─────────────────────────────────────────────────
Claude · Work                             Max
  5h      ███████░░░  32% left    6:10 PM
  Week    ██░░░░░░░░  81% left    Wed 11:00 PM
  Sonnet  █░░░░░░░░░  92% left    Wed 11:00 PM
  ● TokenBar              busy   3m
  ● NIW                   busy  11m
  ○ 4 idle ▸
Claude · Personal                         Pro
  ⚠ Unable to refresh · Last updated 14 min ago
  5h      …
Codex                                     Plus
  5h      ██████████ 100% left    not started
  Week    ████████░░  84% left    Mon 4:20 PM
─────────────────────────────────────────────────
Updated 22:41                    ↻ Refresh   Quit
```

- Progress bar colors follow status, using system colors: green, yellow, orange, red. The bar length and percentage text show remaining or used according to displayMode; the status color is always judged by the remaining amount.
- The right-hand column shows when each window resets as a local clock time (`6:10 PM`, `Wed 11:00 PM`, `Oct 23`; §5.1 rule 6), or `not started` / `reset`. It is wide enough for `Wed 12:00 AM` at the row font; the flexible bar gives up the room, so the panel width and the column alignment across cards are unchanged. Hovering shows the countdown (`Resets in 1d 12h`). Settings › General › Display › "Reset times" (Clock time / Countdown) switches the column to countdowns (`1d 12h`), with the clock time in the tooltip instead. The floating window shows the same panel content and follows the same setting.
- The card's status line appears only when something is wrong, with text generated from ProviderError and LoginHint:
  - on error: `⚠ <message>`;
  - when the data comes from a cache or log, or the most recent refresh failed: `Last updated N min ago`;
  - when the data comes from a cache: `(cached)`.
- When not logged in, the card shows a hint, the login command, and a Copy button.

### 6.4 📌 Floating window

- Implemented as `final class FloatingPanel: NSPanel`, configured as follows:
  - styleMask `[.nonactivatingPanel, .titled, .fullSizeContentView]`;
  - `titleVisibility = .hidden`, `titlebarAppearsTransparent = true`;
  - `level = .floating`;
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`;
  - `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`;
  - override `canBecomeKey` to return true.
- The content view is `DraggableHostingView<CompactView>`, which overrides `mouseDownCanMoveWindow` to return true so the window can be dragged.
- The window position is saved automatically with `setFrameAutosaveName("TokenBarFloating")`. The default position is the top-right corner of the main screen, 8pt below the menu bar.
- `CompactView` uses one row per account, e.g. `Work  32%  2h14m` (showing the worst window), followed by the number of running sessions, e.g. `●2`. A small 📌 in the top-right corner unpins it when clicked.
- The pinned state is remembered, and the floating window is restored automatically on the next launch. Showing the floating window does not change `NSApp.isActive` (selftest checks this).

### 6.5 Settings (Settings scene, two tabs)

**Accounts**

- Account list: reorder by dragging; `+` adds (Claude or Codex), `−` removes.
- Editable fields: display name, enabled, config directory or CODEX_HOME (text field plus a "Choose…" button), dedicated login toggle.
- Read-only: detected email (read live, never persisted), plan, status.

**Adding a Claude dedicated login**

1. First enter a name. A slug is generated from it, matching `[a-z0-9-]{1,32}`; if no slug can be generated, the name is rejected.
2. Create the directory `~/.tokenbar/claude/<slug>` with mode 0700, and set the account's `isDedicatedLogin` to true.
3. Generate the login command:

   ```text
   env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_CUSTOM_OAUTH_URL CLAUDE_CONFIG_DIR='<dir>' '<claude realpath>' auth login
   ```

   Every inserted value is wrapped in single quotes, and any `'` inside a value is escaped as `'\''`.
4. Provide a Copy button and an "Open in Terminal" button. "Open in Terminal" works like this:
   - write a script at `<tmp>/TokenBar/<UUID>.command`, created with `O_EXCL`, mode 0700;
   - open it with `open`;
   - delete the file after 60 seconds.
5. TokenBar checks this directory every 5 seconds: once `oauthAccount` appears in the config JSON, the login counts as successful, and a refresh runs automatically. When the first dedicated login completes, it suggests disabling the default account per the rules in §3.1.

**General**

- Refresh interval; display mode.
- Launch at login:
  - **The toggle state is not stored**; every time Settings opens and whenever the App is activated, `SMAppService.mainApp.status` is read directly.
  - `.enabled`: the toggle shows on.
  - `.requiresApproval`: the toggle shows on, with a line of explanation and an "Open Login Items" button (calls `SMAppService.openSystemSettingsLoginItems()`).
  - `.notRegistered` or `.notFound`: the toggle shows off.
  - Errors from registering or unregistering are shown in place.
  - When the App is not under `/Applications` or `~/Applications`, the toggle is disabled with a hint to run `scripts/install.sh` first.
- "Allow Claude Code to refresh expired dedicated logins" (on by default).
- claude and codex path overrides, with the currently detected path, version and signature status shown below.
- Subprocess proxy (optional).

**Opening the Settings window**: `@Environment(\.openSettings)` plus `NSApp.activate(ignoringOtherApps: true)`.

### 6.6 Selftest (`--selftest`)

- On launch, swap in stub providers: they return fixed snapshots, launch no subprocesses, make no network calls, and do not read the Keychain. The wake delay is set to 0.
- Checks: the status bar item exists, the panel opens, the Settings window opens, the floating window opens without stealing focus, and a refresh happens after wake. When everything passes, print `SELFTEST PASS` and exit with code 0.

---

## 7. CLI (tokenbar)

- `tokenbar status` prints a human-readable table with the same content as the panel.
- `tokenbar status --json` prints JSON like the following. The format is produced by dedicated DTOs (`StatusJSON`, `WindowJSON`) with hand-written CodingKeys, and the output is pinned by golden file tests:

  ```json
  {
    "generated_at": "2026-10-06T13:41:00Z",
    "accounts": [
      {
        "id": "…", "provider": "claude", "name": "Work", "plan": "Max",
        "source": "claude_api", "data_as_of": "…",
        "usage": 0.68, "reset_at": "…",
        "windows": [{"kind": "five_hour", "used_percent": 68, "remaining_percent": 32, "resets_at": "…", "started": true}],
        "error": null
      }
    ]
  }
  ```

- Field values:
  - `kind` can only be: `five_hour`, `weekly`, `weekly_sonnet`, `weekly_opus`, `model:<name>`, `monthly`, `other_<minutes>`.
  - `source` can only be: `claude_api`, `claude_api_after_cli_refresh`, `claude_cache`, `codex_app_server`, `codex_rollout`.
  - `error` is `{"code": "<enum case name>"}` or null.
  - All dates are ISO-8601 ending in Z.
  - `usage` (0-1) and `reset_at` come from the most constrained window after display derivation, matching the format of plan §7 Phase 1.
  - **The output contains no email and no accountUuid.**
- `tokenbar sessions [--json]` lists Claude sessions and the accounts they belong to.
- Options:
  - `--account <name>`;
  - `--allow-claude-refresh`: allows step ②. The CLI does not run step ② by default, because pressing Ctrl-C in the terminal could interrupt Claude Code's refresh.
- Exit codes: 0 means everything succeeded; 1 means at least one account failed, but whatever data is available is still printed; 2 means a configuration error.
- The CLI reads `config.json`, using the in-memory default configuration when it does not exist; it reads and writes `state.json`; it **does not write** `config.json` or `snapshots.json`.

---

## 8. Error Handling and UI States

| Situation | What the card shows |
|---|---|
| Success, live data | Normal display |
| Success, data from a cache or log | Normal display, plus `(cached · 14 min ago)` |
| Failure, with a previous snapshot | Previous data + `⚠ Unable to refresh: <reason>` + `Last updated N min ago` |
| Failure, with no snapshot at all | `⚠ <reason>` |
| Not logged in | Hint + login command + Copy |
| A non-dedicated account's token expired | Cached data + `Waiting for Claude Code to refresh` |
| Keychain access denied | Cached data + `Keychain access denied — showing cached data · Refresh to retry` |
| claude ≥ 2.1.289 not found | `⚠ Claude Code ≥ 2.1.289 not found — dedicated logins can't refresh` |
| codex not found, or signature mismatch | `⚠ Codex CLI not found` (the path can be set manually in Settings) |
| Not a Codex config directory | `⚠ Not a Codex profile — run CODEX_HOME=… codex login` |
| Rate-limited (429 / bare 403 backoff) | Previous data + `Anthropic is rate-limiting usage checks · next try 23:41` (no `Unable to refresh` prefix) + `Updated N min ago · cached`. CLI: `Paused until 23:41 · Anthropic is rate-limiting usage checks · Last updated …` |
| Other backoff (401 / 403 with an error body) | Previous data + `Paused until 23:41` |
| Account changed | `Account changed`, old data cleared |

---

## 9. Security and Privacy

1. **TokenBar stores no credentials.** The Claude access token lives only briefly in memory and is sent only to `https://api.anthropic.com`. The URLSession used is created from `URLSessionConfiguration.ephemeral`, with `urlCache = nil`, no cookies, and a delegate that refuses all redirects; **`URLSession.shared` is never used**. The token is never logged, never persisted, and never enters any Store.
2. **The TokenBar process itself never writes `~/.claude*`, `~/.codex` or the Keychain**, and never calls the OAuth token endpoint. But the subprocesses it launches write as usual:
   - `codex app-server` writes log lines, models_cache.json, SQLite auxiliary files and tmp under CODEX_HOME;
   - the step ② `claude -p "/usage"` runs only against dedicated directories; it rotates that directory's OAuth token (in the Keychain) and rewrites cachedUsageUtilization, sessions and other files (V2 will list every file written). Turning off `allowClaudeCodeRefresh` eliminates the latter.
   - In addition, TokenBar creates the empty directories for dedicated logins.
3. **No raw data leaks**: no ProviderError, log, Store record, or CLI output may **contain** any of the following:
   - subprocess stdout or stderr;
   - HTTP response bodies;
   - JSON values from the Keychain, `~/.claude.json`, or app-server results.

   Subprocess output is parsed in place as it is read and discarded after use. A "canary" unit test feeds a fake secret into every error path and asserts that it does not appear in the encoded snapshots.json, state.json, or CLI output.
4. **Signature verification**: only claude and codex binaries that pass signature verification are launched. Both verification and execution use the realpath, with a fresh stat before launch; scripts and shebang files are never executed; subprocess environments use MinimalEnv.
5. **Codex method allowlist**: JSON-RPC allows only allowlisted methods.
6. **Minimal reads**: only two keys are taken from the Claude config JSON; `sessions/*.key` is never read; the Codex SQLite database is never opened; `auth.json` is only stat'd, never read.
7. **Email**: shown only live in Settings; never persisted, never logged, never in CLI output.
8. **File permissions**: `config.json`, `snapshots.json` and `state.json` are all 0600, with their directory 0700; `~/.tokenbar` and dedicated login directories are 0700; temporary `.command` files are 0700 and deleted after 60 seconds.
9. **App Sandbox is not enabled**, because the app needs to read `~/.claude*` and `~/.codex` and launch external binaries. The App is ad-hoc signed and used only on this machine.

## 10. Performance

- Near-zero CPU when idle; memory (phys_footprint) target under 40MB.
- Cost per refresh:
  - Claude about 0.2-0.5 seconds, i.e. one HTTP request;
  - Codex about 0.5 seconds: launches one subprocess, peaking at 134MB, which exits when done; refresh interval at least 5 minutes;
  - **step ② runs at most once per token lifetime**, and is not retried automatically after failure.
- Opening the panel takes no more than 1 second: it shows the in-memory or on-disk snapshot directly, without waiting for the network.

## 11. Test Strategy

**Unit tests** use swift-testing and run via `scripts/test.sh`. The script checks that at least 1 test ran and runs the grep guard from §4.2. Coverage:

- **Service name derivation**:
  - `nil` → `Claude Code-credentials`;
  - `"/Users/xai/.claude"` → `…-4405f529`;
  - `"/Users/xai/.claude/"` → `…-338287a3`;
  - precomposed and decomposed forms of characters give the same result;
  - the userName derivation rule.
- **Credentials**:
  - JSON parsing, with extra secrets discarded;
  - expiry check with a 5-minute margin;
  - an empty accessToken counts as not logged in;
  - handling of a missing user:profile scope.
- **Claude usage response**:
  - null values, an entirely null window, usage over 100;
  - ISO times with 0, 1, 3, 6 and 9 fractional-second digits, with time zones `+00:00` and `Z`;
  - epoch numbers;
  - per-model rows in `limits[]`;
  - unknown keys.
- **`cachedUsageUtilization`**: not used when the accountUuid differs; only valid if later than the start of step ②.
- **Config JSON**: `.config.json` takes precedence; only two keys are extracted.
- **BackoffPolicy and StateStore**:
  - backoff for 401 and 403 with an error body is bound to the token and cleared as soon as the token changes;
  - 429 and bare 403 (with or without Retry-After): exponential 5 → 60 minutes over consecutive rate limits, a larger Retry-After wins, capped at 1 hour; a 200 resets the count;
  - a fresh Claude Code cache (newer than `lastHTTPAt`, within the refresh interval, same account) replaces a non-manual request;
  - manual refresh cannot bypass a 429 backoff;
  - concurrent reads and writes under `flock`;
  - non-manual requests at least 60 seconds apart.
- **Full ClaudeProvider flow**: with fake credential reader, HTTP, refresher, config reader and Store, covering:
  - every branch of ①②③;
  - non-dedicated accounts never run step ②;
  - step ② does not run while there are active sessions;
  - step ② does not start while one is already running;
  - no automatic retry once `step2Failed` is marked;
  - the 15-minute limit, and manual refresh bypassing it;
  - degrading to step ③ after deadline truncation;
  - after the Keychain returns denied, scheduled refreshes no longer prompt;
  - detection of account changes.
- **ProcessRunner**:
  - a grandchild process spawned by the child keeps stdout open (`/bin/sh -c 'sleep 30 & exit 0'`), and the call still returns within budget;
  - the continuation resumes only once on timeout or cancellation;
  - MinimalEnv does not pass sensitive variables to subprocesses.
- **AppServerClient** (with a fake LineTransport):
  - handshake, out-of-order responses, notifications (including ones with `emittedAtMs`);
  - replying -32601 to requests from the server;
  - retrying without params after -32600;
  - not logged in;
  - timeout;
  - server exiting before responding, and sending after exit;
  - the allowlist rejecting disallowed methods;
  - launch arguments pinned, falling back to `app-server` when they are not accepted.
- **Codex mapping**:
  - classification by duration: weekly window only, 30-day window, null primary;
  - determining whether a window has started;
  - limitReached;
  - preferring `rateLimitsByLimitId`.
- **CODEX_HOME validation**: the three cases of directory missing, empty, or a valid configuration.
- **RolloutReader**: sample data lines, keeping only rows whose limit_id is codex or that have no limit_id, empty windows, `resets_in_seconds`.
- **SessionMonitor**:
  - parsing;
  - process liveness and procStart checks, including time zone offsets, unparseable values, and `proc_pidinfo` returning too short a length;
  - assignment, and dedicated accounts taking precedence;
  - keeping only interactive sessions, excluding processes launched by TokenBar itself;
  - ordering.
- **BinaryLocator (claude, codex)**:
  - candidate collection, `.obsolete` exclusion, realpath;
  - excluding JS launcher scripts and shebang files;
  - version ordering (including alpha), override precedence;
  - candidates that fail signature verification are excluded;
  - never running `--version` on claude.
- **Display derivation**:
  - windows whose reset time has passed;
  - all windows not started;
  - status boundary values 50, 20, 5;
  - which value the menu bar picks, and the `?` and `!` suffixes;
  - displayMode=used;
  - reset time format: clock times (same day, within a week, a week or more, the midnight boundary) and countdowns.
- **UsageAggregator**:
  - keeping the previous snapshot on failure;
  - merge rules covering three cases: a manual request meeting a scheduled refresh, a config change, and actor reentrancy;
  - results emitted in arrival order;
  - discarding results with a stale fingerprint.
- **RefreshScheduler** (with a fake sleep): interval changes, sleep and wake, dropping new triggers within 60 seconds after a successful refresh, launch order.
- **ConfigStore**: defaults for missing fields, unknown keys, schemaVersion too high, corrupt file, migration fixtures, CLI read-only.
- **CLI**: golden file tests; output contains no email or accountUuid; exit codes.
- **Canary test**: see §9.3.
- **Shell quoting and slug generation**: inputs with special characters such as spaces, quotes and newlines.

**Local integration smoke tests** (run by me during implementation):

- the Codex part of `tokenbar status --json`, against the real app-server;
- `tokenbar sessions`;
- the App's `--selftest`.

**What you need to do on this machine**: see §13.

## 12. Build, Bundling and Installation

- Every script forces `DEVELOPER_DIR=/Library/Developer/CommandLineTools`.
- `scripts/test.sh`: carried over from Phase 0, with the grep guard from §4.2 added.
- `scripts/bundle.sh`: produces `dist/TokenBar.app`, ad-hoc signed, with `LSUIElement` set.
- `scripts/install.sh`: copies to `~/Applications/TokenBar.app` with `ditto`, quits the running old instance, and opens the new one.
- bundle id `dev.tokenbar.TokenBar`, version 0.1.0.
- `.gitignore` includes: `.build/`, `.build-tests/`, `dist/`, `.swiftpm/`.

## 13. Items to Verify (complete as early as possible during implementation)

| # | What to verify | Who | If it fails |
|---|---|---|---|
| V1 | ✅ **Verified (2026-10-06, scripts/probe-claude-usage.sh)**: no prompt, exit code 0, 0.08 seconds. Original question: does `tokenbar status` trigger a prompt when reading the Claude Keychain, and is the data correct; if a prompt appears and you click Deny, record the exit code and stderr | **You** (I am barred from Keychain access by permission policy) | If it prompts, click "Always Allow". The grant is for `/usr/bin/security`, so it stays valid after TokenBar is rebuilt. If you deny, that account uses step ③ only, and the card shows `Keychain access denied` |
| V2 | Whether `claude -p "/usage"` really does not call the model, whether it can refresh an expired token, which files it writes in the dedicated directory (including whether it shows up in sessions and what its `kind` value is), and whether it triggers hooks | You set up a dedicated login first, then I run it in that dedicated directory (or you can run it) | If there are side effects, disable step ② by default and use only ①③ |
| V3 | ✅ **Verified (2026-10-06)**: HTTP 200. There are many more top-level keys than reverse engineering found, including experimental fields such as `amber_cistern`, `seven_day_breakdown`, `seven_day_cowork`, `spend`, which the parser can simply ignore. `limits[]` contains per-model rows (`scope.model.display_name` = "Fable", `percent` = 79), and this is in fact the account's tightest limit right now. Original question: does the real `/api/oauth/usage` response format match the parser | Together with V1 | The parser itself is tolerant |
| V4 | Whether launch at login (SMAppService) is allowed by policy on this managed Mac, and whether each status displays correctly | You (try turning on the toggle in Settings) | Do not offer the feature |
| V5 | Whether terminal versions 2.1.123 and 2.1.174 write `sessions/<pid>.json`, and whether the fields are the same | You open one session in each in the terminal; I check | If they do not, note "Terminal sessions require Claude Code ≥ <version>" in the sessions section |
| V6 | Whether the codex launch arguments (`-c features.plugins=false` and the two memories arguments) are accepted by new versions; confirm in a temporary CODEX_HOME that the plugin repository is not cloned | Me (only with a codex that passes signature verification) | Fall back to `app-server` only |
| V7 | Whether logging an account in again in a dedicated directory invalidates the same account's everyday login in `~/.claude` (confirm after waiting 8+ hours, or after the everyday token expires) | You | If it does, only create a dedicated login for "the account you do not use in `~/.claude`" |

## 14. Later (after the MVP)

- Per-session token statistics: incrementally parse `message.usage` in the transcript JSONL
- Low-quota notifications; notify when a session goes from busy to idle
- Usage history and charts
- Codex session list; token statistics via `account/usage/read`
- Optional statusLine wrapper: save the `rate_limits` that Claude Code passes to statusLine over stdin (0-100, epoch seconds) as a live data source that needs no secrets; only works for interactive sessions in the terminal
- Custom icons; more providers (Gemini, Copilot, Cursor)

## 15. v2 Changes Relative to v1 (from the review)

- **Blocking**:
  - added the claude binary lookup rules (§5.3.2);
  - step ② runs only in dedicated login directories, and only when the directory has no live sessions (§5.3);
  - TokenBar never signals the claude subprocess; it is launched in its own group via posix_spawn with I/O to /dev/null (§5.3, §5.7).
- **Major**:
  - config directory paths are now stored as raw strings (§3.1);
  - handling of Keychain prompts and denials, to avoid repeated prompts (§5.3 steps 0 and 1);
  - backoff and step ② state are now persisted, shared by the App and CLI, and cleared as soon as the token changes (StateStore);
  - the wording of §9.2 made more precise;
  - display derivation: windows whose reset time has passed are always shown as reset (§5.1);
  - ProviderError changed to a closed set, with a canary test added;
  - handling when a default account and a dedicated account coexist, and detection of account changes;
  - ProcessRunner can no longer be blocked by grandchild processes, ignores SIGPIPE, and LineTransport is defined;
  - WindowObserver is used to determine panel visibility;
  - each provider has its own deadline;
  - refresh merge semantics defined, with results emitted in arrival order;
  - config schema evolution and corruption handling, and only the App writes config;
  - all side effects injected through CoreEnvironment;
  - RefreshScheduler moved into Core and made testable;
  - the URLSession for usage requests changed to ephemeral, refusing redirects.
- **Minor**:
  - documented the conditions under which cachedUsageUtilization is written;
  - after step ②, check the cache first before deciding whether to call the endpoint;
  - unset two environment variables in the login command, and documented the userName derivation rule;
  - map per-model rows in `limits[]`;
  - CODEX_HOME validation, and a Codex refresh interval of at least 5 minutes;
  - subprocess proxy;
  - added V5, V6, V7;
  - fixed edge cases around time zones and procStart;
  - security rules for .command files and slugs;
  - emails never persisted;
  - fixed duplicate refreshes on sleep and wake;
  - MinimalEnv made required;
  - the floating window can be dragged;
  - launch at login now displays the actual state;
  - the CLI uses dedicated DTOs, with golden file tests added.
