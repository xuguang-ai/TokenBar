# TokenBar — Project Plan

> **Your AI usage at a glance.**

## 1. 项目目标

TokenBar 是一个轻量级的 macOS 菜单栏 / 右上角悬浮 Dashboard，用于集中查看多个 AI coding assistant 账号的 usage 和 quota。

第一版主要解决：

- 同时查看 **2 个 Claude 账号**的使用量
- 查看 **1 个 Codex / ChatGPT 账号**的使用量
- 不需要频繁打开网页、切换账号或分别运行 `/status`
- 在 macOS 右上角快速看到剩余额度和 reset 时间

长期可以扩展到 Gemini、GitHub Copilot、Cursor 等服务。

---

## 2. MVP

### 2.1 Menu Bar

菜单栏常驻 TokenBar 图标，点击后展开小型 Dashboard。

示例：

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

### 2.2 核心功能

- 多 Claude account 支持
- Codex account 支持
- Usage percentage
- Remaining quota（如果数据源提供）
- Reset time / countdown
- 手动 Refresh
- 自动定时 Refresh
- 不同账号自定义名称，例如 `Work` / `Personal`

### 2.3 状态提醒

根据剩余 quota 提供简单状态：

```text
> 50%      Normal
20–50%     Getting low
< 20%      Low
< 5%       Critical
```

后续可以加入 macOS notification。

---

## 3. 技术方案

### App

优先采用原生 macOS：

- **Swift**
- **SwiftUI**
- `MenuBarExtra`
- macOS Keychain
- macOS Notification Center

原因：应用很小，原生实现资源占用低，而且 Menu Bar 体验最好。

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

定义统一数据结构：

```text
UsageProvider
├── getUsage()
├── getResetTime()
├── refresh()
└── accountName
```

这样未来可以很容易增加：

```text
GeminiProvider
CursorProvider
CopilotProvider
OpenAIAPIProvider
```

---

## 4. Usage 数据获取

这是项目最关键的部分，开发前优先验证。

### Claude

目标：研究 Claude Code 本地保存的 authentication / usage 信息以及可用的官方接口，确定是否能够在不打开网页的情况下获取：

- 当前账号
- 5-hour usage
- weekly usage
- reset time

需要特别解决 **多个 Claude account session 如何隔离和读取**。

原则：

- 优先官方或本地 CLI 已使用的数据源
- 不把密码/token上传到任何服务器
- 凭据仅存储在本机 Keychain

### Codex

研究 Codex CLI `/status` 使用的数据来源，优先复用本地 Codex authentication/session，在本机获取：

- usage
- allowance
- reset time

避免要求用户重复登录。

---

## 5. Account Management

设置页面：

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

账号配置只保存：

- Provider
- Display name
- Local credential reference
- Refresh preference

敏感 authentication 信息放入 macOS Keychain。

---

## 6. Refresh Strategy

默认每 **5 分钟**刷新一次。

同时在以下情况刷新：

- 用户点击 Refresh
- App 启动
- Mac 从 sleep 恢复
- Account configuration 改变

如果 provider 出错，保留最后一次成功结果并显示：

```text
Claude · Work
68%
Last updated 14 min ago
⚠ Unable to refresh
```

---

## 7. 开发阶段

### Phase 0 — Feasibility

先写 CLI prototype，不做 UI。

目标：证明可以获取：

```text
Claude A → usage
Claude B → usage
Codex    → usage
```

这是整个项目的 Go / No-Go checkpoint。

### Phase 1 — CLI Prototype

实现：

```bash
tokenbar status
```

输出统一 JSON：

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

实现：

- MenuBarExtra
- Usage cards
- Progress bars
- Reset countdown
- Manual refresh
- Auto refresh

目标是达到“每天自己愿意一直开着”的程度。

### Phase 3 — Multi-account UX

实现：

- Add/remove account
- Rename account
- Reorder account
- Keychain storage
- Login/session error handling

### Phase 4 — Polish

加入：

- Low quota notification
- Launch at Login
- Refresh interval setting
- Dark / Light Mode
- Better icons
- Usage history

---

## 8. 推荐项目结构

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

## 9. 第一版明确不做

为了避免 scope creep，MVP 暂时不做：

- AI API cost accounting
- 团队 usage dashboard
- 云端账号同步
- Web dashboard
- iOS app
- Windows/Linux GUI
- 自动在 Claude/Codex 账号之间切换

TokenBar 第一版只解决一个问题：

> **不用切账号，一眼看到所有 AI coding accounts 还剩多少额度。**

---

## 10. Success Criteria

MVP 成功标准：

1. TokenBar 可以全天常驻 macOS Menu Bar。
2. 一个界面同时显示 2 个 Claude + 1 个 Codex account。
3. Usage 数据无需手工打开 Claude/Codex 页面获取。
4. 从点击 TokenBar 到看到全部 usage < 1 秒（使用缓存）。
5. 后台刷新不会明显增加 CPU / memory 使用。
6. 所有 authentication credentials 都只保存在本机。

---

## 11. 下一步

**第一件事不是写 Swift UI，而是验证 Claude 和 Codex usage 数据到底能不能稳定读取。**

建议开发顺序：

```text
Claude usage 探索
       ↓
Codex usage 探索
       ↓
CLI prototype
       ↓
统一 UsageProvider interface
       ↓
SwiftUI Menu Bar
       ↓
Multi-account + Keychain
       ↓
Notifications / Polish
```

如果 Phase 0 能稳定读取三个账号的数据，后面的 Dashboard 本身实现难度不高。
