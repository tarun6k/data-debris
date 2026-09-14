import XCTest
import DebrisCore
@testable import DataDebris

private typealias Category = DebrisCore.Category

final class DebrisAppTests: XCTestCase {

    func testSidebarItemsMatchSpecOrder() {
        XCTAssertEqual(
            SidebarItem.allCases.map(\.title),
            ["Home", "Results", "Duplicates", "Auto Clean", "History", "Settings"]
        )
    }

    // MARK: - AmountButton (copy rule: buttons name the amount)

    func testAmountButtonTitleAlwaysContainsFormattedBytes() {
        for bytes: Int64 in [0, 1_024, 612_000_000, 9_700_000_000] {
            let title = AmountButton.title(verb: "Clean", bytes: bytes)
            XCTAssertTrue(title.hasPrefix("Clean "))
            XCTAssertTrue(title.contains(Format.bytes(bytes)))
            XCTAssertFalse(Format.bytes(bytes).isEmpty)
        }
        XCTAssertTrue(AmountButton.title(verb: "Review", bytes: 1, ellipsis: true).hasSuffix("…"))
    }

    // MARK: - AppModel with temp stores

    @MainActor
    private func makeModel() throws -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebrisAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(
            store: try FindingsStore(databaseURL: dir.appendingPathComponent("findings.sqlite")),
            history: try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite")),
            exclusions: try ExclusionStore(fileURL: dir.appendingPathComponent("exclusions.json")),
            catalogue: Catalogue(version: 1, rules: []),
            licenseStore: LicenseFixture.activeStore())
        return (model, dir)
    }

    private func finding(
        _ path: String, level: Level, category: Category, bytes: Int64 = 1_000
    ) -> Finding {
        Finding(
            ruleId: "test.\(category.rawValue)",
            url: URL(fileURLWithPath: path),
            size: bytes, allocatedSize: bytes,
            mtime: Date(), lastOpened: nil,
            level: level, category: category,
            reason: "test", consequence: "test")
    }

    /// S2: safe categories arrive checked, review and manual unchecked.
    @MainActor
    func testDefaultSelectionMatchesS2() throws {
        let (model, dir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }

        let scanId = try model.store.beginScan()
        let safe1 = finding(dir.path + "/cache1", level: .safe, category: .appCaches)
        let safe2 = finding(dir.path + "/cache2", level: .safe, category: .appCaches)
        let review = finding(dir.path + "/derived", level: .review, category: .developer)
        let manual = finding(dir.path + "/big.zip", level: .manual, category: .largeOld)
        try model.store.upsert([safe1, safe2, review, manual], scanId: scanId)
        try model.store.finishScan(scanId, status: .complete, deniedCount: 0)
        model.refresh()

        func state(_ category: Category) -> CategoryState? {
            model.rows.first { $0.category == category }?.state
        }
        XCTAssertEqual(state(.appCaches), .all)
        XCTAssertEqual(state(.developer), CategoryState.none)
        XCTAssertEqual(state(.largeOld), CategoryState.none)
        XCTAssertEqual(model.selectedIds, [safe1.id, safe2.id])
    }

    /// "Never touch selected" removes the rows and records exclusions; undo
    /// brings both back.
    @MainActor
    func testNeverTouchRemovesRowsAndAddsExclusions() throws {
        let (model, dir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }

        let filePath = dir.appendingPathComponent("cache.dat").path
        FileManager.default.createFile(atPath: filePath, contents: Data("x".utf8))

        let scanId = try model.store.beginScan()
        let excludeMe = finding(filePath, level: .safe, category: .appCaches)
        let keepMe = finding(dir.path + "/other.dat", level: .safe, category: .appCaches)
        try model.store.upsert([excludeMe, keepMe], scanId: scanId)
        try model.store.finishScan(scanId, status: .complete, deniedCount: 0)
        model.refresh()
        XCTAssertEqual(model.visibleFindings(in: .appCaches).count, 2)

        model.neverTouch([excludeMe])

        XCTAssertTrue(model.exclusions.isExcluded(excludeMe.url))
        XCTAssertEqual(model.visibleFindings(in: .appCaches).map(\.id), [keepMe.id])
        XCTAssertFalse(model.selectedIds.contains(excludeMe.id))

        model.undoNeverTouch()

        XCTAssertFalse(model.exclusions.isExcluded(excludeMe.url))
        XCTAssertEqual(model.visibleFindings(in: .appCaches).count, 2)
        XCTAssertTrue(model.selectedIds.contains(excludeMe.id))
    }

    // MARK: - Clean flow (Phase 4B)

    /// Two real files behind two rules, both safe so S2 pre-selects them.
    @MainActor
    private func makeFlowModel() throws -> (model: AppModel, dir: URL, cache: Finding, log: Finding) {
        let (model, dir) = try makeModel()
        let cachePath = dir.appendingPathComponent("cache.dat").path
        let logPath = dir.appendingPathComponent("app.log").path
        FileManager.default.createFile(atPath: cachePath, contents: Data("cache".utf8))
        FileManager.default.createFile(atPath: logPath, contents: Data("log".utf8))
        let cache = finding(cachePath, level: .safe, category: .appCaches)
        let log = finding(logPath, level: .safe, category: .logs)
        let scanId = try model.store.beginScan()
        try model.store.upsert([cache, log], scanId: scanId)
        try model.store.finishScan(scanId, status: .complete, deniedCount: 0)
        model.refresh()
        return (model, dir, cache, log)
    }

    /// S2: Review never opens on an empty plan — no selection, or a selection
    /// whose files vanished since the scan.
    @MainActor
    func testReviewCannotOpenOnEmptyPlan() throws {
        let (model, dir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertFalse(model.canReview) // the Review button is disabled
        model.openReview()
        XCTAssertNil(model.cleanFlow)

        // Selected but gone from disk: the planner drops it, the sheet stays shut.
        let scanId = try model.store.beginScan()
        let ghost = finding(dir.path + "/vanished.dat", level: .safe, category: .appCaches)
        try model.store.upsert([ghost], scanId: scanId)
        try model.store.finishScan(scanId, status: .complete, deniedCount: 0)
        model.refresh()
        XCTAssertTrue(model.canReview)
        model.openReview()
        XCTAssertNil(model.cleanFlow)
    }

    /// S3: permanent delete needs the second confirmation; cancelling it
    /// returns the run to Trash.
    @MainActor
    func testPermanentRequiresSecondConfirmationAndCancelReverts() throws {
        let (model, dir, _, _) = try makeFlowModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        model.openReview()
        let flow = try XCTUnwrap(model.cleanFlow)

        XCTAssertEqual(flow.disposal, .trash)
        flow.requestDisposal(.permanent)
        XCTAssertTrue(flow.confirmingPermanent)      // alert pending
        XCTAssertEqual(flow.disposal, .trash)        // nothing flipped yet
        flow.cancelPermanent()
        XCTAssertEqual(flow.disposal, .trash)
        XCTAssertEqual(flow.plan.request.disposal, .trash)

        flow.requestDisposal(.permanent)
        flow.confirmPermanent()
        XCTAssertEqual(flow.disposal, .permanent)
        XCTAssertEqual(flow.plan.request.disposal, .permanent)
    }

    /// "Remove from list" drops that rule's items from the plan and unticks
    /// them in the stored selection.
    @MainActor
    func testRemoveFromListDropsRuleItemsAndUnticks() throws {
        let (model, dir, cache, log) = try makeFlowModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        model.openReview()
        let flow = try XCTUnwrap(model.cleanFlow)
        XCTAssertEqual(flow.plan.items.count, 2)

        flow.removeRule(cache.ruleId)

        XCTAssertEqual(flow.plan.items.map(\.ruleId), [log.ruleId])
        XCTAssertFalse(model.selectedIds.contains(cache.id))
        XCTAssertTrue(model.selectedIds.contains(log.id))
    }

    /// S10: the "fully reclaimed once Trash is emptied" line appears exactly
    /// when a Trash run freed less than it moved.
    func testDoneReclaimNoteShownWhenFreedLessThanMoved() {
        XCTAssertTrue(DoneView.showsReclaimNote(freed: 0, moved: 1_000, disposal: .trash))
        XCTAssertTrue(DoneView.showsReclaimNote(freed: 999, moved: 1_000, disposal: .trash))
        XCTAssertFalse(DoneView.showsReclaimNote(freed: 1_000, moved: 1_000, disposal: .trash))
        XCTAssertFalse(DoneView.showsReclaimNote(freed: 0, moved: 0, disposal: .trash))
        XCTAssertFalse(DoneView.showsReclaimNote(freed: 0, moved: 1_000, disposal: .permanent))
    }

    /// The Undo button is disabled with a stated reason whenever
    /// UndoAvailability is unavailable.
    func testUndoDisabledReasonCoversEveryUnavailableCase() {
        XCTAssertNil(DoneView.undoDisabledReason(.available))
        XCTAssertNil(DoneView.undoDisabledReason(.partiallyAvailable(1, of: 2)))
        for reason: UndoAvailability.Reason in
            [.permanentDelete, .trashEmptied, .alreadyRestored, .nothingMoved] {
            XCTAssertNotNil(DoneView.undoDisabledReason(.unavailable(reason)))
        }
    }

    /// S3: an Auto Clean run can never reach the permanent path. The request
    /// type has no auto+permanent constructor, and the Review sheet can only
    /// be entered manually or via Smart Clean.
    func testAutoModeCanNeverBePermanent() {
        XCTAssertEqual(CleanRequest.autoClean.mode, .auto)
        XCTAssertEqual(CleanRequest.autoClean.disposal, .trash)
        XCTAssertEqual(CleanFlow.Entry.allCases, [.manual, .smart])
    }
}
