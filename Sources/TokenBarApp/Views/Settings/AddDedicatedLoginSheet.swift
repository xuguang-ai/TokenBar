// "Add Claude dedicated login" (spec §6.5, §3.1): three steps — name it, run the login command, wait.
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: AppStyle.symbol(for: .claude))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a dedicated Claude login").font(.headline)
                    Text("TokenBar keeps a private login directory for this account. Your everyday ~/.claude "
                         + "and /login are not affected.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, 18)

            step(1, "Name the account", done: configDir != nil) {
                if configDir == nil {
                    TextField("Name", text: $name, prompt: Text("e.g. Work"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await create() } }
                    Text(slugText).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(name.trimmingCharacters(in: .whitespacesAndNewlines))
                        .foregroundStyle(.secondary)
                }
            }
            step(2, "Log in with Claude Code", done: isLoggedIn, active: configDir != nil) {
                if let configDir, let command {
                    Text("Run this in a terminal, then finish the login in your browser.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                AppPasteboard.copy(await freshCommand(configDir: configDir))
                                copied = true
                            }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        Button {
                            Task {
                                do {
                                    try AppTerminalLauncher.open(command: await freshCommand(configDir: configDir))
                                } catch {
                                    self.error = "Could not open Terminal."
                                }
                            }
                        } label: {
                            Label("Open in Terminal", systemImage: "terminal")
                        }
                    }
                    .controlSize(.small)
                } else {
                    Text("TokenBar shows the command once the account is created.")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            }
            step(3, "Wait for the login", done: isLoggedIn, active: configDir != nil, isLast: true) {
                if let configDir {
                    loginStatus(configDir: configDir)
                } else {
                    Text("TokenBar notices the login on its own.")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AppStyle.warning)
                    .padding(.top, 4)
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
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: 520)
    }

    /// A numbered step: a circle (a checkmark once done), a title and its content; dimmed until active.
    private func step(_ number: Int, _ title: String, done: Bool, active: Bool = true, isLast: Bool = false,
                      @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                ZStack {
                    Circle().fill(done ? Color(nsColor: .systemGreen) : (active ? Color.accentColor : Color.primary.opacity(0.12)))
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    } else {
                        Text("\(number)").font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                }
                .foregroundStyle(active || done ? Color.white : Color.secondary)
                .frame(width: 20, height: 20)
                if !isLast {
                    Rectangle().fill(.primary.opacity(0.1)).frame(width: 1).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(active ? .primary : .secondary)
                content()
            }
            .padding(.bottom, isLast ? 0 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number): \(title)\(done ? ", done" : "")")
    }

    private var slugText: String {
        guard let slug = ShellQuoting.slug(from: name) else { return "Use letters or digits." }
        return "Directory: ~/.tokenbar/claude/\(slug)"
    }

    private var isWaiting: Bool {
        guard let configDir else { return false }
        return model.pendingDedicatedLogins[configDir] != nil
    }

    private var isLoggedIn: Bool {
        guard let configDir else { return false }
        return model.completedDedicatedLogins.contains(configDir)
    }

    @ViewBuilder
    private func loginStatus(configDir: String) -> some View {
        if model.completedDedicatedLogins.contains(configDir) {
            Label("Logged in. The account is ready.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
        } else if isWaiting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for the login… TokenBar checks every 5 seconds; you can close this window.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Stopped waiting. The account stays in the list and shows this command until you log in.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
