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
            // Space = Quick Look, ⌘⏎ = Reveal (macOS 13 has no onKeyPress).
            Group {
                Button("") { quickLook() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { revealInFinder() }
                    .keyboardShortcut(.return, modifiers: .command)
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
                $0.url.lastPathComponent.localizedCaseInsensitiveContains(filter)
                    || $0.url.path.localizedCaseInsensitiveContains(filter)
            }
        }
        switch sort {
        case .size: items.sort { $0.allocatedSize > $1.allocatedSize }
        case .name: items.sort { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending }
        case .date: items.sort { $0.mtime > $1.mtime }
        }
        return items
    }

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
            return grouped(items) { Self.appName(for: $0.ownerBundleId) }
        case .folder:
            return grouped(items) { Format.tildePath($0.url.deletingLastPathComponent()) }
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
        let ids = group.items.filter(\.isReclaimable).map(\.id)
        let selected = ids.filter { model.selectedIds.contains($0) }.count
        let state: CategoryState = selected == 0 ? .none : (selected == ids.count ? .all : .some)
        return HStack(spacing: 10) {
            TriStateCheckbox(state: state) {
                model.setSelected(ids, state != .all)
            }
            Text(group.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Text("\(Format.count(group.items.count)) items")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
                    Text(finding.url.lastPathComponent)
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
                PathText(url: finding.url)
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

    /// A checkbox click on a multi-selected row checks/unchecks the whole
    /// selection.
    private func toggleRow(_ finding: Finding) {
        let newValue = !model.selectedIds.contains(finding.id)
        if listSelection.contains(finding.id), listSelection.count > 1 {
            model.setSelected(Array(listSelection), newValue)
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
        let urls = lookupSelection().map(\.url)
        guard !urls.isEmpty else { return }
        QuickLook.shared.show(urls)
    }

    private func revealInFinder() {
        let urls = lookupSelection().prefix(20).map(\.url)
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
