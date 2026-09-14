import AppKit
import Combine
import DebrisCore
import UniformTypeIdentifiers

/// One presentation of the clean sheet: Review → Cleaning → Done. A fresh
/// instance is built every time the sheet opens, so the plan is always
/// re-planned from the current selection (S6 starts here).
@MainActor
final class CleanFlow: ObservableObject, Identifiable {

    /// Auto Clean never comes through this sheet, so it is not a case (S2/S3).
    enum Entry: CaseIterable { case manual, smart }
    enum Stage { case review, cleaning, done }

    let id = UUID()
    private unowned let model: AppModel
    private let entry: Entry
    private let planner = Planner()
    /// The findings behind the plan; shrinks with "Remove from list".
    private var selection: [Finding]
    private let categoryByRule: [String: Category]
    private var cleanTask: Task<Void, Never>?

    @Published private(set) var stage: Stage = .review
    @Published private(set) var plan: CleanPlan
    @Published private(set) var disposal: Disposal = .trash
    /// The second confirmation for "Delete permanently" (S3).
    @Published var confirmingPermanent = false
    /// No-Trash-volume items the user unticked: left out of the run.
    @Published private(set) var uncheckedNoTrashPaths: Set<String> = []
    @Published private(set) var quittingBundleIds: Set<String> = []

    // Cleaning
    @Published private(set) var progress: ExecProgress?
    private(set) var runTotalBytes: Int64 = 0
    private(set) var runTotalItems = 0

    // Done
    @Published private(set) var result: RunResult?
    @Published private(set) var runError: String?
    @Published private(set) var skippedItems: [ItemRecord] = []
    @Published private(set) var undo: UndoAvailability = .unavailable(.nothingMoved)
    @Published private(set) var restoredCount: Int?
    @Published private(set) var freeNow: Int64 = 0
    @Published private(set) var trashBytes: Int64 = 0

    /// nil when the plan comes out empty: Review never opens on nothing (S2).
    init?(model: AppModel, selection: [Finding], entry: Entry) {
        self.model = model
        self.entry = entry
        self.selection = selection
        categoryByRule = Dictionary(selection.map { ($0.ruleId, $0.category) },
                                    uniquingKeysWith: { first, _ in first })
        let plan = planner.plan(selection: selection, request: Self.request(entry, .trash))
        guard !plan.items.isEmpty else { return nil }
        self.plan = plan
    }

    private static func request(_ entry: Entry, _ disposal: Disposal) -> CleanRequest {
        entry == .smart ? .smart(disposal: disposal) : .manual(disposal: disposal)
    }

    private func replan() {
        var next = planner.plan(selection: selection, request: Self.request(entry, disposal))
        next.skipBundleIds = plan.skipBundleIds
        plan = next
    }

    // MARK: - What Clean will actually touch

    /// Mirrors the executor's own skip filter, minus unticked no-Trash items.
    var effectiveItems: [PlanItem] {
        plan.items.filter {
            ($0.ownerBundleId.map { !plan.skipBundleIds.contains($0) } ?? true)
                && !uncheckedNoTrashPaths.contains($0.originalPath)
        }
    }

    var effectiveBytes: Int64 { effectiveItems.reduce(0) { $0 + $1.allocatedSize } }

    struct CategoryGroup: Identifiable {
        let category: Category
        let items: [PlanItem]
        let bytes: Int64
        var id: Category { category }
    }

    var groups: [CategoryGroup] {
        let shown = plan.items.filter {
            $0.ownerBundleId.map { !plan.skipBundleIds.contains($0) } ?? true
        }
        return Dictionary(grouping: shown) { categoryByRule[$0.ruleId] ?? .largeOld }
            .map { CategoryGroup(category: $0.key, items: $0.value,
                                 bytes: $0.value.reduce(0) { $0 + $1.allocatedSize }) }
            .sorted { $0.bytes > $1.bytes }
    }

    var visibleConflicts: [RunningAppConflict] {
        plan.runningAppConflicts.filter { !plan.skipBundleIds.contains($0.bundleId) }
    }

    // MARK: - Review actions

    func requestDisposal(_ new: Disposal) {
        guard new != disposal else { return }
        if new == .permanent {
            confirmingPermanent = true // disposal flips only in confirmPermanent
        } else {
            disposal = .trash
            replan()
        }
    }

    func confirmPermanent() {
        confirmingPermanent = false
        disposal = .permanent
        replan()
    }

    /// Cancelling the second confirmation returns to Trash (S3).
    func cancelPermanent() {
        confirmingPermanent = false
        disposal = .trash
    }

    /// "Remove from list": drops the rule's items from this plan and unticks
    /// them in the selection so they stay out after the sheet closes.
    func removeRule(_ ruleId: String) {
        let dropped = selection.filter { $0.ruleId == ruleId }
        guard !dropped.isEmpty else { return }
        selection.removeAll { $0.ruleId == ruleId }
        model.setSelected(dropped.map(\.id), false)
        replan()
    }

    func skipApp(_ bundleId: String) {
        plan.skipBundleIds.insert(bundleId)
    }

    func quitAndContinue(_ conflict: RunningAppConflict) {
        quittingBundleIds.insert(conflict.bundleId)
        NSRunningApplication.runningApplications(withBundleIdentifier: conflict.bundleId)
            .forEach { $0.terminate() }
        Task {
            // Up to 5 s for the app to go away, then re-plan either way.
            for _ in 0..<25 where !NSRunningApplication
                .runningApplications(withBundleIdentifier: conflict.bundleId).isEmpty {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            quittingBundleIds.remove(conflict.bundleId)
            replan()
        }
    }

    func toggleNoTrashItem(_ path: String) {
        uncheckedNoTrashPaths.formSymmetricDifference([path])
    }

    func exportList() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Data Debris clean list.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = effectiveItems.map(\.originalPath).joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Cleaning

    func startClean() {
        guard stage == .review, !effectiveItems.isEmpty else { return }
        let kept = selection.filter { !uncheckedNoTrashPaths.contains($0.url.path) }
        var finalPlan = planner.plan(selection: kept, request: Self.request(entry, disposal))
        finalPlan.skipBundleIds = plan.skipBundleIds
        // Any no-Trash item still here was left ticked next to its "deleted
        // permanently" note — that tick is the approval (S3).
        finalPlan.permanentApprovedForNoTrash = !finalPlan.itemsRequiringPermanent.isEmpty
        runTotalBytes = finalPlan.estimatedBytes
        runTotalItems = finalPlan.items.filter {
            $0.ownerBundleId.map { !finalPlan.skipBundleIds.contains($0) } ?? true
        }.count
        stage = .cleaning
        CleanWindowGuard.shared.install { [weak self] in self?.cancelClean() }
        let executor = Executor(history: model.history, exclusions: model.exclusions)
        cleanTask = Task {
            var result: RunResult?
            var failure: Error?
            do {
                result = try await executor.execute(plan: finalPlan) { progress in
                    Task { @MainActor [weak self] in self?.progress = progress }
                }
            } catch {
                failure = error
            }
            finishClean(result, failure)
        }
    }

    /// Finishes the current item; already-moved items stay in the Trash.
    func cancelClean() {
        cleanTask?.cancel()
    }

    private func finishClean(_ result: RunResult?, _ error: Error?) {
        CleanWindowGuard.shared.uninstall()
        self.result = result
        runError = error?.localizedDescription
        if let runId = result?.runId {
            let items = (try? model.history.items(runId: runId)) ?? []
            skippedItems = items.filter { $0.status == .skipped }
            undo = (try? model.history.undoAvailability(runId: runId))
                ?? .unavailable(.nothingMoved)
        }
        freeNow = DiskUsage.freeAndTotal().free
        stage = .done
        refreshTrashBytes()
        model.cleanDidFinish()
    }

    // MARK: - Done actions

    func undoRun() {
        guard let runId = result?.runId, restoredCount == nil else { return }
        let executor = Executor(history: model.history)
        Task {
            let restore = try? await executor.restore(runId: runId)
            restoredCount = restore?.restoredCount ?? 0
            undo = (try? model.history.undoAvailability(runId: runId))
                ?? .unavailable(.alreadyRestored)
            refreshTrashBytes()
            model.cleanDidFinish()
        }
    }

    /// Only ever called after the user confirmed the alert; never automatic.
    func emptyTrash() {
        // Finder owns the gesture (and shows its own progress for big
        // trashes). NSAppleScript wants the main thread.
        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        Task {
            // ponytail: Finder empties asynchronously; one second covers the
            // small case, and a wrong number here is only cosmetic.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let runId = result?.runId {
                undo = (try? model.history.undoAvailability(runId: runId)) ?? undo
            }
            refreshTrashBytes()
            model.cleanDidFinish()
        }
    }

    private func refreshTrashBytes() {
        Task.detached { [weak self] in
            let bytes = Self.measureTrash()
            await MainActor.run { [weak self] in self?.trashBytes = bytes }
        }
    }

    private nonisolated static func measureTrash() -> Int64 {
        let trash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash")
        var total: Int64 = 0
        if let walker = FileManager.default.enumerator(
            at: trash, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}

// MARK: - Window close guard

/// While a clean runs, closing the window asks first. Everything else is
/// forwarded to SwiftUI's own window delegate.
final class CleanWindowGuard: NSObject, NSWindowDelegate {
    static let shared = CleanWindowGuard()
    private weak var window: NSWindow?
    private weak var original: NSWindowDelegate?
    private var cancel: (() -> Void)?

    func install(cancel: @escaping () -> Void) {
        // The sheet is key while it's up; guard its parent window.
        guard let window = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? NSApp.mainWindow,
              window.delegate !== self else { return }
        self.cancel = cancel
        original = window.delegate
        self.window = window
        window.delegate = self
    }

    func uninstall() {
        if window?.delegate === self { window?.delegate = original }
        window = nil
        cancel = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let alert = NSAlert()
        alert.messageText = "A clean is in progress"
        alert.informativeText = "Items already moved stay in the Trash and can be restored from History."
        alert.addButton(withTitle: "Keep cleaning")
        alert.addButton(withTitle: "Cancel the clean")
        if alert.runModal() == .alertSecondButtonReturn { cancel?() }
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? { original }
}
