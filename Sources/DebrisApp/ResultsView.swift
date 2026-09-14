import SwiftUI
import DebrisCore

/// Screen 3: category rows with tri-state selection. No delete action here —
/// Review (Phase 4B) is the only gate (S2).
struct ResultsView: View {
    @EnvironmentObject var model: AppModel

    private var totalBytes: Int64 { model.rows.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        if model.rows.isEmpty {
            emptyState
        } else {
            results
        }
    }

    // MARK: - Results

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 16)

            if model.scanWasIncomplete {
                banner("Scan stopped early · Unfinished categories may be missing items")
                    .padding(.bottom, 12)
            } else if model.scanIsStale {
                banner("Scanned more than a day ago · Sizes may have changed")
                    .padding(.bottom, 12)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.sortedRows.enumerated()), id: \.element.id) { index, row in
                        categoryRow(row)
                        if index < model.sortedRows.count - 1 { Divider() }
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
            }

            Spacer(minLength: 12)
            footer
        }
        .padding(24)
        .navigationTitle("Results")
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Format.bytes(totalBytes)) reclaimable")
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                HStack(spacing: 4) {
                    if let finished = model.lastScan?.finishedAt {
                        Text("Scanned \(Format.relative(finished)) · \(DiskUsage.volumeName)")
                    } else {
                        Text(DiskUsage.volumeName)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Text("Sort:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Picker("Sort", selection: $model.resultSort) {
                    ForEach(ResultSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func banner(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
            Spacer()
            Button("Rescan") { model.startScan() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func categoryRow(_ row: CategoryRow) -> some View {
        HStack(spacing: 12) {
            TriStateCheckbox(state: row.state) {
                model.toggleCategory(row.category)
            }

            Button {
                model.openCategory = row.category
            } label: {
                HStack(spacing: 10) {
                    Text(row.category.displayName)
                        .font(.system(size: 13, weight: .medium))
                    SafetyPill(level: row.category.defaultLevel)
                    Spacer()
                    ByteText(bytes: row.bytes)
                        .font(.system(size: 13))
                    Text("\(Format.count(row.count)) items")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            (Text("Selected: ").font(.system(size: 13))
                + Text(Format.bytes(model.selectedBytes)).font(.system(size: 13, weight: .bold))
                + Text(" · \(Format.count(model.selectedCount)) items · goes to Trash, undo anytime")
                    .font(.system(size: 13)).foregroundColor(.secondary))
                .monospacedDigit()
            Spacer()
            Button("Deselect all") { model.deselectAll() }
                .disabled(model.selectedCount == 0)
            AmountButton(verb: "Review", bytes: model.selectedBytes, ellipsis: true) {
                // ReviewView is Phase 4B; the gate stays closed until then.
            }
            .disabled(true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.teal)
            Text("Your Mac is already tidy")
                .font(.system(size: 22, weight: .semibold))
            if let disk = model.disk {
                Text("\(Format.bytes(disk.free)) free of \(Format.bytes(disk.total)) · \(DiskUsage.volumeName)")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("Rescan") { model.startScan() }
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Results")
        .onAppear { model.refreshDisk() }
    }
}
