// TokenBarApp (spec §6): a menu bar extra with a window-style panel, plus a Settings scene.
// The target uses .defaultIsolation(MainActor.self); TokenBarCore stays nonisolated.
import AppKit
import SwiftUI
import TokenBarCore

enum AppLaunchOptions {
    static var isSelfTest: Bool { ProcessInfo.processInfo.arguments.contains("--selftest") }
}

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        AppRenderPreview.runIfRequested()  // debug: `--render-floating <dir>` renders stub PNGs and exits
        signal(SIGPIPE, SIG_IGN)
        let model: AppModel
        if AppLaunchOptions.isSelfTest {
            model = AppSelfTest.makeModel()
        } else {
            model = AppModel(runtime: TokenBarRuntime.live(), isSelfTest: false, wakeDelay: .seconds(10),
                             defaults: .standard)
        }
        _model = State(initialValue: model)
        // Runs once the run loop is up, so NSApp and the status item exist.
        Task { @MainActor in
            model.start()
            if model.isSelfTest { AppSelfTest(model: model).run() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            AppPanelView(model: model)
        } label: {
            AppMenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            AppSettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // State is persisted as it changes (SIGTERM skips applicationWillTerminate), so nothing happens at quit.
}
