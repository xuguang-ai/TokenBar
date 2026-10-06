// Forwards NSWorkspace sleep/wake and app activation to the scheduler and model (spec §6.1, §5.8).
import AppKit
import TokenBarCore

/// Lives as long as the model (the whole app run), so observers are never removed.
final class AppSystemEventsBridge {
    private enum PowerEvent: Sendable { case willSleep, didWake }

    private var observers: [any NSObjectProtocol] = []
    private let continuation: AsyncStream<PowerEvent>.Continuation

    init(scheduler: RefreshScheduler, onActivate: @escaping @MainActor () -> Void) {
        // One consumer keeps sleep/wake in notification order (separate Tasks could reorder them).
        let (stream, continuation) = AsyncStream.makeStream(of: PowerEvent.self)
        self.continuation = continuation
        Task {
            for await event in stream {
                switch event {
                case .willSleep: await scheduler.willSleep()
                case .didWake: await scheduler.didWake()
                }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { continuation.yield(.willSleep) }
        observe(workspace, NSWorkspace.didWakeNotification) { continuation.yield(.didWake) }
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { onActivate() }
    }

    /// The observer block is @Sendable and nonisolated even with `queue: .main`; it does run on the main
    /// thread, so `assumeIsolated` is safe.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { body() }
        }
        observers.append(token)
    }
}
