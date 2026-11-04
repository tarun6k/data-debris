import AppKit
import Quartz
import SwiftUI
import DebrisCore

enum DetailGrouping: String, CaseIterable, Identifiable {
    case byApp = "By app", folder = "Folder", none = "None"
    var id: Self { self }
}

enum DetailSort: String, CaseIterable, Identifiable {
    case size = "Size", name = "Name", date = "Date"
    var id: Self { self }
}

/// Screen 4: every item in one category, grouped and filterable. Excluding
/// is the only destructive-ish action here, and it only ever hides.
struct CategoryDetailView: View {
    @EnvironmentObject var model: AppModel
    let category: Category

    @State private var grouping: DetailGrouping = .byApp
    @State private var sort: DetailSort = .size
    @State private var filter = ""
    @State private var listSelection: Set<String> = []
    @State private var running: Set<String> = []
    @State private var showUndoToast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumb
                .padding(.bottom, 12)
            controls
                .padding(.bottom, 12)
            list
            footer
                .padding(.top, 12)
        }
        .padding(24)
        .navigationTitle("\(category.displayName) · \(Format.bytes(totalBytes))")
        .onAppear { running = model.runningBundleIds() }
        .overlay(alignment: .bottom) { undoToast }
        .background {
            // Space = Quick Look, ⌘⏎ = Reveal, ⌘⌫ = toggle tick
            // (macOS 13 has no onKeyPress).
            Group {
                Button("") { quickLook() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { revealInFinder() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("") { toggleFocusedRows() }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Data

    private var visible: [Finding] {
        var items = model.visibleFindings(in: category)
        if !filter.isEmpty {
            items = items.filter {
                Self.name(for: $0).localizedCaseInsensitiveContains(filter)
                    || $0.storedPath.localizedCaseInsensitiveContains(filter)
            }
        }
        switch sort {
        case .size: items.sort { $0.allocatedSize > $1.allocatedSize }
        case .name: items.sort { Self.name(for: $0).localizedCaseInsensitiveCompare(Self.name(for: $1)) == .orderedAscending }
        case .date: items.sort { $0.mtime > $1.mtime }
        }
        return items
    }

    /// Row title: the file name, or "Docker image <id>" for Docker objects.
    private static func name(for finding: Finding) -> String {
        finding.dockerObject?.displayName ?? finding.url.lastPathComponent
    }

    /// Docker objects group under their own heading whatever the grouping:
    /// they have no owner app and no folder.
    private static let dockerGroupName = "Docker"

    private struct ItemGroup: Identifiable {
        let name: String
        let items: [Finding]
        let bytes: Int64
        var id: String { name }
    }

    // ponytail: filter+sort+group recomputed per keystroke; cache behind
    // (filter, sort, grouping) if typing ever lags at 10k rows.
    private var groups: [ItemGroup] {
        let items = visible
        switch grouping {
        case .none:
            return [ItemGroup(name: "", items: items, bytes: items.reduce(0) { $0 + $1.allocatedSize })]
        case .byApp:
            return grouped(items) {
                $0.dockerObject != nil ? Self.dockerGroupName : Self.appName(for: $0.ownerBundleId)
            }
        case .folder:
            return grouped(items) {
                $0.dockerObject != nil ? Self.dockerGroupName : Format.tildePath($0.url.deletingLastPathComponent())
            }
        }
    }

    private func grouped(_ items: [Finding], by key: (Finding) -> String) -> [ItemGroup] {
        Dictionary(grouping: items, by: key)
            .map { ItemGroup(name: $0.key, items: $0.value, bytes: $0.value.reduce(0) { $0 + $1.allocatedSize }) }
            .sorted { $0.bytes > $1.bytes }
    }

    private static var appNameCache: [String: String] = [:]
    private static func appName(for bundleId: String?) -> String {
        guard let bundleId else { return "Other" }
        if let cached = appNameCache[bundleId] { return cached }
        let name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            name = (url.lastPathComponent as NSString).deletingPathExtension
        } else {
            name = bundleId.components(separatedBy: ".").last.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? bundleId
        }
        appNameCache[bundleId] = name
        return name
    }

    private var totalBytes: Int64 {
        model.visibleFindings(in: category).reduce(0) { $0 + $1.allocatedSize }
    }

    private var selectedInCategory: [Finding] {
        model.visibleFindings(in: category).filter { model.selectedIds.contains($0.id) }
    }

    // MARK: - Header

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            Button("Results") { model.openCategory = nil }
                .buttonStyle(.link)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(category.displayName)
                .font(.system(size: 13, weight: .semibold))
            SafetyPill(level: category.defaultLevel)
            Spacer()
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter by name or path", text: $filter)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 1))
            .frame(maxWidth: 300)

            Spacer()

            labelledPicker("Group:", selection: $grouping)
            labelledPicker("Sort:", selection: $sort)
        }
    }

    private func labelledPicker<T: CaseIterable & Identifiable & RawRepresentable & Hashable>(
        _ label: String, selection: Binding<T>
    ) -> some View where T.RawValue == String, T.AllCases: RandomAccessCollection {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Picker(label, selection: selection) {
                ForEach(T.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: - List

    private var list: some View {
        List(selection: $listSelection) {
            ForEach(groups) { group in
                if group.name.isEmpty {
                    ForEach(group.items, id: \.id) { itemRow($0) }
                } else {
                    Section {
                        ForEach(group.items, id: \.id) { itemRow($0) }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
        }
        .listStyle(.inset)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
    }

    private func groupHeader(_ group: ItemGroup) -> some View {
        // Docker objects are confirmed one by one (spec §6): the group tick
        // never sweeps them in.
        let ids = group.items.filter { $0.isReclaimable && $0.dockerObject == nil }.map(\.id)
        let selected = ids.filter { model.selectedIds.contains($0) }.count
        let state: CategoryState = selected == 0 ? .none : (selected == ids.count ? .all : .some)
        let hasDocker = group.items.contains { $0.dockerObject != nil }
        return HStack(spacing: 10) {
            if ids.isEmpty {
                Spacer().frame(width: 16)
            } else {
                TriStateCheckbox(state: state) {
                    model.setSelected(ids, state != .all)
                }
            }
            Text(group.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text("\(Format.count(group.items.count)) items")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if hasDocker {
                Text("tick each item · removed with docker, no undo")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ByteText(bytes: group.bytes)
                .font(.system(size: 13))
        }
        .padding(.vertical, 4)
    }

    private func itemRow(_ finding: Finding) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if finding.isReclaimable {
                ItemCheckbox(checked: model.selectedIds.contains(finding.id)) {
                    toggleRow(finding)
                }
                .padding(.top, 2)
            } else {
                Spacer().frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(Self.name(for: finding))
                        .font(.system(size: 13))
                    if let owner = finding.ownerBundleId, running.contains(owner) {
                        Text("In use · \(Self.appName(for: owner)) running")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .frame(height: 18)
                            .background(.orange.opacity(0.16), in: Capsule())
                    }
                }
                if finding.dockerObject != nil {
                    Text("Removed with docker · cannot be undone")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else {
                    PathText(url: finding.url)
                }
                Text("\(finding.reason) · \(finding.consequence)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            ByteText(bytes: finding.allocatedSize)
                .font(.system(size: 13))
            Text(Format.modified(finding.mtime))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .tag(finding.id)
        .contextMenu {
            Button("Exclude item") { neverTouch([finding]) }
            if let object = finding.dockerObject {
                Button("Copy ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(object.id, forType: .string)
                }
            } else {
                Button("Exclude folder") {
                    model.excludeFolder(finding.url.deletingLastPathComponent().path)
                    showToast()
                }
                Button("Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(finding.url.path, forType: .string)
                }
                Divider()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([finding.url])
                }
            }
        }
    }

    /// ⌘⌫: flip the tick on the highlighted rows, off the first one's state.
    /// Docker objects only flip one at a time (spec §6).
    private func toggleFocusedRows() {
        let rows = visible.filter { listSelection.contains($0.id) && $0.isReclaimable }
        guard let first = rows.first else { return }
        let ids = rows.count == 1 ? rows.map(\.id) : rows.filter { $0.dockerObject == nil }.map(\.id)
        model.setSelected(ids, !model.selectedIds.contains(first.id))
    }

    /// A checkbox click on a multi-selected row checks/unchecks the whole
    /// selection, except Docker objects, which are confirmed one by one.
    private func toggleRow(_ finding: Finding) {
        let newValue = !model.selectedIds.contains(finding.id)
        if listSelection.contains(finding.id), listSelection.count > 1 {
            let dockerIds = Set(visible.filter { $0.dockerObject != nil }.map(\.id))
            var ids = listSelection.subtracting(dockerIds)
            if finding.dockerObject != nil { ids = [finding.id] }
            model.setSelected(Array(ids), newValue)
        } else {
            model.setSelected([finding.id], newValue)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        let selected = selectedInCategory
        let selectedBytes = selected.reduce(0) { $0 + $1.allocatedSize }
        let total = model.visibleFindings(in: category)
        return HStack(spacing: 12) {
            (Text("Selected ").font(.system(size: 13))
                + Text(Format.bytes(selectedBytes)).font(.system(size: 13, weight: .bold))
                + Text(" of \(Format.bytes(totalBytes)) · \(Format.count(selected.count)) of \(Format.count(total.count)) items")
                    .font(.system(size: 13)).foregroundColor(.secondary))
                .monospacedDigit()
            Spacer()
            Button("Never touch selected") { neverTouch(selected) }
                .disabled(selected.isEmpty)
            Button("Reveal in Finder") { revealInFinder() }
                .disabled(listSelection.isEmpty && selected.isEmpty)
            Button("Back to Results") { model.openCategory = nil }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 1))
    }

    // MARK: - Actions

    private func neverTouch(_ items: [Finding]) {
        model.neverTouch(items)
        listSelection.subtract(items.map(\.id))
        showToast()
    }

    private func showToast() {
        showUndoToast = true
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            showUndoToast = false
        }
    }

    @ViewBuilder
    private var undoToast: some View {
        if showUndoToast, let batch = model.lastExclusionBatch {
            HStack(spacing: 12) {
                Text("Excluded \(Format.count(batch.entries.count)) \(batch.entries.count == 1 ? "item" : "items") · won't be shown again")
                    .font(.system(size: 12))
                Button("Undo") {
                    model.undoNeverTouch()
                    showUndoToast = false
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

    private func quickLook() {
        let urls = lookupSelection().map(\.url).filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        QuickLook.shared.show(urls)
    }

    private func revealInFinder() {
        let urls = lookupSelection().map(\.url).filter(\.isFileURL).prefix(20)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
    }

    /// The list's multi-selection, falling back to checked items.
    private func lookupSelection() -> [Finding] {
        let items = model.visibleFindings(in: category)
        let picked = items.filter { listSelection.contains($0.id) }
        return picked.isEmpty ? selectedInCategory : picked
    }
}

// MARK: - Quick Look

/// QLPreviewPanel needs an object that outlives the keypress.
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}
