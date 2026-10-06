// One account card in the panel (spec §6.3, card states per §8).
import AppKit
import SwiftUI
import TokenBarCore

struct AppAccountCard: View {
    let model: AppModel
    let state: AccountState

    var body: some View {
        let now = model.now
        let display = state.lastSnapshot.map { DisplayDerivation.derive($0, now: now) }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(cardTitle).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                if state.isRefreshing { ProgressView().controlSize(.mini) }
                Spacer()
                if let plan = state.lastSnapshot?.identity?.plan {
                    Text(plan).font(.caption).foregroundStyle(.secondary)
                }
            }
            AppCardStatus(model: model, state: state, now: now)
            if let display {
                if display.windows.isEmpty {
                    Text("No usage windows reported").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(display.windows.enumerated()), id: \.offset) { _, window in
                    AppUsageRow(window: window, mode: model.settings.displayMode, now: now)
                }
            }
            if state.config.provider == .claude, let group = model.sessions(for: state.config.id),
               !group.sessions.isEmpty {
                AppSessionList(sessions: group.sessions, now: now)
                    .padding(.top, 2)
            }
        }
    }

    private var cardTitle: String {
        let title = model.title(for: state)
        // "Claude · Work" for named accounts; the bare provider name otherwise.
        let provider = state.config.provider.defaultDisplayName
        if title == provider || title.hasPrefix(provider) { return title }
        return "\(provider) · \(title)"
    }
}

/// The status line(s) of a card. Only shown when something is unusual (spec §6.3, §8).
private struct AppCardStatus: View {
    let model: AppModel
    let state: AccountState
    let now: Date

    var body: some View {
        if let error = state.lastError {
            errorView(error)
        } else if let snapshot = state.lastSnapshot {
            if snapshot.source.isCached {
                caption("(cached · \(Formatting.age(since: snapshot.dataAsOf, now: now)))")
            }
        } else if state.isRefreshing {
            caption("Loading…")
        } else {
            caption("No data yet")
        }
    }

    @ViewBuilder
    private func errorView(_ error: ProviderError) -> some View {
        switch error {
        case .notLoggedIn(let hint):
            AppLoginCommandView(model: model, kind: hint.appBinaryKind, title: "⚠ Not logged in. Run:",
                                command: model.loginCommand(for: hint))
        case .notACodexProfile:
            AppLoginCommandView(model: model, kind: .codex, title: "⚠ Not a Codex profile. Run:",
                                command: model.loginCommand(for: .codex(home: state.config.codexHome)))
        default:
            VStack(alignment: .leading, spacing: 1) {
                if let paused = error.pausedUntil, paused > now {
                    warning("Paused until \(Self.clock(paused))")
                } else if state.lastSnapshot != nil, !Self.isSelfExplanatory(error) {
                    warning("⚠ Unable to refresh: \(error.userMessage)")
                } else {
                    warning("⚠ \(error.userMessage)")
                }
                if let snapshot = state.lastSnapshot {
                    caption("Last updated \(Formatting.age(since: snapshot.dataAsOf, now: now))"
                            + (snapshot.source.isCached ? " (cached)" : ""))
                }
            }
        }
    }

    /// Messages that already describe the cached-data situation (spec §8 table).
    private static func isSelfExplanatory(_ error: ProviderError) -> Bool {
        switch error {
        case .waitingForClaudeCode, .keychainAccessDenied, .claudeBinaryNotFound, .accountChanged: return true
        default: return false
        }
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func warning(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// Login hint, the command with the located binary path (or "claude"/"codex"), and a Copy button.
struct AppLoginCommandView: View {
    let model: AppModel
    let kind: BinaryKind
    let title: String
    let command: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.orange)
            HStack(alignment: .top, spacing: 6) {
                Text(command)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(copied ? "Copied" : "Copy") {
                    AppPasteboard.copy(command)
                    copied = true
                }
                .controlSize(.small)
            }
        }
        .task(id: kind) { _ = await model.resolveLoginBinary(kind) }
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
