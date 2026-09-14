import SwiftUI
import DebrisCore

/// The clean sheet over Results: Review → Cleaning → Done in one presentation.
struct CleanSheet: View {
    @ObservedObject var flow: CleanFlow

    var body: some View {
        Group {
            switch flow.stage {
            case .review: ReviewView(flow: flow)
            case .cleaning: CleaningView(flow: flow)
            case .done: DoneView(flow: flow)
            }
        }
        .frame(width: 700, height: 540)
        .interactiveDismissDisabled(flow.stage == .cleaning)
    }
}

/// Screen 6: Review & Confirm — the only gate to deletion (S2). Esc or Back
/// closes it and nothing changes; no timers, nothing pre-confirmed.
struct ReviewView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var flow: CleanFlow
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<Category> = []

    var body: some View {
        VStack(spacing: 0) {
            Text("Review")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 14)
            header
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 12) {
                    if !flow.plan.notices.isEmpty { noticesCard }
                    if !flow.visibleConflicts.isEmpty { conflictsCard }
                    categoriesCard
                }
                .padding(.horizontal, 24)
            }
            footer
                .padding(16)
        }
        .alert(
            "Delete \(Format.count(flow.effectiveItems.count)) items permanently?",
            isPresented: $flow.confirmingPermanent
        ) {
            Button("Delete \(Format.count(flow.effectiveItems.count)) items permanently",
                   role: .destructive) { flow.confirmPermanent() }
            Button("Cancel", role: .cancel) { flow.cancelPermanent() }
        } message: {
            Text("This cannot be undone. Items skip the Trash and are removed immediately.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Format.bytes(flow.effectiveBytes)) will be freed")
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                Text("\(Format.count(flow.effectiveItems.count)) items · nothing moves until you click \(flow.disposal == .trash ? "Clean" : "Delete")")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Menu {
                Button("Move to Trash") { flow.requestDisposal(.trash) }
                Button("Delete permanently") { flow.requestDisposal(.permanent) }
            } label: {
                Label(flow.disposal == .trash ? "Move to Trash" : "Delete permanently",
                      systemImage: "trash")
            }
            .fixedSize()
        }
    }

    // MARK: - Consequence notices

    private var noticesCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(flow.plan.notices.enumerated()), id: \.element.ruleId) { index, notice in
                HStack(spacing: 10) {
                    Text("Heads-up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(.orange.opacity(0.16), in: Capsule())
                    Text(noticeText(notice))
                        .font(.system(size: 12))
                        .lineLimit(2)
                    Spacer()
                    Button("Remove from list") { flow.removeRule(notice.ruleId) }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if index < flow.plan.notices.count - 1 { Divider() }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
    }

    private func noticeText(_ notice: ConsequenceNotice) -> String {
        if let app = notice.ownerAppName { return "\(app) — \(notice.consequence)" }
        return notice.consequence
    }

    // MARK: - Running apps

    private var conflictsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(flow.visibleConflicts.enumerated()), id: \.element.bundleId) { index, conflict in
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("\(conflict.appName) is running · \(Format.count(conflict.itemCount)) \(conflict.itemCount == 1 ? "item" : "items")")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                    Spacer()
                    if flow.quittingBundleIds.contains(conflict.bundleId) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Quit \(conflict.appName) and continue") {
                            flow.quitAndContinue(conflict)
                        }
                        .controlSize(.small)
                        Button("Skip \(conflict.appName) items") {
                            flow.skipApp(conflict.bundleId)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if index < flow.visibleConflicts.count - 1 { Divider() }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
    }

    // MARK: - Category lists

    private var categoriesCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(flow.groups.enumerated()), id: \.element.id) { index, group in
                categoryRow(group)
                if expanded.contains(group.category) {
                    itemList(group)
                }
                if index < flow.groups.count - 1 { Divider() }
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
    }

    private func categoryRow(_ group: CleanFlow.CategoryGroup) -> some View {
        Button {
            expanded.formSymmetricDifference([group.category])
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded.contains(group.category) ? 90 : 0))
                Text(group.category.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text("\(Format.count(group.items.count)) items")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                ByteText(bytes: group.bytes)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func itemList(_ group: CleanFlow.CategoryGroup) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(group.items, id: \.originalPath) { item in
                HStack(spacing: 8) {
                    if item.requiresPermanent {
                        ItemCheckbox(
                            checked: !flow.uncheckedNoTrashPaths.contains(item.originalPath)
                        ) { flow.toggleNoTrashItem(item.originalPath) }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        PathText(url: URL(fileURLWithPath: item.originalPath))
                        if group.category == .duplicates,
                           let note = flow.duplicateNote(forPath: item.originalPath) {
                            Text(note)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        if item.requiresPermanent {
                            Text("No Trash on this volume · will be deleted permanently")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    ByteText(bytes: item.allocatedSize, weight: .regular)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 34)
                .padding(.trailing, 14)
                .padding(.vertical, 4)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Back") { dismiss() }
                .keyboardShortcut(.cancelAction) // Esc closes, nothing changes
            Button("Export list") { flow.exportList() }
                .buttonStyle(.link)
            Spacer()
            Text(flow.disposal == .trash
                 ? "Undo available from History"
                 : "No undo for permanent delete")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if flow.disposal == .trash {
                AmountButton(verb: "Clean", bytes: flow.effectiveBytes) {
                    flow.startClean()
                }
                .disabled(flow.effectiveItems.isEmpty)
            } else {
                AmountButton(verb: "Delete", bytes: flow.effectiveBytes,
                             suffix: "permanently", destructive: true) {
                    flow.startClean()
                }
                .disabled(flow.effectiveItems.isEmpty)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
    }
}
