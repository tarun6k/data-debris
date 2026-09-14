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
        case .plan:
            ChoosePlanSheet(flow: flow)
        case .waiting(let shortReference):
            VStack(spacing: 14) {
                ProgressView()
                Text("Waiting for checkout…")
                    .font(.system(size: 15, weight: .semibold))
                Text("Finish the purchase in your browser — activation is automatic. "
                    + "Reference \(shortReference).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Cancel") { flow.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            .frame(width: 380)
        case .activationLimit(let key, let machineIds):
            VStack(alignment: .leading, spacing: 12) {
                Text("This key is already active on 2 Macs")
                    .font(.system(size: 15, weight: .semibold))
                Text("Deactivate one of them to use the key on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ForEach(machineIds, id: \.self) { machine in
                    HStack {
                        Text(machine)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Deactivate") {
                            Task { await flow.deactivateMachine(key: key, machineId: machine) }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { flow.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(20)
            .frame(width: 420)
        case .failed(let message, let retryKey):
            VStack(spacing: 14) {
                Text(message)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { flow.cancel() }
                        .keyboardShortcut(.cancelAction)
                    Button("Back to plans") { flow.backToPlans() }
                    if let retryKey {
                        Button("Retry") { Task { await flow.activate(key: retryKey) } }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.teal)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(24)
            .frame(width: 400)
        }
    }
}
