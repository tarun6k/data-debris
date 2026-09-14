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
    let catalogue: Catalogue
    private let autoCleanConfigURL: URL?
    private let launchAgents: LaunchAgentManager
    let licenseStore: LicenseStore
    let entitlements: Entitlements
    let licenseService: LicenseService?
    let privacyText: PrivacySheetText

    @Published var sidebar: SidebarItem? = .home
    @Published var openCategory: Category?
    @Published var showWelcome: Bool
    @Published var resultSort: ResultSort = .size
    /// Non-nil while the Review/Cleaning/Done sheet is up — the only gate (S2).
    @Published var cleanFlow: CleanFlow?
    /// Non-nil while the purchase sheets are up (privacy → plan → waiting).
    @Published var purchase: PurchaseFlow?
    /// Mirror of Entitlements.state for SwiftUI; refreshed after any license event.
    @Published private(set) var entitlementState: EntitlementState = .free
    /// One-line confirmation ("Data Debris is active until 14 Sep 2027").
    @Published var licenseToast: String?
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

    @Published private(set) var autoCleanConfig = AutoCleanConfig()
    /// The most recent Auto Clean that actually moved files (not .skipped).
    @Published private(set) var lastAutoRun: RunRecord?
    @Published private(set) var autoCleanRunning = false
    /// Outcome line under "Run now" ("Moved 120 MB to Trash · 34 items").
    @Published private(set) var autoCleanLastOutcome: String?

    let home = FileManager.default.homeDirectoryForCurrentUser

    private var cancellables: Set<AnyCancellable> = []
    private var scanPoll: AnyCancellable?

    private static let welcomeCompletedKey = "welcomeCompleted"
    private static let fdaWasGrantedKey = "fdaWasGranted"

    init(store: FindingsStore, history: HistoryStore, exclusions: ExclusionStore,
         catalogue: Catalogue, autoCleanConfigURL: URL? = nil,
         launchAgents: LaunchAgentManager? = nil,
         licenseStore: LicenseStore? = nil,
         licenseService: LicenseService? = nil,
         privacyText: PrivacySheetText? = nil) {
        self.store = store
        self.history = history
        self.exclusions = exclusions
        self.catalogue = catalogue
        self.autoCleanConfigURL = autoCleanConfigURL ?? (try? AutoCleanConfig.defaultFileURL())
        self.launchAgents = launchAgents ?? LaunchAgentManager()
        self.licenseStore = licenseStore ?? LicenseStore()
        self.entitlements = Entitlements(store: self.licenseStore)
        self.licenseService = licenseService
            ?? LicenseConfig.current.workerURL.map { LicenseClient(baseURL: $0) }
        self.privacyText = privacyText ?? PrivacySheetText()
        if let url = self.autoCleanConfigURL {
            autoCleanConfig = AutoCleanConfig.load(from: url).validated(against: catalogue)
        }
        entitlementState = entitlements.state

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
            // The agent points at the binary by absolute path; heal it if the
            // bundle moved. Only here — tests must never touch launchctl.
            if model.autoCleanConfig.enabled {
                try? LaunchAgentManager().repairIfMoved(
                    schedule: model.autoCleanConfig.schedule,
                    lowSpaceTrigger: model.autoCleanConfig.lowSpaceTriggerGB != nil)
            }
            model.startLicenseHousekeeping()
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
        lastAutoRun = ((try? history.runs()) ?? []).first {
            $0.mode == .auto && $0.status != .skipped && $0.finishedAt != nil
        }
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

    // MARK: - Auto Clean

    /// Categories with at least one eligible rule — the only ones Screen 8
    /// offers. Duplicates, Large & old and Trash never appear here.
    var autoCleanCategories: [Category] {
        Category.allCases.filter { !autoCleanEligibleRuleIds(in: $0).isEmpty }
    }

    func autoCleanEligibleRuleIds(in category: Category) -> Set<String> {
        Set(catalogue.rules.filter { $0.category == category && $0.autoCleanEligible }.map(\.id))
    }

    func autoCleanState(for category: Category) -> CategoryState {
        let eligible = autoCleanEligibleRuleIds(in: category)
        let ticked = eligible.intersection(autoCleanConfig.enabledRuleIds)
        if ticked.isEmpty { return .none }
        return ticked == eligible ? .all : .some
    }

    func toggleAutoCleanCategory(_ category: Category) {
        let eligible = autoCleanEligibleRuleIds(in: category)
        updateAutoClean { config in
            var ids = Set(config.enabledRuleIds)
            if eligible.isSubset(of: ids) { ids.subtract(eligible) } else { ids.formUnion(eligible) }
            config.enabledRuleIds = ids.sorted()
        }
    }

    /// Every config change funnels through here: validate (S9 — ineligible
    /// ids are stripped), publish, persist, and keep the LaunchAgents in
    /// step. Reinstalling on each change is a bootout+bootstrap pair; cheap.
    func updateAutoClean(_ change: (inout AutoCleanConfig) -> Void) {
        var config = autoCleanConfig
        change(&config)
        config = config.validated(against: catalogue)
        autoCleanConfig = config
        if let url = autoCleanConfigURL { try? config.save(to: url) }
        if config.enabled {
            try? launchAgents.install(schedule: config.schedule,
                                      lowSpaceTrigger: config.lowSpaceTriggerGB != nil)
        } else {
            launchAgents.uninstall()
        }
    }

    func setAutoCleanEnabled(_ on: Bool) {
        if on {
            guard requireEntitled(.autoClean, toResume: .enableAutoClean) else { return }
        }
        updateAutoClean { $0.enabled = on }
    }

    var nextAutoCleanRun: Date? {
        guard autoCleanConfig.enabled else { return nil }
        let schedule = autoCleanConfig.schedule
        var match = DateComponents(hour: schedule.hour, minute: schedule.minute)
        switch schedule.frequency {
        case .daily: break
        case .weekly: match.weekday = schedule.weekday
        case .monthly: match.day = 1 // the agent plist also runs on the 1st
        }
        return Calendar.current.nextDate(after: Date(), matching: match,
                                         matchingPolicy: .nextTime)
    }

    /// "Next run Sun 20 Sep, 03:00 · Last run 6 Sep, 1.9 GB" — Screen 8 and
    /// the Home card share it.
    var autoCleanStatusLine: String {
        guard autoCleanConfig.enabled else { return "Not scheduled" }
        var parts: [String] = []
        if let next = nextAutoCleanRun { parts.append("Next run \(Format.runMoment(next))") }
        if let run = lastAutoRun, let finished = run.finishedAt {
            parts.append("Last run \(Format.dayMonth(finished)), \(Format.bytes(run.movedBytes))")
        }
        return parts.isEmpty ? "On" : parts.joined(separator: " · ")
    }

    /// Menu bar gauge: amber below the user's low-space trigger, or below
    /// 10 % free when no trigger is set.
    var menuBarLowSpace: Bool {
        let (free, total) = DiskUsage.freeAndTotal()
        guard total > 0 else { return false }
        if let gb = autoCleanConfig.lowSpaceTriggerGB {
            return free < Int64(gb) * 1_000_000_000
        }
        return Double(free) / Double(total) < 0.10
    }

    /// Menu bar: "Auto Clean ran · 1.9 GB · Undo" for 24 h after a run.
    var undoableAutoRun: RunRecord? {
        guard let run = lastAutoRun, run.status == .completed,
              let finished = run.finishedAt,
              Date().timeIntervalSince(finished) <= 24 * 3600 else { return nil }
        return run
    }

    /// "Run now": same engine and preconditions, still Trash-only (S3).
    func runAutoCleanNow() {
        guard requireEntitled(.autoClean, toResume: .runAutoCleanNow) else { return }
        guard !autoCleanRunning else { return }
        autoCleanRunning = true
        autoCleanLastOutcome = nil
        let config = autoCleanConfig
        Task {
            let line: String
            do {
                let runner = try AutoCleanRunner(config: config, catalogue: catalogue,
                                                 history: history, exclusions: exclusions)
                switch try await runner.run(reason: .manual) {
                case .completed(let runId, let movedBytes, let itemCount):
                    line = "Moved \(Format.bytes(movedBytes)) to Trash · "
                        + "\(Format.count(itemCount)) \(itemCount == 1 ? "item" : "items")"
                    await AutoCleanNotifier.post(runId: runId, movedBytes: movedBytes,
                                                 itemCount: itemCount, notify: config.notify)
                case .deferred(let reason, _):
                    line = "Skipped: \(reason.displayText)"
                case .notNeeded:
                    line = "Nothing to do"
                }
            } catch {
                line = "Could not run: \(error.localizedDescription)"
            }
            autoCleanLastOutcome = line
            autoCleanRunning = false
            refresh()
            refreshDisk()
        }
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
    /// Review directly. Review is still the only gate (S2). Gated before it
    /// touches the selection, so "Not now" really changes nothing.
    func smartClean() {
        guard requireEntitled(.clean, toResume: .smartClean) else { return }
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
        guard requireEntitled(.clean, toResume: .openReview(entry)) else { return }
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

    // MARK: - Licensing (Screen 12/13 — the purchase gate)

    var privacyAcknowledged: Bool {
        autoCleanConfig.privacyAcknowledgement?.textHash == privacyText.textHash
    }

    func refreshEntitlement() {
        entitlementState = entitlements.state
    }

    /// Every locked action funnels through here: allowed = proceed; otherwise
    /// the purchase flow starts and, on activation, resumes the action.
    @discardableResult
    func requireEntitled(_ feature: LockedFeature, toResume resume: PurchaseFlow.ResumeAction) -> Bool {
        refreshEntitlement()
        guard entitlements.require(feature) == .needsPurchase else { return true }
        startPurchase(resuming: resume)
        return false
    }

    func startPurchase(resuming resume: PurchaseFlow.ResumeAction = .none) {
        guard purchase == nil, cleanFlow == nil else { return }
        guard let service = licenseService else {
            licenseToast = "The license service is not configured in this build"
            return
        }
        purchase = PurchaseFlow(
            resume: resume,
            acknowledged: privacyAcknowledged,
            service: service,
            store: licenseStore,
            launchCheckout: { [weak self] plan, autoRenew, reference in
                self?.openCheckout(plan: plan, autoRenew: autoRenew, reference: reference)
            },
            recordAcknowledgement: { [weak self] in self?.recordPrivacyAcknowledgement() },
            onDone: { [weak self] flow, outcome in self?.purchaseDidFinish(flow, outcome) })
    }

    private var checkoutServer: CheckoutServer?

    /// Serves the bundled Paddle page on 127.0.0.1 and hands it to the default
    /// browser; the flow polls the worker for the key the webhook will mint.
    func openCheckout(plan: LicensePlan, autoRenew: Bool, reference: String) {
        let config = LicenseConfig.current
        guard let priceId = config.priceId(plan: plan, autoRenew: autoRenew),
              let token = config.paddleClientToken,
              let template = Bundle.main.url(forResource: "checkout", withExtension: "html")
                  .flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else {
            licenseToast = "Checkout is not configured in this build"
            // choosePlan is still mid-flight; cancel on the next turn so the
            // flow's own bookkeeping (waiting step, poll task) exists to cancel.
            DispatchQueue.main.async { self.purchase?.cancel() }
            return
        }
        let page = CheckoutServer.page(
            template: template, env: config.paddleEnv, token: token,
            priceId: priceId, reference: reference, machineId: MachineIdentity.machineId())
        checkoutServer?.stop()
        let server = CheckoutServer(html: page)
        checkoutServer = server
        server.start { url in
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    /// datadebris://checkout-success?ref=… — the browser came back; check for
    /// the key right now instead of on the next 3 s tick.
    func handleURL(_ url: URL) {
        guard url.scheme == "datadebris" else { return }
        purchase?.checkoutCallbackReceived()
    }

    // MARK: - Settings > License

    var licensePayload: EntitlementPayload? { licenseStore.load()?.0 }

    /// "Enter a different key" in Settings. ponytail: errors surface as
    /// toasts here; the full Manage Macs list stays in the purchase flow.
    func enterLicenseKey(_ key: String) async {
        guard let service = licenseService else {
            licenseToast = "The license service is not configured in this build"
            return
        }
        do {
            let entitlement = try await service.activate(
                key: key, machineId: MachineIdentity.machineId(),
                machineName: MachineIdentity.machineName())
            try licenseStore.save(licenseKey: key, entitlement: entitlement, lastValidatedAt: Date())
            refreshEntitlement()
            entitlements.reconcileAutoCleanAgent(config: autoCleanConfig, agents: launchAgents)
            if let (payload, _) = licenseStore.load() {
                licenseToast = Self.activationToast(payload)
            }
        } catch LicenseClientError.activationLimit {
            licenseToast = "This key is already active on 2 Macs. Deactivate one of them first."
        } catch LicenseClientError.unknownKey {
            licenseToast = "That key was not found. Check it against the email from your purchase."
        } catch LicenseClientError.inactive {
            licenseToast = "This key is no longer active (refunded or expired)."
        } catch {
            licenseToast = "Could not reach the license service. Check your connection and retry."
        }
    }

    func recoverLicenseKey(email: String) async {
        try? await licenseService?.recover(email: email)
    }

    /// Frees this Mac's slot on the server first; the local cache is cleared
    /// only on success so the two never disagree about a used slot.
    func deactivateThisMac() async {
        guard let service = licenseService, let (_, stored) = licenseStore.load() else { return }
        do {
            try await service.deactivate(key: stored.licenseKey,
                                         machineId: MachineIdentity.machineId())
            licenseStore.clear()
            refreshEntitlement()
            entitlements.reconcileAutoCleanAgent(config: autoCleanConfig, agents: launchAgents)
            licenseToast = "This Mac is deactivated — the license slot is free"
        } catch {
            licenseToast = "Could not reach the license service. Check your connection and retry."
        }
    }

    static func activationToast(_ payload: EntitlementPayload) -> String {
        "Data Debris is active until "
            + payload.expiryDate.formatted(date: .abbreviated, time: .omitted)
    }

    /// Written directly, not via updateAutoClean — acknowledging the privacy
    /// sheet must not churn the LaunchAgents.
    private func recordPrivacyAcknowledgement() {
        var config = autoCleanConfig
        config.privacyAcknowledgement = PrivacyAcknowledgement(
            textHash: privacyText.textHash, acknowledgedAt: Date())
        autoCleanConfig = config
        if let url = autoCleanConfigURL { try? config.save(to: url) }
    }

    private func purchaseDidFinish(_ flow: PurchaseFlow, _ outcome: PurchaseFlow.Outcome) {
        guard purchase === flow else { return }
        purchase = nil
        checkoutServer?.stop()
        checkoutServer = nil
        guard case .activated(let payload) = outcome else { return }
        refreshEntitlement()
        entitlements.reconcileAutoCleanAgent(config: autoCleanConfig, agents: launchAgents)
        licenseToast = Self.activationToast(payload)
        switch flow.resume {
        case .openReview(let entry): openReview(entry: entry)
        case .smartClean: smartClean()
        case .enableAutoClean: setAutoCleanEnabled(true)
        case .runAutoCleanNow: runAutoCleanNow()
        case .none: break
        }
    }

    /// Launch and wake: at most one validate round-trip per 24 h; the
    /// LaunchAgents follow the entitlement (no unpaid background cleaning).
    func licenseHousekeeping() {
        refreshEntitlement()
        entitlements.reconcileAutoCleanAgent(config: autoCleanConfig, agents: launchAgents)
        guard let service = licenseService else { return }
        Task {
            await entitlements.validateIfNeeded(machineId: MachineIdentity.machineId()) {
                try await service.validate(key: $0, machineId: $1)
            }
            refreshEntitlement()
            entitlements.reconcileAutoCleanAgent(config: autoCleanConfig, agents: launchAgents)
        }
    }

    /// live() only — tests must never observe system notifications.
    func startLicenseHousekeeping() {
        licenseHousekeeping()
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.licenseHousekeeping() }
            .store(in: &cancellables)
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
