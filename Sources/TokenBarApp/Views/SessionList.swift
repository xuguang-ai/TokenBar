// Claude sessions under a card (spec §5.5): busy rows first, idle collapsed into one "N idle" disclosure.
import SwiftUI
import TokenBarCore

struct AppSessionList: View {
    let sessions: [SessionInfo]
    let now: Date
    /// "Running" above the busy rows (cards); the "Other Claude sessions" module has its own title.
    var showsHeading = true
    @State private var showIdle: Bool

    init(sessions: [SessionInfo], now: Date, showsHeading: Bool = true, initiallyExpanded: Bool = false) {
        self.sessions = sessions
        self.now = now
        self.showsHeading = showsHeading
        _showIdle = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        let busy = sessions.filter { $0.status == .busy }.sorted(by: Self.longestRunningFirst)
        let idle = sessions.filter { $0.status != .busy }.sorted(by: Self.longestRunningFirst)
        VStack(alignment: .leading, spacing: 5) {
            if showsHeading && !busy.isEmpty {
                Text("Running")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 1)
            }
            ForEach(busy) { AppSessionRow(session: $0, now: now) }
            if !idle.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showIdle.toggle() }
                } label: {
                    HStack(spacing: 0) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showIdle ? 90 : 0))
                            .frame(width: AppStyle.iconColumn)
                            .padding(.trailing, 6)
                        Text("\(idle.count) idle")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(idle.count) idle session\(idle.count == 1 ? "" : "s")")
                .accessibilityValue(showIdle ? "expanded" : "collapsed")
                .accessibilityHint(showIdle ? "Hides the idle sessions" : "Shows the idle sessions")
                if showIdle {
                    ForEach(idle) { AppSessionRow(session: $0, now: now).opacity(0.6) }
                }
            }
        }
    }

    /// Oldest `statusUpdatedAt` first, so the longest-running session is on top.
    static func longestRunningFirst(_ a: SessionInfo, _ b: SessionInfo) -> Bool {
        (a.statusUpdatedAt ?? .distantFuture) < (b.statusUpdatedAt ?? .distantFuture)
    }
}

private struct AppSessionRow: View {
    let session: SessionInfo
    let now: Date

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if session.status == .busy {
                    AppBusyDot()
                } else {
                    Circle()
                        .strokeBorder(.secondary, lineWidth: 1)
                        .frame(width: 6.5, height: 6.5)
                }
            }
            .frame(width: AppStyle.iconColumn)
            .padding(.trailing, 6)
            Text(session.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(duration)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.displayName), \(session.status.rawValue)"
                            + (duration.isEmpty ? "" : ", for \(duration)"))
    }

    private var duration: String {
        guard let since = session.statusUpdatedAt else { return "" }
        return Formatting.countdown(to: now, now: since)
    }
}
