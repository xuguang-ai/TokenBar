// Accounts tab (spec §6.5): accounts in provider sections, each with its own add button; reorder within a
// section; a grouped-form editor for the selected account with a live identity line.
import AppKit
import SwiftUI
import TokenBarCore

struct AppAccountsPane: View {
    let model: AppModel
    /// Render preview only: emails to show instead of reading them live.
    let previewEmails: [UUID: String]?
    @State private var selection: UUID?
    @State private var showingDedicatedLogin = false
    /// Read live from each Claude account's global config; shown here only and never stored (spec §9.7).
    @State private var emails: [UUID: String] = [:]

    init(model: AppModel, initialSelection: UUID? = nil, previewEmails: [UUID: String]? = nil) {
        self.model = model
        self.previewEmails = previewEmails
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.disableDefaultOffer != nil {
                AppDisableDefaultBanner(model: model)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                Divider()
            }
            HStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(ProviderKind.allCases, id: \.self) { provider in
                        section(provider)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 236)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showingDedicatedLogin) {
            AppAddDedicatedLoginSheet(model: model)
        }
        .task(id: claudeDirsKey) { readEmails() }
    }

    private func accounts(_ provider: ProviderKind) -> [AccountConfig] {
        model.settings.accounts.filter { $0.provider == provider }
    }

    private func section(_ provider: ProviderKind) -> some View {
        let items = accounts(provider)
        return Section {
            ForEach(items) { account in
                AppAccountListRow(model: model, account: account, email: email(for: account))
                    .tag(account.id)
                    .contextMenu {
                        Button("Remove Account") { remove(account.id) }
                    }
            }
            .onMove { move(provider: provider, from: $0, to: $1) }
            if items.isEmpty {
                Text("No \(provider.defaultDisplayName) accounts")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
            }
        } header: {
            HStack {
                Text(provider.defaultDisplayName)
                Spacer()
                addButton(provider)
            }
        }
    }

    @ViewBuilder
    private func addButton(_ provider: ProviderKind) -> some View {
        Menu {
            switch provider {
            case .claude:
                Button("Add Dedicated Login…") { showingDedicatedLogin = true }
                Button("Add Account with Config Dir…") { addAccountWithDirectory(.claude) }
            case .codex:
                Button("Add Codex Account") { selection = model.addAccount(.codex) }
                Button("Add Account with CODEX_HOME…") { addAccountWithDirectory(.codex) }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a \(provider.defaultDisplayName) account")
        .accessibilityLabel("Add a \(provider.defaultDisplayName) account")
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, let account = model.settings.accounts.first(where: { $0.id == id }) {
            AppAccountEditor(model: model, account: account, email: email(for: account)) { remove(account.id) }
                .id(account.id)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select an account").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    /// Reorders within one provider section. Sections are contiguous in `settings.accounts` (Core groups
    /// them), so the section offsets map to global offsets.
    private func move(provider: ProviderKind, from source: IndexSet, to destination: Int) {
        let all = model.settings.accounts
        let indices = all.indices.filter { all[$0].provider == provider }
        guard !indices.isEmpty else { return }
        let globalSource = IndexSet(source.compactMap { $0 < indices.count ? indices[$0] : nil })
        let globalDestination = destination < indices.count ? indices[destination] : indices[indices.count - 1] + 1
        model.moveAccounts(from: globalSource, to: globalDestination)
    }

    private func remove(_ id: UUID) {
        model.removeAccount(id)
        if selection == id { selection = nil }
    }

    /// Picks the folder first, then adds the account for it, named after the folder (".claude-work" → "claude-work").
    private func addAccountWithDirectory(_ provider: ProviderKind) {
        guard let path = AppFolderPicker.choose(startingAt: nil) else { return }
        let folder = URL(fileURLWithPath: path).lastPathComponent
        let name = folder.hasPrefix(".") ? String(folder.dropFirst()) : folder
        selection = model.addAccount(provider, directory: path, displayName: name.isEmpty ? nil : name)
    }

    // MARK: Emails

    private var claudeDirsKey: [String] {
        model.settings.accounts.filter { $0.provider == .claude }.map { "\($0.id)|\($0.claudeConfigDir ?? "")" }
    }

    private func email(for account: AccountConfig) -> String? {
        (previewEmails ?? emails)[account.id]
    }

    private func readEmails() {
        guard previewEmails == nil else { return }
        var found: [UUID: String] = [:]
        for account in model.settings.accounts where account.provider == .claude {
            let config = model.runtime.configReader.read(configDir: account.claudeConfigDir)
            if let email = config?.oauthAccount?.emailAddress, !email.isEmpty { found[account.id] = email }
        }
        if found != emails { emails = found }
    }
}

/// Symbol, name and "Plan · email" (or the login type); disabled rows are dimmed and marked "Off".
private struct AppAccountListRow: View {
    let model: AppModel
    let account: AccountConfig
    let email: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: AppStyle.symbol(for: account.provider))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if !account.isEnabled {
                AppPlanBadge(text: "Off")
                    .help("Not shown or refreshed. Turn it on in the account's settings.")
            }
        }
        .opacity(account.isEnabled ? 1 : 0.55)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let plan = AppStyle.plan(model.state(for: account.id)?.lastSnapshot?.identity?.plan)
        let known = [plan, email].compactMap { $0 }
        if !known.isEmpty { return known.joined(separator: " · ") }
        return AppAccountEditor.loginKind(account)
    }
}

private struct AppAccountEditor: View {
    let model: AppModel
    let account: AccountConfig
    let email: String?
    let onRemove: () -> Void
    @State private var confirmingRemove = false

    var body: some View {
        Form {
            Section {
                header
            }
            Section {
                AppCommitTextField(title: "Name", value: account.displayName) { name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    model.updateAccount(account.id) { $0.displayName = trimmed }
                }
                Toggle(isOn: Binding(
                    get: { account.isEnabled },
                    set: { value in model.updateAccount(account.id) { $0.isEnabled = value } })) {
                    Text("Show in TokenBar")
                    Text("Disabled accounts are not refreshed.")
                }
            }
            switch account.provider {
            case .claude: claudeFields
            case .codex: codexFields
            }
            Section("Status") {
                if account.provider == .claude {
                    LabeledContent("Email", value: email ?? "—")
                }
                LabeledContent("Plan", value: AppStyle.plan(state?.lastSnapshot?.identity?.plan) ?? "—")
                LabeledContent("Status", value: statusText)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Remove Account…", role: .destructive) { confirmingRemove = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove “\(account.displayName)”?", isPresented: $confirmingRemove) {
            Button("Remove", role: .destructive, action: onRemove)
        } message: {
            Text("TokenBar stops showing this account. Its login and files are not touched.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: AppStyle.symbol(for: account.provider))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(account.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let plan = AppStyle.plan(state?.lastSnapshot?.identity?.plan) { AppPlanBadge(text: plan) }
                }
                Text("\(account.provider.defaultDisplayName) · \(Self.loginKind(account))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
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

    /// "Default login", "Dedicated login", "Custom config dir", "~/.codex", "Custom CODEX_HOME".
    static func loginKind(_ account: AccountConfig) -> String {
        switch account.provider {
        case .claude:
            if account.claudeConfigDir == nil { return "Default login" }
            return account.isEffectiveDedicatedLogin ? "Dedicated login" : "Custom config dir"
        case .codex:
            return account.codexHome == nil ? "~/.codex" : "Custom CODEX_HOME"
        }
    }

    @ViewBuilder
    private var claudeFields: some View {
        Section {
            HStack {
                AppCommitTextField(title: "Config dir", value: account.claudeConfigDir ?? "",
                                   prompt: "Default (~/.claude)") { setClaudeDir($0) }
                Button("Choose…") {
                    if let path = AppFolderPicker.choose(startingAt: account.claudeConfigDir) { setClaudeDir(path) }
                }
            }
            if isHomeClaudeDir {
                VStack(alignment: .leading, spacing: 4) {
                    Label("This is ~/.claude given as a path. It is not the same as the default login: the "
                          + "keychain entry differs.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(AppStyle.warning)
                    Button("Use the default login instead") { setClaudeDir("") }
                        .controlSize(.small)
                }
            }
            Toggle(isOn: Binding(
                get: { account.isEffectiveDedicatedLogin },
                set: { value in model.updateAccount(account.id) { $0.isDedicatedLogin = value } })) {
                Text("Dedicated login")
                Text(account.claudeConfigDir == nil
                     ? "The default login is shared with your own Claude Code and can't be dedicated."
                     : "TokenBar may let Claude Code refresh this login when its token expires.")
            }
            // The default login (~/.claude) is shared with your own Claude Code and can never be dedicated.
            .disabled(account.claudeConfigDir == nil)
        } header: {
            Text("Login")
        }
    }

    @ViewBuilder
    private var codexFields: some View {
        Section("Profile") {
            HStack {
                AppCommitTextField(title: "CODEX_HOME", value: account.codexHome ?? "",
                                   prompt: "Default (~/.codex)") { setCodexHome($0) }
                Button("Choose…") {
                    if let path = AppFolderPicker.choose(startingAt: account.codexHome) { setCodexHome(path) }
                }
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
