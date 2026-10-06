// Non-modal offer to disable the default Claude account after the first dedicated login (spec §3.1).
// Shown in the panel and in the Accounts pane; answering it in either place clears both.
import SwiftUI
import TokenBarCore

struct AppDisableDefaultBanner: View {
    let model: AppModel

    var body: some View {
        if let account = model.disableDefaultOffer {
            AppNoticeModule(
                symbol: "info.circle.fill", tint: .accentColor,
                title: "Your dedicated login is ready",
                message: "“\(account.displayName)” follows whoever is logged in with /login. "
                    + "Disable it to show only your dedicated logins."
            ) {
                HStack(spacing: 6) {
                    Button("Disable default") { model.answerDisableDefaultOffer(disable: true) }
                        .buttonStyle(.borderedProminent)
                    Button("Keep") { model.answerDisableDefaultOffer(disable: false) }
                }
                .controlSize(.small)
            }
        }
    }
}
