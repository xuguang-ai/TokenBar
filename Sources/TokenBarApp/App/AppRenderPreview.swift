// Debug entry points that write PNGs built from stub data, then exit:
//   TokenBarApp --render-floating <dir>   the floating window: the panel content on the glass chrome
//   TokenBarApp --render-panel <dir>      the panel content alone, 360 pt wide, light and dark
//   TokenBarApp --render-settings <dir>   the Accounts and General panes, 640 pt wide
// They never touch the keychain, the network, subprocesses or user data: the stub AppModel runs on a temp
// Application Support dir and a fake home, and is never started.
import AppKit
import SwiftUI
import TokenBarCore

enum AppRenderPreview {
    static let floatingFlag = "--render-floating"
    static let panelFlag = "--render-panel"
    static let settingsFlag = "--render-settings"

    /// Renders and exits when a flag is present; otherwise returns immediately.
    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(where: { [floatingFlag, panelFlag, settingsFlag].contains($0) })
        else { return }
        let flag = arguments[flagIndex]
        guard flagIndex + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: TokenBarApp \(flag) <outputDir>\n".utf8))
            exit(2)
        }
        let path = (arguments[flagIndex + 1] as NSString).expandingTildeInPath
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            switch flag {
            case panelFlag: try renderPanels(to: directory)
            case settingsFlag: try renderSettings(to: directory)
            default: try renderFloating(to: directory)
            }
            try? FileManager.default.removeItem(at: StubModel.root)
            exit(0)
        } catch {
            try? FileManager.default.removeItem(at: StubModel.root)
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private struct RenderError: Error {}

    private static let schemes: [ColorScheme] = [.light, .dark]
    private static func schemeName(_ scheme: ColorScheme) -> String { scheme == .dark ? "dark" : "light" }

    // MARK: Panel

    enum PanelScenario: String, CaseIterable {
        /// The user's real setup: two Claude accounts and Codex, sessions under the first card.
        case a
        /// §8 states: critical, not logged in, stale, paused, the disable-default banner, other sessions.
        case b
        /// No enabled accounts.
        case c
    }

    private static func renderPanels(to directory: URL) throws {
        for scenario in PanelScenario.allCases {
            let model = StubModel.panel(scenario)
            for scheme in schemes {
                let dark = scheme == .dark
                let view = AppPanelContent(model: model, expandIdleSessions: scenario == .b)
                    .background(dark ? Color(red: 0.17, green: 0.17, blue: 0.18)
                                     : Color(red: 0.945, green: 0.945, blue: 0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(dark ? 0.16 : 0.1), lineWidth: 0.5))
                    .padding(14)
                    .background(dark ? Color(white: 0.07) : Color(white: 0.84))
                let url = directory.appendingPathComponent("panel-\(scenario.rawValue)-\(schemeName(scheme)).png")
                try snapshot(view, scheme: scheme, width: AppStyle.panelWidth + 28, height: nil, to: url)
            }
        }
    }

    // MARK: Settings

    private static func renderSettings(to directory: URL) throws {
        let model = StubModel.panel(.a, extraDisabledCodex: true)
        let selected = model.settings.accounts.first { $0.claudeConfigDir != nil }?.id
        let emails = Dictionary(uniqueKeysWithValues: model.settings.accounts.compactMap { account -> (UUID, String)? in
            guard account.provider == .claude else { return nil }
            return (account.id, account.claudeConfigDir == nil ? "you@team.example" : "xai@iu.edu")
        })
        let home = "/Users/you"
        func candidate(_ path: String, _ version: String, _ status: BinaryCandidate.Status) -> BinaryCandidate {
            BinaryCandidate(path: URL(fileURLWithPath: path), realpath: nil, version: SemVer(version), status: status,
                            isOverride: false)
        }
        let candidates: [BinaryKind: [BinaryCandidate]] = [
            .claude: [candidate("\(home)/.local/bin/claude", "2.1.301", .usable),
                      candidate("/opt/homebrew/bin/claude", "2.0.14", .versionTooOld)],
            .codex: [candidate("/opt/homebrew/bin/codex", "0.46.0", .usable)],
        ]
        let panes: [(String, AnyView)] = [
            ("accounts", AnyView(AppAccountsPane(model: model, initialSelection: selected, previewEmails: emails))),
            ("general", AnyView(AppGeneralPane(model: model, previewCandidates: candidates))),
        ]
        for (name, pane) in panes {
            for scheme in schemes {
                let view = pane
                    .frame(width: 640, height: 430)
                    .background(Color(nsColor: .windowBackgroundColor))
                let url = directory.appendingPathComponent("settings-\(name)-\(schemeName(scheme)).png")
                try snapshot(view, scheme: scheme, width: 640, height: 430, to: url)
            }
        }
        // The dedicated-login sheet at its first step.
        let sheet = AppAddDedicatedLoginSheet(model: model).background(Color(nsColor: .windowBackgroundColor))
        try snapshot(sheet, scheme: .light, width: 520, height: nil,
                     to: directory.appendingPathComponent("settings-dedicated-login-light.png"))
    }

    // MARK: Snapshot

    /// Draws `view` in an offscreen window at 2x. Unlike ImageRenderer, this also draws AppKit-backed
    /// controls (lists, switches, text fields, spinners). Materials do not render offscreen, so callers
    /// put a solid stand-in background behind the content.
    private static func snapshot(_ view: some View, scheme: ColorScheme, width: CGFloat, height: CGFloat?,
                                 to url: URL) throws {
        _ = NSApplication.shared
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, scheme).environment(\.controlActiveState, .key)))
        host.appearance = appearance
        host.frame = CGRect(x: 0, y: 0, width: width, height: height ?? 100)
        let window = AppRenderWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: width, height: height ?? 100),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = host
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        let size = CGSize(width: width, height: height ?? ceil(host.fittingSize.height))
        window.setContentSize(size)
        host.frame = CGRect(origin: .zero, size: size)
        settle()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { throw RenderError() }
        rep.size = size
        (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        window.contentView = nil
        window.close()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw RenderError() }
        try png.write(to: url)
        print(url.path)
    }

    // MARK: Floating

    /// The floating window shows the full panel on the glass chrome (Liquid Glass live; an opaque stand-in
    /// here, because offscreen rendering cannot show vibrancy). The dark renders show the pointer over the
    /// window, so the hover-only close button is visible.
    private static func renderFloating(to directory: URL) throws {
        for scenario in [PanelScenario.a, .b] {
            let model = StubModel.panel(scenario)
            for scheme in schemes {
                let dark = scheme == .dark
                let close = AppPanelContent.CloseControl(isShown: dark, action: {})
                let view = AppPanelContent(model: model, close: close, expandIdleSessions: scenario == .b)
                    .modifier(AppFloatingChrome(backdrop: .solid(dark
                        ? Color(red: 0.165, green: 0.165, blue: 0.175)
                        : Color(red: 0.965, green: 0.965, blue: 0.97))))
                    .shadow(color: .black.opacity(dark ? 0.45 : 0.16), radius: 14, y: 6)
                    .padding(28)
                    .background(dark ? Color(white: 0.07) : Color(white: 0.84))
                let url = directory.appendingPathComponent("floating-\(scenario.rawValue)-\(schemeName(scheme)).png")
                try snapshot(view, scheme: scheme, width: AppStyle.panelWidth + 56, height: nil, to: url)
                print(url.path)
            }
        }
    }
}

/// Draws its controls in the active (key) state, as the real panel and Settings window look in use,
/// without ever being ordered on screen or activating the app.
private final class AppRenderWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

// MARK: - Stub AppModel for the panel and Settings renders

private enum StubModel {
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TokenBar-render-\(UUID().uuidString)", isDirectory: true)
    /// A fake home that does not exist: login commands and paths read naturally, and nothing is read.
    static let home = "/Users/you"
    static let hour: TimeInterval = 3_600

    /// 12:09 local time today, so the footer reads "Updated 12:08".
    static let now: Date = {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = 12
        components.minute = 9
        return Calendar.current.date(from: components) ?? Date(timeIntervalSinceReferenceDate: 812_000_000)
    }()

    static func makeModel() -> AppModel {
        var env = CoreEnvironment.live()
        env.appSupportDirectory = root.appendingPathComponent("AppSupport", isDirectory: true)
        env.homeDirectory = URL(fileURLWithPath: home, isDirectory: true)
        let fixed = now
        env.now = { fixed }
        let runtime = TokenBarRuntime(env: env, providerOverrides: [
            .claude: AppSelfTestStubProvider(kind: .claude, now: env.now),
            .codex: AppSelfTestStubProvider(kind: .codex, now: env.now),
        ])
        return AppModel(runtime: runtime, isSelfTest: true, wakeDelay: .zero, defaults: nil)
    }

    static func snapshot(_ config: AccountConfig, plan: String, age: TimeInterval = 60, cached: Bool = false,
                         _ windows: [UsageWindow]) -> UsageSnapshot {
        let asOf = now.addingTimeInterval(-age)
        return UsageSnapshot(accountID: config.id, fetchedAt: asOf, dataAsOf: asOf,
                             source: config.provider == .codex ? .codexAppServer
                                 : (cached ? .claudeCache(fetchedAt: asOf) : .claudeAPI),
                             identity: AccountIdentity(plan: plan), windows: windows, limitReached: false)
    }

    static func window(_ kind: UsageWindow.Kind, _ used: Double, resetsIn hours: Double?) -> UsageWindow {
        guard let hours else { return UsageWindow(kind: kind, usedPercent: used, resetsAt: nil, isStarted: false) }
        return UsageWindow(kind: kind, usedPercent: used, resetsAt: now.addingTimeInterval(hours * hour))
    }

    static func session(_ pid: Int32, _ name: String, _ status: SessionStatus, minutes: Double, dir: String)
        -> SessionInfo {
        SessionInfo(pid: pid, cwd: "\(home)/src/\(name)", status: status,
                    statusUpdatedAt: now.addingTimeInterval(-minutes * 60), configDir: dir)
    }

    static func panel(_ scenario: AppRenderPreview.PanelScenario, extraDisabledCodex: Bool = false) -> AppModel {
        let model = makeModel()
        var settings = AppSettings.makeDefault()
        settings.displayMode = .used
        var states: [AccountState] = []
        var sessions: [SessionGroup] = []
        var offer = false
        let claudeDir = "\(home)/.claude"

        switch scenario {
        case .a:
            let claude = AccountConfig(id: AppSettings.defaultClaudeAccountID, provider: .claude,
                                       displayName: "Claude")
            let iu = AccountConfig(provider: .claude, displayName: "xai@iu.edu",
                                   claudeConfigDir: "\(home)/.tokenbar/claude/iu", isDedicatedLogin: true)
            let codex = AccountConfig(id: AppSettings.defaultCodexAccountID, provider: .codex, displayName: "Codex")
            // Deliberately ungrouped (as an old config.json could be): the panel must still keep Claude together.
            settings.accounts = [claude, codex, iu]
            if extraDisabledCodex {
                settings.accounts.append(AccountConfig(provider: .codex, displayName: "Codex Work",
                                                       codexHome: "\(home)/.codex-work", isEnabled: false))
            }
            states = [
                AccountState(config: claude, lastSnapshot: snapshot(claude, plan: "team", [
                    window(.fiveHour, 60, resetsIn: 2 + 14 / 60),
                    window(.weekly, 78, resetsIn: 35.2),
                    window(.model(name: "Fable"), 82, resetsIn: 35.2),
                ])),
                AccountState(config: codex, lastSnapshot: snapshot(codex, plan: "plus", [
                    window(.fiveHour, 0, resetsIn: nil),
                    window(.weekly, 16, resetsIn: 98.3),
                ])),
                AccountState(config: iu, lastSnapshot: snapshot(iu, plan: "max", [
                    window(.fiveHour, 12, resetsIn: 4.02),
                    window(.weekly, 30, resetsIn: 122.5),
                ])),
            ]
            states += settings.accounts.dropFirst(3).map { AccountState(config: $0) }
            sessions = [SessionGroup(accountID: claude.id, sessions: [
                session(101, "tokenbar", .busy, minutes: 14, dir: claudeDir),
                session(102, "api-server", .idle, minutes: 62, dir: claudeDir),
                session(103, "docs-site", .idle, minutes: 48, dir: claudeDir),
                session(104, "infra", .idle, minutes: 31, dir: claudeDir),
                session(105, "notes", .idle, minutes: 12, dir: claudeDir),
                session(106, "scratch", .idle, minutes: 3, dir: claudeDir),
            ])]
        case .b:
            let claude = AccountConfig(id: AppSettings.defaultClaudeAccountID, provider: .claude,
                                       displayName: "Claude")
            let work = AccountConfig(provider: .claude, displayName: "Work",
                                     claudeConfigDir: "\(home)/.tokenbar/claude/work", isDedicatedLogin: true)
            let personal = AccountConfig(provider: .claude, displayName: "Personal",
                                         claudeConfigDir: "\(home)/.claude-personal")
            let codex = AccountConfig(id: AppSettings.defaultCodexAccountID, provider: .codex, displayName: "Codex")
            settings.accounts = [claude, work, personal, codex]
            var critical = AccountState(config: claude, lastSnapshot: snapshot(claude, plan: "team", [
                window(.fiveHour, 97, resetsIn: 0.64),
                window(.weekly, 71, resetsIn: 50),
            ]))
            critical.isRefreshing = true
            states = [
                critical,
                AccountState(config: work, lastError: .notLoggedIn(hint: .claude(configDir: work.claudeConfigDir))),
                AccountState(config: personal, lastSnapshot: snapshot(personal, plan: "pro", age: 14 * 60, cached: true, [
                    window(.fiveHour, 22, resetsIn: 3.1),
                    window(.weekly, 44, resetsIn: 60),
                ]), lastError: .network(urlErrorCode: -1009)),
                AccountState(config: codex, lastSnapshot: snapshot(codex, plan: "plus", age: 3 * 60, [
                    window(.fiveHour, 38, resetsIn: 2.5),
                    window(.weekly, 52, resetsIn: 70),
                ]), lastError: .rateLimited(until: now.addingTimeInterval(32 * 60))),
            ]
            sessions = [
                SessionGroup(accountID: claude.id, sessions: [
                    session(201, "migration", .busy, minutes: 6, dir: claudeDir),
                ]),
                SessionGroup(accountID: nil, sessions: [
                    session(301, "notebook", .busy, minutes: 8, dir: "\(home)/.claude-lab"),
                    session(302, "sandbox", .idle, minutes: 40, dir: "\(home)/.claude-lab"),
                    session(303, "an-unusually-long-project-directory-name", .idle, minutes: 95,
                            dir: "\(home)/.claude-lab"),
                ]),
            ]
            offer = true
        case .c:
            settings.accounts = settings.accounts.map { var account = $0; account.isEnabled = false; return account }
            states = settings.accounts.map { AccountState(config: $0) }
        }
        model.installRenderState(settings: settings, accounts: states, sessions: sessions, now: now,
                                 lastRefreshAt: now.addingTimeInterval(-60), offerToDisableDefault: offer)
        return model
    }
}
