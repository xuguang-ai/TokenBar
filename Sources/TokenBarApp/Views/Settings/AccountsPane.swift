// Accounts tab (spec §6.5): reorderable list, add/remove, per-account editor with a live identity line.
import AppKit
import SwiftUI
import TokenBarCore

struct AppAccountsPane: View {
    let model: AppModel
    @State private var selection: UUID?
    @State private var showingDedicatedLogin = false

    var body: some View {
        VStack(spacing: 0) {
            if model.disableDefaultOffer != nil {
                AppDisableDefaultBanner(model: model).padding(8)
                Divider()
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(model.settings.accounts) { account in
                            AppAccountListRow(account: account).tag(account.id)
                        }
                        .onMove { model.moveAccounts(from: $0, to: $1) }
                    }
                    HStack(spacing: 4) {
                        Menu {
                            Button("Claude account") { selection = model.addAccount(.claude) }
                            Button("Codex account") { selection = model.addAccount(.codex) }
                            Divider()
                            Button("Add Claude dedicated login…") { showingDedicatedLogin = true }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Button {
                            if let selection { model.removeAccount(selection) }
                            selection = nil
                        } label: {
                            Image(systemName: "minus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(selection == nil)
                        Spacer()
                    }
                    .padding(8)
                }
                .frame(width: 210)
                Divider()
                Group {
                    if let id = selection, let account = model.settings.accounts.first(where: { $0.id == id }) {
                        AppAccountEditor(model: model, account: account).id(account.id)
                    } else {
                        Text("Select an account").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .sheet(isPresented: $showingDedicatedLogin) {
            AppAddDedicatedLoginSheet(model: model)
        }
    }
}

private struct AppAccountListRow: View {
    let account: AccountConfig

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: account.provider == .claude ? "sparkle" : "terminal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !account.isEnabled {
                Text("off").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        switch account.provider {
        case .claude:
            if account.claudeConfigDir == nil { return "Claude · default login" }
            return account.isDedicatedLogin ? "Claude · dedicated login" : "Claude · config dir"
        case .codex:
            return account.codexHome == nil ? "Codex · ~/.codex" : "Codex · CODEX_HOME"
        }
    }
}

private struct AppAccountEditor: View {
    let model: AppModel
    let account: AccountConfig
    /// Read live from the Claude global config; shown here only and never stored (spec §9.7).
    @State private var email: String?

    var body: some View {
        Form {
            AppCommitTextField(title: "Name", value: account.displayName) { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                model.updateAccount(account.id) { $0.displayName = trimmed }
            }
            Toggle("Enabled", isOn: Binding(
                get: { account.isEnabled },
                set: { value in model.updateAccount(account.id) { $0.isEnabled = value } }))
            switch account.provider {
            case .claude: claudeFields
            case .codex: codexFields
            }
            Section("Status") {
                if account.provider == .claude {
                    LabeledContent("Email", value: email ?? "—")
                }
                LabeledContent("Plan", value: state?.lastSnapshot?.identity?.plan ?? "—")
                LabeledContent("Status", value: statusText)
            }
        }
        .formStyle(.grouped)
        .task(id: account.claudeConfigDir) {
            guard account.provider == .claude else { return }
            email = model.runtime.configReader.read(configDir: account.claudeConfigDir)?.oauthAccount?.emailAddress
        }
    }

    private var state: AccountState? { model.state(for: account.id) }

    private var statusText: String {
        guard let state else { return "—" }
        if state.isRefreshing { return "Refreshing…" }
        if let error = state.lastError { return error.userMessage }
        if let snapshot = state.lastSnapshot {
            return "OK · updated \(Formatting.age(since: snapshot.fetchedAt, now: model.now))"
        }
        return "No data yet"
    }

    @ViewBuilder
    private var claudeFields: some View {
        HStack {
            AppCommitTextField(title: "Config dir", value: account.claudeConfigDir ?? "",
                               prompt: "Default (~/.claude)") { setClaudeDir($0) }
            Button("Choose…") {
                if let path = AppFolderPicker.choose(startingAt: account.claudeConfigDir) { setClaudeDir(path) }
            }
        }
        if isHomeClaudeDir {
            VStack(alignment: .leading, spacing: 4) {
                Text("This is ~/.claude given as a path. It is not the same as the default login: the keychain "
                     + "entry differs.")
                    .font(.caption).foregroundStyle(.orange)
                Button("Use the default login instead") { setClaudeDir("") }
                    .controlSize(.small)
            }
        }
        Toggle("Dedicated login (TokenBar may let Claude Code refresh it)", isOn: Binding(
            get: { account.isDedicatedLogin },
            set: { value in model.updateAccount(account.id) { $0.isDedicatedLogin = value } }))
    }

    @ViewBuilder
    private var codexFields: some View {
        HStack {
            AppCommitTextField(title: "CODEX_HOME", value: account.codexHome ?? "",
                               prompt: "Default (~/.codex)") { setCodexHome($0) }
            Button("Choose…") {
                if let path = AppFolderPicker.choose(startingAt: account.codexHome) { setCodexHome(path) }
            }
        }
    }

    /// Only a leading `~` is expanded (spec §3.1); everything else is stored as typed, with no trailing-slash
    /// or realpath changes. The stored string is the one used for CLAUDE_CONFIG_DIR, the keychain hash and
    /// the login command.
    private func setClaudeDir(_ value: String) {
        let path = expandedPath(value)
        model.updateAccount(account.id) { $0.claudeConfigDir = path }
    }

    private func setCodexHome(_ value: String) {
        let path = expandedPath(value)
        model.updateAccount(account.id) { $0.codexHome = path }
    }

    private func expandedPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ClaudePaths.expandTilde(trimmed, home: model.runtime.env.homeDirectory)
    }

    private var isHomeClaudeDir: Bool {
        guard let dir = account.claudeConfigDir else { return false }
        let home = model.runtime.env.homeDirectory.path
        let expanded = dir.hasPrefix("~") ? home + dir.dropFirst() : dir
        var normalized = expanded
        while normalized.count > 1 && normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized == home + "/.claude"
    }
}
