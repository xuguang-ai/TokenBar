// One account module in the panel (spec §6.3, card states per §8).
import AppKit
import SwiftUI
import TokenBarCore

struct AppAccountCard: View {
    let model: AppModel
    let state: AccountState
    var expandIdleSessions = false

    var body: some View {
        let now = model.now
        let display = state.lastSnapshot.map { DisplayDerivation.derive($0, now: now) }
        VStack(alignment: .leading, spacing: 0) {
            AppCardHeader(state: state)
            AppCardStatus(model: model, state: state, now: now)
            if let display {
                VStack(alignment: .leading, spacing: 7) {
                    if display.windows.isEmpty {
                        AppStatusLine(symbol: "minus.circle", text: "No usage windows reported")
                    }
                    ForEach(Array(display.windows.enumerated()), id: \.offset) { _, window in
                        AppUsageRow(window: window, mode: model.settings.displayMode, now: now, isStale: isStale)
                    }
                }
                .padding(.top, 10)
            }
            if state.config.provider == .claude, let group = model.sessions(for: state.config.id),
               !group.sessions.isEmpty {
                AppHairline()
                    .padding(.top, 11)
                    .padding(.bottom, 8)
                AppSessionList(sessions: group.sessions, now: now, initiallyExpanded: expandIdleSessions)
            }
        }
        .appModule()
    }

    /// The bars show older data: the last refresh failed, or it is paused.
    private var isStale: Bool {
        guard let error = state.lastError else { return false }
        switch error {
        case .keychainAccessDenied, .waitingForClaudeCode: return true
        default: return state.lastSnapshot != nil
        }
    }
}

/// "<symbol> Claude  xai@iu.edu  Max" with a spinner while refreshing. One accessibility element.
private struct AppCardHeader: View {
    let state: AccountState

    var body: some View {
        let provider = state.config.provider.defaultDisplayName
        let name = state.config.displayName
        let showsName = name.caseInsensitiveCompare(provider) != .orderedSame && !name.isEmpty
        let plan = AppStyle.plan(state.lastSnapshot?.identity?.plan)
        HStack(spacing: 0) {
            Image(systemName: AppStyle.symbol(for: state.config.provider))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: AppStyle.iconColumn, alignment: .center)
                .padding(.trailing, 6)
            Text(provider)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()
            if showsName {
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 5)
            }
            if let plan {
                AppPlanBadge(text: plan).padding(.leading, 6)
            }
            Spacer(minLength: 8)
            if state.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .help("Refreshing")
            }
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([provider, showsName ? name : nil, plan, state.isRefreshing ? "refreshing" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isHeader)
    }
}

/// The status line(s) of a card. Only shown when something is unusual (spec §6.3, §8).
private struct AppCardStatus: View {
    let model: AppModel
    let state: AccountState
    let now: Date

    var body: some View {
        Group {
            if let error = state.lastError {
                errorView(error)
            } else if let snapshot = state.lastSnapshot {
                if snapshot.source.isCached {
                    AppStatusLine(symbol: "clock.arrow.circlepath", text: ageText(snapshot))
                }
            } else if state.isRefreshing {
                AppStatusLine(symbol: "ellipsis.circle", text: "Loading…")
            } else {
                AppStatusLine(symbol: "circle.dashed", text: "No data yet")
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func errorView(_ error: ProviderError) -> some View {
        switch error {
        case .notLoggedIn(let hint):
            loginView(hint: hint, title: "Not logged in. Run this in Terminal:")
        case .notACodexProfile:
            loginView(hint: .codex(home: state.config.codexHome), title: "Not a Codex profile. Run this in Terminal:")
        default:
            VStack(alignment: .leading, spacing: 3) {
                if case .rateLimited(let until) = error {
                    // Self-explanatory: says why the data is old and when the next request may go out.
                    AppStatusLine(symbol: "pause.circle",
                                  text: error.userMessage + (until > now ? " · next try \(AppStyle.clock(until))" : ""))
                } else if let paused = error.pausedUntil, paused > now {
                    AppStatusLine(symbol: "pause.circle", text: "Paused until \(AppStyle.clock(paused)) · \(error.userMessage)")
                } else if state.lastSnapshot != nil, !Self.isSelfExplanatory(error) {
                    AppStatusLine(symbol: "exclamationmark.triangle.fill",
                                  text: "Unable to refresh · \(error.userMessage)", tone: .warning)
                } else {
                    AppStatusLine(symbol: "exclamationmark.triangle.fill", text: error.userMessage, tone: .warning)
                }
                ageCaption
            }
        }
    }

    private func loginView(hint: LoginHint, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AppStatusLine(symbol: "exclamationmark.triangle.fill", text: title, tone: .warning)
            AppLoginCommandView(model: model, hint: hint)
            ageCaption
        }
    }

    /// Marks the bars below an error as stale: "Updated 14 min ago" (+ " · cached").
    @ViewBuilder
    private var ageCaption: some View {
        if let snapshot = state.lastSnapshot {
            Text(ageText(snapshot))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, AppStyle.iconColumn + 3)
        }
    }

    private func ageText(_ snapshot: UsageSnapshot) -> String {
        "Updated \(Formatting.age(since: snapshot.dataAsOf, now: now))" + (snapshot.source.isCached ? " · cached" : "")
    }

    /// Messages that already describe the cached-data situation (spec §8 table).
    private static func isSelfExplanatory(_ error: ProviderError) -> Bool {
        switch error {
        case .waitingForClaudeCode, .keychainAccessDenied, .claudeBinaryNotFound, .accountChanged, .rateLimited: return true
        default: return false
        }
    }
}

/// The login command (with the located binary path, or "claude"/"codex") in a selectable monospaced box,
/// with a Copy button. The binary is re-located whenever the view appears, after each refresh, when the
/// override changes and on Copy, so a Claude update or a new override never leaves a stale path behind.
struct AppLoginCommandView: View {
    let model: AppModel
    let hint: LoginHint
    @State private var copied = false

    private struct LocateKey: Hashable {
        var hint: LoginHint
        var override: String?
        var lastRefreshAt: Date?
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(model.loginCommand(for: hint))
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task {
                    AppPasteboard.copy(await model.resolvedLoginCommand(for: hint))
                    copied = true
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copied ? AnyShapeStyle(Color(nsColor: .systemGreen)) : AnyShapeStyle(.secondary))
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copied ? "Copied" : "Copy command")
            .accessibilityLabel(copied ? "Copied" : "Copy command")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.primary.opacity(0.08),
                                                                                    lineWidth: 0.5))
        .task(id: locateKey) { _ = await model.resolveLoginBinary(hint.appBinaryKind) }
    }

    private var locateKey: LocateKey {
        let override = hint.appBinaryKind == .claude
            ? model.settings.claudeBinaryOverride : model.settings.codexBinaryOverride
        return LocateKey(hint: hint, override: override, lastRefreshAt: model.lastRefreshAt)
    }
}

enum AppPasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension LoginHint {
    var appBinaryKind: BinaryKind {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }
}
