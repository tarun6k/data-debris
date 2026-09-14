import XCTest
@testable import DebrisCore

final class ScanPipelineTests: XCTestCase {

    private var home: URL!

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
        home = nil
    }

    private func makePipeline(exclusions: ExclusionStore? = nil) throws -> (ScanRunner, FindingsStore) {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("debris-test-\(UUID().uuidString).sqlite")
        let store = try FindingsStore(databaseURL: dbURL)
        let runner = ScanRunner(
            scope: ScanScope(roots: [home]),
            catalogue: try Catalogue.bundled(),
            store: store,
            exclusions: exclusions,
            protectedPaths: ProtectedPaths(home: home),
            home: home)
        return (runner, store)
    }

    private func finding(_ findings: [Finding], _ ruleId: String, _ pathSuffix: String) -> Finding? {
        findings.first { $0.ruleId == ruleId && $0.url.path.hasSuffix(pathSuffix) }
    }

    private func scanned(_ runner: ScanRunner, _ store: FindingsStore) async throws -> [Finding] {
        _ = try await runner.run()
        let scan = try XCTUnwrap(store.lastScan())
        return try store.findings(in: scan.id)
    }

    // MARK: - Findings and traps

    func testExpectedFindingsWithLevelsAndCategories() async throws {
        home = try SyntheticHome.build()
        let (runner, store) = try makePipeline()
        let result = try await runner.run()
        let findings = try store.findings(in: result.scanId)

        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(try XCTUnwrap(store.lastScan()).status, .complete)

        let generic = try XCTUnwrap(finding(findings, "appcaches.generic", "Library/Caches/com.example.demo"))
        XCTAssertEqual(generic.category, .appCaches)
        XCTAssertEqual(generic.level, .safe)
        XCTAssertEqual(generic.size, 5_000_000)

        let chrome = try XCTUnwrap(finding(findings, "appcaches.browser.chrome", "Chrome/Default/Cache"))
        XCTAssertEqual(chrome.size, 1_000_000)

        let log = try XCTUnwrap(finding(findings, "logs.general", "Library/Logs/old.log"))
        XCTAssertEqual(log.category, .logs)
        XCTAssertEqual(log.level, .safe)

        let derived = try XCTUnwrap(finding(findings, "dev.xcode.deriveddata", "DerivedData/Proj-abc"))
        XCTAssertEqual(derived.level, .safe)
        XCTAssertEqual(derived.size, 300_000)

        let nodeModules = try XCTUnwrap(finding(findings, "dev.projectbuild", "code/proj/node_modules"))
        XCTAssertEqual(nodeModules.level, .review)
        XCTAssertEqual(nodeModules.size, 50_000)

        XCTAssertEqual(try XCTUnwrap(finding(findings, "trash.user", ".Trash/old.zip")).level, .safe)

        let large = try XCTUnwrap(finding(findings, "largeold.files", "big/dataset.bin"))
        XCTAssertEqual(large.level, .manual)
        XCTAssertEqual(large.size, 600_000_000)
        XCTAssertTrue(large.isReclaimable)
        XCTAssertEqual(large.reason, "Large file not opened in 6 months")
    }

    func testTrapsAreAbsent() async throws {
        home = try SyntheticHome.build()
        let (runner, store) = try makePipeline()
        let findings = try await scanned(runner, store)

        XCTAssertFalse(findings.contains { $0.url.path.hasSuffix("Cookies") })
        XCTAssertFalse(findings.contains { $0.url.path.hasSuffix("Library/Caches/Google") })
        XCTAssertFalse(findings.contains { $0.url.path.contains("Application Support") })
        XCTAssertFalse(findings.contains { $0.url.path.hasSuffix("new.log") })
        XCTAssertFalse(findings.contains { $0.url.path.contains("/src") })
        XCTAssertFalse(findings.contains { $0.url.path.hasSuffix("system-link") })

        // Exactly: generic, chrome, old.log, deriveddata, node_modules,
        // trash, dataset.bin, link-a, link-b.
        XCTAssertEqual(findings.count, 9)
    }

    // MARK: - Reclaimability (S10)

    func testHardLinksAreFoundButNotReclaimable() async throws {
        home = try SyntheticHome.build()
        let (runner, store) = try makePipeline()
        let findings = try await scanned(runner, store)

        let linkA = try XCTUnwrap(finding(findings, "largeold.files", "linked/link-a"))
        let linkB = try XCTUnwrap(finding(findings, "largeold.files", "linked/link-b"))
        XCTAssertFalse(linkA.isReclaimable)
        XCTAssertFalse(linkB.isReclaimable)

        // Not-reclaimable items never contribute to totals or selection.
        XCTAssertEqual(try store.totals()[.largeOld]?.count, 1)
        XCTAssertNil(try store.isSelected(linkA.id))
    }

    func testCloudPlaceholderIsNotReclaimable() throws {
        let analyzer = LargeOldAnalyzer(thresholds: Thresholds(), catalogue: try Catalogue.bundled())
        let record = FileRecord(
            url: URL(fileURLWithPath: "/Users/someone/big.bin"),
            size: 600_000_000,
            mtime: Date(timeIntervalSinceNow: -200 * 86_400),
            lastOpened: Date(timeIntervalSinceNow: -200 * 86_400),
            isCloudPlaceholder: true)
        let finding = try XCTUnwrap(analyzer.process(record))
        XCTAssertFalse(finding.isReclaimable)
    }

    // MARK: - Totals

    func testTotalsByCategory() async throws {
        home = try SyntheticHome.build()
        let (runner, store) = try makePipeline()
        let result = try await runner.run()
        let totals = try store.totals()

        XCTAssertEqual(totals[.appCaches]?.count, 2)
        XCTAssertGreaterThanOrEqual(totals[.appCaches]?.bytes ?? 0, 6_000_000)
        XCTAssertEqual(totals[.logs]?.count, 1)
        XCTAssertEqual(totals[.developer]?.count, 2)
        XCTAssertEqual(totals[.trash]?.count, 1)
        XCTAssertEqual(totals[.largeOld]?.count, 1)
        XCTAssertNil(totals[.duplicates])

        // Cross-check against the stored findings (allocated bytes, S10).
        let findings = try store.findings(in: result.scanId)
        for (category, total) in totals {
            let expected = findings
                .filter { $0.category == category && $0.isReclaimable }
                .reduce(Int64(0)) { $0 + $1.allocatedSize }
            XCTAssertEqual(total.bytes, expected, "\(category)")
        }

        XCTAssertEqual(result.trashCount, 1)
        XCTAssertGreaterThanOrEqual(result.trashBytes, 2_000_000)
    }

    // MARK: - Selection defaults (S2)

    func testDefaultSelectionAndCategoryStates() async throws {
        home = try SyntheticHome.build()
        let (runner, store) = try makePipeline()
        let findings = try await scanned(runner, store)

        let generic = try XCTUnwrap(finding(findings, "appcaches.generic", "com.example.demo"))
        let nodeModules = try XCTUnwrap(finding(findings, "dev.projectbuild", "node_modules"))
        let large = try XCTUnwrap(finding(findings, "largeold.files", "dataset.bin"))

        XCTAssertEqual(try store.isSelected(generic.id), true)      // safe
        XCTAssertEqual(try store.isSelected(nodeModules.id), false) // review
        XCTAssertEqual(try store.isSelected(large.id), false)       // manual

        XCTAssertEqual(try store.categoryState(.appCaches), .all)
        XCTAssertEqual(try store.categoryState(.logs), .all)
        XCTAssertEqual(try store.categoryState(.trash), .all)
        XCTAssertEqual(try store.categoryState(.developer), .some) // safe + review mix
        XCTAssertEqual(try store.categoryState(.largeOld), .none)

        // generic, chrome, old.log, deriveddata, trash = the safe five.
        XCTAssertEqual(try store.selectedTotals().count, 5)
    }

    func testSetSelectedAndSetCategory() async throws {
        home = try SyntheticHome.build()
        let (runner, store) = try makePipeline()
        let findings = try await scanned(runner, store)

        let generic = try XCTUnwrap(finding(findings, "appcaches.generic", "com.example.demo"))
        let nodeModules = try XCTUnwrap(finding(findings, "dev.projectbuild", "node_modules"))
        let linkA = try XCTUnwrap(finding(findings, "largeold.files", "link-a"))

        try store.setSelected([nodeModules.id], true)
        XCTAssertEqual(try store.isSelected(nodeModules.id), true)
        XCTAssertEqual(try store.categoryState(.developer), .all)

        // Non-reclaimable selection must never be created (S10).
        try store.setSelected([linkA.id], true)
        XCTAssertNil(try store.isSelected(linkA.id))

        try store.setCategory(.appCaches, state: .none)
        XCTAssertEqual(try store.categoryState(.appCaches), .none)
        XCTAssertEqual(try store.isSelected(generic.id), false)

        // 5 safe defaults − 2 app caches + 1 node_modules.
        XCTAssertEqual(try store.selectedTotals().count, 4)
    }

    // MARK: - Cancellation

    func testCancelMidScanKeepsPartialFindings() async throws {
        home = try SyntheticHome.build(bulkLogs: 300)
        let (runner, store) = try makePipeline()

        let result = try await runner.run { progress in
            if progress.findingCount >= 10 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        XCTAssertEqual(result.status, .cancelled)
        let scan = try XCTUnwrap(store.lastScan())
        XCTAssertEqual(scan.status, .cancelled)
        let findings = try store.findings(in: scan.id)
        XCTAssertGreaterThan(findings.count, 0)
        XCTAssertLessThan(findings.count, 300)
    }

    // MARK: - Exclusions

    func testExclusionRemovesFindingOnRescan() async throws {
        home = try SyntheticHome.build()
        let exclusionsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("debris-excl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: exclusionsURL) }
        let exclusions = try ExclusionStore(fileURL: exclusionsURL)
        let (runner, store) = try makePipeline(exclusions: exclusions)

        let first = try await scanned(runner, store)
        XCTAssertNotNil(finding(first, "appcaches.generic", "com.example.demo"))

        try exclusions.addFolder(home.appendingPathComponent("Library/Caches/com.example.demo").path)
        let second = try await scanned(runner, store)

        XCTAssertNil(finding(second, "appcaches.generic", "com.example.demo"))
        XCTAssertEqual(try store.totals()[.appCaches]?.count, 1) // Chrome cache remains
    }
}
