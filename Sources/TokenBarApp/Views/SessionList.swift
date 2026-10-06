// Claude sessions under a card (spec §5.5): busy rows first, idle collapsed into "N idle ▸".
import SwiftUI
import TokenBarCore

struct AppSessionList: View {
    let sessions: [SessionInfo]
    let now: Date
    @State private var showIdle = false

    var body: some View {
        let busy = sessions.filter { $0.status == .busy }.sorted(by: Self.longestRunningFirst)
        let idle = sessions.filter { $0.status != .busy }.sorted(by: Self.longestRunningFirst)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(busy) { AppSessionRow(session: $0, now: now) }
            if !idle.isEmpty {
                Button {
                    showIdle.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text("○").foregroundStyle(.secondary)
                        Text("\(idle.count) idle \(showIdle ? "▾" : "▸")")
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showIdle {
                    ForEach(idle) { AppSessionRow(session: $0, now: now) }
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
        HStack(spacing: 6) {
            Text(session.status == .busy ? "●" : "○")
                .foregroundStyle(session.status == .busy ? Color.green : Color.secondary)
            Text(session.displayName).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(session.status.rawValue).foregroundStyle(.secondary)
            Text(duration)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .font(.caption)
    }

    private var duration: String {
        guard let since = session.statusUpdatedAt else { return "" }
        return Formatting.countdown(to: now, now: since)
    }
}
