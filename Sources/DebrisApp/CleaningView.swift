import SwiftUI
import DebrisCore

/// Screen 7: shown in the sheet while the Executor runs. Determinate by
/// bytes; Cancel finishes the current item, moved items stay in the Trash.
struct CleaningView: View {
    @ObservedObject var flow: CleanFlow

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(flow.disposal == .trash ? "Moving to Trash…" : "Deleting…")
                .font(.system(size: 24, weight: .bold))
                .padding(.bottom, 20)

            ProgressView(value: Double(flow.progress?.bytesMoved ?? 0),
                         total: Double(max(1, flow.runTotalBytes)))
                .tint(Theme.teal)
                .frame(maxWidth: 420)
                .padding(.bottom, 10)

            Text("\(Format.count(flow.progress?.itemsDone ?? 0)) of \(Format.count(flow.runTotalItems)) items · \(Format.bytes(flow.progress?.bytesMoved ?? 0))")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)

            PathText(url: URL(fileURLWithPath: flow.progress?.currentPath ?? ""))
                .frame(maxWidth: 420)
                .opacity(flow.progress == nil ? 0 : 1)

            Spacer()

            Button("Cancel") { flow.cancelClean() }
            Text("Finishes the current item · anything already moved stays in the Trash")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
    }
}
