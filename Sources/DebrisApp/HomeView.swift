import SwiftUI
import DebrisCore

/// Screen 1: how full is my disk, when did I last clean, what can I do now.
struct HomeView: View {
    @EnvironmentObject var model: AppModel

    private var lowSpace: Bool {
        guard let disk = model.disk, disk.total > 0 else { return false }
        return Double(disk.free) / Double(disk.total) < 0.10
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !model.fdaGranted {
                    limitedAccessBanner
                }
                gaugeCard
                actionRow
                autoCleanCard
                if !model.recentRuns.isEmpty {
                    recentRunsCard
                }
            }
            .padding(24)
        }
        .navigationTitle("Data Debris")
        .onAppear { model.refreshDisk() }
    }

    // MARK: - Banner

    private var limitedAccessBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Some caches hidden · Grant access")
                .font(.system(size: 12))
            Spacer()
            Button("Open System Settings") { FullDiskAccess.openSettings() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Gauge

    private var gaugeCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Format.bytes(model.disk?.free ?? 0) + " free")
                        .font(.system(size: 34, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(lowSpace ? Color.orange : Color.primary)
                    Text("of \(Format.bytes(model.disk?.total ?? 0)) · \(DiskUsage.volumeName)")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let run = model.recentRuns.first {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Last clean")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        // S10: moved to Trash is not "freed".
                        Text("\(Format.relative(run.startedAt)) · \(Format.bytes(run.movedBytes)) to Trash")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                    }
                }
            }
            .padding(.bottom, 16)

            segmentedBar
                .padding(.bottom, 12)
            legend
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
    }

    private struct Segment: Identifiable {
        let name: String
        let bytes: Int64
        let color: Color
        var id: String { name }
    }

    private var segments: [Segment] {
        guard let disk = model.disk, disk.hasSegments else { return [] }
        return [
            Segment(name: "System", bytes: disk.system, color: Color(white: 0.45)),
            Segment(name: "Apps", bytes: disk.apps, color: Theme.teal.opacity(0.95)),
            Segment(name: "Documents", bytes: disk.documents, color: Theme.teal.opacity(0.7)),
            Segment(name: "Other", bytes: disk.other, color: Theme.teal.opacity(0.4)),
        ]
    }

    private var segmentedBar: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(segment.color)
                        .frame(width: max(2, geo.size.width * fraction(segment.bytes)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func fraction(_ bytes: Int64) -> CGFloat {
        guard let total = model.disk?.total, total > 0 else { return 0 }
        return CGFloat(bytes) / CGFloat(total)
    }

    @ViewBuilder
    private var legend: some View {
        if segments.isEmpty {
            Text("Measuring usage…")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 16) {
                ForEach(segments) { segment in
                    HStack(spacing: 5) {
                        Circle().fill(segment.color).frame(width: 7, height: 7)
                        Text("\(segment.name) \(Format.bytes(segment.bytes))")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button(model.lastScan == nil ? "Run your first scan" : "Scan now") {
                model.startScan()
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.teal)
            .keyboardShortcut("r") // also in the menu; here so the button shows it

            if lowSpace {
                Text("Recommended")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .background(.orange.opacity(0.16), in: Capsule())
            }

            if model.hasResults && model.safeBytes > 0 {
                Button("Smart Clean · \(Format.bytes(model.safeBytes)) safe items") {
                    model.smartClean()
                }
            }

            if model.hasResults && !model.scanIsStale {
                Button("View last results") { model.sidebar = .results }
                    .buttonStyle(.link)
            }
            Spacer()
        }
    }

    // MARK: - Cards

    private var autoCleanCard: some View {
        card(icon: "clock") {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Auto Clean")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Off")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(.secondary.opacity(0.16), in: Capsule())
                }
                Text("Not scheduled")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } trailing: {
            EmptyView() // Edit link arrives with Auto Clean (Phase 6)
        }
    }

    private var recentRunsCard: some View {
        card(icon: "clock.arrow.circlepath") {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recent runs")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.recentRuns.map(Self.runLine).joined(separator: "  ·  "))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } trailing: {
            Button("History") { model.sidebar = .history }
                .buttonStyle(.link)
        }
    }

    private static func runLine(_ run: RunRecord) -> String {
        let day = run.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let mode = run.mode == .auto ? "Auto" : run.mode == .smart ? "Smart" : "Manual"
        return "\(day) · \(mode) · \(Format.bytes(run.movedBytes))"
    }

    private func card(
        icon: String,
        @ViewBuilder content: () -> some View,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            content()
            Spacer()
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
    }
}
