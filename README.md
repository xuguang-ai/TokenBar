# TokenBar

> **一眼看到所有 AI coding 账号还剩多少额度。**

TokenBar 是一个常驻 macOS 菜单栏的小工具。它会显示：

- 多个 **Claude** 账号和 **Codex**（ChatGPT）账号的 5 小时额度、每周额度、按模型划分的周限额，以及各自的重置倒计时；
- 当前正在运行的 **Claude Code 窗口**：哪些在跑任务（busy），哪些空闲（idle），各持续了多久。

它不需要打开网页，也不需要切换账号；所有凭据都只留在本机。设计细节见 [docs/superpowers/specs/2026-10-05-tokenbar-mvp-design.md](docs/superpowers/specs/2026-10-05-tokenbar-mvp-design.md)，可行性调研结论见 [docs/phase0/findings.md](docs/phase0/findings.md)。

## 环境要求

- macOS 14 或更高版本（开发和验证都在 macOS 26 上完成）
- Xcode Command Line Tools（Swift 6.2）。不需要完整的 Xcode
- 至少一个已登录的 Claude Code（≥ 2.1.289 时可以自动刷新专用登录）和/或 Codex（VS Code 的 ChatGPT 扩展或 `codex` CLI）

## 构建与安装

```bash
cd ~/Desktop/TokenBar
scripts/bundle.sh     # release 构建 → dist/TokenBar.app（ad-hoc 签名）
scripts/install.sh    # 复制到 ~/Applications/TokenBar.app 并启动（会先退出旧实例）
```

所有脚本会自动把 `DEVELOPER_DIR` 设为 Command Line Tools。这台机器上的 Xcode 27 尚未接受许可，直接用 `swift` 命令会失败。

## 第一次使用：为每个 Claude 账号建一个专用登录

如果你在同一个 `~/.claude` 里用 `/login` 来回切换账号，TokenBar 没法把 `~/.claude` 当作某个固定账号的数据来源。做法是给每个账号建一个 **TokenBar 专用登录目录**，各登录一次：

1. 点菜单栏的 TokenBar 图标 → ⚙ → **Accounts** → `+` → **Add Claude dedicated login…**
2. 输入一个名字，例如 `Work`。TokenBar 会创建 `~/.tokenbar/claude/work`（权限 0700），并给出一条登录命令：

   ```bash
   env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_CUSTOM_OAUTH_URL CLAUDE_CONFIG_DIR='/Users/<you>/.tokenbar/claude/work' '<claude 路径>' auth login
   ```

3. 点 **Open in Terminal**（或者 Copy 后自己粘贴到终端），在弹出的浏览器里登录**对应的** claude.ai 账号。
4. TokenBar 大约 5 秒内会检测到登录完成，然后自动加上这个账号并开始刷新。
5. 第二个账号（例如 `Personal`）重复上面几步。第一个专用登录完成后，TokenBar 会建议停用默认的 "Claude" 卡片，避免同一个账号显示两遍。

你日常照样在 `~/.claude` 里工作、用 `/login` 切换，互不影响。专用目录只供 TokenBar 读取用量；它的 token 过期后，TokenBar 会在后台运行一次 `claude -p "/usage"`，由 Claude Code 自己完成刷新。

Codex 默认读取 `~/.codex`，一般不需要做任何配置。

## 日常使用

**菜单栏**

- 菜单栏显示所有账号里**最紧张**的那个百分比（默认显示已用，和 Claude `/usage`、Codex `/status` 一致；可在设置里改成显示剩余）。
- 后缀含义：`?` 表示数据过旧或刷新失败；`!` 表示所有账号都失败了而且没有任何数据；`–` 表示还没有数据。

**面板**

点开图标是下拉面板：

- 每个账号一张卡片，按窗口分行（5h / Week / Sonnet / 模型限额），每行有进度条、百分比和重置倒计时。
- 进度条按剩余额度变色：
  - 大于 50% 为绿色；
  - 20–50% 为黄色；
  - 20% 以下为橙色；
  - 5% 以下为红色。
- 卡片在需要时会多一行状态说明，例如数据来自缓存、`Paused until …`、`Not logged in`（附带登录命令和 Copy 按钮）。
- Claude 卡片下列出正在运行的窗口：busy 在前，idle 折叠成一行 "N idle ▸"。

**📌 悬浮窗**

点面板上的 📌，会出现一个右上角的置顶小窗：

- 所有桌面（Space）都能看到，不抢焦点；
- 可以拖动，位置会被记住；
- 再点一次 📌 就收回。

**⚙ 设置**

- **Accounts**：
  - 增删账号、改名、拖动排序、启用或停用；
  - 编辑配置目录或 `CODEX_HOME`；
  - 查看实时检测到的邮箱和套餐。
- **General**：
  - 刷新间隔（Codex 至少 5 分钟）；
  - 显示剩余还是已用；
  - 开机自启（要求 App 放在 `~/Applications` 或 `/Applications`）；
  - 是否允许 Claude Code 刷新专用登录；
  - 手动指定 claude/codex 路径；
  - 子进程使用的代理。

**刷新时机**

默认每 5 分钟一次，另外在以下时候也会刷新：

- 点 Refresh；
- App 启动；
- Mac 从睡眠中唤醒（唤醒 10 秒后）；
- 修改设置。

刷新失败时保留上次成功的数据，并标出更新时间。

## 命令行：`tokenbar`

```bash
swift build                              # 生成 .build/debug/tokenbar
.build/debug/tokenbar status             # 表格
.build/debug/tokenbar status --json      # JSON（计划 Phase 1 定义的格式）
.build/debug/tokenbar status --account Codex --account Work
.build/debug/tokenbar sessions [--json]  # 正在运行的 Claude Code 窗口
.build/debug/tokenbar --help | --version
```

- 默认**不会**让 Claude Code 刷新过期的专用登录；需要时加 `--allow-claude-refresh`。原因是在终端里按 Ctrl-C 有可能打断正在进行的刷新。
- 退出码：
  - `0`：全部成功；
  - `1`：至少一个账号失败（仍会输出能拿到的数据）；
  - `2`：配置错误或参数错误。
- CLI 只读 `config.json`（由 App 写入），不会改动它。输出里不包含邮箱和 accountUuid。

## 隐私与安全

- **不保存凭据。**
  - Claude 的 access token 是 TokenBar 通过 `/usr/bin/security` 从 Claude Code 自己的钥匙串条目里读出来的。它只在内存里短暂存在，只发往 `https://api.anthropic.com`（不使用缓存，不跟随重定向）。
  - Codex 的数据由官方 `codex app-server` 读取，TokenBar 从头到尾看不到 Codex 的 token。
- **不碰你的登录。**
  - TokenBar 从不调用 OAuth 刷新接口，也从不写 `~/.claude*`、`~/.codex` 或钥匙串。
  - token 的刷新只交给 Claude Code 自己处理，而且只在专用登录目录里做，不会把你日常的 Claude Code 登出。
- **只运行签名验证通过的程序。**
  - claude 必须由 Anthropic（Q6L2SF6YDW）签名，codex 必须由 OpenAI（2DC432GLL2）签名。
  - 子进程只拿到最少的环境变量，不会继承你 shell 里的 API key。
- **本地文件。**
  - 本地文件都放在 `~/Library/Application Support/TokenBar/`：
    - `config.json`：账号和设置；
    - `snapshots.json`：上次的用量；
    - `state.json`：退避状态。
  - 权限为 0600，所在目录为 0700。
  - 邮箱不会落盘。

## 开发

```bash
scripts/test.sh                                           # swift-testing 全量测试（不要直接用 swift test）
scripts/test.sh --filter ClaudeProvider                   # 只跑一部分
swift build -c release && scripts/bundle.sh \
  && dist/TokenBar.app/Contents/MacOS/TokenBar --selftest # 用假数据自检 UI，输出 SELFTEST PASS
bash scripts/probe-claude-usage.sh                        # 一次性探测：读 Claude 钥匙串并调用用量接口，只打印数字
```

- 代码结构：
  - `Sources/TokenBarCore`：所有逻辑，不含 UI；
  - `Sources/TokenBarCLI`：命令行；
  - `Sources/TokenBarApp`：SwiftUI/AppKit 界面。
- Core 里所有副作用（时钟、文件、子进程、网络、签名校验）都通过 `CoreEnvironment` 注入。
- `scripts/test.sh` 有一个守卫：如果 `Live*.swift` 以外的 Core 代码直接调用了这些 API，测试就会失败。
- 实现计划：[docs/superpowers/plans/2026-10-06-tokenbar-mvp.md](docs/superpowers/plans/2026-10-06-tokenbar-mvp.md)。

## 还需要你在本机验证的事项（规格 §13）

| # | 内容 | 状态 |
|---|---|---|
| V1 | 读 Claude 钥匙串会不会弹框 | ✅ 不弹框（0.08 秒） |
| V2 | `claude -p "/usage"` 会不会调用模型、能不能刷新过期 token、会写哪些文件 | 待验证：建好第一个专用登录后做 |
| V3 | 真实的用量接口格式 | ✅ 与解析器一致 |
| V4 | 开机自启是否被学校的管理策略允许 | 待验证：在设置里打开开关试一下 |
| V5 | 终端里旧版本的 claude（2.1.123 / 2.1.174）会不会写会话注册表 | 待验证 |
| V6 | codex 启动参数在新版本上是否都被接受 | 待验证 |
| V7 | 在专用目录里登录同一个账号，会不会挤掉日常 `~/.claude` 里的登录 | 待验证：登录后过 8 小时以上再看日常的 Claude Code 是否还在登录状态 |
