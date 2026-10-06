# TokenBar MVP 设计规格

- 版本：v2（2026-10-06）。v1 经过三路对抗式评审（事实一致性、可实现性、安全与逻辑），共 49 条意见，已全部合入，改动摘要见 §15
- 状态：待你评审
- 依据：[TokenBar_PLAN.md](../../../TokenBar_PLAN.md)；Phase 0 调研结论 [docs/phase0/findings.md](../../phase0/findings.md)；验证过的脚本与样例在 [docs/phase0/artifacts/](../../phase0/artifacts/)
- 已确认的决策：
  - 展示形态：菜单栏下拉面板，可以"📌 钉住"成右上角的置顶悬浮窗
  - Claude 账号卡片下显示正在运行的 Claude Code 窗口（会话）。每个会话的 token 统计放到下一阶段
  - Claude 取数用方案 A（混合）：钥匙串 token 直连官方接口 → token 过期时让 Claude Code 自己刷新（只在专用登录目录里做）→ 最后用缓存兜底
  - 你在 Claude Code 里用 `/login` 来回切换两个账号，所以每个账号用一个 TokenBar 专用登录目录（§3.1）

---

## 1. 目标与范围

MVP 包括：计划的 Phase 1（CLI）、Phase 2（菜单栏 MVP）、Phase 3 里最基本的账号管理，再加上前面确认的两项需求（悬浮窗、会话列表）。成功标准沿用计划 §10。

### 1.1 MVP 包含的功能

- 菜单栏常驻图标，点开是下拉面板（`MenuBarExtra`，`.window` 样式）
- 2 个 Claude 账号 + 1 个 Codex 账号（数据模型支持任意多个）
- 每个账号显示：5 小时窗口、周窗口，以及 Claude 的 Sonnet 周窗口和按模型划分的周限额。内容包括用量、重置倒计时、状态分级
- 刷新时机：手动；定时（默认每 5 分钟）；启动、唤醒、账号配置变更时
- 刷新失败时保留上次成功的结果，并标明
- 📌 置顶悬浮窗
- Claude 会话列表：busy/idle 状态和持续时长
- 设置页：
  - 账号的增删、改名、排序、启用
  - 刷新间隔
  - 显示模式（剩余或已用）
  - 开机自启
  - claude/codex 路径覆盖、子进程代理
  - 添加 Claude 专用登录的引导
- CLI：`tokenbar status [--json]`、`tokenbar sessions [--json]`

### 1.2 MVP 不做的功能

- 每会话 token 统计（下一阶段做）
- Codex 会话列表（还没有验证过的数据来源）
- 低额度通知、用量历史、自定义图标（计划 Phase 4）
- 计划 §9 列出的所有"第一版不做"的项目

---

## 2. Phase 0 结论（设计依赖的事实）

状态标记：✅ 已在本机实测；🔍 从已安装的二进制逆向得出，并经过独立复核；⚠️ 还需要在本机验证（见 §13）。完整证据在 [docs/phase0/findings.md](../../phase0/findings.md)。

### 2.1 Claude Code

| 事实 | 状态 |
|---|---|
| 配置目录默认是 `~/.claude`，可以用 `CLAUDE_CONFIG_DIR` 覆盖。一个配置目录就是一个独立的登录 | 🔍 |
| 全局配置 JSON 的位置：如果 `<配置目录>/.config.json` 存在就用它；否则没设 env 时是 `~/.claude.json`，设了 env 时是 `$CLAUDE_CONFIG_DIR/.claude.json`。文件里有 `oauthAccount`（身份）和 `cachedUsageUtilization`（用量缓存），**也有可能包含密钥的其他字段**，比如 MCP 的环境变量 | 🔍 |
| 凭据存在 macOS 钥匙串的 generic password 里。service 名：没设 env 时是 `Claude Code-credentials`；设了 env 时是 `Claude Code-credentials-` 加上 `sha256(NFC(CLAUDE_CONFIG_DIR 原样字符串))` 的前 8 位十六进制。hash 的输入是**原样字符串**：不 realpath，不去末尾的 `/`。account 是 `$USER`，取不到时用 `getpwuid` 的用户名；不匹配 `^[a-zA-Z0-9._-]+$` 时用 `claude-code-user`。Claude Code 自己就是用 `/usr/bin/security` 子进程读写钥匙串的 | 🔍 |
| 钥匙串的值除了 `claudeAiOauth`，还包含很多别的密钥（designOauth、mcpOAuth、pluginSecrets、trustedDeviceToken……），可能超过 4KB | 🔍 |
| 钥匙串里没有条目（退出码 44）时，Claude Code 会改读 `<配置目录>/.credentials.json`（明文，权限 0600） | 🔍 |
| `claudeAiOauth` 的结构：`{accessToken, refreshToken, expiresAt（毫秒）, scopes[], subscriptionType, rateLimitTier, …}` | 🔍 |
| `security` 的退出码：0 = 成功；44 = 未找到；36 = 钥匙串已锁定。用户取消或授权失败可能是 128 或 51（推测，未验证）；Claude Code 同时会按 stderr 的关键字来分类 | 🔍 ⚠️ |
| 不支持 `CLAUDE_SECURESTORAGE_CONFIG_DIR`、`CLAUDE_CODE_CUSTOM_OAUTH_URL`，因为它们会改变存储位置或 service 名。TokenBar 默认这两个变量没有设置，并在调用子进程时把它们去掉 | 🔍 |
| 用量接口是 `GET https://api.anthropic.com/api/oauth/usage`。header：`Authorization: Bearer <accessToken>`、`anthropic-beta: oauth-2025-04-20`、`Content-Type: application/json`。token 需要带 `user:profile` scope | 🔍 |
| 响应里的顶层窗口有 `five_hour`、`seven_day`、`seven_day_sonnet`、`seven_day_opus` 等，每个是 `{utilization: 0–100（可以超过 100）或 null, resets_at: ISO-8601 或 null}`。整个窗口对象也可能是 null。`limits[]` 是按模型划分的行，`resets_at` 可能是 epoch 秒。另外还有 `extra_usage` | 🔍 |
| 离 `expiresAt` 不到 5 分钟时，token 就算过期 | 🔍 |
| **refresh token 会轮换**：如果别的进程刷新了 token，Claude Code 存着的 refresh token 就作废了。它下次刷新会失败，然后清空凭据，相当于被登出 | 🔍 |
| 后端的退避规则（Claude Code 按 token 记录）：401 或带错误体的 403 → 1 小时；429 → 按 Retry-After，没有就 5 分钟，最长 1 小时。Claude Code 自己最多每 60 秒读一次用量 | 🔍 |
| `cachedUsageUtilization = {fetchedAtMs, accountUuid, utilization:{…}}` 是上一次成功读取用量接口的快照，**只有 ≥ 2.1.287 的版本会写**，而且只在读用量时写：/usage 面板、`claude -p "/usage"`、SDK get_usage，VS Code 扩展在登录后和面板请求时也会触发。每个账号最多 60 秒写一次，登出或换账号时会被删掉。本机终端里的 2.1.123 和 2.1.174 从来不写它 | 🔍 |
| `claude -p "/usage"`（≥ 2.1.289）在本地执行，不调用模型；token 由 Claude Code 自己刷新（带锁、用 compare-and-swap 写回），同时更新 `cachedUsageUtilization`。如果缓存不到 60 秒，它直接用缓存，不联网 | 🔍 ⚠️ |
| `claude auth login` 和 `claude auth status` 子命令存在。`status` 只读，默认输出 JSON | ✅ |
| 会话注册表在 `<配置目录>/sessions/<pid>.json`，字段有 `{pid, sessionId, cwd, name, status: busy\|idle, statusUpdatedAt（毫秒）, startedAt（毫秒）, procStart（例如 "Tue Oct  6 05:33:53 2026"）, kind, entrypoint, version, …}`。同一目录下的 `*.key` 是密钥文件，**绝不能读**。已确认 2.1.289 会写这个文件；2.1.123 和 2.1.174 写不写还没验证 | ✅ ⚠️ |
| 本机的 claude 二进制：VS Code 扩展内置的 2.1.289（旧版本文件夹都列在 `.obsolete` 里）、`~/.local/bin/claude` → `~/.local/share/claude/versions/2.1.174`、nvm 下的 2.1.123。签名都是 `Developer ID Application: Anthropic PBC (Q6L2SF6YDW)` | ✅ |
| 别的进程用 `/usr/bin/security` 读 Claude Code 的钥匙串条目时会不会弹框 | ⚠️ |
| 同一个账号在专用目录里再登录一次，会不会把日常 `~/.claude` 的登录挤掉 | ⚠️ |

### 2.2 Codex

| 事实 | 状态 |
|---|---|
| `codex app-server` 走 stdio，每行一个 JSON，没有 `jsonrpc` 字段。稳定的 v2 方法 `account/read` 和 `account/rateLimits/read` 用的是 Codex 自己的登录 | ✅（0.160.0） |
| 握手顺序：`initialize`（带 clientInfo）→ 通知 `initialized` → 发请求。响应按 id 匹配，可能乱序，中间会穿插通知（0.160 的通知多一个 `emittedAtMs` 字段）。**要等全部响应收到后再关 stdin**，关掉之后进程约 10ms 以退出码 0 结束 | ✅ |
| 已验证的启动参数：`-c memories.generate_memories=false -c memories.use_memories=false app-server --listen stdio://`。如果不关插件（`-c features.plugins=false`，等同于 `--disable plugins`），每次启动都会请求 plugins/featured；全新的 home 还会克隆 136MB 的插件仓库 | ✅（关插件这一点只在临时目录测过） |
| 实测从启动到拿到全部结果 0.42 秒，峰值 RSS 134MB，CPU 0.11 秒。每次启动都会照常写日志行、models_cache.json 和 tmp | ✅ |
| 结果结构：`rateLimitsByLimitId["codex"]`（或 `rateLimits`）下有 `primary/secondary: {usedPercent: Int, windowDurationMins, resetsAt: unix 秒}`，以及 `rateLimitReachedType`、`ordinaryUsageAllowed`、`planType`、`credits` | ✅ |
| 窗口还没开始时，`usedPercent == 0`，`resetsAt ≈ now + windowDurationMins×60`，而且每次读都会往后挪。`usedPercent` 是整数，用量不到 1% 也显示 0 | ✅ |
| 窗口要按 `windowDurationMins` 分类（300 = 5 小时，10080 = 周，43200 = 30 天），不能按 primary/secondary 的位置分。有的套餐只有周窗口，或者只有 30 天窗口 | ✅ |
| 一个 CODEX_HOME 对应一个账号。目录不存在时会干净地报错；**目录存在但为空时，会被直接初始化成新的配置** | ✅ |
| 二进制的路径会随 VS Code 扩展更新而变化（昨晚就从 0.160.0 自动升到了 0.160.1），旧版本文件夹会被列进 `.obsolete`。本机还有一个 npm 版 0.138.0，`~/miniconda3/bin/codex` 是它的 JS 启动脚本。所有可用的原生二进制签名都是 `OpenAI OpCo, LLC (2DC432GLL2)` | ✅ |
| 被动备用数据：`$CODEX_HOME/sessions/**/rollout-*.jsonl` 里 `token_count` 事件带的 `rate_limits`。这些数据很稀疏，也容易过时 | ✅ |
| 绝对不能调用的方法：`account/rateLimitResetCredit/consume`（会消耗重置额度）、`sendAddCreditsNudgeEmail`、login/logout、`account/read{refreshToken:true}` | 🔍 |

### 2.3 构建环境

| 事实 | 状态 |
|---|---|
| 只有 Command Line Tools（Swift 6.2.4、macOS 26.2 SDK）。Xcode 27 装了但没接受许可，所以必须设 `DEVELOPER_DIR=/Library/Developer/CommandLineTools` | ✅ |
| swift-tools-version 6.2，最低支持 macOS 14，Swift 6 语言模式。App target 用 `.defaultIsolation(MainActor.self)`，编译零并发错误 | ✅ |
| `swift test` 需要加 3 个参数（见 `scripts/test.sh`）。如果这些参数只写在 Package.swift 里，会出现"一个测试都没跑，却返回 0"，所以脚本必须检查这种情况 | ✅ |
| 产品名 `TokenBar` 和 `tokenbar` 在不区分大小写的磁盘上会冲突，所以 App 的产品名叫 `TokenBarApp`，打包时再改名 | ✅ |
| 菜单栏的 label 只用 `Label` 时只会显示图标，要用 `HStack { Image; Text }` | ✅ |
| 打开设置窗口要用 `openSettings` 加 `NSApp.activate(ignoringOtherApps: true)`；`showSettingsWindow:` 在 macOS 14 以上无效 | ✅ |
| 手工打包的 .app 里，`Bundle.module` 找不到资源，所以不用 SwiftPM 的资源机制 | ✅ |
| GUI 进程的 PATH 很短，也没有 shell 里的代理变量 | ✅ |
| ad-hoc 签名每次构建 cdhash 都会变，所以不能依赖任何 TCC 授权，也不能依赖钥匙串的"始终允许"授权给 TokenBar 本身 | ✅ |
| 这是学校统一管理的 Mac（Jamf、Microsoft Defender、CyberArk EPM），可疑的二进制可能直接被杀掉 | ✅ |

---

## 3. 账号模型

### 3.1 一个 Claude 账号对应一个配置目录

```swift
public struct AccountConfig {
    …
    public var claudeConfigDir: String?   // nil 表示默认目录
    public var isDedicatedLogin: Bool     // 只有 §6.5 的"添加专用登录"流程会把它设成 true（设置里也有显式开关）
}
```

- `claudeConfigDir == nil` 表示默认目录：不设 `CLAUDE_CONFIG_DIR`，钥匙串 service 名不带 hash，配置 JSON 是 `~/.claude.json`。
- 路径规则：只展开开头的 `~`，其余字符**原样保存**，不去末尾的 `/`，也不做 realpath。这个原样字符串既用来设 `CLAUDE_CONFIG_DIR`、算 hash，也出现在给你的登录命令里。
  - TokenBar 自己创建的专用目录，一律用不带末尾 `/` 的绝对路径。
  - 你手动填写的已有目录：如果读钥匙串得到退出码 44，就把末尾的 `/` 加上或去掉再试一次；试中了就提示你，并保存试中的那种写法。
  - 如果填的正好是 `$HOME/.claude`，要提醒你：这和"默认登录（nil）"不是一回事，因为两者的钥匙串 service 名不同。同时提供"改为默认"的选项。

**专用登录目录（推荐，适合用 /login 来回切换的情况）**：

- `~/.claude` 当前登录的是哪个账号会变，所以不能把它当成某个固定账号的数据来源。
- 给每个 Claude 账号建一个 TokenBar 专用目录 `~/.tokenbar/claude/<slug>`。`~/.tokenbar` 和 `~/.tokenbar/claude` 的权限都设成 0700。每个目录用 Claude Code 登录一次（§6.5）。
- 这些目录只供 TokenBar 读用量。你日常照样在 `~/.claude` 里工作、照样用 /login 切换。一个账号在两个目录各登录一次，等于开了两个独立的 OAuth 会话，和在两台设备上登录一样（⚠️ 见 V7）。
- 专用目录平时没人用，access token 会过期，这时用 §5.3 的第②步，让 Claude Code 自己刷新。这个登录只有 TokenBar 在用，所以不会和日常的 Claude Code 争抢 refresh token。

**默认账号的处理**：

- 首次启动时创建两个账号：一个 Claude 账号（`claudeConfigDir = nil`，显示名 "Claude"，`isDedicatedLogin = false`），一个 Codex 账号（`codexHome = nil`，显示名 "Codex"）。
- 第一个专用登录完成后，TokenBar 会建议停用默认账号（默认选项是停用）。
- 如果你选择保留，默认账号显示为 "Claude (current /login)"。当它和某个专用账号的 accountUuid 相同时，后面会附上那个专用账号的名字。

### 3.2 会话归属到哪个账号

- 会话注册表在你**日常工作**用的配置目录里（一般是 `~/.claude/sessions/`）。
- 被监视的目录 = `~/.claude`（默认目录）加上所有 Claude 账号的 `claudeConfigDir`，去重。
- 对每个被监视的目录，读它配置 JSON 里的 `oauthAccount.accountUuid`，把这个目录下的会话归到 `identity.accountUuid` 相同的 TokenBar 账号。如果有多个账号同时匹配，专用账号（`claudeConfigDir != nil`）优先于默认账号。每个会话只出现在一张卡片下。
- 哪个账号都匹配不上的会话，放进面板底部的 "Other Claude sessions" 组。
- 你在 `~/.claude` 里用 /login 切换后，会话列表会自动跟到对应的卡片下。

### 3.3 一个 Codex 账号对应一个 CODEX_HOME

- `codexHome: String?`，`nil` 表示 `~/.codex`。
- 启动 app-server 之前，要求这个目录存在，并且里面有 `config.toml` 或 `auth.json`。只做 stat 检查，**不读内容**。不满足时显示 ⚠ "Not a Codex profile — run `CODEX_HOME=<dir> codex login`"，避免 app-server 把一个空目录初始化成新的配置。

---

## 4. 架构

### 4.1 包结构（SwiftPM）

和计划 §8 的对应关系：Models、Providers、Services 都放在 `TokenBarCore` 里；Views 在 `TokenBarApp` 里；CLI 是 `TokenBarCLI`。

```text
TokenBar/
├── Package.swift
├── Sources/
│   ├── TokenBarCore/            # 不含 UI；nonisolated；Sendable 值类型 + async API
│   │   ├── Models/              # AccountConfig, AppSettings, UsageSnapshot, UsageWindow, UsageStatus, DisplayDerivation, SessionInfo, ProviderError
│   │   ├── Environment/         # CoreEnvironment（所有副作用都从这里进来）+ LiveEnvironment
│   │   ├── Providers/           # UsageProvider；Claude/*；Codex/*
│   │   ├── Services/            # UsageAggregator, RefreshScheduler, ConfigStore, SnapshotStore, StateStore, SessionMonitor, BackoffPolicy
│   │   └── Support/             # ProcessRunner, MinimalEnv, BinaryLocator, CodeSignatureVerifier, DateParsing, Formatting, ShellQuoting
│   ├── TokenBarCLI/             # 可执行产品 `tokenbar`
│   └── TokenBarApp/             # 可执行产品 `TokenBarApp`（打包成 TokenBar.app）
│       ├── App/                 # @main App, AppModel, SystemEventsBridge（睡眠/唤醒）, SelfTest
│       ├── Views/               # MenuBarLabel, PanelView, WindowObserver, AccountCard, UsageRow, SessionList, Settings/*
│       └── Floating/            # FloatingPanel, FloatingPanelController
├── Tests/TokenBarCoreTests/     # 包括 Fixtures/（样例 JSON、rollout 行、旧版本的 config）
├── scripts/                     # test.sh, bundle.sh, install.sh
├── docs/
└── README.md
```

### 4.2 CoreEnvironment（测试注入点）

Core 里的任何类型都**不能直接调用** `Date()`、`FileManager.default.homeDirectoryForCurrentUser`、`NSHomeDirectory()`、`Process`、`URLSession`、`ProcessInfo.processInfo.environment`。所有副作用一律通过下面这个结构注入：

```swift
public struct CoreEnvironment: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async throws -> Void
    public var homeDirectory: URL
    public var appSupportDirectory: URL           // ~/Library/Application Support/TokenBar
    public var temporaryDirectory: URL
    public var userName: String                   // §2.1 中钥匙串 account 的取值规则
    public var processRunner: any ProcessRunning
    public var fileSystem: any FileSystemAccess   // 读写、stat、目录列表、权限、文件锁
    public var http: any HTTPClient
    public var signatureVerifier: any CodeSignatureVerifying
    public var processInspector: any ProcessInspecting   // kill(pid,0)、进程启动时间
    public var systemProxy: @Sendable () -> ProxySettings?
    public static func live() -> CoreEnvironment       // 唯一可以使用真实 API 的地方
}
```

测试里所有路径都建在每个测试自己的临时目录下。`scripts/test.sh` 会检查：`Sources/TokenBarCore` 里除了 `LiveEnvironment.swift`，只要出现 `Date()`、`homeDirectoryForCurrentUser`、`NSHomeDirectory()`、`URLSession.shared`、`Process()`，就判定失败。

### 4.3 数据流

```text
App: SystemEventsBridge（willSleep / didWake）、按钮、设置变更 ─┐
CLI: 单次调用 ─────────────────────────────────────────────────┤
                                                             ▼
                 RefreshScheduler（actor，在 Core 里）──► UsageAggregator（actor）
                                                             │ 每个账号一个子任务，各自有 deadline；结果按到达顺序产出
                       ┌─────────────────────────────────────┴────────────────────────┐
                ClaudeProvider                                                  CodexProvider
   CredentialReader(/usr/bin/security) → UsageClient(HTTPS)          BinaryLocator + Verifier
   ClaudeCodeRefresher(claude -p "/usage"，只用于专用目录)            AppServerClient(LineTransport)
   ConfigReader(oauthAccount / cachedUsageUtilization)              RolloutReader（被动备用）
                       └───────────────► StateStore（退避、第②步、钥匙串授权；App 和 CLI 共用）
AsyncStream<(UUID, Result)> ──► AppModel（@MainActor @Observable）──► SnapshotStore（只有 App 写）
SessionMonitor（独立轮询，频率随面板是否可见变化）──► AppModel.sessions
```

---

## 5. 数据层详细设计（TokenBarCore）

### 5.1 模型

```swift
public enum ProviderKind: String, Codable, Sendable { case claude, codex }
public enum DisplayMode: String, Codable, Sendable { case remaining, used }

public struct AccountConfig: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var provider: ProviderKind
    public var displayName: String
    public var claudeConfigDir: String?
    public var isDedicatedLogin: Bool        // 只用于 Claude；第②步只对 true 的账号生效
    public var codexHome: String?
    public var isEnabled: Bool
}

public struct AppSettings: Codable, Sendable {
    public var schemaVersion: Int            // 当前 = 1
    public var accounts: [AccountConfig]     // 数组顺序就是显示顺序
    public var refreshIntervalMinutes: Int   // 默认 5，可选 1/2/5/10/15/30；Codex 实际按 max(该值, 5)
    public var displayMode: DisplayMode      // 默认 .remaining
    public var allowClaudeCodeRefresh: Bool  // 默认 true；只影响专用登录
    public var claudeBinaryOverride: String?
    public var codexBinaryOverride: String?
    public var subprocessProxy: String?      // 例如 "http://proxy:8080"；为 nil 时用系统代理设置
}

public struct UsageWindow: Codable, Sendable, Hashable {
    public enum Kind: Codable, Sendable, Hashable {
        case fiveHour, weekly, weeklySonnet, weeklyOpus, monthly
        case model(name: String)             // Claude limits[] 里按模型划分的周限额
        case other(minutes: Int)
    }
    public var kind: Kind
    public var usedPercent: Double           // 0…100，可能超过 100
    public var resetsAt: Date?
    public var isStarted: Bool               // false = 窗口还没开始；数据层判定见 §5.3.1、§5.4，显示层判定见下文
}

public struct AccountIdentity: Codable, Sendable, Hashable {
    public var accountUuid: String?          // Claude oauthAccount.accountUuid；会落盘（用于判断会话归属）
    public var plan: String?                 // "Max" / "Pro" / "Plus" …
    public var organization: String?
    public var email: String?                // 不参与 Codable（用自定义 CodingKeys），不落盘，只在设置页实时读取并显示
}

public enum SnapshotSource: Codable, Sendable, Hashable {
    case claudeAPI, claudeAPIAfterCLIRefresh, claudeCache(fetchedAt: Date), codexAppServer, codexRollout(eventAt: Date)
}

public struct UsageSnapshot: Codable, Sendable {
    public var accountID: UUID
    public var fetchedAt: Date               // TokenBar 拿到数据的时间
    public var dataAsOf: Date                // 数据本身的时间（来自缓存或日志时可能更早）
    public var source: SnapshotSource
    public var identity: AccountIdentity?
    public var windows: [UsageWindow]        // 顺序：fiveHour, weekly, weeklySonnet, weeklyOpus, model…, monthly, other
    public var limitReached: Bool
}
```

**ProviderError 是封闭集合，不带任何原始文本**（防泄露，见 §9）：

```swift
public enum ProviderError: Error, Codable, Sendable, Hashable {
    case notLoggedIn(hint: LoginHint)                 // LoginHint = .claude(configDir: String?) | .codex(home: String?)；文字由 UI 生成
    case waitingForClaudeCode                         // 非专用账号的 token 过期了，等日常的 Claude Code 去刷新
    case tokenLacksProfileScope
    case keychainLocked
    case keychainAccessDenied(exitCode: Int32)        // 用户拒绝、取消，或超时
    case keychainReadFailed(exitCode: Int32)
    case unauthorized(until: Date)
    case rateLimited(until: Date)
    case network(URLErrorCode)                        // 只存 URLError.Code 的原始值
    case httpStatus(Int)
    case claudeBinaryNotFound                         // 没找到 ≥ 2.1.289 且签名有效的 claude
    case codexBinaryNotFound
    case binarySignatureInvalid(BinaryKind)
    case notACodexProfile
    case protocolError(ProtocolErrorCode)             // 封闭枚举：serverExited, malformedResponse, unexpectedMessage, methodNotAllowed, …
    case decoding(codingPath: [String])               // 只记录键名，不记录值
    case timeout
    case accountChanged
}
```

**AccountState**（交给 UI 用）：

```swift
public struct AccountState: Sendable {
    public var config: AccountConfig
    public var lastSnapshot: UsageSnapshot?          // 最近一次成功的结果
    public var lastError: ProviderError?             // 最近一次尝试失败的原因；成功时为 nil
    public var lastAttemptAt: Date?
    public var isRefreshing: Bool
    public var pausedUntil: Date?                    // 退避中
}
```

**显示推导**（`DisplayDerivation`，纯函数，App 和 CLI 每次渲染都调用）：

1. 无论快照来自哪里，凡是 `resetsAt ≤ now` 的窗口，一律当作 usedPercent = 0、isStarted = false、不显示倒计时（标为 `reset`），也不参与 limitReached 的判断。
2. App 在最早的 `resetsAt` 时刻触发一次重新渲染。
3. 状态 UsageStatus 按剩余百分比 r 分档（计划 §2.3）：`r > 50` 是 `.normal`；`20 ≤ r ≤ 50` 是 `.gettingLow`；`5 ≤ r < 20` 是 `.low`；`r < 5`，或者 limitReached 时，是 `.critical`。
4. 一个账号的状态，取它所有**已开始**窗口里最差的那个。一个已开始的窗口都没有时，状态是 `.normal`，显示 100% left。
5. 菜单栏只考虑有快照的启用账号，取最差账号最差窗口的值。如果这个账号的快照比 2 倍刷新间隔还旧，或者它的 `lastError != nil`，数字后面加 `?`（例如 `31%?`）。如果所有启用账号都没有快照，并且都在出错，就显示 `!`。
6. 倒计时的格式：大于等于 1 天显示 `3d 4h`；大于等于 1 小时显示 `2h 14m`；大于等于 1 分钟显示 `45m`；不到 1 分钟显示 `<1m`。

### 5.2 UsageProvider

```swift
public enum RefreshTrigger: Sendable { case scheduled, manual, launch, wake, configChange }
public protocol UsageProvider: Sendable {
    func fetchUsage(for account: AccountConfig, settings: AppSettings,
                    trigger: RefreshTrigger, deadline: Date) async throws(ProviderError) -> UsageSnapshot
}
```

计划里的接口是 `getUsage()/getResetTime()/refresh()/accountName`，这里改成一次调用返回完整快照：重置时间在快照里，账号名来自 `AccountConfig`。如果编译器不支持 typed throws，可以退回普通的 `throws`，再在边界处转换成 ProviderError。

### 5.3 ClaudeProvider

由以下组件组成：`ClaudePaths`（推导目录、配置 JSON 路径和 service 名）、`ClaudeCredentialReader`、`ClaudeConfigReader`、`ClaudeUsageClient`、`ClaudeCodeRefresher`、`ClaudeBinaryLocator`（§5.3.2），以及共用的 `StateStore` 和 `BackoffPolicy`。每个组件都通过协议注入。

**时间预算**：provider 拿到 `deadline = 开始时间 + 120 秒`。每一步实际可用的超时，取"这一步自己的超时"和"deadline − now − 2 秒"中较小的那个。如果剩余时间不够开始某一步，或者某一步被截断，就直接跳到第③步。

**每个账号的流程如下**：

0. **前置检查**（读 StateStore）
   - 如果这个账号在 429 或裸 403 的退避期内，直接走第③步。卡片显示 `Paused until HH:MM`。手动刷新**也不能**跳过这个退避。
   - 如果这个 service 被标记为 `keychainAccess = deniedOrPrompting`，并且这次不是手动刷新，就跳过钥匙串，直接走第③步，错误为 `.keychainAccessDenied`。

1. **读凭据**：执行 `/usr/bin/security find-generic-password -a <userName> -w -s <service>`。
   - 自动触发时超时 10 秒；手动触发时超时 60 秒，留时间给你点"始终允许"。
   - 全局同一时刻只跑一个 `security` 进程，多个账号排队执行。
   - 退出码 0：解析 JSON，只保留 `claudeAiOauth.{accessToken, expiresAt, scopes, subscriptionType}`，其余全部丢弃。stdout 不写日志，也不会进入错误信息。
     - 如果 `accessToken` 为空或不存在 → `.notLoggedIn(.claude(configDir))`。
     - 如果 scopes 里没有 `user:profile` → `.tokenLacksProfileScope`，只走第③步。
   - 退出码 44：先试"加上或去掉末尾 `/`"的那个变体（§3.1）。还是没有，就改读 `<配置目录>/.credentials.json`，结构相同。仍然没有，并且配置 JSON 里也没有 `oauthAccount` → `.notLoggedIn`。
   - 退出码 36 → `.keychainLocked`，走第③步。
   - 超时、退出码 128 或 51、stderr 里有 "User canceled" 或 "auth failed"：
     - 记为 `.keychainAccessDenied(code)`；
     - 在 StateStore 里把这个 service 标为 `deniedOrPrompting`，之后只有手动刷新才会再读；
     - 走第③步。
   - 其他退出码 → `.keychainReadFailed(code)`，走第③步。

2. **第①步：直接调用用量接口**
   - 前提：`now + 5 分钟 < expiresAt`。
   - 退避规则用 token 的 `expiresAt` 来识别"是不是同一个 token"：如果 StateStore 里有 401 退避，而且 `backoffTokenExpiresAt == expiresAt`，说明还是那个被拒的 token，跳到第③步。token 一变，退避就清除。
   - 非手动触发时，同一账号两次 HTTP 调用至少间隔 60 秒。
   - 发起请求：`GET /api/oauth/usage`，超时 10 秒，header 见 §2.1，`User-Agent: TokenBar/<version>`。用的 URLSession 必须是 ephemeral，不开 URLCache 和 cookie，并且拒绝重定向（见 §9）。
   - 返回 200：按 §5.3.1 解析，source 记为 `.claudeAPI`。然后**再读一次** `oauthAccount.accountUuid`；如果它在刷新过程中变了，丢弃这次结果，记为 `.accountChanged`。
   - 返回 401：重新读一次钥匙串。token 变了就重试一次。没变：
     - 专用账号转第②步；
     - 非专用账号设置 1 小时退避（和这个 token 绑定），记为 `.waitingForClaudeCode`，走第③步。
   - 返回带 API 错误体的 403：同样设置 1 小时退避（和 token 绑定），走第③步。
   - 返回 429 或裸 403：按 Retry-After 退避，没有就 5 分钟，最长 1 小时。这个退避按账号算，记为 `.rateLimited`，走第③步。
   - 网络错误 → `.network`，走第③步。如果是唤醒后 30 秒内出的网络错误，视为暂时故障：保留原来的状态，不覆盖 lastError。

3. **第②步：让 Claude Code 自己刷新**
   - **只对专用登录生效**：要求 `isDedicatedLogin == true` 并且 `claudeConfigDir != nil`。
   - 必须**同时满足**以下条件：
     - token 已过期，或者第①步 401 之后重读钥匙串也没用；
     - `allowClaudeCodeRefresh` 为 true；
     - 这个目录的 `sessions/` 里没有活着的会话（有人在用这个目录时不去碰它）；
     - StateStore 里没有这个目录正在执行的第②步；
     - 这个 token 没被标记为 `step2Failed`（标记的含义见后文）；
     - 距离这个账号上次执行第②步至少 15 分钟（手动刷新不受这条限制）；
     - 调用方允许执行第②步（CLI 默认不允许，见 §7）。
   - 非专用账号的 token 过期了：不执行第②步，记为 `.waitingForClaudeCode`，走第③步。
   - 选择 claude 二进制：用 `ClaudeBinaryLocator`（§5.3.2）。找不到时记为 `.claudeBinaryNotFound`，卡片和设置页都显示 "Claude Code ≥ 2.1.289 not found — dedicated logins can't refresh"。
   - **启动方式**：用 `posix_spawn` 加 `POSIX_SPAWN_SETPGROUP`，让 claude 自成一个进程组，避免终端里的 Ctrl-C 或 TokenBar 被杀时把它一起带走。
     - argv：`[<realpath>, "-p", "/usage"]`。
     - stdin、stdout、stderr 都接到 `/dev/null`。不解析它的输出，也就不存在管道卡死或 SIGPIPE 的问题。
     - env 用 `MinimalEnv.make(extra: ["CLAUDE_CONFIG_DIR": dir])`。
     - cwd 固定为 `<appSupport>/claude-cwd`，权限 0700。固定目录可以避免每次运行都在 projects/ 里生成新条目。
   - **TokenBar 绝不向这个子进程发任何信号**。如果它在刷新 token 的中途被杀，这个目录就会被登出。
     - 开始执行前，在 StateStore 里登记 `step2InFlight = {pid, startedAt}`。
     - 用 `DispatchSource.makeProcessSource(.exit)` 等它退出，最多等到 deadline（单步上限 60 秒）。
     - 到时间还没退出，就停止等待，走第③步，但不杀进程。后台继续 `waitpid`，等它退出后回收，并清除 `step2InFlight` 登记。
     - 如果登记的 pid 已经不在了（App 重启过），就把这条登记视为作废。
   - **执行完之后**：
     - 先读配置 JSON。如果 `cachedUsageUtilization.fetchedAtMs` 晚于第②步的开始时间，并且 accountUuid 匹配，直接用这份缓存，source 记为 `.claudeAPIAfterCLIRefresh`，不再调接口。
     - 否则重新读钥匙串，再调一次接口（只调一次）。
     - 如果 token 仍然是空的或已过期：记为 `.notLoggedIn`，并在 StateStore 里标记 `step2Failed`（和这个 token 的 expiresAt 绑定）。在 token 变化或你手动刷新之前，不再自动执行第②步。

4. **第③步：读缓存**
   - 读配置 JSON 里的 `cachedUsageUtilization`，要求 `accountUuid == oauthAccount.accountUuid`。
   - source 记为 `.claudeCache(fetchedAt)`。重置时间已过的窗口，由显示推导统一处理。
   - 如果没有缓存，就抛出前面几步记下的错误。

5. **身份**
   - 从配置 JSON 的 `oauthAccount.{accountUuid, organizationName, organizationType}`，加上凭据里的 `subscriptionType` 得出。套餐名优先用 `subscriptionType`：`max → Max`、`pro → Pro`；否则按 organizationType 映射：`claude_max → Max`、`claude_pro → Pro`、`claude_team → Team`、`claude_enterprise → Enterprise`。
   - 如果这次读到的 accountUuid 和 `lastSnapshot.identity.accountUuid` 不一样，说明账号换了：丢弃这个账号的 lastSnapshot 和退避状态，卡片提示 `Account changed`。

**读配置 JSON 的规则**：用 `JSONSerialization` 解析，**只取** `oauthAccount` 和 `cachedUsageUtilization` 两个键。文件内容不写日志、不缓存、不往外传。

#### 5.3.1 Claude 用量响应的映射

- 顶层窗口：`five_hour → .fiveHour`、`seven_day → .weekly`、`seven_day_sonnet → .weeklySonnet`、`seven_day_opus → .weeklyOpus`。
  - 值不是对象、整个是 null、或 `utilization == null` 的窗口直接跳过。
  - 其他键全部忽略，这样以后新增的键不会造成解析失败。
- `limits[]` 里 `scope.model` 不为空的行，映射为 `.model(name: scope.model.display_name)`，用量取 `percent`（0–100）。
- `resets_at` 用 `DateParsing.flexible` 解析：
  - 字符串时，先用带小数秒的 `ISO8601DateFormatter`（`.withInternetDateTime` + `.withFractionalSeconds`）试；失败再用不带小数秒的试；
  - 是数字时，按 epoch 秒处理；
  - 都失败就返回 nil，表示不显示倒计时，**不算解析错误**。
  - formatter 每次调用时新建，或者加锁使用，因为它不是 Sendable。
- 数据层的 `isStarted` 恒为 true，因为 Claude 没有"窗口未开始"的概念。显示推导可能会把它改成 false。
- 任何窗口或 `limits[]` 行的用量 ≥ 100 时，`limitReached` 为 true。

#### 5.3.2 Claude 二进制的候选位置（ClaudeBinaryLocator）

按以下顺序收集候选：

1. `claudeBinaryOverride`。
2. `~/.local/share/claude/versions/<ver>`（`~/.local/bin/claude` 指向这里）。版本号就是文件名。
3. `{~/.vscode, ~/.vscode-insiders, ~/.cursor, ~/.windsurf}/extensions/anthropic.claude-code-<ver>-darwin-arm64/resources/native-binary/claude`。跳过对应 extensions 目录下 `.obsolete` 里列出的文件夹。版本号取自文件夹名。
4. `/opt/homebrew/bin/claude`、`/usr/local/bin/claude`。

过滤规则：

- 所有候选先做 realpath，校验和执行的都是 realpath 得到的实际路径，不是符号链接本身。
- 必须是普通文件、Mach-O 格式（检查文件头的 magic，脚本和 shebang 文件直接排除）、带执行位，并且签名的 Team ID 是 `Q6L2SF6YDW`（§5.6）。
- **从不对 claude 运行 `--version`**：
  - 版本号只能从路径里得出，无法得出就不参与第②步；
  - override 的版本未知时允许使用，但设置页会显示 "version unknown"；版本已知但低于 2.1.289 时拒绝。
- 选版本最高且 ≥ 2.1.289 的那个。每次执行第②步前都重新解析，并在启动前重新校验。

### 5.4 CodexProvider

由以下组件组成：`CodexBinaryLocator`（共用 BinaryLocator 的框架）、`CodeSignatureVerifier`、`AppServerClient`、`CodexRateLimitMapper`、`RolloutReader`。

1. **定位二进制**：每次刷新都重新解析，并缓存上一次可用的路径。
   - 候选位置（全部收集后再过滤）：
     - `codexBinaryOverride`；
     - `/opt/homebrew/bin/codex`、`/usr/local/bin/codex`、`~/.local/bin/codex`、`~/.bun/bin/codex`、`~/.npm-global/bin/codex`；
     - npm 全局包里的原生二进制 `<prefix>/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex`，其中 prefix ∈ {`~/miniconda3`, `~/anaconda3`, `/opt/homebrew`, `/usr/local`, `~/.npm-global`, `~/.nvm/versions/node/*`}。npm 的 JS 启动脚本（例如 `~/miniconda3/bin/codex → codex.js`）**不能直接执行**，必须先解析到上面这个原生二进制；
     - `/Applications/Codex.app/Contents/Resources/codex`、`~/Applications/Codex.app/Contents/Resources/codex`；
     - `{~/.vscode, ~/.vscode-insiders, ~/.cursor, ~/.windsurf}/extensions/openai.chatgpt-*/bin/macos-aarch64/codex`，跳过 `.obsolete` 里列出的文件夹。
   - 过滤：先做 realpath；必须是普通文件、Mach-O 格式、带执行位，并且签名的 Team ID 是 `2DC432GLL2`。
   - 版本号依次从这些地方取：同目录 `codex-package.json` 的 `version`；扩展文件夹名；npm 的 `package.json`。都取不到时，在签名校验通过之后运行 `--version`（超时 5 秒，env 用 MinimalEnv）。
   - 选版本最高的，预发布版本（`-alpha.N`）要正确排序。override 永远优先，但同样要通过签名校验。
2. **启动 app-server**：
   - argv：`["-c","features.plugins=false","-c","memories.generate_memories=false","-c","memories.use_memories=false","app-server","--listen","stdio://"]`。
   - 如果进程在 1 秒内以非零码退出，并且 stderr 提到 unknown 或 unexpected argument，就改用 `["app-server"]` 重试一次。按二进制版本记住这次结果（V6 会确认这些参数）。
   - env 用 `MinimalEnv.make(extra: ["CODEX_HOME": home?, "RUST_LOG": "error"])`。
   - 启动之后，用 `SecCodeCreateWithPID` 加同一个签名要求再校验一次；不通过就立刻杀掉。codex 不受"不能杀子进程"的限制。
   - 进程启动前（App 和 CLI 的 main 一开始），先调 `signal(SIGPIPE, SIG_IGN)`。
3. **JSON-RPC**（`AppServerClient`）：
   - 底层通过 `LineTransport` 收发：

     ```swift
     public protocol LineTransport: Sendable {
         func send(_ line: Data) async throws               // 写入一行，内部自动补 "\n"；写失败会抛错（EPIPE），而不是让进程收到 SIGPIPE
         var incoming: AsyncThrowingStream<Data, Error> { get }  // 一个元素就是一行；子进程退出或读到 EOF 时，以 .protocolError(.serverExited) 结束
         func closeInput() async
         func terminate() async                             // SIGTERM，2 秒后还没退出就 SIGKILL
     }
     ```

     正式实现里，用 `readabilityHandler` 按行切分后放进流里。incoming 一结束，所有还在等待的请求 id 立即失败。
   - **请求流程**：
     1. 发送 `initialize`，参数是 `{clientInfo:{name:"tokenbar", title:"TokenBar", version}, capabilities:{experimentalApi:false}}`，等它返回。
     2. 发送 `initialized` 通知。
     3. 发送 `account/read {refreshToken:false}`（id 1）和 `account/rateLimits/read {excludeResetCreditDetails:true}`（id 2）。如果 id 2 返回 `-32600`，并且错误信息里有 "invalid type"，就去掉 params 重发一次。
   - **消息处理**：响应按 id 匹配，通知一律忽略（字段多一个少一个都不影响）。服务器发来的请求，统一回复 `{"id":…,"error":{"code":-32601,"message":"not supported"}}`。
   - **方法白名单**：只允许 `initialize`、`initialized`、`account/read`、`account/rateLimits/read`。其他方法在发送之前就抛出 `.protocolError(.methodNotAllowed)`。
   - **关闭流程**：所有响应都收到之后才 `closeInput()`。之后 3 秒还没退出就 `terminate()`。整个流程超时 20 秒。
4. **映射**：
   - `limits = rateLimitsByLimitId["codex"] ?? rateLimits`。
   - `primary` 和 `secondary` 按 `windowDurationMins` 归类：300 → `.fiveHour`，10080 → `.weekly`，43200 → `.monthly`，其他 → `.other`。两者都可能是 null。`resetsAt` 是 unix 秒。
   - `isStarted = !(usedPercent == 0 && |resetsAt − now − duration×60| ≤ 120 秒)`。
   - `limitReached = rateLimitReachedType != nil || ordinaryUsageAllowed == false`。
   - 身份：`plan` 取 `planType`，首字母大写。`email` 只在设置页实时显示。
   - 所有字段按可选来解码，未知的键忽略。
5. **未登录**：`account == null`，或者错误信息里有 "authentication required"，记为 `.notLoggedIn(.codex(home))`。
6. **被动备用**：找不到可用的二进制、超时、或协议出错时使用。
   - 在 `$CODEX_HOME/sessions` 和 `archived_sessions` 里，按修改时间取最新的 3 个 `rollout-*.jsonl`，每个只读文件末尾 512KB。
   - 解析其中带 `rate_limits` 的 `token_count` 事件，**只保留** `limit_id == "codex"` 或者没有 `limit_id` 字段的事件。
   - 取最新的、至少有一个窗口不为空的快照。窗口按 `window_minutes` 归类。重置时间优先用 `resets_at`（epoch）；没有的话，用"事件时间 + `resets_in_seconds`"。
   - source 记为 `.codexRollout(eventAt)`。**不打开 Codex 的 SQLite 数据库。**

### 5.5 SessionMonitor（Claude 会话）

- 被监视的目录见 §3.2。每个目录只列出 `sessions/*.json`，**从不读 `.key` 文件**。
- 解码成 `SessionInfo {pid, sessionId, cwd, name, status(busy|idle|unknown), statusUpdatedAt, startedAt, procStart, kind, entrypoint, version, configDir}`。不认识的字段直接忽略；`status` 是不认识的值时，记为 `.unknown`。
- **只显示交互式会话**：`kind == "interactive"` 或者没有 `kind` 字段。同时排除 TokenBar 自己启动的第②步子进程，这些 pid 由 aggregator 公布。
- **判断进程是否还活着**：
  - `kill(pid, 0)` 成功，或返回 `EPERM`，就认为进程存在。
  - `procStart` 能解析时（先把连续空格合并成一个，再按 `EEE MMM d HH:mm:ss yyyy`、`en_US_POSIX`、本地时区解析），拿它和 `proc_pidinfo(PROC_PIDTBSDINFO)` 返回的 `pbi_start_tvsec` 比较。相差在 2 秒内算同一个进程。
  - 如果相差正好是 15 分钟的整数倍，并且不超过 14 小时，也算同一个进程。这种情况通常是时区变了。
  - `procStart` 缺失或解析不了时，只检查进程是否存在。`proc_pidinfo` 返回的长度不够时，也只检查是否存在。
  - 只有能解析出 `procStart`，并且时间对不上，才把这个文件当作过期文件。过期文件只是忽略，不删除。
- **轮询频率**：面板或悬浮窗可见时，每 3 秒一次；否则每 30 秒一次。频率一变，马上重新开始计时；所以打开面板时会立刻轮询一次（判断可见性的方法见 §6.1）。
- **显示方式**：busy 的排在前面，按 `statusUpdatedAt` 从早到晚，运行最久的在最上面。idle 的折叠成一行 "N idle"，可以展开。每一行显示名称（用 `name`；没有就用 `cwd` 的最后一级目录名）、状态，以及持续时长（now − statusUpdatedAt）。

### 5.6 CodeSignatureVerifier

- 用 Security.framework 实现：
  1. `SecStaticCodeCreateWithPath(realpath)`；
  2. 用 `SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"<TEAM>\"")` 生成签名要求；
  3. 调用 `SecStaticCodeCheckValidityWithErrors`，flags 为 `kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode`。
- 校验在一个专用的 `DispatchQueue` 上运行，再通过 continuation 桥接给调用方，不占用 Swift 协作线程池。**整个过程不执行被校验的文件。**
- Team ID：codex 是 `2DC432GLL2`，claude 是 `Q6L2SF6YDW`。
- 校验结果按 `(realpath, st_dev, st_ino, st_size, st_mtimespec, st_ctimespec)` 缓存。启动子进程前，再 stat 一次；任何一项变了就重新校验。

### 5.7 ProcessRunner 与 MinimalEnv

- `environment` 是必填参数，没有默认值。所有调用方都通过 `MinimalEnv.make(extra:)` 构造环境变量，只包含：
  - HOME、USER、LOGNAME（都取 `userName`）；
  - `PATH=/usr/bin:/bin:/usr/sbin:/sbin`、TMPDIR；
  - 代理变量 HTTPS_PROXY、HTTP_PROXY、NO_PROXY，取值依次来自 `subprocessProxy` 设置、系统代理设置（`CFNetworkCopySystemProxySettings`）。
  - **不会**带上任何 `*_API_KEY`、`*_TOKEN`、`ANTHROPIC_*`、`CLAUDE_CODE_*`、`CLAUDE_SECURESTORAGE_CONFIG_DIR`、`OPENAI_*`、`CODEX_API_KEY`、`CODEX_ACCESS_TOKEN`（有单元测试保证）。
- 一次性执行（`security`、`codex --version`）：
  - stdin 写完后关闭；stdout、stderr 各自最多收 4MB。
  - 超时、或者 Task 被取消时：先 SIGTERM，2 秒后 SIGKILL。不管进程状态如何，continuation 都**恰好恢复一次**（用 `OSAllocatedUnfairLock<Bool>` 防止重复恢复）。
  - 子进程退出后，最多再等 2 秒的 EOF；超时就关闭读端，返回已经收到的数据，并标记 `pipesTruncated`。
  - 无论如何，整个调用在"超时 + 5 秒"之内一定返回。
- 流式执行：给 `codex app-server` 提供 `LineTransport` 的正式实现。
- 分离执行：给第②步的 claude 用，见 §5.3，基于 `posix_spawn`，输入输出接 /dev/null，从不发信号。

### 5.8 Aggregator、Scheduler 与存储

**UsageAggregator（actor）**

- 接口：`refresh(accounts:settings:trigger:) -> AsyncStream<(UUID, Result<UsageSnapshot, ProviderError>)>`。每个账号的结果一出来就发出，不用等最慢的那个。
- 每个账号有一个 `inFlight[accountID] = (task, configFingerprint, trigger)`，**必须在第一个 await 之前同步写好**。configFingerprint 是 AccountConfig 加上相关设置字段算出的 hash。
- 新的刷新请求什么情况下直接并入正在进行的那次：fingerprint 相同，并且满足以下任一条件：
  - 正在进行的那次是手动刷新；
  - 新请求不是手动刷新。
- 其他情况下，记下 `pendingRerun[accountID] = 新的 trigger`，等当前这次结束后再跑一次。在这期间来的请求都合并进这一次补跑。
- 结果出来时，如果 fingerprint 和当前设置已经对不上，就丢弃这个结果。
- 外层还有一个 130 秒的安全超时，触发时记为 `.timeout`。正常情况下，provider 内部的 deadline 会更早结束。

**RefreshScheduler（actor，在 Core 里）**

- 接受各种刷新触发，通过注入的 `sleep` 实现定时循环，所以可以测试。App 只负责把 NSWorkspace 的睡眠和唤醒事件、按钮操作转给它。
- 定时间隔：Claude 用 `refreshIntervalMinutes`，Codex 用 `max(refreshIntervalMinutes, 5)`。
- `willSleep`：取消定时循环。
- `didWake`：等 10 秒，执行一次 `.wake` 刷新，然后从这一刻起重新开始定时循环。
- 启动时：先加载 SnapshotStore，让界面立刻有数据，再执行一次 `.launch` 刷新。
- 某个账号刚成功刷新完的 60 秒内，再来的非手动触发直接丢弃。

**ConfigStore**

- 文件：`<appSupport>/config.json`，权限 0600，目录权限 0700，原子写入。
- **只有 App 会创建和写入这个文件**。文件不存在时，CLI 在内存里用默认配置，不写盘。
- 解码规则：除了 `accounts`，每个字段都用 `decodeIfPresent ?? 默认值`，未知的键忽略。
  - `schemaVersion` 比支持的版本还高：App 显示只读错误，不写文件；CLI 以退出码 2 结束。
  - 解码失败：App 把文件改名为 `config.json.corrupt-<epoch>`，用默认配置启动，并显示警告；CLI 以退出码 2 结束，不碰这个文件。
- 版本迁移用纯函数 `migrate(vN) -> vN+1` 实现，用 fixture 文件做单元测试。
- 每次定时刷新、以及打开面板时，App 检查 config.json 的 mtime；变了就重新加载，这样手工编辑也能生效。

**SnapshotStore**

- 文件：`<appSupport>/snapshots.json`，权限 0600，原子写入。只有 App 会写。
- 内容：每个账号最近一次成功的快照，以及最近一次错误。邮箱不落盘。

**StateStore**

- 文件：`<appSupport>/state.json`，权限 0600，原子写入。读改写都要先对 `state.lock` 加 `flock`。**App 和 CLI 都会读写。**
- 每个账号记录：
  - `backoffUntil`、`backoffReason`、`backoffTokenExpiresAt`；
  - `lastStep2At`、`step2InFlight{pid,startedAt}`、`step2FailedForTokenExpiresAt`；
  - `lastHTTPAt`；
  - `keychainAccess`（ok 或 deniedOrPrompting）。
- **除了 `expiresAt`，不保存任何从 token 推导出来的值。**

---

## 6. App（TokenBarApp）

### 6.1 生命周期、刷新与面板可见性

- `@main struct TokenBarApp: App` 包含两部分：
  - `MenuBarExtra(content: PanelView, label: MenuBarLabel).menuBarExtraStyle(.window)`；
  - `Settings { SettingsView }`。
- `AppModel`（`@MainActor @Observable`）持有这些状态：`accounts: [AccountState]`、`sessions`、`settings`、`lastRefreshAt`、`isPinned`、`isPanelVisible`。它逐个消费 aggregator 产出的结果，并写入 SnapshotStore。
- **面板是否可见**：SwiftUI 没有现成的 API，做法如下。
  1. `PanelView` 里嵌一个零尺寸的 `NSViewRepresentable`，叫 `WindowObserver`。
  2. 它在 `viewDidMoveToWindow` 时拿到所在的 NSWindow，然后监听 `NSWindow.didChangeOcclusionStateNotification`、`didBecomeKeyNotification`、`didResignKeyNotification`。
  3. 设 `isPanelVisible = window.isVisible && window.occlusionState.contains(.visible)`。
  4. 悬浮窗的可见性就等于 `isPinned`。
  5. SessionMonitor 的轮询频率由 `isPanelVisible || isPinned` 决定。
- 面板上的 Refresh 按钮发出 `.manual` 触发。它可以跳过第②步的 15 分钟限制，以及钥匙串的 denied 标记；但不能跳过 429 退避（这时按钮显示 `Paused until HH:MM`）。
- App 被 SIGTERM 杀掉时，`applicationWillTerminate` 不会执行。所以所有状态都在变化时立即落盘，不等退出时再保存。

### 6.2 菜单栏 Label

- 内容是 `HStack(spacing: 3) { Image(systemName: …); Text(…) }`。显示的数字和后缀 `?`、`!` 的规则见 §5.1 显示推导第 5 条。还没有任何数据时显示 `–`。
- 图标按状态选不同的 SF Symbol（gauge 系列）；`.critical` 时用 `exclamationmark.triangle.fill`。

### 6.3 下拉面板（宽 340pt）

```text
TokenBar                                    📌  ⚙
─────────────────────────────────────────────────
Claude · Work                             Max
  5h      ███████░░░  32% left    2h 14m
  Week    ██░░░░░░░░  81% left    3d 4h
  Sonnet  █░░░░░░░░░  92% left    3d 4h
  ● TokenBar              busy   3m
  ● NIW                   busy  11m
  ○ 4 idle ▸
Claude · Personal                         Pro
  ⚠ Unable to refresh · Last updated 14 min ago
  5h      …
Codex                                     Plus
  5h      ██████████ 100% left    not started
  Week    ████████░░  84% left    6d 17h
─────────────────────────────────────────────────
Updated 22:41                    ↻ Refresh   Quit
```

- 进度条的颜色按状态取系统色：绿、黄、橙、红。条的长度和百分比文字按 displayMode 显示剩余或已用，状态颜色始终按剩余量判断。
- 卡片的状态行只在异常时出现，文字由 ProviderError 和 LoginHint 生成：
  - 出错时：`⚠ <消息>`；
  - 数据来自缓存或日志、或者最近一次刷新失败时：`Last updated N min ago`；
  - 数据来自缓存时：`(cached)`。
- 未登录时，卡片里显示提示、登录命令和 Copy 按钮。

### 6.4 📌 悬浮窗

- 用 `final class FloatingPanel: NSPanel` 实现，配置如下：
  - styleMask 为 `[.nonactivatingPanel, .titled, .fullSizeContentView]`；
  - `titleVisibility = .hidden`，`titlebarAppearsTransparent = true`；
  - `level = .floating`；
  - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`；
  - `hidesOnDeactivate = false`，`becomesKeyOnlyIfNeeded = true`；
  - 重写 `canBecomeKey` 返回 true。
- 内容视图是 `DraggableHostingView<CompactView>`，它重写 `mouseDownCanMoveWindow` 返回 true，这样窗口可以拖动。
- 窗口位置用 `setFrameAutosaveName("TokenBarFloating")` 自动保存。默认位置在主屏幕右上角，菜单栏下方 8pt。
- `CompactView` 每个账号占一行，例如 `Work  32%  2h14m`（显示最差的那个窗口），后面跟着运行中的会话数，例如 `●2`。右上角有一个小 📌，点它取消钉住。
- 钉住的状态会被记住，下次启动时自动恢复悬浮窗。显示悬浮窗时，`NSApp.isActive` 不会改变（selftest 会检查这一点）。

### 6.5 设置（Settings 场景，两个标签页）

**Accounts**

- 账号列表：可以拖动排序；`+` 添加（Claude 或 Codex），`−` 删除。
- 可以编辑的字段：显示名、是否启用、配置目录或 CODEX_HOME（文本框，加一个 "Choose…" 按钮）、专用登录开关。
- 只读显示：检测到的邮箱（实时读取，不落盘）、套餐、状态。

**添加 Claude 专用登录**

1. 先输入一个名称。由它生成 slug，规则是 `[a-z0-9-]{1,32}`，生成不了就拒绝。
2. 用权限 0700 创建目录 `~/.tokenbar/claude/<slug>`，账号的 `isDedicatedLogin` 设为 true。
3. 生成登录命令：

   ```text
   env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_CUSTOM_OAUTH_URL CLAUDE_CONFIG_DIR='<dir>' '<claude realpath>' auth login
   ```

   所有插入的值都用单引号括起来，值里面的 `'` 转义成 `'\''`。
4. 提供 Copy 按钮和 "Open in Terminal" 按钮。"Open in Terminal" 的做法：
   - 在 `<tmp>/TokenBar/<UUID>.command` 写一个脚本，用 `O_EXCL` 创建，权限 0700；
   - 用 `open` 打开它；
   - 60 秒后删除这个文件。
5. TokenBar 每 5 秒检查一次这个目录：配置 JSON 里出现 `oauthAccount`，就算登录成功，然后自动刷新。第一个专用登录完成时，按 §3.1 的规则建议停用默认账号。

**General**

- 刷新间隔；显示模式。
- 开机自启：
  - **不保存开关状态**，每次打开设置页、以及 App 被激活时，都直接读 `SMAppService.mainApp.status`。
  - `.enabled`：开关显示为开。
  - `.requiresApproval`：开关显示为开，附一行说明，并提供 "Open Login Items" 按钮（调用 `SMAppService.openSystemSettingsLoginItems()`）。
  - `.notRegistered` 或 `.notFound`：开关显示为关。
  - 注册或注销出错时，就地显示错误。
  - App 不在 `/Applications` 或 `~/Applications` 下时，开关不可用，并提示先运行 `scripts/install.sh`。
- "允许 Claude Code 刷新过期的专用登录"（默认开）。
- claude、codex 的路径覆盖，下面显示当前检测到的路径、版本和签名状态。
- 子进程代理（可选）。

**打开设置窗口**：`@Environment(\.openSettings)` 加 `NSApp.activate(ignoringOtherApps: true)`。

### 6.6 自检（`--selftest`）

- 启动时换成桩 provider：返回固定的快照，不启动子进程，不联网，不读钥匙串。唤醒延迟设为 0。
- 检查项：状态栏项存在、面板能打开、设置窗口能打开、悬浮窗能打开且不抢焦点、唤醒后会刷新。全部通过后，打印 `SELFTEST PASS` 并以退出码 0 结束。

---

## 7. CLI（tokenbar）

- `tokenbar status` 输出人类可读的表格，内容和面板一致。
- `tokenbar status --json` 输出下面这样的 JSON。这个格式由专门的 DTO（`StatusJSON`、`WindowJSON`）生成，CodingKeys 是手写的，并有 golden file 测试固定输出：

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

- 字段取值：
  - `kind` 只能是：`five_hour`、`weekly`、`weekly_sonnet`、`weekly_opus`、`model:<name>`、`monthly`、`other_<minutes>`。
  - `source` 只能是：`claude_api`、`claude_api_after_cli_refresh`、`claude_cache`、`codex_app_server`、`codex_rollout`。
  - `error` 是 `{"code": "<枚举名>"}` 或 null。
  - 日期一律用 ISO-8601，以 Z 结尾。
  - `usage`（0–1）和 `reset_at` 取经过显示推导后最受限的那个窗口，对应计划 §7 Phase 1 的格式。
  - **输出里没有邮箱，也没有 accountUuid。**
- `tokenbar sessions [--json]` 列出 Claude 会话以及它们归属的账号。
- 选项：
  - `--account <name>`；
  - `--allow-claude-refresh`：允许执行第②步。CLI 默认不执行第②步，因为在终端里按 Ctrl-C 有可能中断 Claude Code 的刷新。
- 退出码：0 表示全部成功；1 表示至少一个账号失败，但仍会输出能拿到的数据；2 表示配置错误。
- CLI 读 `config.json`，配置不存在时用内存里的默认配置；读写 `state.json`；**不写** `config.json` 和 `snapshots.json`。

---

## 8. 错误处理与界面状态

| 情况 | 卡片上显示 |
|---|---|
| 成功，实时数据 | 正常显示 |
| 成功，数据来自缓存或日志 | 正常显示，另加 `(cached · 14 min ago)` |
| 失败，但有上次的快照 | 上次的数据 + `⚠ Unable to refresh: <原因>` + `Last updated N min ago` |
| 失败，没有任何快照 | `⚠ <原因>` |
| 未登录 | 提示 + 登录命令 + Copy |
| 非专用账号的 token 过期了 | 缓存数据 + `Waiting for Claude Code to refresh` |
| 钥匙串访问被拒绝 | 缓存数据 + `Keychain access denied — showing cached data · Refresh to retry` |
| 找不到 claude ≥ 2.1.289 | `⚠ Claude Code ≥ 2.1.289 not found — dedicated logins can't refresh` |
| 找不到 codex，或签名不符 | `⚠ Codex CLI not found`（可以在设置里手动指定路径） |
| 不是 Codex 配置目录 | `⚠ Not a Codex profile — run CODEX_HOME=… codex login` |
| 退避中 | 上次的数据 + `Paused until 23:41` |
| 账号变了 | `Account changed`，旧数据已清除 |

---

## 9. 安全与隐私

1. **TokenBar 不保存任何凭据。** Claude 的 access token 只在内存里短暂存在，只发往 `https://api.anthropic.com`。用的 URLSession 由 `URLSessionConfiguration.ephemeral` 创建，`urlCache = nil`，不用 cookie，用 delegate 拒绝所有重定向；**从不使用 `URLSession.shared`**。token 不写日志，不落盘，不进入任何 Store。
2. **TokenBar 进程本身从不写 `~/.claude*`、`~/.codex` 或钥匙串**，也从不调用 OAuth token 端点。但它启动的子进程会照常写入：
   - `codex app-server` 会在 CODEX_HOME 下写日志行、models_cache.json、SQLite 的辅助文件和 tmp；
   - 第②步的 `claude -p "/usage"` 只针对专用目录运行，会轮换这个目录的 OAuth token（钥匙串），并重写 cachedUsageUtilization、sessions 等文件（V2 会列出全部写入的文件）。关掉 `allowClaudeCodeRefresh` 就不会有后者。
   - 另外，TokenBar 会创建专用登录用的空目录。
3. **不泄露原始数据**：任何 ProviderError、日志、Store 记录、CLI 输出，都**不能包含**以下内容：
   - 子进程的 stdout 或 stderr；
   - HTTP 响应体；
   - 钥匙串、`~/.claude.json`、app-server 结果里的 JSON 值。

   子进程的输出读到就地解析，用完就丢掉。有一个"金丝雀"单元测试，把一个假密钥送进每一条错误路径，然后断言它不会出现在编码后的 snapshots.json、state.json 和 CLI 输出里。
4. **签名校验**：只启动签名校验通过的 claude 和 codex。校验和执行用的都是 realpath，启动前会重新 stat；不执行脚本或 shebang 文件；子进程的环境变量用 MinimalEnv。
5. **Codex 方法白名单**：JSON-RPC 只允许白名单内的方法。
6. **最少读取**：Claude 配置 JSON 只取两个键；不读 `sessions/*.key`；不打开 Codex 的 SQLite 数据库；`auth.json` 只做 stat，不读内容。
7. **邮箱**：只在设置页实时显示，不落盘，不写日志，不出现在 CLI 输出里。
8. **文件权限**：`config.json`、`snapshots.json`、`state.json` 都是 0600，所在目录 0700；`~/.tokenbar` 和专用登录目录 0700；临时的 `.command` 文件 0700，60 秒后删除。
9. **不启用 App Sandbox**，因为需要读取 `~/.claude*`、`~/.codex` 并启动外部二进制。App 用 ad-hoc 签名，只在本机使用。

## 10. 性能

- 空闲时 CPU 接近 0；内存（phys_footprint）目标低于 40MB。
- 每次刷新的开销：
  - Claude 约 0.2–0.5 秒，就是一次 HTTP 请求；
  - Codex 约 0.5 秒：启动一个子进程，峰值 134MB，用完就退出，刷新间隔至少 5 分钟；
  - **第②步每个 token 有效期内最多执行一次**，失败后不会自动重试。
- 打开面板不超过 1 秒：直接显示内存或磁盘里的快照，不等网络。

## 11. 测试策略

**单元测试**用 swift-testing，通过 `scripts/test.sh` 运行。脚本会检查至少跑了 1 个测试，并执行 §4.2 的 grep 守卫。覆盖以下内容：

- **service 名推导**：
  - `nil` → `Claude Code-credentials`；
  - `"/Users/xai/.claude"` → `…-4405f529`；
  - `"/Users/xai/.claude/"` → `…-338287a3`；
  - 字符的合成形式和分解形式得到相同结果；
  - userName 的取值规则。
- **凭据**：
  - JSON 解析，多余的密钥会被丢掉；
  - 过期判断，留 5 分钟余量；
  - accessToken 为空时判为未登录；
  - 缺少 user:profile scope 时的处理。
- **Claude 用量响应**：
  - null 值、整个窗口为 null、用量超过 100；
  - ISO 时间带 0、1、3、6、9 位小数秒，时区分别为 `+00:00` 和 `Z`；
  - epoch 数字；
  - `limits[]` 里按模型划分的行；
  - 不认识的键。
- **`cachedUsageUtilization`**：accountUuid 不一致时不使用；必须晚于第②步开始的时间才算有效。
- **配置 JSON**：`.config.json` 优先；只提取两个键。
- **BackoffPolicy 与 StateStore**：
  - 401 和带错误体的 403 的退避与 token 绑定，token 一换就清除；
  - 429 和裸 403（有或没有 Retry-After）、上限 1 小时；
  - 手动刷新不能跳过 429 退避；
  - `flock` 并发读写；
  - 非手动请求至少间隔 60 秒。
- **ClaudeProvider 的完整流程**：用假的读凭据、HTTP、刷新器、配置读取组件和 Store，覆盖：
  - ①②③ 的每个分支；
  - 非专用账号不会执行第②步；
  - 有活跃会话时不执行第②步；
  - 已经有第②步在执行时不再启动；
  - `step2Failed` 被标记后不再自动重试；
  - 15 分钟限制，以及手动刷新可以跳过它；
  - deadline 截断后能降级到第③步；
  - 钥匙串返回 denied 后，定时刷新不再弹框；
  - 账号变化的检测。
- **ProcessRunner**：
  - 子进程派生的孙进程一直占着 stdout（`/bin/sh -c 'sleep 30 & exit 0'`），调用仍在预算时间内返回；
  - 超时或取消时 continuation 只恢复一次；
  - MinimalEnv 不会把敏感变量传给子进程。
- **AppServerClient**（用假的 LineTransport）：
  - 握手、乱序响应、通知（包括带 `emittedAtMs` 的）；
  - 服务器发来请求时回复 -32601；
  - 收到 -32600 后去掉 params 重试；
  - 未登录；
  - 超时；
  - 服务器在响应前退出、退出后再发送；
  - 白名单拒绝非法方法；
  - 启动参数被固定，参数不被接受时退回 `app-server`。
- **Codex 映射**：
  - 按时长分类：只有周窗口、30 天窗口、primary 为 null；
  - 判断窗口是否已开始；
  - limitReached；
  - 优先使用 `rateLimitsByLimitId`。
- **CODEX_HOME 校验**：目录不存在、为空、或者是有效配置三种情况。
- **RolloutReader**：样例数据行、只保留 limit_id 为 codex 或没有 limit_id 的行、空窗口、`resets_in_seconds`。
- **SessionMonitor**：
  - 解析；
  - 进程存活以及 procStart 校验，包括时区偏移、解析不了、`proc_pidinfo` 返回长度不足等情况；
  - 归属判断，以及专用账号优先；
  - 只保留 interactive 会话，排除 TokenBar 自己启动的进程；
  - 排序。
- **BinaryLocator（claude、codex）**：
  - 候选收集、排除 `.obsolete`、realpath；
  - 排除 JS 启动脚本和 shebang 文件；
  - 版本排序（包括 alpha）、override 优先；
  - 签名校验失败的候选被排除；
  - 从不对 claude 运行 `--version`。
- **显示推导**：
  - 重置时间已过的窗口；
  - 所有窗口都未开始；
  - 状态边界值 50、20、5；
  - 菜单栏选哪个值，以及 `?` 和 `!` 后缀；
  - displayMode=used；
  - 倒计时格式。
- **UsageAggregator**：
  - 失败时保留上次的快照；
  - 合并规则覆盖三种情况：手动请求遇上定时刷新、配置变更、actor 重入；
  - 结果按到达顺序产出；
  - 丢弃 fingerprint 过期的结果。
- **RefreshScheduler**（用假的 sleep）：间隔变化、睡眠和唤醒、刷新成功后 60 秒内丢弃新触发、启动顺序。
- **ConfigStore**：缺少字段时用默认值、未知的键、schemaVersion 过高、文件损坏、迁移用的 fixture、CLI 只读。
- **CLI**：golden file 测试；输出不含邮箱和 accountUuid；退出码。
- **金丝雀测试**：见 §9.3。
- **Shell 引号转义与 slug 生成**：包含空格、引号、换行等特殊字符的输入。

**本机集成冒烟测试**（实现时由我来跑）：

- `tokenbar status --json` 的 Codex 部分，跑真实的 app-server；
- `tokenbar sessions`；
- App 的 `--selftest`。

**需要你在本机做的**：见 §13。

## 12. 构建、打包与安装

- 所有脚本都强制设置 `DEVELOPER_DIR=/Library/Developer/CommandLineTools`。
- `scripts/test.sh`：沿用 Phase 0 的版本，并加上 §4.2 的 grep 守卫。
- `scripts/bundle.sh`：生成 `dist/TokenBar.app`，ad-hoc 签名，设置 `LSUIElement`。
- `scripts/install.sh`：用 `ditto` 复制到 `~/Applications/TokenBar.app`，退出正在运行的旧实例，再打开新的。
- bundle id 为 `dev.tokenbar.TokenBar`，版本 0.1.0。
- `.gitignore` 包括：`.build/`、`.build-tests/`、`dist/`、`.swiftpm/`。

## 13. 待验证项（实现过程中尽早完成）

| # | 验证内容 | 谁来做 | 失败时怎么办 |
|---|---|---|---|
| V1 | `tokenbar status` 读 Claude 钥匙串时会不会弹框、数据对不对；如果弹框后点了拒绝，记录退出码和 stderr | **你**（我被权限策略禁止访问钥匙串） | 如果弹框，点"始终允许"。这个授权是给 `/usr/bin/security` 的，TokenBar 重新构建后也不会失效。如果你拒绝了，该账号只用第③步，卡片提示 `Keychain access denied` |
| V2 | `claude -p "/usage"` 是否确实不调用模型、能否刷新过期的 token、会在专用目录里写哪些文件（包括会不会出现在 sessions 里、`kind` 的值是什么）、会不会触发 hooks | 你先建好一个专用登录，然后由我在这个专用目录里运行（你来跑也可以） | 如果有副作用，默认关闭第②步，只用①③ |
| V3 | 真实的 `/api/oauth/usage` 响应格式是否和解析器一致 | 和 V1 一起做 | 解析器本身容错 |
| V4 | 开机自启（SMAppService）在这台受管理的 Mac 上是否被策略允许，以及各种状态显示是否正确 | 你（在设置里打开开关试一下） | 不提供这个功能 |
| V5 | 终端里的 2.1.123 和 2.1.174 会不会写 `sessions/<pid>.json`，字段是否相同 | 你在终端里分别开一个会话，我来检查 | 不写的话，在会话区注明 "Terminal sessions require Claude Code ≥ <版本>" |
| V6 | codex 的启动参数（`-c features.plugins=false` 和两个 memories 参数）在新版本上是否被接受；在临时 CODEX_HOME 里确认不会克隆插件仓库 | 我（只用签名校验通过的 codex） | 退回只用 `app-server` |
| V7 | 在专用目录里再登录一次某个账号，会不会让日常 `~/.claude` 里同一个账号的登录失效（等 8 小时以上，或者等日常 token 过期后再确认） | 你 | 如果会失效，改成只给"不在 `~/.claude` 里用的那个账号"建专用登录 |

## 14. 后续（MVP 之后）

- 每会话的 token 统计：增量解析 transcript JSONL 里的 `message.usage`
- 低额度通知；会话从 busy 变成 idle 时发通知
- 用量历史和图表
- Codex 会话列表；用 `account/usage/read` 统计 token
- 可选的 statusLine 包装器：把 Claude Code 通过 stdin 传给 statusLine 的 `rate_limits` 保存下来（0–100、epoch 秒），作为一个不需要密钥的实时数据来源，只在终端里的交互式会话有效
- 自定义图标；更多 Provider（Gemini、Copilot、Cursor）

## 15. v2 相对 v1 的改动（来自评审）

- **阻断级**：
  - 补上了 claude 二进制的查找规则（§5.3.2）；
  - 第②步只在专用登录目录里执行，并且目录里不能有活着的会话（§5.3）；
  - TokenBar 绝不向 claude 子进程发信号，用 posix_spawn 单独成组启动，输入输出接 /dev/null（§5.3、§5.7）。
- **重大**：
  - 配置目录的路径改为原样保存（§3.1）；
  - 钥匙串弹框和拒绝时的处理，避免反复弹框（§5.3 第 0、1 步）；
  - 退避和第②步的状态改为持久化，App 和 CLI 共享，token 一变就清除（StateStore）；
  - §9.2 的说法改得更准确；
  - 显示推导：重置时间已过的窗口一律显示为已重置（§5.1）；
  - ProviderError 改成封闭集合，加上金丝雀测试；
  - 默认账号和专用账号同时存在时的处理，以及账号变化的检测；
  - ProcessRunner 不会被孙进程卡住，忽略 SIGPIPE，定义了 LineTransport；
  - 用 WindowObserver 判断面板是否可见；
  - 每个 provider 有自己的 deadline；
  - 定义了刷新合并的语义，结果按到达顺序产出；
  - config 的 schema 演进和损坏处理，并且只有 App 写 config；
  - 所有副作用都通过 CoreEnvironment 注入；
  - RefreshScheduler 移进 Core，可以测试；
  - 用量请求的 URLSession 改成 ephemeral，并拒绝重定向。
- **次要**：
  - 补充 cachedUsageUtilization 的写入条件；
  - 第②步之后先看缓存，再决定要不要调接口；
  - 登录命令里 unset 两个环境变量，并补上 userName 的取值规则；
  - 映射 `limits[]` 里按模型划分的行；
  - CODEX_HOME 校验，Codex 至少每 5 分钟刷新一次；
  - 子进程代理；
  - 新增 V5、V6、V7；
  - 修正时区和 procStart 的边界情况；
  - .command 文件和 slug 的安全规则；
  - 邮箱不落盘；
  - 修正睡眠和唤醒时会重复刷新的问题；
  - MinimalEnv 改为必填；
  - 悬浮窗可以拖动；
  - 开机自启改为按实际状态显示；
  - CLI 用专门的 DTO，并加 golden file 测试。
