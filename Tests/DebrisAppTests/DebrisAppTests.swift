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
            catalogue: Catalogue(version: 1, rules: []))
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
}
