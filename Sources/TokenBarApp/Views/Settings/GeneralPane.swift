// General tab (spec §6.5): refresh, display, launch at login, and advanced options (Claude Code refresh,
// binaries, proxy). A grouped form with a helper caption under each choice.
import AppKit
import ServiceManagement
import SwiftUI
import TokenBarCore

struct AppGeneralPane: View {
    let model: AppModel
    /// Render preview only: binary candidates to show instead of locating them.
    var previewCandidates: [BinaryKind: [BinaryCandidate]]?

    var body: some View {
        Form {
            Section("Refresh") {
                Picker(selection: Binding(
                    get: { model.settings.refreshIntervalMinutes },
                    set: { value in model.updateSettings { $0.refreshIntervalMinutes = value } })) {
                    ForEach(AppSettings.allowedRefreshIntervals, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                    }
                } label: {
                    Text("Refresh every")
                    Text("Codex refreshes at most every 5 minutes.")
                }
            }
            Section("Display") {
                Picker(selection: Binding(
                    get: { shownMenuBarSource },
                    set: { value in model.updateSettings { $0.menuBarSource = value } })) {
                    Text("Active Claude account").tag(MenuBarSource.activeClaude)
                    Text("Most constrained account").tag(MenuBarSource.mostConstrained)
                    Divider()
                    ForEach(model.settings.accounts.filter(\.isEnabled)) { account in
                        Text(account.displayName).tag(MenuBarSource.account(account.id))
                    }
                } label: {
                    Text("Menu bar shows")
                    Text(Self.menuBarSourceCaption(shownMenuBarSource))
                }
                Picker(selection: Binding(
                    get: { model.settings.displayMode },
                    set: { value in model.updateSettings { $0.displayMode = value } })) {
                    Text("Used").tag(DisplayMode.used)
                    Text("Remaining").tag(DisplayMode.remaining)
                } label: {
                    Text("Show percentages as")
                    Text("Applies to the menu bar, the panel and the floating window.")
                }
                .pickerStyle(.segmented)
                Picker(selection: Binding(
                    get: { model.settings.resetTimeStyle },
                    set: { value in model.updateSettings { $0.resetTimeStyle = value } })) {
                    Text("Clock time").tag(ResetTimeStyle.clock)
                    Text("Countdown").tag(ResetTimeStyle.countdown)
                } label: {
                    Text("Reset times")
                    Text("“Wed 11:00 PM” or “1d 12h”. The other format shows on hover.")
                }
                .pickerStyle(.segmented)
            }
            Section("Startup") {
                AppLaunchAtLoginRow(isSelfTest: model.isSelfTest)
            }
            Section("Advanced") {
                Toggle(isOn: Binding(
                    get: { model.settings.allowClaudeCodeRefresh },
                    set: { value in model.updateSettings { $0.allowClaudeCodeRefresh = value } })) {
                    Text("Let Claude Code refresh dedicated logins")
                    Text("When a dedicated login's token expires, TokenBar may run Claude Code to renew it.")
                }
                AppCommitTextField(title: "Subprocess proxy", value: model.settings.subprocessProxy ?? "",
                                   prompt: "System settings") { value in
                    model.updateSettings { $0.subprocessProxy = Self.optional(value) }
                }
                Text("For example http://proxy:8080. Used for claude and codex child processes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                AppCommitTextField(title: "Override path", value: model.settings.claudeBinaryOverride ?? "",
                                   prompt: "Automatic") { value in
                    model.updateSettings { $0.claudeBinaryOverride = Self.optional(value) }
                }
                AppBinaryCandidatesView(model: model, kind: .claude, preview: previewCandidates?[.claude])
            } header: {
                Text("Claude Code binary")
            } footer: {
                Text("TokenBar only runs binaries signed by Anthropic, version 2.1.289 or later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Codex binary") {
                AppCommitTextField(title: "Override path", value: model.settings.codexBinaryOverride ?? "",
                                   prompt: "Automatic") { value in
                    model.updateSettings { $0.codexBinaryOverride = Self.optional(value) }
                }
                AppBinaryCandidatesView(model: model, kind: .codex, preview: previewCandidates?[.codex])
            }
        }
        .formStyle(.grouped)
    }

    /// A chosen account that is missing or disabled behaves like `.activeClaude` (spec §5.1 rule 5).
    private var shownMenuBarSource: MenuBarSource {
        let source = model.settings.menuBarSource
        if case .account(let id) = source, !model.settings.accounts.contains(where: { $0.id == id && $0.isEnabled }) {
            return .activeClaude
        }
        return source
    }

    static func menuBarSourceCaption(_ source: MenuBarSource) -> String {
        switch source {
        case .activeClaude: return "Follows the account ~/.claude is logged in to."
        case .mostConstrained: return "The account closest to a limit."
        case .account: return "Always this account."
        }
    }

    static func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Reads `SMAppService.mainApp.status` live (on appear and on activation); the state is never stored.
private struct AppLaunchAtLoginRow: View {
    let isSelfTest: Bool
    @State private var status: SMAppService.Status = .notRegistered
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: { setEnabled($0) })) {
                Text("Launch at login")
                if !Self.isInstalled {
                    Text("Available once TokenBar is in /Applications or ~/Applications (run scripts/install.sh).")
                }
            }
            .disabled(!Self.isInstalled || isSelfTest)
            if status == .requiresApproval {
                HStack {
                    Text("Approve TokenBar in System Settings › Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(AppStyle.warning)
            }
        }
        .onAppear(perform: readStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            readStatus()
        }
    }

    static var isInstalled: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApps + "/")
    }

    private func readStatus() {
        status = SMAppService.mainApp.status
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = enabled ? "Could not enable launch at login." : "Could not disable launch at login."
        }
        readStatus()
    }
}

/// Every candidate binary with its version and status (spec §6.5). Not run in the selftest.
private struct AppBinaryCandidatesView: View {
    let model: AppModel
    let kind: BinaryKind
    let preview: [BinaryCandidate]?
    @State private var candidates: [BinaryCandidate]?

    var body: some View {
        Group {
            if let shown = preview ?? candidates {
                if shown.isEmpty {
                    Text("No \(kind.rawValue) binary found").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(shown, id: \.self) { candidate in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: candidate.status == .usable ? "checkmark.circle.fill" : "minus.circle")
                            .font(.caption)
                            .foregroundStyle(candidate.status == .usable
                                             ? AnyShapeStyle(Color(nsColor: .systemGreen)) : AnyShapeStyle(.tertiary))
                        Text(Self.abbreviate(candidate.path.path))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(candidate.version?.description ?? "?")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Text(Self.statusText(candidate))
                            .font(.caption)
                            .foregroundStyle(candidate.status == .usable ? .primary : .secondary)
                    }
                }
            } else if model.isSelfTest {
                Text("Not checked in selftest mode").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: overrideValue) {
            guard !model.isSelfTest, preview == nil else { return }
            candidates = await model.runtime.binaryLocator.candidates(kind, settings: model.settings)
        }
    }

    private var overrideValue: String? {
        kind == .claude ? model.settings.claudeBinaryOverride : model.settings.codexBinaryOverride
    }

    static func statusText(_ candidate: BinaryCandidate) -> String {
        let text: String
        switch candidate.status {
        case .usable: text = "usable"
        case .signatureInvalid: text = "bad signature"
        case .notMachO: text = "not a binary"
        case .notExecutable: text = "not executable"
        case .versionTooOld: text = "too old"
        case .versionUnknown: text = "version unknown"
        case .missing: text = "missing"
        }
        return candidate.isOverride ? "override · " + text : text
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
