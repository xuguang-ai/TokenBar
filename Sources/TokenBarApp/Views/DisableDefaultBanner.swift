// Non-modal offer to disable the default Claude account after the first dedicated login (spec §3.1).
// Shown in the panel and in the Accounts pane; answering it in either place clears both.
import SwiftUI
import TokenBarCore

struct AppDisableDefaultBanner: View {
    let model: AppModel

    var body: some View {
        if let account = model.disableDefaultOffer {
            VStack(alignment: .leading, spacing: 6) {
                Text("Disable the default Claude account?").font(.caption.weight(.semibold))
                Text("Your first dedicated login is ready. \"\(account.displayName)\" follows whoever is logged in "
                     + "with /login in ~/.claude. If you keep it, it is shown as \"Claude (current /login)\".")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Disable default") { model.answerDisableDefaultOffer(disable: true) }
                    Button("Keep") { model.answerDisableDefaultOffer(disable: false) }
                }
                .controlSize(.small)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
