import XCTest
import DebrisCore
@testable import DataDebris

/// Model-level tests for Screen 5: the Keep badge is structural (S7), the
/// selection guard, and "Apply rule to all".
final class DuplicatesViewTests: XCTestCase {

    @MainActor
    private func makeModel() throws -> (AppModel, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicatesViewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(
            store: try FindingsStore(databaseURL: dir.appendingPathComponent("findings.sqlite")),
            history: try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite")),
            exclusions: try ExclusionStore(fileURL: dir.appendingPathComponent("exclusions.json")),
            catalogue: Catalogue(version: 1, rules: []))
        return (model, dir)
    }

    @MainActor
    private func copy(_ model: AppModel, _ relative: String, alloc: Int64, daysAgo: Double) -> DuplicateCopy {
        let url = model.home.appendingPathComponent(relative)
        return DuplicateCopy(
            url: url, mtime: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400),
            size: alloc, allocatedSize: alloc,
            location: HomeLocation.classify(url, home: model.home))
    }

    /// Seeds one scan with the groups persisted the way ScanRunner does it.
    @MainActor
    private func seed(_ model: AppModel, groups: [DuplicateGroup]) throws {
        let scanId = try model.store.beginScan()
        try model.store.saveDuplicates(groups, clonePairs: 0, status: "done", scanId: scanId)
        try model.store.upsert(groups.flatMap { $0.findings(home: model.home) }, scanId: scanId)
        try model.store.finishScan(scanId, status: .complete, deniedCount: 0)
        model.refresh()
    }

    @MainActor
    func testKeepBadgeCanNeverBeRemoved() throws {
        let (model, dir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }

        let keeperCopy = copy(model, "Pictures/dup-test/a.jpg", alloc: 100, daysAgo: 300)
        let other = copy(model, "Downloads/dup-test/a.jpg", alloc: 100, daysAgo: 10)
        let group = try XCTUnwrap(DuplicateGroup(hash: "g1", copies: [keeperCopy, other]))
        try seed(model, groups: [group])

        let loaded = try XCTUnwrap(model.duplicateGroups.first)
        XCTAssertEqual(loaded.keeperId, keeperCopy.findingId, "canonical keeper is Pictures")

        // The keeper has no Finding, so nothing upstream can list or pick it…
        XCTAssertFalse(model.findings.contains { $0.id == keeperCopy.findingId })
        // …the guard refuses it anyway…
        XCTAssertFalse(model.canSelectDuplicate(keeperCopy, in: loaded))
        // …and forcing it through the store is a no-op (no findings row).
        try model.store.setSelected([keeperCopy.findingId], true)
        model.refresh()
        XCTAssertFalse(model.selectedIds.contains(keeperCopy.findingId))
    }

    @MainActor
    func testSelectionGuardAlwaysLeavesOneCopy() throws {
        let (model, dir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }

        let keeperCopy = copy(model, "Pictures/dup-test/b.jpg", alloc: 100, daysAgo: 300)
        let otherA = copy(model, "Downloads/dup-test/b.jpg", alloc: 100, daysAgo: 10)
        let otherB = copy(model, "Desktop/dup-test/b.jpg", alloc: 100, daysAgo: 100)
        let group = try XCTUnwrap(DuplicateGroup(hash: "g2", copies: [keeperCopy, otherA, otherB]))
        try seed(model, groups: [group])
        let loaded = try XCTUnwrap(model.duplicateGroups.first)

        // Every non-keeper can be ticked: the keeper always survives (S7).
        for other in loaded.others {
            XCTAssertTrue(model.canSelectDuplicate(other, in: loaded))
            model.toggleDuplicate(other, in: loaded)
        }
        XCTAssertEqual(model.selectedIds.count, 2)
        // Ticking never reaches the keeper, so one copy is always unselected.
        XCTAssertFalse(model.selectedIds.contains(loaded.keeperId))
        XCTAssertFalse(model.canSelectDuplicate(loaded.keeper, in: loaded))

        // Untick works and is never blocked.
        model.toggleDuplicate(loaded.others[0], in: loaded)
        XCTAssertEqual(model.selectedIds.count, 1)
    }

    @MainActor
    func testApplyRuleToAllMovesKeepersAndUpdatesReclaimable() throws {
        let (model, dir) = try makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }

        // In each group the newest copy is bigger on disk, so moving the
        // keeper to it shrinks the reclaimable total.
        let g1 = try XCTUnwrap(DuplicateGroup(hash: "g3", copies: [
            copy(model, "Pictures/dup-test/c.jpg", alloc: 100, daysAgo: 300),
            copy(model, "Downloads/dup-test/c.jpg", alloc: 200, daysAgo: 10),
        ]))
        let g2 = try XCTUnwrap(DuplicateGroup(hash: "g4", copies: [
            copy(model, "Documents/dup-test/d.pdf", alloc: 300, daysAgo: 300),
            copy(model, "Desktop/dup-test/d.pdf", alloc: 400, daysAgo: 10),
        ]))
        try seed(model, groups: [g1, g2])

        XCTAssertEqual(model.duplicateReclaimableBytes, 200 + 400)
        XCTAssertEqual(model.groupsAffected(by: .newest), 2)
        XCTAssertEqual(model.groupsAffected(by: .canonical), 0, "already the canonical keepers")

        model.applyKeeperRule(.newest)

        XCTAssertEqual(model.duplicateReclaimableBytes, 100 + 300)
        XCTAssertEqual(model.groupsAffected(by: .newest), 0)
        for group in model.duplicateGroups {
            XCTAssertEqual(group.keeper.mtime, group.copies.map(\.mtime).max())
        }
        // The findings swapped sides: old keepers are removable now, new
        // keepers are not.
        let dupFindings = model.findings.filter { $0.category == .duplicates }
        XCTAssertEqual(dupFindings.count, 2)
        for group in model.duplicateGroups {
            XCTAssertFalse(dupFindings.contains { $0.id == group.keeperId })
        }

        // Undo puts every keeper back and restores the total.
        XCTAssertEqual(model.lastKeeperBatch?.previousKeepers.count, 2)
        model.undoKeeperBatch()
        XCTAssertEqual(model.duplicateReclaimableBytes, 200 + 400)
        XCTAssertEqual(model.groupsAffected(by: .newest), 2)
        XCTAssertNil(model.lastKeeperBatch)
    }
}
