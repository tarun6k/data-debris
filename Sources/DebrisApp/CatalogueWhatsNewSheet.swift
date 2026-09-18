import DebrisCore
import SwiftUI

/// Shown once after an update changed the bundled catalogue. Informational:
/// the update never ticks a rule for Auto Clean (S9) or touches exclusions.
struct CatalogueWhatsNewSheet: View {
    @EnvironmentObject var model: AppModel
    let changes: CatalogueChanges

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What's new in the catalogue")
                .font(.system(size: 17, weight: .semibold))
            Text("Catalogue version \(changes.toVersion), was \(changes.fromVersion).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !changes.added.isEmpty {
                        Text("Now recognised").font(.system(size: 13, weight: .semibold))
                        ForEach(changes.added) { rule in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(rule.id).font(.system(size: 12, design: .monospaced))
                                    Text(rule.category.displayName)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Text(rule.reason)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if !changes.removedIds.isEmpty {
                        Text("No longer recognised").font(.system(size: 13, weight: .semibold))
                        ForEach(changes.removedIds, id: \.self) { id in
                            Text(id).font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            Text("New rules stay off for Auto Clean until you turn them on. Your selections, exclusions and privacy choice are unchanged.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK") { model.catalogueChanges = nil }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.teal)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
