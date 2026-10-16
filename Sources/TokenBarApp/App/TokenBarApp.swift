// TokenBarApp (spec §6): an AppKit status item that toggles the floating window, plus a Settings scene.
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
    /// Owned for the App's lifetime; the NSStatusItem itself is created after launch.
    private let statusItem: AppStatusItemController

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
        let statusItem = AppStatusItemController(model: model)
        self.statusItem = statusItem
        // Runs once the run loop is up, so NSApp exists. The status item comes first: the floating window
        // opens under it the first time.
        Task { @MainActor in
            statusItem.install()
            model.start(floatingAnchor: { [weak statusItem] in statusItem?.buttonScreenFrame })
            if model.isSelfTest { AppSelfTest(model: model, statusItem: statusItem).run() }
        }
    }

    var body: some Scene {
        Settings {
            AppSettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // State is persisted as it changes (SIGTERM skips applicationWillTerminate), so nothing happens at quit.
}
