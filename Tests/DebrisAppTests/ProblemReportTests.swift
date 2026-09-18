import XCTest
@testable import DebrisCore
@testable import DataDebris

/// The report shows paths and sizes from the last run and the plan state,
/// never hashes, the key, machine ids or an email address the user did not
/// type themselves.
final class ProblemReportTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProblemReportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func historyWithRun(hash: String) throws -> HistoryStore {
        let history = try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite"))
        let item = PlanItem(
            originalPath: "/Users/sam/Library/Caches/com.example.app/blob.bin",
            size: 4_000, allocatedSize: 4_096, mtime: 0, inode: 7, volumeUUID: "vol-uuid-1",
            hash: hash, ruleId: "appcaches.example", ownerBundleId: "com.example.app",
            isDirectory: false, requiresPermanent: false)
        let runId = try history.createRun(request: .manual(), estimatedBytes: 4_096,
                                          volumeFreeBefore: 1, items: [item])
        let itemId = try history.items(runId: runId)[0].id
        try history.markItem(itemId, status: .done, trashURL: "/Users/sam/.Trash/blob.bin", movedAt: Date())
        try history.finishRun(runId, status: .completed, movedBytes: 4_096, freedBytes: 0,
                              volumeFreeAfter: 1)
        return history
    }

    func testJournalHasPathsAndSizesOnly() throws {
        let hash = "deadbeefcafef00d0123456789abcdef0123456789abcdef0123456789abcdef"
        let history = try historyWithRun(hash: hash)
        let active = EntitlementState.active(
            plan: .oneYear, expiresAt: Date(timeIntervalSince1970: 1_800_000_000), autoRenew: true,
            machines: [LicensedMachine(id: "machine-id-secret", name: "Sam's MacBook", activatedAt: 1_700_000_000)])
        let report = ProblemReport.gather(kind: .problem, history: history, entitlement: active,
                                          fdaGranted: false, macOSVersion: "Version 26.0 (Build 25A5)",
                                          appVersion: "1.0 (1)")
        let text = report.text()

        XCTAssertTrue(text.contains("/Users/sam/Library/Caches/com.example.app/blob.bin"))
        XCTAssertTrue(text.contains("4 KB"), text)
        XCTAssertTrue(text.contains("Full Disk Access: Not granted"))
        XCTAssertTrue(text.contains("macOS: Version 26.0 (Build 25A5)"))
        XCTAssertTrue(text.contains("App: 1.0 (1)"))
        XCTAssertTrue(text.contains("Plan: Active, 1 Year"))

        XCTAssertFalse(text.contains(hash), "no hashes")
        XCTAssertFalse(text.contains("deadbeef"), "no hash fragments")
        XCTAssertFalse(text.contains(".Trash"), "no Trash locations")
        XCTAssertFalse(text.contains("vol-uuid-1"), "no volume ids")
        XCTAssertFalse(text.contains("machine-id-secret"), "no machine ids")
        XCTAssertFalse(text.contains("Sam's MacBook"), "no machine names")
        XCTAssertFalse(text.contains("@"), "no email address unless the user typed one")
    }

    func testLicenseKeyNeverAppears() throws {
        let history = try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite"))
        let store = LicenseFixture.activeStore()
        let key = try XCTUnwrap(store.load()?.stored.licenseKey)
        XCTAssertFalse(key.isEmpty)
        let state = Entitlements(store: store, clock: LicenseFixture.clock()).state
        let report = ProblemReport.gather(kind: .problem, history: history, entitlement: state,
                                          fdaGranted: true)
        let text = report.text()
        XCTAssertFalse(text.contains(key))
        XCTAssertFalse(text.contains(String(key.suffix(4))), "not even the last four")
        XCTAssertTrue(text.contains("Last run: none yet"))
        XCTAssertTrue(text.contains("(not filled in)"))
    }

    func testUserTextIsTheOnlyFreeText() throws {
        let history = try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite"))
        var report = ProblemReport.gather(kind: .betaFeedback, history: history, entitlement: .free,
                                          fdaGranted: true)
        report.description = "Reach me at sam@example.test"
        let text = report.text()
        XCTAssertTrue(text.hasPrefix("Data Debris beta feedback"))
        XCTAssertTrue(text.contains("Feedback:\nReach me at sam@example.test"))
        XCTAssertEqual(text.components(separatedBy: "@").count - 1, 1, "only the typed address")
    }

    func testLongJournalsAreCapped() throws {
        let history = try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite"))
        let items = (0..<(ProblemReport.journalLimit + 5)).map { index in
            PlanItem(originalPath: "/Users/sam/tmp/file-\(index)", size: 1, allocatedSize: 1, mtime: 0,
                     inode: UInt64(index), volumeUUID: "", hash: nil, ruleId: "r", ownerBundleId: nil,
                     isDirectory: false, requiresPermanent: false)
        }
        _ = try history.createRun(request: .manual(), estimatedBytes: 0, volumeFreeBefore: 0, items: items)
        let run = try XCTUnwrap(ProblemReport.lastRun(from: history))
        XCTAssertEqual(run.entries.count, ProblemReport.journalLimit)
        XCTAssertEqual(run.omitted, 5)
        XCTAssertTrue(ProblemReport.gather(kind: .problem, history: history, entitlement: .free,
                                           fdaGranted: true).text().contains("… and 5 more"))
    }

    func testPlanDescriptionsCarryNoIdentifiers() {
        XCTAssertEqual(ProblemReport.planDescription(.free), "Free")
        XCTAssertEqual(ProblemReport.planDescription(.pastDue), "Past due")
        XCTAssertTrue(ProblemReport.planDescription(.expiring(daysLeft: 3)).contains("3 days"))
    }
}
