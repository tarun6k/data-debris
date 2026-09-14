import DebrisCore
import QuickLookThumbnailing
import SwiftUI

/// Screen 5: groups of identical files; the user picks which copy survives.
/// The keeper carries the badge and has no Finding, so it can never be
/// selected for removal (S7); everything selected here still goes through
/// Review (S2).
struct DuplicatesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        DuplicatesContent(session: model.session)
    }
}

private struct DuplicatesContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: ScanSession
    @State private var selectedGroupId: String?
    @State private var showKeeperToast = false

    var body: some View {
        Group {
            if model.isScanning {
                hashingState
            } else if model.duplicateGroups.isEmpty {
                if model.duplicateStatus == "done" {
                    noDuplicatesState
                } else {
                    skippedState
                }
            } else {
                mainLayout
            }
        }
        .navigationTitle("Duplicates")
    }

    private var currentGroup: DuplicateGroup? {
        model.duplicateGroups.first { $0.hash == selectedGroupId } ?? model.duplicateGroups.first
    }

    private var currentIndex: Int {
        currentGroup.flatMap { group in
            model.duplicateGroups.firstIndex { $0.hash == group.hash }
        } ?? 0
    }

    // MARK: - Main layout

    private var mainLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 16)
            HStack(alignment: .top, spacing: 16) {
                groupList
                    .frame(width: 260)
                if let group = currentGroup {
                    groupDetail(group)
                }
            }
            footer
                .padding(.top, 12)
        }
        .padding(24)
        .background(keyButtons)
        .overlay(alignment: .bottom) { keeperToast }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Format.bytes(model.duplicateReclaimableBytes)) reclaimable")
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                Text(subtitleText)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Text("Apply rule to all:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ruleButton("Keep oldest", .oldest)
                ruleButton("Keep newest", .newest)
                keepInMenu
                ruleButton("Keep shortest path", .shortestPath)
            }
        }
    }

    private var subtitleText: String {
        let groups = model.duplicateGroups.count
        var text = "\(Format.count(groups)) duplicate \(groups == 1 ? "group" : "groups")"
        if model.clonePairsIgnored > 0 {
            text += " · \(Format.count(model.clonePairsIgnored)) clone \(model.clonePairsIgnored == 1 ? "pair" : "pairs") ignored (they already share storage)"
        }
        return text
    }

    private func ruleButton(_ title: String, _ rule: KeeperRule) -> some View {
        let affected = model.groupsAffected(by: rule)
        return Button(title) { applyRule(rule) }
            .disabled(affected == 0)
            .help("Affects \(Format.count(affected)) \(affected == 1 ? "group" : "groups")")
    }

    private var keepInMenu: some View {
        Menu("Keep in…") {
            ForEach(["Pictures", "Documents", "Music", "Movies", "Desktop", "Downloads"], id: \.self) { folder in
                let rule = KeeperRule.inFolder(model.home.appendingPathComponent(folder))
                let affected = model.groupsAffected(by: rule)
                Button("Keep in \(folder) — affects \(Format.count(affected)) \(affected == 1 ? "group" : "groups")") {
                    applyRule(rule)
                }
                .disabled(affected == 0)
            }
        }
        .fixedSize()
    }

    private func applyRule(_ rule: KeeperRule) {
        model.applyKeeperRule(rule)
        showKeeperToast = true
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            showKeeperToast = false
        }
    }

    @ViewBuilder
    private var keeperToast: some View {
        if showKeeperToast, let batch = model.lastKeeperBatch {
            HStack(spacing: 12) {
                Text("Keeper changed in \(Format.count(batch.previousKeepers.count)) \(batch.previousKeepers.count == 1 ? "group" : "groups")")
                    .font(.system(size: 12))
                Button("Undo") {
                    model.undoKeeperBatch()
                    showKeeperToast = false
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 1))
            .padding(.bottom, 70)
            .transition(.opacity)
        }
    }

    // MARK: - Group list

    private var groupList: some View {
        List(model.duplicateGroups, selection: $selectedGroupId) { group in
            VStack(alignment: .leading, spacing: 2) {
                Text(group.keeper.url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(Format.count(group.copies.count)) copies · \(Format.bytes(group.size))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .tag(group.hash)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
    }

    // MARK: - Group detail

    private func groupDetail(_ group: DuplicateGroup) -> some View {
        let ordered = [group.keeper] + group.others.sorted { $0.url.path < $1.url.path }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ForEach(ordered.prefix(4)) { copy in
                    ThumbnailView(url: copy.url)
                }
            }
            .frame(height: 160)
            VStack(spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, copy in
                    copyRow(copy, in: group)
                    if index < ordered.count - 1 { Divider() }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 1))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func copyRow(_ copy: DuplicateCopy, in group: DuplicateGroup) -> some View {
        let isKeeper = copy.findingId == group.keeperId
        let checked = model.selectedIds.contains(copy.findingId)
        return HStack(spacing: 12) {
            if isKeeper {
                Text("Keep")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .frame(height: 20)
                    .background(.green.opacity(0.15), in: Capsule())
            } else {
                ItemCheckbox(checked: checked) {
                    model.toggleDuplicate(copy, in: group)
                }
                .disabled(!checked && !model.canSelectDuplicate(copy, in: group))
                .help(!checked && !model.canSelectDuplicate(copy, in: group)
                      ? "One copy is always kept" : "")
            }
            VStack(alignment: .leading, spacing: 2) {
                PathText(url: copy.url)
                Text(note(for: copy, in: group))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ByteText(bytes: copy.size)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func note(for copy: DuplicateCopy, in group: DuplicateGroup) -> String {
        if copy.findingId == group.keeperId {
            var parts: [String] = []
            let mtimes = group.copies.map(\.mtime)
            if copy.mtime == mtimes.min() {
                parts.append("Oldest")
            } else if copy.mtime == mtimes.max() {
                parts.append("Newest")
            }
            parts.append("in \(locationName(copy.location))")
            return parts.joined(separator: " · ")
        }
        if Calendar.current.isDate(copy.mtime, inSameDayAs: group.keeper.mtime) {
            return "Modified same day"
        }
        return "Copy"
    }

    private func locationName(_ location: HomeLocation) -> String {
        switch location {
        case .pictures: return "Pictures"
        case .documents: return "Documents"
        case .music: return "Music"
        case .movies: return "Movies"
        case .desktop: return "Desktop"
        case .downloads: return "Downloads"
        case .otherHome: return "Home"
        case .external: return "External"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text("One copy is always kept — the last checkbox stays disabled.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text("Group \(Format.count(currentIndex + 1)) of \(Format.count(model.duplicateGroups.count))")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Skip") { advance() }
            Button("Next") { acceptAndAdvance() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
        }
    }

    /// Next ticks every removable copy of the group (the keeper stays by
    /// construction) and moves on; Skip moves on leaving the group untouched.
    private func acceptAndAdvance() {
        if let group = currentGroup {
            model.setSelected(group.others.map(\.findingId), true)
        }
        advance()
    }

    private func advance() {
        let groups = model.duplicateGroups
        guard !groups.isEmpty else { return }
        selectedGroupId = groups[min(currentIndex + 1, groups.count - 1)].hash
    }

    private func retreat() {
        let groups = model.duplicateGroups
        guard !groups.isEmpty else { return }
        selectedGroupId = groups[max(currentIndex - 1, 0)].hash
    }

    /// ←/→ between groups, Space Quick Look, ⌘⏎ Reveal in Finder.
    private var keyButtons: some View {
        Group {
            Button("") { retreat() }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { advance() }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") {
                if let group = currentGroup { QuickLook.shared.show(group.copies.map(\.url)) }
            }.keyboardShortcut(.space, modifiers: [])
            Button("") {
                if let group = currentGroup {
                    NSWorkspace.shared.activateFileViewerSelecting(group.copies.map(\.url))
                }
            }.keyboardShortcut(.return, modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: - Empty and progress states

    private var hashingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            if session.dupPhase == .hashing, let progress = session.dupProgress {
                Text("Hashing candidates · \(Format.count(progress.filesHashed)) files · \(Format.bytes(progress.bytesHashed))")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                PathText(url: URL(fileURLWithPath: progress.currentPath))
            } else {
                Text("Duplicates are hashed after the file walk finishes.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noDuplicatesState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.on.square")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No duplicates found")
                .font(.system(size: 17, weight: .semibold))
            Text("External drives are not scanned unless you include them in Settings.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var skippedState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.on.square")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Duplicate scan skipped")
                .font(.system(size: 17, weight: .semibold))
            Text("Hashing was skipped, so this scan has no duplicate results.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Scan for duplicates now") {
                model.startScan()
                model.sidebar = .duplicates // stay here and watch hashing
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.teal)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Quick Look thumbnails

/// QLThumbnailGenerator with an NSCache; misses fall back to the gray
/// placeholder tile from the design.
private enum Thumbnails {
    static let cache = NSCache<NSURL, NSImage>()

    static func load(_ url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 320, height: 240),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return nil }
        cache.setObject(rep.nsImage, forKey: url as NSURL)
        return rep.nsImage
    }
}

private struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "eye")
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: 220, maxHeight: 160)
        .task(id: url) { image = await Thumbnails.load(url) }
    }
}
