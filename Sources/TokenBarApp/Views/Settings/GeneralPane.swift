// General tab (spec §6.5): refresh, display, launch at login, Claude Code refresh, binaries, proxy.
import AppKit
import ServiceManagement
import SwiftUI
import TokenBarCore

struct AppGeneralPane: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Refresh") {
                Picker("Refresh every", selection: Binding(
                    get: { model.settings.refreshIntervalMinutes },
                    set: { value in model.updateSettings { $0.refreshIntervalMinutes = value } })) {
                    ForEach(AppSettings.allowedRefreshIntervals, id: \.self) { minutes in
                        Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                    }
                }
                Text("Codex refreshes at most every 5 minutes.").font(.caption).foregroundStyle(.secondary)
                Picker("Show", selection: Binding(
                    get: { model.settings.displayMode },
                    set: { value in model.updateSettings { $0.displayMode = value } })) {
                    Text("Remaining").tag(DisplayMode.remaining)
                    Text("Used").tag(DisplayMode.used)
                }
                Toggle("Allow Claude Code to refresh expired dedicated logins", isOn: Binding(
                    get: { model.settings.allowClaudeCodeRefresh },
                    set: { value in model.updateSettings { $0.allowClaudeCodeRefresh = value } }))
            }
            Section("Startup") {
                AppLaunchAtLoginRow(isSelfTest: model.isSelfTest)
            }
            Section("Claude Code binary") {
                AppCommitTextField(title: "Override path", value: model.settings.claudeBinaryOverride ?? "",
                                   prompt: "Automatic") { value in
                    model.updateSettings { $0.claudeBinaryOverride = Self.optional(value) }
                }
                AppBinaryCandidatesView(model: model, kind: .claude)
            }
            Section("Codex binary") {
                AppCommitTextField(title: "Override path", value: model.settings.codexBinaryOverride ?? "",
                                   prompt: "Automatic") { value in
                    model.updateSettings { $0.codexBinaryOverride = Self.optional(value) }
                }
                AppBinaryCandidatesView(model: model, kind: .codex)
            }
            Section("Network") {
                AppCommitTextField(title: "Subprocess proxy", value: model.settings.subprocessProxy ?? "",
                                   prompt: "System proxy settings") { value in
                    model.updateSettings { $0.subprocessProxy = Self.optional(value) }
                }
                Text("For example http://proxy:8080. Used for claude and codex child processes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at login", isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: { setEnabled($0) }))
                .disabled(!Self.isInstalled || isSelfTest)
            if status == .requiresApproval {
                HStack {
                    Text("Approve TokenBar in System Settings › Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.small)
                }
            }
            if !Self.isInstalled {
                Text("Available once TokenBar is in /Applications or ~/Applications (run scripts/install.sh).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text("⚠ " + error).font(.caption).foregroundStyle(.orange)
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
    @State private var candidates: [BinaryCandidate]?

    var body: some View {
        Group {
            if model.isSelfTest {
                Text("Not checked in selftest mode").font(.caption).foregroundStyle(.secondary)
            } else if let candidates {
                if candidates.isEmpty {
                    Text("No \(kind.rawValue) binary found").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(candidates, id: \.self) { candidate in
                    HStack(alignment: .firstTextBaseline) {
                        Text(Self.abbreviate(candidate.path.path))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(candidate.version?.description ?? "?").font(.caption).monospacedDigit()
                        Text(Self.statusText(candidate))
                            .font(.caption)
                            .foregroundStyle(candidate.status == .usable ? Color.green : Color.secondary)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: overrideValue) {
            guard !model.isSelfTest else { return }
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
