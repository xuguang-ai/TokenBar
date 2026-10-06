// The menu bar panel, 360 pt wide (spec §6.3): a header, one module per enabled account, a footer toolbar.
import AppKit
import SwiftUI
import TokenBarCore

/// The live panel: the content plus visibility tracking. The render preview draws `AppPanelContent` alone,
/// so it never ticks the clock or reloads the config.
struct AppPanelView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        AppPanelContent(model: model)
            .background(AppWindowObserver { visible in model.isPanelVisible = visible }.frame(width: 0, height: 0))
            .onAppear {
                model.openSettingsAction = openSettings
                model.reloadConfigIfChanged()
                model.tick()
            }
    }
}

struct AppPanelContent: View {
    let model: AppModel
    /// Render preview only: expand the idle-session disclosures.
    var expandIdleSessions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.top, 9)
                .padding(.bottom, 7)
            VStack(alignment: .leading, spacing: AppStyle.moduleSpacing) {
                modules
            }
            .padding(.horizontal, AppStyle.panelInset)
            AppHairline()
                .padding(.top, 10)
            footer
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
        }
        .frame(width: AppStyle.panelWidth)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 2) {
            Text("TokenBar")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            AppIconButton(symbol: model.isPinned ? "pin.fill" : "pin",
                          help: model.isPinned ? "Hide the floating window" : "Show a floating window",
                          tint: model.isPinned ? .accentColor : nil) {
                model.isPinned.toggle()
            }
            AppIconButton(symbol: "gearshape", help: "Settings") { model.openSettings() }
        }
    }

    // MARK: Modules

    @ViewBuilder
    private var modules: some View {
        if case .tooNew(let version) = model.configState {
            AppNoticeModule(symbol: "exclamationmark.triangle.fill", tint: AppStyle.warning,
                            title: "Settings are read-only",
                            message: "config.json was written by a newer TokenBar (schema \(version)). "
                                + "Update TokenBar to change settings.")
        }
        AppDisableDefaultBanner(model: model)
        let accounts = model.enabledAccounts
        if accounts.isEmpty && !model.isReadOnly {
            AppPanelEmptyState(openSettings: model.openSettings)
        }
        ForEach(accounts, id: \.config.id) { state in
            AppAccountCard(model: model, state: state, expandIdleSessions: expandIdleSessions)
        }
        let others = model.otherSessions
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: AppStyle.iconColumn)
                    Text("Other Claude sessions")
                        .font(.system(size: 13, weight: .semibold))
                }
                .accessibilityElement(children: .combine)
                AppSessionList(sessions: others, now: model.now, showsHeading: false,
                               initiallyExpanded: expandIdleSessions)
            }
            .appModule()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 2) {
            Text(footerText)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            AppIconButton(symbol: "arrow.clockwise", help: refreshHelp, spinning: isRefreshing) {
                model.refreshNow()
            }
            .disabled(model.isReadOnly)
            AppTextButton("Quit") { NSApp.terminate(nil) }
        }
    }

    private var isRefreshing: Bool { model.accounts.contains(where: \.isRefreshing) }

    private var footerText: String {
        if let until = allPausedUntil { return "Paused until \(AppStyle.clock(until))" }
        if isRefreshing { return "Updating…" }
        guard let last = model.lastRefreshAt ?? model.accounts.compactMap(\.lastAttemptAt).max() else {
            return "Not updated yet"
        }
        return "Updated \(AppStyle.clock(last))"
    }

    /// Manual refresh cannot skip a 429 backoff: say so when every enabled account is paused (spec §6.1).
    private var allPausedUntil: Date? {
        let now = model.now
        let pauses = model.enabledAccounts.map { $0.pausedUntil.flatMap { $0 > now ? $0 : nil } }
        guard !pauses.isEmpty, pauses.allSatisfy({ $0 != nil }) else { return nil }
        return pauses.compactMap { $0 }.min()
    }

    private var refreshHelp: String {
        allPausedUntil.map { "Paused until \(AppStyle.clock($0))" } ?? "Refresh now"
    }
}

/// No enabled accounts: a friendly message and a way into Settings.
private struct AppPanelEmptyState: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text("No accounts to show")
                .font(.system(size: 13, weight: .semibold))
            Text("Turn on a Claude or Codex account in Settings\nto see its usage here.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings…", action: openSettings)
                .controlSize(.small)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .appModule()
    }
}

/// An inline notice with an accent (or warning) tint: icon, title, message and optional buttons.
struct AppNoticeModule<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: AppStyle.iconColumn)
                .padding(.top, 0.5)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
                    .padding(.top, 5)
            }
        }
        .appModule(tint: tint)
    }
}

extension AppNoticeModule where Actions == EmptyView {
    init(symbol: String, tint: Color, title: String, message: String) {
        self.init(symbol: symbol, tint: tint, title: title, message: message) { EmptyView() }
    }
}
