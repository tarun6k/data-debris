import AppKit
import Combine
import DebrisCore
import SwiftUI

struct CategoryRow: Identifiable, Equatable {
    let category: Category
    let bytes: Int64
    let count: Int
    let state: CategoryState
    var id: Category { category }
}

enum ResultSort: String, CaseIterable, Identifiable {
    case size = "Size", category = "Category", safety = "Safety"
    var id: Self { self }
}

/// One model owns the stores and navigation; selection changes write through
/// to FindingsStore so they survive relaunch (S2 defaults live in the store).
@MainActor
final class AppModel: ObservableObject {

    let store: FindingsStore
    let history: HistoryStore
    let exclusions: ExclusionStore
    let session = ScanSession()
    private let catalogue: Catalogue

    @Published var sidebar: SidebarItem? = .home
    @Published var openCategory: Category?
    @Published var showWelcome: Bool
    @Published var resultSort: ResultSort = .size
    /// Non-nil while the Review/Cleaning/Done sheet is up — the only gate (S2).
    @Published var cleanFlow: CleanFlow?
    /// Set after a clean: the last scan's numbers no longer match the disk.
    @Published private(set) var cleanedSinceScan = false

    @Published private(set) var rows: [CategoryRow] = []
    @Published private(set) var findings: [Finding] = []
    @Published private(set) var selectedIds: Set<String> = []
    @Published private(set) var selectedBytes: Int64 = 0
    @Published private(set) var selectedCount = 0
    @Published private(set) var lastScan: ScanInfo?
    @Published private(set) var recentRuns: [RunRecord] = []
    @Published private(set) var disk: DiskSnapshot?
    @Published private(set) var fdaGranted = FullDiskAccess.granted
    @Published private(set) var scanStartedAt: Date?

    /// Set by "Never touch selected" so the toast can undo the whole batch.
    struct ExclusionBatch { let entries: [(path: String, isFolder: Bool)]; let findingIds: [String] }
    @Published var lastExclusionBatch: ExclusionBatch?

    @Published private(set) var duplicateGroups: [DuplicateGroup] = []
    @Published private(set) var clonePairsIgnored = 0
    /// "done" | "skipped" | nil (scan predates Phase 5).
    @Published private(set) var duplicateStatus: String?
    /// Set by "Apply rule to all" so the toast can put the keepers back.
    struct KeeperBatch { let previousKeepers: [String: String] } // group hash → keeper id
    @Published var lastKeeperBatch: KeeperBatch?

    let home = FileManager.default.homeDirectoryForCurrentUser

    private var cancellables: Set<AnyCancellable> = []
    private var scanPoll: AnyCancellable?

    private static let welcomeCompletedKey = "welcomeCompleted"
    private static let fdaWasGrantedKey = "fdaWasGranted"

    init(store: FindingsStore, history: HistoryStore, exclusions: ExclusionStore, catalogue: Catalogue) {
        self.store = store
        self.history = history
        self.exclusions = exclusions
        self.catalogue = catalogue

        let defaults = UserDefaults.standard
        // First launch, or FDA revoked after we once saw it granted.
        showWelcome = !defaults.bool(forKey: Self.welcomeCompletedKey)
            || (defaults.bool(forKey: Self.fdaWasGrantedKey) && !FullDiskAccess.granted)
        if FullDiskAccess.granted { defaults.set(true, forKey: Self.fdaWasGrantedKey) }

        session.$isScanning
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] scanning in if !scanning { self?.scanFinished() } }
            .store(in: &cancellables)

        // A headless auto-clean process announces its run; pick up the new
        // History row and disk numbers without a relaunch.
        DistributedNotificationCenter.default()
            .publisher(for: .debrisAutoCleanDidRun)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
                self?.refreshDisk()
            }
            .store(in: &cancellables)

        refresh()
        applyDebugRoute()
        #if DEBUG
        applyDriveIfRequested()
        #endif
    }

    static func live() -> AppModel {
        MoveToApplications.removeOldCopyIfPending()
        do {
            let model = AppModel(
                store: try FindingsStore(),
                history: try HistoryStore(),
                exclusions: try ExclusionStore(),
                catalogue: try Catalogue.bundled())
            _ = try? model.history.recoverInterruptedRuns()
            _ = try? model.history.pruneExpiredRuns(olderThanDays: Self.historyRetentionDays)
            return model
        } catch {
            fatalError("Cannot open the app's data folder: \(error)")
        }
    }

    // MARK: - Derived state

    var isScanning: Bool { session.isScanning }

    var hasResults: Bool { lastScan != nil && !rows.isEmpty }

    var scanIsStale: Bool {
        if cleanedSinceScan { return true }
        guard let finished = lastScan?.finishedAt else { return false }
        return Date().timeIntervalSince(finished) > 24 * 3600
    }

    /// The retention control lives in Settings (later phase); History shows it.
    static var historyRetentionDays: Int {
        let days = UserDefaults.standard.integer(forKey: "historyRetentionDays")
        return [30, 90, 365].contains(days) ? days : 90
    }

    var scanWasIncomplete: Bool {
        lastScan?.status == .cancelled
    }

    /// What Smart Clean would select: safe, reclaimable, not excluded.
    var safeBytes: Int64 {
        findings
            .filter { $0.level == .safe && $0.isReclaimable && !isExcluded($0) }
            .reduce(0) { $0 + $1.allocatedSize }
    }

    var sortedRows: [CategoryRow] {
        switch resultSort {
        case .size: return rows.sorted { $0.bytes > $1.bytes }
        case .category: return rows.sorted { $0.category.displayName < $1.category.displayName }
        case .safety: return rows.sorted {
            ($0.category.defaultLevel.sortRank, $1.bytes) < ($1.category.defaultLevel.sortRank, $0.bytes)
        }
        }
    }

    func isExcluded(_ finding: Finding) -> Bool {
        exclusions.isExcluded(finding.url) || exclusions.excludesOwner(finding.ownerBundleId)
    }

    func visibleFindings(in category: Category) -> [Finding] {
        findings.filter { $0.category == category && !isExcluded($0) }
    }

    func runningBundleIds() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    // MARK: - Refresh

    func refresh() {
        lastScan = try? store.lastScan()
        let totals = (try? store.totals()) ?? [:]
        rows = Category.allCases.compactMap { category in
            guard let (bytes, count) = totals[category], count > 0 else { return nil }
            let state = (try? store.categoryState(category)) ?? CategoryState.none
            return CategoryRow(category: category, bytes: bytes, count: count, state: state)
        }
        if let scanId = lastScan?.id {
            findings = (try? store.findings(in: scanId)) ?? []
            selectedIds = (try? store.selectedFindingIds(in: scanId)) ?? []
            let dup = (try? store.duplicates(in: scanId, home: home))
                ?? (groups: [], clonePairs: 0, status: nil)
            duplicateGroups = dup.groups
            clonePairsIgnored = dup.clonePairs
            duplicateStatus = dup.status
        } else {
            findings = []
            selectedIds = []
            duplicateGroups = []
            clonePairsIgnored = 0
            duplicateStatus = nil
        }
        let selected = (try? store.selectedTotals()) ?? (0, 0)
        selectedBytes = selected.0
        selectedCount = selected.1
        recentRuns = Array(((try? history.runs()) ?? []).prefix(2))
    }

    func refreshDisk() {
        let (free, total) = DiskUsage.freeAndTotal()
        if var cached = disk ?? DiskUsage.cached() {
            cached.free = free
            cached.total = total
            disk = cached
        } else {
            disk = DiskSnapshot(total: total, free: free, system: 0, apps: 0,
                                documents: 0, computedAt: .distantPast)
        }
        Task { disk = await DiskUsage.refresh() }
    }

    func recheckFDA() {
        fdaGranted = FullDiskAccess.granted
        if fdaGranted { UserDefaults.standard.set(true, forKey: Self.fdaWasGrantedKey) }
    }

    func completeWelcome() {
        UserDefaults.standard.set(true, forKey: Self.welcomeCompletedKey)
        recheckFDA()
        showWelcome = false
    }

    // MARK: - Scanning

    func startScan() {
        guard !session.isScanning else { return }
        sidebar = .results
        openCategory = nil
        cleanedSinceScan = false
        scanStartedAt = Date()
        let runner = ScanRunner(
            scope: debugScope ?? ScanScope(),
            catalogue: catalogue,
            store: store,
            exclusions: exclusions)
        session.start(runner)
        // Category rows update live from the store while the scan writes.
        scanPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refreshLiveTotals() }
    }

    func stopScan() {
        session.cancel()
    }

    private func refreshLiveTotals() {
        let totals = (try? store.totals()) ?? [:]
        rows = Category.allCases.compactMap { category in
            guard let (bytes, count) = totals[category] else { return nil }
            return CategoryRow(category: category, bytes: bytes, count: count,
                               state: CategoryState.none)
        }
    }

    /// `--scan-roots a,b,c`: restrict a debug scan to specific folders.
    private var debugScope: ScanScope? {
        #if DEBUG
        guard let index = CommandLine.arguments.firstIndex(of: "--scan-roots"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        let roots = CommandLine.arguments[index + 1]
            .split(separator: ",")
            .map { URL(fileURLWithPath: (String($0) as NSString).expandingTildeInPath) }
        return ScanScope(roots: roots)
        #else
        return nil
        #endif
    }

    private func scanFinished() {
        scanPoll = nil
        scanStartedAt = nil
        #if DEBUG
        if let dup = session.lastResult?.duplicates {
            FileHandle.standardError.write(Data(
                "DUP: groups=\(dup.groups.count) clonePairs=\(dup.clonePairsIgnored) filesHashed=\(dup.filesHashed) bytesHashed=\(dup.bytesHashed) pauseEvents=\(dup.pauseEvents) duration=\(String(format: "%.1f", dup.duration))s\n".utf8))
        }
        #endif
        // Next scan's progress bar is determinate against this count.
        // Partial (denied paths) still walked everything it could; only a
        // cancelled scan under-counts.
        if let result = session.lastResult, result.status != .cancelled {
            UserDefaults.standard.set(result.recordCount, forKey: "lastScanRecordCount")
        }
        refresh()
    }

    /// 0…1 against the previous complete scan's record count; nil = first
    /// scan, show an indeterminate bar.
    var scanProgressFraction: Double? {
        let last = UserDefaults.standard.integer(forKey: "lastScanRecordCount")
        guard last > 0 else { return nil }
        return min(0.97, Double(session.recordCount) / Double(last))
    }

    // MARK: - Selection (writes through to the store, S2)

    func toggleCategory(_ category: Category) {
        let current = (try? store.categoryState(category)) ?? CategoryState.none
        let next: CategoryState = current == .all ? .none : .all
        try? store.setCategory(category, state: next)
        refresh()
    }

    func setSelected(_ findingIds: [String], _ selected: Bool) {
        guard !findingIds.isEmpty else { return }
        try? store.setSelected(findingIds, selected)
        refresh()
    }

    func toggleItem(_ finding: Finding) {
        setSelected([finding.id], !selectedIds.contains(finding.id))
    }

    func deselectAll() {
        for category in Category.allCases {
            try? store.setCategory(category, state: CategoryState.none)
        }
        refresh()
    }

    /// Smart Clean: select every safe finding, deselect the rest, and open
    /// Review directly. Review is still the only gate (S2).
    func smartClean() {
        let safe = findings.filter { $0.level == .safe && $0.isReclaimable && !isExcluded($0) }
        let rest = findings.filter { $0.level != .safe && $0.isReclaimable }
        try? store.setSelected(safe.map(\.id), true)
        try? store.setSelected(rest.map(\.id), false)
        refresh()
        sidebar = .results
        openCategory = nil
        openReview(entry: .smart)
    }

    // MARK: - Duplicates

    var duplicateReclaimableBytes: Int64 {
        duplicateGroups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    /// S7 guard: the keeper is unselectable (it has no Finding, so selecting
    /// it is impossible by construction — this refuses it defensively), and a
    /// selection that would leave no unselected copy in the group is refused.
    func canSelectDuplicate(_ copy: DuplicateCopy, in group: DuplicateGroup) -> Bool {
        guard copy.findingId != group.keeperId else { return false }
        return group.copies.contains {
            $0.findingId != copy.findingId && !selectedIds.contains($0.findingId)
        }
    }

    func toggleDuplicate(_ copy: DuplicateCopy, in group: DuplicateGroup) {
        if selectedIds.contains(copy.findingId) {
            setSelected([copy.findingId], false)
        } else if canSelectDuplicate(copy, in: group) {
            setSelected([copy.findingId], true)
        }
    }

    /// How many groups "Apply rule to all" would move the keeper in.
    func groupsAffected(by rule: KeeperRule) -> Int {
        duplicateGroups.filter { group in
            if let target = group.keeper(under: rule) { return target != group.keeperId }
            return false
        }.count
    }

    func applyKeeperRule(_ rule: KeeperRule) {
        guard let scanId = lastScan?.id else { return }
        var previous: [String: String] = [:]
        for var group in duplicateGroups {
            guard let target = group.keeper(under: rule), target != group.keeperId else { continue }
            previous[group.hash] = group.keeperId
            guard (try? group.setKeeper(target)) != nil else { continue }
            try? store.updateKeeper(of: group, scanId: scanId, home: home)
        }
        lastKeeperBatch = previous.isEmpty ? nil : KeeperBatch(previousKeepers: previous)
        refresh()
    }

    func undoKeeperBatch() {
        guard let batch = lastKeeperBatch, let scanId = lastScan?.id else { return }
        for var group in duplicateGroups {
            guard let old = batch.previousKeepers[group.hash],
                  (try? group.setKeeper(old)) != nil else { continue }
            try? store.updateKeeper(of: group, scanId: scanId, home: home)
        }
        lastKeeperBatch = nil
        refresh()
    }

    // MARK: - Clean flow (S2: Review is the only gate)

    var canReview: Bool { selectedCount > 0 && !isScanning }

    func openReview(entry: CleanFlow.Entry = .manual) {
        guard cleanFlow == nil else { return }
        let selection = findings.filter {
            selectedIds.contains($0.id) && $0.isReclaimable && !isExcluded($0)
        }
        // CleanFlow.init is nil on an empty plan: the sheet never opens on nothing.
        cleanFlow = CleanFlow(model: self, selection: selection, entry: entry)
    }

    /// After a run or a restore: fresh gauge, fresh runs, stale-scan banner.
    func cleanDidFinish() {
        cleanedSinceScan = true
        refresh()
        refreshDisk()
    }

    /// ⌘Z: restore the most recent run that still has items in the Trash.
    var lastUndoableRunId: Int64? {
        // ponytail: availability stats every done item of recent runs; cap at
        // the last 10 runs so the menu stays instant.
        for run in ((try? history.runs()) ?? []).prefix(10) {
            let availability = (try? history.undoAvailability(runId: run.id))
                ?? .unavailable(.nothingMoved)
            if case .unavailable = availability { continue }
            return run.id
        }
        return nil
    }

    func undoLastClean() {
        guard let runId = lastUndoableRunId else { return }
        let executor = Executor(history: history)
        Task {
            _ = try? await executor.restore(runId: runId)
            refresh()
            refreshDisk()
        }
    }

    // MARK: - Exclusions

    func neverTouch(_ items: [Finding]) {
        guard !items.isEmpty else { return }
        var entries: [(path: String, isFolder: Bool)] = []
        for finding in items {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: finding.url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                try? exclusions.addFolder(finding.url.path)
            } else {
                try? exclusions.addPath(finding.url.path)
            }
            entries.append((finding.url.path, isDirectory.boolValue))
        }
        let ids = items.map(\.id)
        try? store.setSelected(ids, false)
        lastExclusionBatch = ExclusionBatch(entries: entries, findingIds: ids)
        refresh()
    }

    /// Context-menu "Exclude folder": excludes the containing folder, hiding
    /// every finding under it.
    func excludeFolder(_ path: String) {
        try? exclusions.addFolder(path)
        lastExclusionBatch = ExclusionBatch(entries: [(path, true)], findingIds: [])
        refresh()
    }

    func undoNeverTouch() {
        guard let batch = lastExclusionBatch else { return }
        for entry in batch.entries {
            if entry.isFolder {
                try? exclusions.removeFolder(entry.path)
            } else {
                try? exclusions.removePath(entry.path)
            }
        }
        try? store.setSelected(batch.findingIds, true)
        lastExclusionBatch = nil
        refresh()
    }

    // MARK: - Debug screenshot routing

    private func applyDebugRoute() {
        #if DEBUG
        guard let index = CommandLine.arguments.firstIndex(of: "--screen"),
              CommandLine.arguments.indices.contains(index + 1) else { return }
        let route = CommandLine.arguments[index + 1]
        switch route {
        case "welcome": showWelcome = true
        case "home": showWelcome = false; sidebar = .home
        case "results": showWelcome = false; sidebar = .results
        case "scanning":
            showWelcome = false
            Task { self.startScan() }
        case "review":
            showWelcome = false
            sidebar = .results
            // Give the window a beat to exist before the sheet presents.
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.openReview()
            }
        case "history":
            showWelcome = false
            sidebar = .history
        case "duplicates":
            showWelcome = false
            sidebar = .duplicates
        default:
            if route.hasPrefix("detail:"), let category = Category(rawValue: String(route.dropFirst(7))) {
                showWelcome = false
                sidebar = .results
                openCategory = category
            }
        }
        #endif
    }
}
