import SwiftUI

/// One sheet hosts the whole purchase: the step enum drives which screen is
/// up, so the fixed order lives in PurchaseFlow, not in view code.
struct PurchaseSheet: View {
    @ObservedObject var flow: PurchaseFlow
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch flow.step {
        case .privacy:
            PrivacySecuritySheet(
                text: model.privacyText,
                onContinue: { flow.acknowledgePrivacy() },
                onNotNow: { flow.cancel() })
        default:
            // Plan, waiting and error screens land in the next commits of
            // this phase; until then any non-privacy step is escapable.
            VStack(spacing: 16) {
                ProgressView()
                Button("Cancel") { flow.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .frame(width: 360, height: 200)
        }
    }
}
