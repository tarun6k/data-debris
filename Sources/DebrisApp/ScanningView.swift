import SwiftUI
import DebrisCore

/// Screen 2: the running byte total is the headline; categories tick off
/// below with live sizes.
struct ScanningView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScanningContent(session: model.session)
    }
}

private struct ScanningContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ScanSession
    @State private var showSkipDuplicates = false

    private static let order: [Category] = [.appCaches, .logs, .developer, .duplicates, .largeOld, .trash]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(Format.bytes(session.bytesFound)) found so far")
                        .font(.system(size: 34, weight: .bold))
                        .monospacedDigit()
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Scanning \(DiskUsage.volumeName) · \(elapsedText)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Stop & show results") { model.stopScan() }
            }
            .padding(.bottom, 20)

            Group {
                // Hashing time depends on duplicate bytes, unknowable up
                // front — indeterminate is the honest bar (S10 in spirit).
                if let fraction = model.scanProgressFraction, session.dupPhase != .hashing {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .tint(Theme.teal)
            .padding(.bottom, 20)

            VStack(spacing: 0) {
                ForEach(Array(Self.order.enumerated()), id: \.element) { index, category in
                    categoryRow(category)
                    if index < Self.order.count - 1 { Divider() }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
            .padding(.bottom, 10)

            // ponytail: one pass feeds every analyzer, so the current path is
            // global, not per-category as in the design PNG.
            PathText(url: URL(fileURLWithPath: session.currentPath.isEmpty ? "/" : session.currentPath))
                .padding(.bottom, 10)

            if showSkipDuplicates, session.dupPhase == .queued || session.dupPhase == .hashing {
                HStack(spacing: 4) {
                    Text("Duplicate hashing runs last and is throttled on battery.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Skip duplicates") { session.skipDuplicates() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
            }
            Spacer()
        }
        .padding(24)
        .navigationTitle("Scanning…")
        .task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            showSkipDuplicates = true
        }
    }

    private var elapsedText: String {
        let seconds = Int(Date().timeIntervalSince(model.scanStartedAt ?? Date()))
        if seconds < 60 { return "\(seconds) s elapsed" }
        return "\(seconds / 60) min elapsed"
    }

    @ViewBuilder
    private func categoryRow(_ category: Category) -> some View {
        let row = model.rows.first { $0.category == category }
        let hashing = category == .duplicates && session.dupPhase == .hashing
        let active = (row?.count ?? 0) > 0 || hashing

        HStack(spacing: 12) {
            if active {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 18, height: 18)
            }

            Text(category.displayName)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)

            Spacer()

            if hashing, let progress = session.dupProgress {
                Text("hashing · \(Format.count(progress.filesHashed)) files · \(Format.bytes(progress.bytesHashed))…")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if category == .duplicates && session.dupPhase == .skipped {
                Text("skipped")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            } else if let row, row.count > 0 {
                Text("\(Format.bytes(row.bytes)) · \(Format.count(row.count)) items…")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}
