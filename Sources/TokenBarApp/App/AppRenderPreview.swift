// Debug entry point: `TokenBarApp --render-floating <dir>` writes PNGs of the floating window's content
// built from stub data, then exits. It never touches the keychain, the network, subprocesses or user data.
import AppKit
import SwiftUI
import TokenBarCore

enum AppRenderPreview {
    static let flag = "--render-floating"

    /// Renders and exits when the flag is present; otherwise returns immediately.
    static func runIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag) else { return }
        guard index + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: TokenBarApp \(flag) <outputDir>\n".utf8))
            exit(2)
        }
        let directory = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for scenario in Scenario.allCases {
                for scheme in [ColorScheme.light, .dark] {
                    let name = "floating-\(scenario.rawValue)-\(scheme == .dark ? "dark" : "light").png"
                    let url = directory.appendingPathComponent(name)
                    try render(scenario, scheme: scheme, to: url)
                    print(url.path)
                }
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
            exit(1)
        }
    }

    enum Scenario: String, CaseIterable {
        case a, b, c
    }

    private struct RenderError: Error {}

    private static func render(_ scenario: Scenario, scheme: ColorScheme, to url: URL) throws {
        let dark = scheme == .dark
        let card = AppFloatingCard(
            rows: rows(for: scenario),
            isRefreshing: scenario == .b,
            isHovering: scenario == .b,
            canRefresh: true,
            onUnpin: {}, onRefresh: {})
            .modifier(AppFloatingChrome(backdrop: .solid(dark
                ? Color(red: 0.165, green: 0.165, blue: 0.175)
                : Color(red: 0.965, green: 0.965, blue: 0.97))))
            .shadow(color: .black.opacity(dark ? 0.45 : 0.16), radius: 14, y: 6)
            .padding(28)
            .environment(\.colorScheme, scheme)
            .environment(\.displayScale, 2)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        var image: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw RenderError() }
        try png.write(to: url)
    }

    // MARK: Stub data

    private static let now = Date(timeIntervalSinceReferenceDate: 812_000_000)

    private static func rows(for scenario: Scenario) -> [AppFloatingRowModel] {
        var settings = AppSettings.makeDefault()
        settings.displayMode = .used
        let hour: TimeInterval = 3_600
        func account(_ provider: ProviderKind, _ name: String) -> AccountConfig {
            AccountConfig(provider: provider, displayName: name)
        }
        func snapshot(_ config: AccountConfig, plan: String, age: TimeInterval = 60, _ windows: [UsageWindow])
            -> UsageSnapshot
        {
            UsageSnapshot(accountID: config.id, fetchedAt: now.addingTimeInterval(-age),
                          dataAsOf: now.addingTimeInterval(-age), source: .claudeAPI,
                          identity: AccountIdentity(plan: plan), windows: windows, limitReached: false)
        }
        func row(_ state: AccountState, busy: [String] = []) -> AppFloatingRowModel {
            AppFloatingRowModel.make(state: state, settings: settings, now: now, busySessionNames: busy)
        }

        let work = account(.claude, "Work")
        let personal = account(.claude, "Personal")
        let codex = account(.codex, "Codex")
        switch scenario {
        case .a:
            return [
                row(AccountState(config: work, lastSnapshot: snapshot(work, plan: "team", [
                    UsageWindow(kind: .fiveHour, usedPercent: 41, resetsAt: now.addingTimeInterval(2.2 * hour)),
                    UsageWindow(kind: .weekly, usedPercent: 58, resetsAt: now.addingTimeInterval(35.5 * hour)),
                    UsageWindow(kind: .model(name: "Fable"), usedPercent: 82,
                                resetsAt: now.addingTimeInterval(35.5 * hour)),
                ])), busy: ["tokenbar", "api-server"]),
                row(AccountState(config: personal, lastSnapshot: snapshot(personal, plan: "pro", [
                    UsageWindow(kind: .fiveHour, usedPercent: 35, resetsAt: now.addingTimeInterval(3.2 * hour)),
                    UsageWindow(kind: .weekly, usedPercent: 22, resetsAt: now.addingTimeInterval(100 * hour)),
                ]))),
                row(AccountState(config: codex, lastSnapshot: snapshot(codex, plan: "plus", [
                    UsageWindow(kind: .fiveHour, usedPercent: 0, resetsAt: nil, isStarted: false),
                    UsageWindow(kind: .weekly, usedPercent: 16, resetsAt: now.addingTimeInterval(98.3 * hour)),
                ]))),
            ]
        case .b:
            return [
                row(AccountState(config: work, lastSnapshot: snapshot(work, plan: "team", [
                    UsageWindow(kind: .fiveHour, usedPercent: 97, resetsAt: now.addingTimeInterval(0.64 * hour)),
                    UsageWindow(kind: .weekly, usedPercent: 71, resetsAt: now.addingTimeInterval(50 * hour)),
                ])), busy: ["migration"]),
                row(AccountState(config: personal, lastSnapshot: snapshot(personal, plan: "pro", age: 14 * 60, [
                    UsageWindow(kind: .weekly, usedPercent: 44, resetsAt: now.addingTimeInterval(60 * hour)),
                ]), lastError: .network(urlErrorCode: -1009))),
                row(AccountState(config: codex, lastError: .notLoggedIn(hint: .codex(home: nil)))),
            ]
        case .c:
            let solo = account(.claude, "Research & Development Lab")
            return [
                row(AccountState(config: solo, lastSnapshot: snapshot(solo, plan: "max_20x", [
                    UsageWindow(kind: .fiveHour, usedPercent: 23, resetsAt: now.addingTimeInterval(4.1 * hour)),
                    UsageWindow(kind: .weekly, usedPercent: 9, resetsAt: now.addingTimeInterval(120 * hour)),
                ]))),
            ]
        }
    }
}
