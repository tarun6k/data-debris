import SwiftUI
import DebrisCore

/// Screen 0: three steps — What we clean · How we keep you safe · Grant
/// access. Never blocks on FDA; "Continue with limited access" always works.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var step: Int = {
        #if DEBUG // --step 2 for screenshots
        if let index = CommandLine.arguments.firstIndex(of: "--step"),
           CommandLine.arguments.indices.contains(index + 1) {
            return Int(CommandLine.arguments[index + 1]) ?? 0
        }
        #endif
        return 0
    }()

    private let fdaPoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            switch step {
            case 0: whatWeClean
            case 1: howWeKeepYouSafe
            default: grantAccess
            }
            Spacer()
            dots
                .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Welcome to Data Debris")
        .onReceive(fdaPoll) { _ in
            if step == 2 { model.recheckFDA() }
        }
    }

    // MARK: - Steps

    private var whatWeClean: some View {
        page(
            icon: "magnifyingglass",
            title: "Find what's taking space.",
            subtitle: "App caches, logs, developer leftovers, duplicates, large old files and Trash. Everything found is listed for you; anything unknown stays untouched."
        ) {
            Button("Continue") { step = 1 }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
        }
    }

    private var howWeKeepYouSafe: some View {
        page(
            icon: "arrow.uturn.backward",
            title: "Nothing goes without your say.",
            subtitle: "You review every item before it moves. Removals go to Trash, not oblivion, and can be undone from History."
        ) {
            Button("Continue") { step = 2 }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
        }
    }

    private var grantAccess: some View {
        page(
            icon: "checkmark.shield",
            title: "Reclaim space. Keep control.",
            subtitle: "We show you everything before it goes. Deleted files go to Trash, not oblivion."
        ) {
            // The Move-to-Applications sheet (ContentView) runs before this
            // step, so the grant lands on the app's final location.
            card(
                title: "Full Disk Access",
                body: fdaBody,
                pill: (model.fdaGranted ? "Granted" : "Not granted",
                       model.fdaGranted ? Color.green : Color.orange))
            HStack(spacing: 12) {
                if model.fdaGranted {
                    Button("Start scanning") {
                        model.completeWelcome()
                        model.startScan()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.teal)
                } else {
                    Button("Open System Settings") { FullDiskAccess.openSettings() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.teal)
                    Button("Continue with limited access") { model.completeWelcome() }
                }
            }
        }
    }

    private var fdaBody: Text {
        Text("Lets the app read the parts of ")
            + Text("~/Library").font(.system(size: 12, design: .monospaced))
            + Text(" that macOS protects, such as Safari and Mail caches. Without it those stay hidden; the rest of your home folder is still scanned.")
    }

    // MARK: - Pieces

    private func page(
        icon: String, title: String, subtitle: String,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 22)
                .fill(LinearGradient(
                    colors: [Theme.teal, Theme.teal.opacity(0.75)],
                    startPoint: .top, endPoint: .bottom))
                .frame(width: 96, height: 96)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white)
                }
                .shadow(color: Theme.teal.opacity(0.3), radius: 12, y: 6)
                .padding(.bottom, 36)

            Text(title)
                .font(.system(size: 30, weight: .bold))
                .padding(.bottom, 16)

            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 540)
                .padding(.bottom, 28)

            VStack(spacing: 20) { actions() }
        }
    }

    private func card(title: String, body: Text, pill: (label: String, color: Color)?) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                body
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            if let pill {
                Text(pill.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pill.color)
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .background(pill.color.opacity(0.16), in: Capsule())
            }
        }
        .padding(16)
        .frame(maxWidth: 520)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
        .padding(.bottom, 4)
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(index == step ? Theme.teal : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                    .onTapGesture { step = index }
            }
        }
        .accessibilityLabel("Step \(step + 1) of 3")
    }
}
