// "Add Claude dedicated login" (spec §6.5, §3.1).
import AppKit
import Darwin
import SwiftUI
import TokenBarCore

struct AppAddDedicatedLoginSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var configDir: String?
    @State private var command: String?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Claude dedicated login").font(.headline)
            Text("TokenBar creates a private login directory for this account. Log in there once with Claude "
                 + "Code; your everyday ~/.claude and /login are not affected.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if configDir == nil {
                TextField("Name (e.g. Work)", text: $name)
                    .onSubmit { Task { await create() } }
                Text(slugText).font(.caption).foregroundStyle(.secondary)
            }
            if let configDir, let command {
                Text("Run this in a terminal, then finish the login in your browser:").font(.callout)
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button(copied ? "Copied" : "Copy") {
                        Task {
                            AppPasteboard.copy(await freshCommand(configDir: configDir))
                            copied = true
                        }
                    }
                    Button("Open in Terminal") {
                        Task {
                            do {
                                try AppTerminalLauncher.open(command: await freshCommand(configDir: configDir))
                            } catch {
                                self.error = "Could not open Terminal."
                            }
                        }
                    }
                }
                loginStatus(configDir: configDir)
            }
            if let error {
                Text("⚠ " + error).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                if configDir == nil {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Create") { Task { await create() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(ShellQuoting.slug(from: name) == nil)
                } else {
                    Button("Stop waiting") {
                        if let configDir { model.cancelDedicatedLogin(configDir: configDir) }
                        dismiss()
                    }
                    .disabled(!isWaiting)
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var slugText: String {
        guard let slug = ShellQuoting.slug(from: name) else { return "Use letters or digits." }
        return "Directory: ~/.tokenbar/claude/\(slug)"
    }

    private var isWaiting: Bool {
        guard let configDir else { return false }
        return model.pendingDedicatedLogins[configDir] != nil
    }

    @ViewBuilder
    private func loginStatus(configDir: String) -> some View {
        if model.completedDedicatedLogins.contains(configDir) {
            Label("Logged in. The account is ready.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if isWaiting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for the login… (checked every 5 s; you can close this window)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Stopped waiting. The account stays in the list and shows this command until you log in.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Re-locates claude so the command never carries a path that went away since the sheet opened.
    private func freshCommand(configDir: String) async -> String {
        let fresh = await model.resolvedLoginCommand(for: .claude(configDir: configDir))
        command = fresh
        return fresh
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // The account is saved now, with the same absolute dir string the command uses (spec §6.5).
            let dir = try model.addDedicatedLogin(name: trimmed)
            configDir = dir
            command = await model.resolvedLoginCommand(for: .claude(configDir: dir))
            error = nil
            model.watchDedicatedLogin(configDir: dir, name: trimmed)
        } catch {
            self.error = error.message
        }
    }
}

/// "Open in Terminal": a 0700 `<tmp>/TokenBar/<UUID>.command` created with O_EXCL, opened through
/// NSWorkspace and deleted after 60 s (spec §6.5 step 4, §9.8).
enum AppTerminalLauncher {
    enum LaunchError: Error { case cannotCreate, cannotWrite, cannotOpen }

    static func open(command: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TokenBar", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent("\(UUID().uuidString).command")
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
        guard fd >= 0 else { throw LaunchError.cannotCreate }
        let script = Data("#!/bin/sh\n\(command)\n".utf8)
        let written = script.withUnsafeBytes { buffer in
            fchmod(fd, 0o700) == 0 ? Darwin.write(fd, buffer.baseAddress, buffer.count) : -1
        }
        close(fd)
        guard written == script.count else {
            try? FileManager.default.removeItem(at: url)
            throw LaunchError.cannotWrite
        }
        Task {
            try? await Task.sleep(for: .seconds(60))
            try? FileManager.default.removeItem(at: url)
        }
        guard NSWorkspace.shared.open(url) else { throw LaunchError.cannotOpen }
    }
}
