# TokenBar MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to carry out this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build TokenBar, a macOS menu bar app plus a `tokenbar` CLI. It shows Claude Code and Codex plan usage for several accounts, and lists running Claude Code sessions. The behavior is specified in [the design spec v2](../specs/2026-10-05-tokenbar-mvp-design.md).

**Architecture:** One SwiftPM package with three parts:
- `TokenBarCore`: nonisolated logic. All side effects go through `CoreEnvironment`.
- `TokenBarCLI`: the `tokenbar` executable.
- `TokenBarApp`: a SwiftUI `MenuBarExtra`, bundled as `TokenBar.app` by `scripts/bundle.sh`.

The spec is the behavioral source of truth. This plan fixes the file layout, the order of work, the shared contracts, and the acceptance checks.

**Tech Stack:**
- Swift 6.2 with Command Line Tools only (no Xcode); Swift 6 language mode; minimum target macOS 14.
- swift-testing via `scripts/test.sh`.
- Apple frameworks: CryptoKit, Security.framework, Foundation `Process`/`posix_spawn`, URLSession (ephemeral), SwiftUI/AppKit, ServiceManagement.

**How code reaches this plan:** Task 1 (the contract) is written directly into the repository and committed; those files are the exact interfaces every later task compiles against. For Tasks 2–8, the executing agent writes the code test-first (TDD) against the spec sections listed in the task. Each task names the files it owns, the tests it must add, and the commands that must pass. **An agent edits only the files it owns.** If a contract file looks wrong, the agent reports that and does not edit it.

---

## Global rules for every task

- Run every command with `export DEVELOPER_DIR=/Library/Developer/CommandLineTools`. The scripts already set it.
- Build with `swift build`. Run tests with `scripts/test.sh`, never with plain `swift test`. `scripts/test.sh` fails when 0 tests ran, and fails when Core code calls `Date()`, `Process()`, `URLSession.shared`, `NSHomeDirectory()` or `homeDirectoryForCurrentUser` outside `Sources/TokenBarCore/Environment/Live*.swift`.
- Tests must not touch the real `~/.claude*`, `~/.codex`, `~/Library` or the keychain:
  - put all paths under a per-test temp dir (`TempDir`);
  - fake every subprocess and every HTTP call (`FakeProcessRunner`, `FakeHTTPClient` in `Tests/TokenBarCoreTests/Support/TestSupport.swift`).
- Never run `security`, and never read `~/.codex/auth.json`, `.credentials.json` or `sessions/*.key`. Executing claude or codex is allowed only for binaries whose code signature has been verified (Team IDs: claude `Q6L2SF6YDW`, codex `2DC432GLL2`). The live CLI smoke test may run only the **Codex** account (`--account Codex`), never a Claude account, because a Claude account reads the keychain.
- No secrets in logs, errors, stores or CLI output (spec §9.3). Never print subprocess stdout/stderr, HTTP bodies, or JSON values from credential or config files.
- Commit after each green step. Messages use conventional prefixes (`feat:`, `test:`, `fix:`, `chore:`) and end with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## File map

| Path | Owner | Responsibility |
|---|---|---|
| `Package.swift`, `.gitignore`, `scripts/test.sh`, `scripts/bundle.sh`, `scripts/install.sh` | Task 1 | Build, test and bundle infrastructure |
| `Sources/TokenBarCore/Models/*.swift` | Task 1 | Value types from spec §5.1: accounts, settings, windows, snapshots, errors, state, sessions, status |
| `Sources/TokenBarCore/Models/DisplayDerivation.swift` | Task 1 | Pure display rules from spec §5.1 |
| `Sources/TokenBarCore/Environment/Effects.swift`, `CoreEnvironment.swift` | Task 1 | Effect protocols and the injected environment (spec §4.2) |
| `Sources/TokenBarCore/Environment/LocalFileSystem.swift` | Task 1 | Live `FileSystemAccess` (FileManager, stat, flock); tests use it with temp dirs |
| `Sources/TokenBarCore/Providers/Contracts.swift` | Task 1 | `UsageProvider`, `RefreshContext`, `BinaryLocating`, `ClaudeConfigReading` |
| `Sources/TokenBarCore/Services/StateStoring.swift` | Task 1 | `StateStoring` protocol, `AccountRuntimeState`, `InMemoryStateStore` |
| `Sources/TokenBarCore/Support/{ClaudePaths,MinimalEnv,SemVer,Formatting}.swift` | Task 1 | Pure helpers |
| `Tests/TokenBarCoreTests/Support/TestSupport.swift` | Task 1 | Shared fakes: `TestClock`, `TempDir`, `FakeProcessRunner`, `FakeHTTPClient`, `FakeSignatureVerifier`, `FakeProcessInspector`, `makeTestEnvironment` |
| `Sources/TokenBarCore/Support/{DateParsing,ShellQuoting}.swift`; `Sources/TokenBarCore/Services/{ConfigStore,SnapshotStore,StateStore}.swift` | Task 2 | Date parsing, quoting and slugs, the three stores |
| `Sources/TokenBarCore/Environment/Live*.swift` (except LocalFileSystem); `Sources/TokenBarCore/Support/{ProcessRunner,LineTransportImpl,DetachedSpawner,CodeSignatureVerifier,BinaryLocator}.swift` | Task 3 | Live process, HTTP, signature, inspector and proxy implementations; Claude and Codex binary locators |
| `Sources/TokenBarCore/Providers/Claude/*.swift` | Task 4 | Claude credential reader, config reader, usage mapping and client, Code refresher, provider |
| `Sources/TokenBarCore/Providers/Codex/*.swift`; `Sources/TokenBarCore/Services/SessionMonitor.swift` | Task 5 | Codex app-server client, mapper, rollout reader and provider; session monitor |
| `Sources/TokenBarCore/Services/{UsageAggregator,RefreshScheduler}.swift` | Task 6 | Refresh merging and scheduling |
| `Sources/TokenBarCore/Runtime/*.swift`, `Sources/TokenBarCore/CLI/*.swift`, `Sources/TokenBarCLI/*.swift` | Task 7 | Composition root, CLI output DTOs, CLI executable |
| `Sources/TokenBarApp/**` | Task 8 | The SwiftUI/AppKit app, `--selftest` |

Each task's tests go in `Tests/TokenBarCoreTests/<Area>/…Tests.swift`, in the same area the task owns. Task 8 has no unit tests; it is verified by `--selftest` and the build.

## Execution order

```text
Task 1 (contract, inline) ──► [Task 2 ‖ Task 3 ‖ Task 4 ‖ Task 5 ‖ Task 6]  (parallel, one git worktree each)
                          ──► merge + full test run ──► [Task 7 ‖ Task 8] ──► merge ──► review ──► Task 9 (verification)
```

---

### Task 1: Scaffold and shared contract (done inline by the lead)

**Files:** everything marked "Task 1" in the file map.

- [ ] Write `Package.swift`:
  - tools 6.2, macOS 14, Swift 6 mode;
  - products `TokenBarCore`, `tokenbar` (TokenBarCLI) and `TokenBarApp`; the App target uses `.defaultIsolation(MainActor.self)`;
  - test target `TokenBarCoreTests` with `exclude: ["Fixtures"]`.
- [ ] Write the scripts:
  - `scripts/test.sh` is the Phase 0 version plus the grep guard;
  - `scripts/bundle.sh` is the Phase 0 version;
  - `scripts/install.sh` copies `dist/TokenBar.app` to `~/Applications` with `ditto`, quits any running instance, then opens the new one.
- [ ] Write the Models, Environment, contract protocols, helpers and TestSupport. Contract decisions:
  - `UsageProvider.fetchUsage` returns `ProviderOutcome {snapshot, warning}`. `warning` is set when data came from a fallback path because of an error, e.g. cache shown while the keychain was denied. The method throws `ProviderError` only when there is no data at all.
  - Aggregator results are `AccountRefreshEvent`. `AccountState.apply(_:wakeGraceUntil:)` encodes spec §5.3 (account change, wake grace).
  - Tests use the real `LocalFileSystem` with temp dirs, and fakes for processes, HTTP, signatures, the clock and process inspection.
- [ ] Add placeholder executables so the package builds. Tasks 7 and 8 replace them:
  - the CLI prints `tokenbar: CLI not built yet` and exits 2;
  - the App is a bare MenuBarExtra.
- [ ] Add `Tests/TokenBarCoreTests/ContractTests.swift`:
  - keychain service vectors (`nil`, `"/Users/xai/.claude"` → `-4405f529`, `"/Users/xai/.claude/"` → `-338287a3`, NFC equivalence);
  - defaults and decode-with-missing-fields for `AppSettings`;
  - `MinimalEnv` drops forbidden keys;
  - `SemVer` ordering, including `-alpha.N` and the `aN` form;
  - `DisplayDerivation`: boundary values 50/20/5, a reset in the past, no started windows, menu bar `?`/`!`;
  - `Formatting.countdown`.
- [ ] Run `swift build && scripts/test.sh`. Expected: build succeeds, all ContractTests pass, and at least one test ran.
- [ ] Commit `feat: package scaffold and shared contract`.

### Task 2: Date parsing, quoting and stores (spec §5.3.1 DateParsing, §6.5 slug and quoting, §5.8 stores)

**Files:** `Support/DateParsing.swift`, `Support/ShellQuoting.swift`, `Services/ConfigStore.swift`, `Services/SnapshotStore.swift`, `Services/StateStore.swift`. Tests go in `Tests/TokenBarCoreTests/Stores/*` and `Tests/TokenBarCoreTests/Support/DateParsingTests.swift`.

- [ ] **`DateParsing.flexible(_ value: Any?) -> Date?`**
  - Try `ISO8601DateFormatter` with `[.withInternetDateTime, .withFractionalSeconds]` first, then `[.withInternetDateTime]`.
  - Treat a number as epoch seconds.
  - Return nil when nothing parses.
  - Create the formatters per call (they are not Sendable).
  - **Tests:** 0/1/3/6/9 fractional digits; `+00:00` and `Z`; an Int and a Double epoch; garbage → nil.
- [ ] **`DateParsing.procStart(_ s: String, timeZone: TimeZone) -> Date?`**
  - Collapse runs of whitespace, then parse `EEE MMM d HH:mm:ss yyyy` with the `en_US_POSIX` locale.
  - **Tests:** `"Tue Oct  6 05:33:53 2026"`; garbage → nil.
- [ ] **`ShellQuoting`**
  - `quote(_:)` wraps the value in `'…'` and escapes `'` as `'\''`.
  - `slug(from:) -> String?` returns `[a-z0-9-]{1,32}` or nil.
  - `claudeLoginCommand(configDir:claudePath:) -> String` builds exactly the `env -u … CLAUDE_CONFIG_DIR='…' '…' auth login` line from spec §6.5.
  - **Tests:** input with spaces, a single quote, a newline, `$()` and unicode; slug edge cases.
- [ ] **`ConfigStore`** (`env:`)
  - `load() throws(ConfigLoadError) -> AppSettings`, where `ConfigLoadError` is `.missing`, `.corrupt` or `.tooNew(Int)`.
  - `loadOrDefault(forApp: Bool)`. In App mode a corrupt file is renamed to `config.json.corrupt-<epoch>` and defaults are returned along with a warning flag. In CLI mode nothing is written.
  - `save(_:)` writes 0600 into a 0700 directory, atomically.
  - `modificationDate()`.
  - A `migrate` hook for v1 (identity).
  - **Tests:** missing; corrupt (app vs CLI); a too-new schema; unknown keys ignored; missing fields defaulted; file permissions; the CLI path never writes.
- [ ] **`SnapshotStore`** (`env:`)
  - `load() -> [UUID: StoredAccountState]` and `save(_:)`, with 0600 permissions.
  - **Tests:** round trip; `email` is never written (encode a snapshot that has an email, then assert the bytes do not contain it).
- [ ] **`StateStore: StateStoring`** (`env:`)
  - Backed by `state.json` (0600), guarded by `flock` on `state.lock`.
  - `read`/`update` are atomic read-modify-write.
  - **Tests:** concurrent updates from two `StateStore` instances on the same dir lose nothing (100 increments of a test field via `lastHTTPAt` timestamps); permissions; corrupt file → empty state.
- [ ] Run `scripts/test.sh` until green, then commit after each component.

### Task 3: Live effects and binary locators (spec §5.6, §5.7, §5.3.2, §5.4 step 1, §9.1)

**Files:**
- `Environment/LiveEnvironment.swift`: `extension CoreEnvironment { static func live() }`, `LiveHTTPClient`, `LiveProcessInspector`, `systemProxy`
- `Support/ProcessRunner.swift`
- `Support/LineTransportImpl.swift`
- `Support/DetachedSpawner.swift`
- `Support/CodeSignatureVerifier.swift`
- `Support/BinaryLocator.swift`

Tests go in `Tests/TokenBarCoreTests/Process/*` and `Tests/TokenBarCoreTests/Binaries/*`.

- [ ] **`LiveProcessRunner: ProcessRunning`**
  - `run`: one-shot. Returns within `timeout + 5 s` no matter what the pipes do. After the child exits, waits at most 2 s for EOF. On timeout or cancel: SIGTERM, then SIGKILL after 2 s, and the continuation resumes exactly once (`OSAllocatedUnfairLock`).
  - `startStreaming` returns `LineTransport`: lines are split in `readabilityHandler`; the stream finishes with `ProtocolErrorCode.serverExited` on EOF; `send` throws instead of raising SIGPIPE.
  - `spawnDetached`: `posix_spawn` with `POSIX_SPAWN_SETPGROUP`, stdio set to `/dev/null`, never signalled. `waitForExit(timeout:)` uses a `DispatchSource` process-exit source, and a background reaper calls `waitpid`.
  - **Tests** (real `/bin/sh` and `/bin/echo`):
    - stdout and stderr captured;
    - exit code;
    - timeout kills `sleep 30`;
    - a grandchild holding stdout (`/bin/sh -c 'sleep 30 & exit 0'`) still returns within the budget;
    - cancellation;
    - `startStreaming` with `/bin/cat` echoes lines, and the stream finishes on EOF;
    - `send` after exit throws;
    - `spawnDetached` with `/bin/sleep 1` returns its exit, and returns nil when the timeout is shorter than the run;
    - the env passed is exactly the given dictionary (the child runs `/usr/bin/env`).
- [ ] **`LiveHTTPClient: HTTPClient`**
  - Built from `URLSessionConfiguration.ephemeral`, with `urlCache = nil`, cookies disabled and `requestCachePolicy = .reloadIgnoringLocalCacheData`.
  - A delegate refuses every redirect, so the error is `.redirectRefused`.
  - **Tests:** unit-test the delegate's redirect decision and the session configuration properties. No network.
- [ ] **`LiveProcessInspector`**
  - `isAlive`: `kill(pid,0) == 0` or `errno == EPERM`.
  - `startTime`: `proc_pidinfo(PROC_PIDTBSDINFO)`, returning nil when the result is shorter than the struct.
  - **Tests:** the current pid is alive and its start time is close to `ProcessInfo` uptime math; pid 999999 is not alive.
- [ ] **`LiveCodeSignatureVerifier`**
  - Static check: `SecStaticCodeCreateWithPath` + `SecRequirementCreateWithString` + `SecStaticCodeCheckValidityWithErrors` with strict, all-architectures and nested-code flags, run on a dedicated serial `DispatchQueue`.
  - `verifyRunningProcess`: `SecCodeCopyGuestWithAttributes` with the pid, then `SecCodeCheckValidity`.
  - **Tests:**
    - `/bin/ls` fails the requirement for team `2DC432GLL2`;
    - if a VS Code codex exists at a real path on this machine, verifying it for `2DC432GLL2` passes (skip when absent);
    - a non-Mach-O file fails.
- [ ] **`BinaryLocator: BinaryLocating`**
  - Candidate lists come from spec §5.3.2 (claude) and §5.4 step 1 (codex), including the npm vendor path, `.obsolete` handling for every editor extensions dir, and realpath.
  - A candidate must be a regular file with the Mach-O magic (`FEEDFACF`, `CAFEBABE` or `BEBAFECA`), have the exec bit, and pass the signature check.
  - Versions come from: the folder name, the `versions/<ver>` component, `codex-package.json` or npm `package.json`. Codex may fall back to running `--version` **after** verification. Claude is never executed for its version.
  - Selection: the highest version; claude must be ≥ 2.1.289; the override wins but must still pass verification.
  - Cache keyed by (realpath, dev, ino, size, mtime, ctime). Stat again right before returning.
  - **Tests:** build fake trees under a temp HOME with `FakeSignatureVerifier`, covering:
    - `.obsolete` exclusion;
    - a JS shim excluded;
    - a shebang file excluded;
    - version ordering with alpha versions;
    - the override, and an override below 2.1.289;
    - verifier rejection;
    - symlink → realpath;
    - claude is never passed to the ProcessRunner.
- [ ] **`CoreEnvironment.live()`**
  - `userName`: `USER`, falling back to `getpwuid`, validated by `ClaudePaths.keychainAccount`.
  - `appSupportDirectory` = `~/Library/Application Support/TokenBar`.
  - `systemProxy` from `CFNetworkCopySystemProxySettings`.
- [ ] Run `scripts/test.sh` until green, then commit after each component.

### Task 4: Claude provider (spec §5.3, §5.3.1, §2.1)

**Files:** `Providers/Claude/ClaudeCredentialReader.swift`, `ClaudeConfigReader.swift`, `ClaudeUsageMapper.swift`, `ClaudeUsageClient.swift`, `ClaudeCodeRefresher.swift`, `ClaudeProvider.swift`. Tests go in `Tests/TokenBarCoreTests/Claude/*`, with fixtures in `Tests/TokenBarCoreTests/Fixtures/claude/`.

- [ ] **`ClaudeCredentialReader`**
  - Runs `/usr/bin/security find-generic-password -a <account> -w -s <service>` through `env.processRunner`. Timeout is 10 s, or 60 s for a manual refresh. A global serial gate ensures one `security` runs at a time.
  - Exit-code and stderr classification follows spec §5.3 step 1.
  - Exit 44 → retry with the trailing-slash variant, then fall back to `.credentials.json`.
  - Parses hex-encoded output too. Keeps only `{accessToken, expiresAt, scopes, subscriptionType}`.
  - **Tests:** every exit code; stderr "User canceled"; a timeout; hex output; extra secret keys dropped (assert that no other key survives in the returned struct); an empty token.
- [ ] **`ClaudeConfigReader: ClaudeConfigReading`**
  - Uses the `.config.json` precedence.
  - Extracts **only** `oauthAccount` and `cachedUsageUtilization` with `JSONSerialization`.
  - **Tests:** a fixture containing `mcpServers.env` secrets → those values never appear in the result's `String(describing:)`; precedence; malformed JSON → nil.
- [ ] **`ClaudeUsageMapper`**
  - Maps top-level windows and `limits[]` model rows. Skips windows that are null or not an object; ignores unknown keys; computes limitReached.
  - Also maps `cachedUsageUtilization.utilization` (same shape).
  - **Tests:** the fixture from `docs/phase0/artifacts/claude__usage-response-example.json` (first object; strip the `//` lines); null cases; >100; epoch `resets_at` on limit rows.
- [ ] **`ClaudeUsageClient`**
  - GET `https://api.anthropic.com/api/oauth/usage` with the exact headers. Maps 200, 401, 403-with-body vs bare 403, 429 + Retry-After, and network errors.
  - **Tests** with `FakeHTTPClient`: header assertions, including that the `Authorization` value is never present in thrown errors; each status.
- [ ] **`ClaudeCodeRefresher`**
  - Runs the step ② mechanics through `env.processRunner.spawnDetached`, using `BinaryLocating` for claude.
  - The fixed cwd is `<appSupport>/claude-cwd` with mode 0700.
  - Registers `step2InFlight` in StateStoring before spawning and clears it afterwards. Never signals the child.
  - **Tests:** argv is exactly `[realpath, "-p", "/usage"]`; env comes from `MinimalEnv` with `CLAUDE_CONFIG_DIR`; no spawn when another is in flight; on timeout it returns `.stillRunning` and does not kill.
- [ ] **`ClaudeProvider: UsageProvider`**
  - Implements the whole flow 0 → 1 → ① → ② → ③ → 5 from spec §5.3, including the deadline budgeting, the dedicated-only and no-live-sessions conditions for ② (it takes a `liveSessionChecker` closure), the 15-minute limit with the manual bypass, `step2Failed`, token-bound backoff, the 60 s HTTP spacing, account-change detection, and cache-first after ②.
  - **Tests:** one test per branch listed in spec §11 under "ClaudeProvider 的完整流程", using fakes and `InMemoryStateStore`.
- [ ] Run `scripts/test.sh` until green, then commit after each component.

### Task 5: Codex provider and session monitor (spec §5.4, §5.5, §3.2, §3.3)

**Files:** `Providers/Codex/AppServerClient.swift`, `CodexRateLimitMapper.swift`, `RolloutReader.swift`, `CodexProvider.swift`; `Services/SessionMonitor.swift`. Tests go in `Tests/TokenBarCoreTests/Codex/*` and `Tests/TokenBarCoreTests/Sessions/*`. Fixtures are the Phase 0 samples, redacted.

- [ ] **`AppServerClient`**
  - Takes `any LineTransport`.
  - Runs the handshake, sends the two pipelined requests, matches responses by id, ignores notifications (tolerating extra keys such as `emittedAtMs`), and answers server requests with -32601.
  - On a -32600 "invalid type" error, retries without params.
  - Enforces the method allowlist.
  - Calls `closeInput()` only after all responses arrive, then waits 3 s before `terminate()`. Overall timeout is 20 s.
  - **Tests:** a scripted `FakeLineTransport` (defined in the test file), covering every case in spec §11 under "AppServerClient".
- [ ] **`CodexRateLimitMapper`**
  - Windows are classified by duration.
  - `isStarted` uses the ±120 s rule.
  - limitReached; plan; prefers `rateLimitsByLimitId["codex"]`.
  - **Tests:** the real result example; a weekly-only plan; a 30-day window; a null primary.
- [ ] **`RolloutReader`**
  - Reads the 3 newest files under `sessions` and `archived_sessions`, 512 KB tail each.
  - Keeps rows where `limit_id == codex` or `limit_id` is missing.
  - Uses `resets_at` or event time + `resets_in_seconds`. Never opens SQLite.
  - **Tests:** fixture lines with mixed limit_ids, null windows, and a partial first line in the tail.
- [ ] **`CodexProvider: UsageProvider`**
  - `CODEX_HOME` validation (exists and contains `config.toml` or `auth.json`, stat only).
  - Locates the binary through `BinaryLocating`.
  - Spawns the exact argv from spec §5.4 step 2, with the unknown-argument fallback remembered per version, and a minimal env.
  - Verifies the running pid's signature; kills on failure.
  - Falls back to the rollout data.
  - `notLoggedIn` mapping.
  - **Tests:** fakes for every branch.
- [ ] **`SessionMonitor`**
  - `scan(watched:accounts:identities:excludePIDs:) async -> [SessionGroup]`.
  - Reads only `.json` files. Filters to interactive sessions.
  - Liveness and `procStart` rules from spec §5.5, including the timezone tolerance and unparseable or short results.
  - Attribution prefers dedicated accounts; unmatched sessions go to "Other".
  - Sorting.
  - `watchedDirectories(settings:home:)` helper.
  - **Tests:** temp-dir fixtures with `FakeProcessInspector`; a `.key` file present must never be opened (assert through a file named `x.key` that would make the test fail if read — use a directory named `*.key` so that reading throws).
- [ ] Run `scripts/test.sh` until green, then commit after each component.

### Task 6: Aggregator and scheduler (spec §5.8)

**Files:** `Services/UsageAggregator.swift`, `Services/RefreshScheduler.swift`. Tests go in `Tests/TokenBarCoreTests/Refresh/*`.

- [ ] **`UsageAggregator`** (actor)
  - `init(providers: [ProviderKind: any UsageProvider], env:, stepDeadline: Duration = .seconds(120), safetyTimeout: Duration = .seconds(130))`.
  - `refresh(accounts:settings:context:) -> AsyncStream<AccountRefreshEvent>`.
  - `inFlight` and `pendingRerun` follow the rules exactly, with fingerprints, and are recorded before the first `await`.
  - Stale-fingerprint results are dropped. The safety timeout maps to `.timeout`. Unknown thrown errors map to `.protocolError(.unexpected)`.
  - **Tests** with fake providers (controllable continuations):
    - a manual request joins a manual run;
    - a manual request during a scheduled run → rerun;
    - a config change → rerun, with the stale result dropped;
    - reentrancy (two calls before any await → one provider call);
    - results stream in arrival order;
    - the safety timeout.
- [ ] **`RefreshScheduler`** (actor)
  - Takes an injected `sleep`. Interval loop per provider kind (Codex uses ≥5 min).
  - Implements `willSleep`, `didWake` (10 s delay, then the loop restarts), and launch (snapshots first, then refresh).
  - Drops non-manual triggers within 60 s of a success. Calls a handler closure.
  - **Tests** use `TestClock`: the interval; an interval change; sleep and wake producing exactly one wake refresh; the 60 s drop; the launch sequence.
- [ ] Run `scripts/test.sh` until green, then commit after each component.

### Task 7: Runtime composition and CLI (spec §7)

**Files:** `Sources/TokenBarCore/Runtime/TokenBarRuntime.swift` (wires env, stores, locator, providers, aggregator and session monitor; used by both CLI and App), `Sources/TokenBarCore/CLI/StatusJSON.swift`, `Sources/TokenBarCore/CLI/StatusTable.swift`, `Sources/TokenBarCLI/main.swift`. Tests go in `Tests/TokenBarCoreTests/CLI/*` with golden files.

- [ ] **`StatusJSON` / `WindowJSON` DTOs**
  - Hand-written keys and mappings from spec §7. No email, no accountUuid. ISO-8601 Z dates.
  - `usage` and `reset_at` come from `DisplayDerivation.worstWindow`.
  - **Tests:** a golden file; a canary secret placed into an account email and into an error path never appears in the output.
- [ ] **`StatusTable`**: human-readable output (spec §6.3 rows).
- [ ] **`main.swift`**
  - The first statement is `signal(SIGPIPE, SIG_IGN)`.
  - Subcommands `status` and `sessions`. Options `--json`, `--account <name>`, `--allow-claude-refresh`.
  - Exit codes 0/1/2.
  - Reads config via `ConfigStore` in CLI mode (never writes). Reads and writes `state.json`.
- [ ] Smoke test, running only the Codex account and real binaries after signature verification:

  ```bash
  swift build && .build/debug/tokenbar status --json --account Codex
  ```

  Expected: one account with `"provider": "codex"` and windows, or a well-formed error object. Exit code 0 or 1.
- [ ] Smoke test: `.build/debug/tokenbar sessions --json`. Expected: groups of sessions from `~/.claude/sessions` (read-only).
- [ ] Commit.

### Task 8: The App (spec §6)

**Files:** everything under `Sources/TokenBarApp/` (replace the placeholder).

- [ ] Write `App/TokenBarApp.swift` (`@main`), `App/AppModel.swift`, `App/SystemEventsBridge.swift` and `App/SelfTest.swift`.
  - `AppModel` consumes `TokenBarRuntime`. It applies events through `AccountState.apply` and persists through `SnapshotStore`.
  - The selftest swaps in stub providers.
- [ ] Write the views:
  - `Views/MenuBarLabel.swift` (HStack, symbol per status, `?`/`!`);
  - `Views/PanelView.swift`, `Views/WindowObserver.swift`, `Views/AccountCard.swift`, `Views/UsageRow.swift`, `Views/SessionList.swift`;
  - `Views/Settings/{SettingsView,AccountsPane,GeneralPane,AddDedicatedLoginSheet}.swift`.
- [ ] Write `Floating/FloatingPanel.swift` and `Floating/FloatingPanelController.swift`: a non-activating NSPanel that is draggable and autosaves its frame.
- [ ] Launch at login reads `SMAppService.mainApp.status` live and handles each status (spec §6.5).
- [ ] Verify:

  ```bash
  swift build -c release && scripts/bundle.sh && dist/TokenBar.app/Contents/MacOS/TokenBar --selftest; echo $?
  ```

  Expected: `SELFTEST PASS` and exit code 0. The selftest uses stubs only: no keychain, no network, no subprocess.
- [ ] Commit.

### Task 9: Verification and handover

- [ ] Merge everything to `main`. On a clean checkout, run `swift build -c release && scripts/test.sh && scripts/bundle.sh && dist/TokenBar.app/Contents/MacOS/TokenBar --selftest`.
- [ ] Run the Codex-only CLI smoke test again on the merged build.
- [ ] Run a code review over the full diff (correctness, security/privacy against spec §9, and spec conformance). Fix confirmed findings.
- [ ] Update `README.md`: build, test, install, first-run setup (dedicated logins), CLI usage, and the V1–V7 checklist for the user.
- [ ] Hand the user the V1–V7 items from spec §13.
