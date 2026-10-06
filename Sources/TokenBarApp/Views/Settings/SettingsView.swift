// Settings scene (spec §6.5): Accounts and General tabs.
import SwiftUI
import TokenBarCore

struct AppSettingsView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if case .tooNew(let version) = model.configState {
                AppSettingsBanner(text: "config.json was written by a newer TokenBar (schema \(version)). "
                                  + "Settings are read-only and will not be saved.")
            }
            if let warning = model.configWarning {
                AppSettingsBanner(text: warning)
            }
            if let error = model.lastSaveError {
                AppSettingsBanner(text: error)
            }
            TabView {
                AppAccountsPane(model: model)
                    .tabItem { Label("Accounts", systemImage: "person.2") }
                AppGeneralPane(model: model)
                    .tabItem { Label("General", systemImage: "gearshape") }
            }
            .disabled(model.isReadOnly)
        }
        .frame(width: 640, height: 460)
    }
}

private struct AppSettingsBanner: View {
    let text: String

    var body: some View {
        Text("⚠ " + text)
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A text field that saves only on Return or when it loses focus, so typing does not trigger a
/// `.configChange` refresh per keystroke.
struct AppCommitTextField: View {
    let title: String
    let value: String
    var prompt: String?
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: prompt.map { Text($0) })
            .focused($focused)
            .onSubmit(commit)
            .onAppear { text = value }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onChange(of: value) { _, newValue in
                if !focused { text = newValue }
            }
            .onDisappear(perform: commit)
    }

    private func commit() {
        if text != value { onCommit(text) }
    }
}

/// Folder picker for config dirs and CODEX_HOME.
enum AppFolderPicker {
    static func choose(startingAt path: String?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = true
        if let path, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL.path
    }
}
