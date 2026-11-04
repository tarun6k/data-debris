import XCTest
import DebrisCore
@testable import DataDebris

private typealias Category = DebrisCore.Category

/// Docker objects (spec §6) in the app layer: ticked one by one, counted in
/// Review, and reported as "no undo" wherever the journal shows them.
@MainActor
final class DockerItemsTests: XCTestCase {
    private var dir: URL!
    private var model: AppModel!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DockerItemsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model = AppModel(
            store: try FindingsStore(databaseURL: dir.appendingPathComponent("findings.sqlite")),
            history: try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite")),
            exclusions: try ExclusionStore(fileURL: dir.appendingPathComponent("exclusions.json")),
            catalogue: Catalogue(version: 1, rules: []),
            licenseStore: LicenseFixture.activeStore())
    }

    override func tearDown() async throws {
        model = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func dockerFinding(_ object: DockerObject, bytes: Int64) -> Finding {
        Finding(
            ruleId: DockerAnalyzer.ruleId, url: object.url,
            size: bytes, allocatedSize: bytes, mtime: Date(), lastOpened: nil,
            level: .review, category: .developer,
            reason: "Untagged image no container uses.",
            consequence: "Images re-pulled on next run.")
    }

    private func fileFinding(_ name: String, bytes: Int64 = 1_000) -> Finding {
        let path = dir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        return Finding(
            ruleId: "test.developer", url: URL(fileURLWithPath: path),
            size: bytes, allocatedSize: bytes, mtime: Date(), lastOpened: nil,
            level: .review, category: .developer, reason: "test", consequence: "test")
    }

    private func store(_ findings: [Finding]) throws {
        let scanId = try model.store.beginScan()
        try model.store.upsert(findings, scanId: scanId)
        try model.store.finishScan(scanId, status: .complete, deniedCount: 0)
        model.refresh()
    }

    /// Spec §6: "user confirms per item". A category tick on Results never
    /// sweeps Docker objects in, and still cycles the rest on and off.
    func testCategoryTickLeavesDockerObjectsForIndividualConfirmation() throws {
        let image = dockerFinding(.image(id: "3f2a1b9c0d4e"), bytes: 1_230_000_000)
        let folder = fileFinding("DerivedData.bin")
        try store([image, folder])
        XCTAssertFalse(model.selectedIds.contains(image.id), "review level arrives unticked (S2)")

        model.toggleCategory(.developer)
        XCTAssertTrue(model.selectedIds.contains(folder.id))
        XCTAssertFalse(model.selectedIds.contains(image.id))

        model.toggleCategory(.developer)
        XCTAssertFalse(model.selectedIds.contains(folder.id), "the tick still cycles back to none")

        model.setSelected([image.id], true)
        XCTAssertTrue(model.selectedIds.contains(image.id), "one item at a time is how they are ticked")
    }

    /// Review counts a ticked Docker object in "Clean N GB", lets the user
    /// untick it there, and says undo does not cover it.
    func testReviewCountsDockerObjectsAndNotesNoUndo() throws {
        let image = dockerFinding(.image(id: "3f2a1b9c0d4e"), bytes: 1_230_000_000)
        let cache = dockerFinding(.buildCache(id: "k2l3m4n5o6p7"), bytes: 456_000_000)
        let folder = fileFinding("DerivedData.bin", bytes: 1_000)
        try store([image, cache, folder])
        model.setSelected([image.id, cache.id, folder.id], true)

        model.openReview()
        let flow = try XCTUnwrap(model.cleanFlow)
        XCTAssertEqual(flow.effectiveBytes, 1_230_000_000 + 456_000_000 + 1_000)
        XCTAssertEqual(flow.dockerItemCount, 2)
        XCTAssertEqual(AmountButton.title(verb: "Clean", bytes: flow.effectiveBytes),
                       "Clean \(Format.bytes(1_686_001_000))")
        XCTAssertEqual(ReviewView.undoNote(disposal: .trash, dockerItems: flow.dockerItemCount),
                       "Undo available from History, except Docker items")

        flow.toggleItem(cache.storedPath)
        XCTAssertEqual(flow.effectiveBytes, 1_230_000_000 + 1_000)
        XCTAssertEqual(flow.dockerItemCount, 1)

        flow.toggleItem(image.storedPath)
        XCTAssertEqual(flow.dockerItemCount, 0)
        XCTAssertEqual(ReviewView.undoNote(disposal: .trash, dockerItems: 0),
                       "Undo available from History")
        XCTAssertEqual(ReviewView.undoNote(disposal: .permanent, dockerItems: 3),
                       "No undo for permanent delete")
    }

    /// Done and History read the journal: a removed Docker object is
    /// irreversible, so both report undo as unavailable and name the object.
    func testDoneAndHistoryReportNoUndoForRemovedDockerObjects() throws {
        let image = dockerFinding(.image(id: "3f2a1b9c0d4e"), bytes: 1_230_000_000)
        let plan = Planner().plan(selection: [image], request: .manual())
        let runId = try model.history.createRun(
            request: plan.request, estimatedBytes: plan.estimatedBytes,
            volumeFreeBefore: 0, items: plan.items)
        let items = try model.history.items(runId: runId)
        try model.history.markItem(try XCTUnwrap(items.first).id, status: .irreversible, movedAt: Date())

        let availability = try model.history.undoAvailability(runId: runId)
        XCTAssertEqual(availability, .unavailable(.permanentDelete))
        XCTAssertNotNil(DoneView.undoDisabledReason(availability), "DoneView prints Undo unavailable")

        let record = try XCTUnwrap(try model.history.items(runId: runId).first)
        XCTAssertEqual(HistoryView.itemStatusText(record), "Removed with docker · no undo")
        XCTAssertEqual(DoneView.subline(freeNow: 0, doneCount: 1, dockerCount: 1, disposal: .trash),
                       "\(Format.bytes(0)) free now · 0 items moved to Trash · 1 Docker object removed")
    }

    /// The what's-new sheet says the rule is review-only and never in Auto Clean.
    func testWhatsNewMarksReviewOnlyRulesAsNeverInAutoClean() throws {
        let rule = try XCTUnwrap(Catalogue.bundled().rules.first { $0.id == DockerAnalyzer.ruleId })
        XCTAssertFalse(rule.autoCleanEligible)
        XCTAssertEqual(CatalogueWhatsNewSheet.autoCleanNote(for: rule), "Review only · never in Auto Clean")
        let eligible = Rule(id: "x", category: .appCaches, level: .safe, match: ["~/Library/Caches/x"],
                            unit: .directory, reason: "r", consequence: "c", autoCleanEligible: true)
        XCTAssertEqual(CatalogueWhatsNewSheet.autoCleanNote(for: eligible), "Off for Auto Clean")
    }

    /// "Never touch" on a Docker object excludes it by id, hides it, and
    /// comes back with the toast's Undo.
    func testNeverTouchExcludesDockerObjectById() throws {
        let image = dockerFinding(.image(id: "3f2a1b9c0d4e"), bytes: 1_230_000_000)
        try store([image])
        model.neverTouch([image])
        XCTAssertTrue(model.exclusions.isExcluded(path: image.storedPath))
        XCTAssertTrue(model.visibleFindings(in: .developer).isEmpty)
        XCTAssertEqual(model.lastExclusionBatch?.entries.map(\.path), [image.storedPath])

        model.undoNeverTouch()
        XCTAssertFalse(model.exclusions.isExcluded(path: image.storedPath))
        XCTAssertEqual(model.visibleFindings(in: .developer).map(\.id), [image.id])
    }
}
