// The menu bar panel, 340 pt wide (spec §6.3).
import AppKit
import SwiftUI
import TokenBarCore

struct AppPanelView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        .background(AppWindowObserver { visible in model.isPanelVisible = visible }.frame(width: 0, height: 0))
        .onAppear {
            model.openSettingsAction = openSettings
            model.reloadConfigIfChanged()
            model.tick()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("TokenBar").font(.headline)
            Spacer()
            Button {
                model.isPinned.toggle()
            } label: {
                Text("📌").opacity(model.isPinned ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .help(model.isPinned ? "Hide the floating window" : "Show a floating window")
            Button {
                model.openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    @ViewBuilder
    private var content: some View {
        if case .tooNew(let version) = model.configState {
            Text("⚠ config.json was written by a newer TokenBar (schema \(version)). "
                 + "Settings are read-only; update TokenBar.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.enabledAccounts.isEmpty {
            Text("No enabled accounts. Add one in Settings.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(model.enabledAccounts, id: \.config.id) { state in
            AppAccountCard(model: model, state: state)
        }
        let others = model.otherSessions
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Other Claude sessions").font(.subheadline.weight(.semibold))
                AppSessionList(sessions: others, now: model.now)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(updatedText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.accounts.contains(where: \.isRefreshing) { ProgressView().controlSize(.small) }
            Button {
                model.refreshNow()
            } label: {
                Label(refreshTitle, systemImage: "arrow.clockwise")
            }
            .disabled(model.isReadOnly)
            Button("Quit") { NSApp.terminate(nil) }
        }
    }

    private var updatedText: String {
        guard let last = model.lastRefreshAt ?? model.accounts.compactMap(\.lastAttemptAt).max() else {
            return "Not updated yet"
        }
        return "Updated \(last.formatted(date: .omitted, time: .shortened))"
    }

    /// Manual refresh cannot skip a 429 backoff: say so when every enabled account is paused (spec §6.1).
    private var refreshTitle: String {
        let now = model.now
        let pauses = model.enabledAccounts.map { $0.pausedUntil.flatMap { $0 > now ? $0 : nil } }
        if !pauses.isEmpty, pauses.allSatisfy({ $0 != nil }), let until = pauses.compactMap({ $0 }).min() {
            return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        }
        return "Refresh"
    }
}
