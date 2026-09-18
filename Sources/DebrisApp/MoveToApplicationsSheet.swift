import SwiftUI

/// Offered before any Full Disk Access request, on every launch from outside
/// an Applications folder (macOS ties the permission to the app's location).
struct MoveToApplicationsSheet: View {
    @EnvironmentObject var model: AppModel
    let destination: URL
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move Data Debris to Applications?")
                .font(.system(size: 17, weight: .semibold))
            Text("macOS ties Full Disk Access to where the app lives. Moving it now means the permission you grant stays with it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Not now") { model.moveOffer = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Move to Applications") {
                    do {
                        try MoveToApplications.moveAndRelaunch(to: destination)
                    } catch {
                        failure = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// Shown once by the freshly moved copy when the grant did not follow it.
struct MovedNoticeSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Full Disk Access needs granting again")
                .font(.system(size: 17, weight: .semibold))
            Text("macOS ties the permission to the app's location, and Data Debris has just moved to Applications.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Later") { model.movedNotice = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Open System Settings") {
                    FullDiskAccess.openSettings()
                    model.movedNotice = nil
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
