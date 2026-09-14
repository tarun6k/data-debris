import SwiftUI
import DebrisCore

/// Screen 8: replaces Cleaning when the run ends. Honest numbers (S10):
/// "freed" is the measured free-space delta, "moved to Trash" is not "freed".
struct DoneView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var flow: CleanFlow
    @Environment(\.dismiss) private var dismiss
    @State private var showSkipped = false
    @State private var confirmEmptyTrash = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Circle()
                .fill(Color.green.opacity(0.15))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.green)
                }
                .padding(.bottom, 18)

            Text("\(Format.bytes(flow.result?.freedBytes ?? 0)) freed")
                .font(.system(size: 34, weight: .bold))
                .monospacedDigit()
                .padding(.bottom, 6)
            Text(subline)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            if let error = flow.runError {
                Text("The run stopped early: \(error)")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.top, 10)
            }

            if !flow.skippedItems.isEmpty {
                skippedCard
                    .padding(.top, 18)
            }

            if let result = flow.result,
               Self.showsReclaimNote(freed: result.freedBytes, moved: result.movedBytes,
                                     disposal: flow.disposal) {
                Text("Space is fully reclaimed once Trash is emptied. Items stay restorable until then.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
            }

            Spacer()
            actions
                .padding(.bottom, 8)
            if let reason = Self.undoDisabledReason(flow.undo), flow.restoredCount == nil {
                Text("Undo unavailable: \(reason)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer().frame(height: 20)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .alert("Empty the Trash?", isPresented: $confirmEmptyTrash) {
            Button("Empty Trash", role: .destructive) { flow.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes everything in the Trash, including items other apps put there. It cannot be undone.")
        }
    }

    // MARK: - Testable copy rules

    /// The "fully reclaimed once Trash is emptied" line: only when the run
    /// measurably freed less than it moved, and only for Trash runs.
    static func showsReclaimNote(freed: Int64, moved: Int64, disposal: Disposal) -> Bool {
        disposal == .trash && moved > 0 && freed < moved
    }

    static func undoDisabledReason(_ availability: UndoAvailability) -> String? {
        switch availability {
        case .available, .partiallyAvailable:
            return nil
        case .unavailable(.permanentDelete):
            return "items were deleted permanently"
        case .unavailable(.trashEmptied):
            return "the Trash was emptied"
        case .unavailable(.alreadyRestored):
            return "already restored"
        case .unavailable(.nothingMoved):
            return "nothing was moved"
        }
    }

    // MARK: - Pieces

    private var subline: String {
        let count = Format.count(flow.result?.doneCount ?? 0)
        let free = Format.bytes(flow.freeNow)
        return flow.disposal == .trash
            ? "\(free) free now · \(count) items moved to Trash"
            : "\(free) free now · \(count) items deleted permanently"
    }

    private struct SkipGroup: Identifiable {
        let text: String
        let items: [ItemRecord]
        var id: String { text }
    }

    private var skipGroups: [SkipGroup] {
        Dictionary(grouping: flow.skippedItems) { Self.reasonText($0.skipReason) }
            .map { SkipGroup(text: $0.key, items: $0.value) }
            .sorted { $0.items.count > $1.items.count }
    }

    static func reasonText(_ reason: SkipReason?) -> String {
        switch reason {
        case .inUse(let app): return "In use by \(app) — quit it and clean again"
        case .changed: return "Changed since the scan"
        case .vanished: return "Already gone"
        case .noTrash: return "No Trash on this volume"
        case .cancelled: return "Cancelled before it was reached"
        case .protected: return "Protected location"
        case .trashEmptied: return "Trash was emptied"
        case .moveFailed(let text): return "Could not move: \(text)"
        case nil: return "Skipped"
        }
    }

    private var skippedCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(Format.count(flow.skippedItems.count)) \(flow.skippedItems.count == 1 ? "item" : "items") skipped")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                if let first = skipGroups.first {
                    Text(first.text)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer()
                Button(showSkipped ? "Hide" : "Show") { showSkipped.toggle() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if showSkipped {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(skipGroups) { group in
                            ForEach(group.items, id: \.id) { item in
                                HStack(spacing: 8) {
                                    PathText(url: URL(fileURLWithPath: item.originalPath))
                                    Spacer()
                                    Text(group.text)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 140)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if case .unavailable = flow.undo, flow.restoredCount == nil {
                // Permanent runs and the like: no undo to offer.
            } else {
                Button(flow.restoredCount.map { "Restored \(Format.count($0)) items" }
                       ?? "Undo (restore from Trash)") {
                    flow.undoRun()
                }
                .disabled(flow.restoredCount != nil)
            }

            Button("Empty Trash · \(Format.bytes(flow.trashBytes))") {
                confirmEmptyTrash = true // asks first, never automatic (S3)
            }
            .disabled(flow.trashBytes == 0)

            Button("Back to Home") {
                dismiss()
                model.sidebar = .home
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.teal)
            .keyboardShortcut(.defaultAction)
        }
    }
}
