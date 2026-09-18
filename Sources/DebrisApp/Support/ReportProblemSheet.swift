import SwiftUI

/// Settings > Help and the Help menu. Everything the email will contain is
/// on screen and editable before anything is composed; Send only opens the
/// mail app's compose window.
struct ReportProblemSheet: View {
    @EnvironmentObject var model: AppModel
    let kind: ProblemReport.Kind
    @State private var description = ""
    @State private var draft = ""
    @State private var outcome: ReportMailer.Outcome?
    private let support = AppConfig.current.supportEmail

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title).font(.system(size: 17, weight: .semibold))
            Text(kind.prompt).font(.system(size: 12, weight: .semibold))
            TextEditor(text: $description)
                .font(.system(size: 12))
                .frame(height: 70)
                .border(Color.secondary.opacity(0.3))
                .onChange(of: description) { _ in regenerate() }
            HStack {
                Text("Everything below goes to \(support). Delete any line you would rather keep to yourself.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset preview") { regenerate() }.controlSize(.small)
            }
            TextEditor(text: $draft)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 260)
                .border(Color.secondary.opacity(0.3))
            if let outcome {
                Text(outcomeText(outcome))
                    .font(.system(size: 12))
                    .foregroundStyle(outcome == .composeWindow || outcome == .mailto ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.problemReport = nil }.keyboardShortcut(.cancelAction)
                Button("Open in Mail") {
                    outcome = ReportMailer.compose(to: support, subject: kind.subject, body: draft)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear { regenerate() }
    }

    private func regenerate() {
        var report = model.problemReport(kind: kind)
        report.description = description
        draft = report.text()
    }

    private func outcomeText(_ outcome: ReportMailer.Outcome) -> String {
        switch outcome {
        case .composeWindow: return "A compose window is open in your mail app with the report attached. Nothing is sent until you press Send there."
        case .mailto: return "Your mail app opened with the report in the body. Nothing is sent until you press Send there."
        case .failed(let reason): return reason
        }
    }
}
