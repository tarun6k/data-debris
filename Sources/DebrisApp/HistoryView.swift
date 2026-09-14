import AppKit
import SwiftUI
import DebrisCore
import UniformTypeIdentifiers

/// Screen 10: one row per run, expandable to its items, restore per run or
/// per item while copies remain in the Trash (S5). Paths and sizes only —
/// the journal never stores file contents.
struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var rows: [RunRow] = []
    @State private var expanded: Set<Int64> = []

    struct RunRow: Identifiable {
        let run: RunRecord
        let items: [ItemRecord]
        let availability: UndoAvailability
        var id: Int64 { run.id }
        var restorableCount: Int { items.filter { $0.status == .done }.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 16)
            if rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            runRow(row)
                            if expanded.contains(row.id) { itemList(row) }
                            if index < rows.count - 1 { Divider() }
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
                }
            }
            Spacer(minLength: 10)
            Text("History is kept for \(AppModel.historyRetentionDays) days · change in Settings · paths and sizes only, never file contents")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .navigationTitle("History")
        .onAppear { reload() }
    }

    // ponytail: loads every run's items up front; page by run if the journal
    // ever grows past a few hundred runs.
    private func reload() {
        rows = ((try? model.history.runs()) ?? []).map { run in
            RunRow(
                run: run,
                items: (try? model.history.items(runId: run.id)) ?? [],
                availability: (try? model.history.undoAvailability(runId: run.id))
                    ?? .unavailable(.nothingMoved))
        }
    }

    // MARK: - Header

    private var thirtyDayTotal: Int64 {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        return rows.filter { $0.run.startedAt > cutoff }
            .reduce(0) { $0 + $1.run.movedBytes }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("History")
                    .font(.system(size: 34, weight: .bold))
                // S10: moved to Trash is not "freed".
                Text("Last 30 days: \(Format.bytes(thirtyDayTotal)) moved to Trash")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Export log") { exportCSV() }
                .disabled(rows.isEmpty)
        }
    }

    // MARK: - Run rows

    private func runRow(_ row: RunRow) -> some View {
        HStack(spacing: 12) {
            Button {
                expanded.formSymmetricDifference([row.id])
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded.contains(row.id) ? 90 : 0))
                    Text(row.run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                    Text(modeName(row.run.mode))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("\(Format.count(row.items.count)) \(row.items.count == 1 ? "item" : "items")")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    statusPill(row)
                    Spacer()
                    ByteText(bytes: row.run.movedBytes)
                        .font(.system(size: 13))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if case .unavailable = row.availability {
                Text(DoneView.undoDisabledReason(row.availability).map { "No undo: \($0)" } ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                AmountButton(verb: "Restore", count: row.restorableCount) {
                    restoreRun(row.run.id)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func modeName(_ mode: RunMode) -> String {
        switch mode {
        case .manual: return "Manual"
        case .auto: return "Auto"
        case .smart: return "Smart"
        }
    }

    private func statusPill(_ row: RunRow) -> some View {
        let (label, color) = pillContent(row)
        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(color.opacity(0.16), in: Capsule())
    }

    private func pillContent(_ row: RunRow) -> (String, Color) {
        switch row.run.status {
        case .restored: return ("Restored", .green)
        case .partiallyRestored: return ("Partially restored", .orange)
        default: break
        }
        if row.run.disposal == .permanent { return ("Deleted permanently", .red) }
        switch row.availability {
        case .available, .partiallyAvailable: return ("In Trash", Theme.teal)
        case .unavailable(.trashEmptied): return ("Trash emptied", .gray)
        case .unavailable(.alreadyRestored): return ("Restored", .green)
        case .unavailable: return ("Nothing moved", .gray)
        }
    }

    // MARK: - Items

    private func itemList(_ row: RunRow) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(row.items, id: \.id) { item in
                HStack(spacing: 8) {
                    PathText(url: URL(fileURLWithPath: item.originalPath))
                    Spacer()
                    Text(itemStatusText(item))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ByteText(bytes: item.allocatedSize, weight: .regular)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                    if item.status == .done {
                        Button("Restore") { restoreItems([item.id]) }
                            .controlSize(.small)
                    }
                }
                .padding(.leading, 42)
                .padding(.trailing, 16)
                .padding(.vertical, 3)
            }
        }
        .padding(.bottom, 8)
    }

    private func itemStatusText(_ item: ItemRecord) -> String {
        switch item.status {
        case .done: return "In Trash"
        case .restored: return "Restored"
        case .skipped: return DoneView.reasonText(item.skipReason)
        case .irreversible: return "Deleted permanently"
        case .pending: return "Pending"
        }
    }

    // MARK: - Actions

    private func restoreRun(_ runId: Int64) {
        let executor = Executor(history: model.history)
        Task {
            _ = try? await executor.restore(runId: runId)
            model.cleanDidFinish()
            reload()
        }
    }

    private func restoreItems(_ itemIds: [Int64]) {
        let executor = Executor(history: model.history)
        Task {
            _ = try? await executor.restore(itemIds: itemIds)
            model.cleanDidFinish()
            reload()
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Data Debris history.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = ["run_id,started,mode,disposal,run_status,path,allocated_bytes,item_status,skip_reason"]
        let iso = ISO8601DateFormatter()
        for row in rows {
            for item in row.items {
                lines.append([
                    String(row.run.id),
                    iso.string(from: row.run.startedAt),
                    row.run.mode.rawValue,
                    row.run.disposal.rawValue,
                    row.run.status.rawValue,
                    item.originalPath,
                    String(item.allocatedSize),
                    item.status.rawValue,
                    item.skipReason.map { DoneView.reasonText($0) } ?? "",
                ].map(csvField).joined(separator: ","))
            }
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No cleans yet")
                .font(.system(size: 18, weight: .semibold))
            Text("Runs appear here the moment they start — the journal is written before anything moves.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
