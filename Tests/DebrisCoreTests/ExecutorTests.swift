import XCTest
@testable import DebrisCore

final class ExecutorTests: XCTestCase {

    private var home: URL!
    private var history: HistoryStore!
    private var dbURL: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("debris-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("work"), withIntermediateDirectories: true)
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("debris-history-\(UUID().uuidString).sqlite")
        history = try HistoryStore(databaseURL: dbURL)
    }

    override func tearDownWithError() throws {
        // Anything a test left in the real Trash gets removed.
        if let history {
            for run in try history.runs() {
                for item in try history.items(runId: run.id) where item.status == .done {
                    if let trash = item.trashURL {
                        try? FileManager.default.removeItem(atPath: trash)
                    }
                }
            }
        }
        if let home { try? FileManager.default.removeItem(at: home) }
        if let dbURL {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(atPath: dbURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: dbURL.path + "-shm")
        }
        history = nil
        home = nil
        dbURL = nil
    }

    // MARK: - Helpers

    private struct StatFailed: Error {}

    @discardableResult
    private func makeFile(_ name: String, bytes: Int = 1024) throws -> URL {
        let url = home.appendingPathComponent("work/\(name)")
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    /// A synthetic Finding whose size/mtime come from lstat, exactly like the
    /// executor's re-verification will read them.
    private func finding(
        for url: URL, ruleId: String = "logs.general", owner: String? = nil
    ) throws -> Finding {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw StatFailed() }
        let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
        let size = isDirectory ? Int64(0) : Int64(st.st_size)
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return Finding(
            ruleId: ruleId, url: url, size: size, allocatedSize: size,
            mtime: Date(timeIntervalSince1970: mtime), lastOpened: nil,
            level: .safe, category: .logs, reason: "test",
            consequence: "Consequence for \(ruleId)", ownerBundleId: owner)
    }

    private func plan(_ findings: [Finding], request: CleanRequest = .manual()) -> CleanPlan {
        Planner(runningApplications: { [] }).plan(selection: findings, request: request)
    }

    private func makeExecutor() -> Executor {
        Executor(history: history, protectedPaths: ProtectedPaths(home: home))
    }

    // MARK: - Planner

    func testPlannerDropsVanishedDedupesNoticesAndFindsConflicts() throws {
        let a = try makeFile("p-a.log")
        let b = try makeFile("p-b.log", bytes: 2048)
        let ghostURL = try makeFile("ghost.log", bytes: 10)
        let ghost = try finding(for: ghostURL)
        try FileManager.default.removeItem(at: ghostURL)

        let planner = Planner(runningApplications: {
            [RunningAppInfo(bundleId: "com.example.owner", name: "Owner App")]
        })
        let plan = planner.plan(
            selection: [try finding(for: b, owner: "com.example.owner"), try finding(for: a), ghost],
            request: .manual())

        XCTAssertEqual(plan.items.map(\.originalPath), [a.path, b.path]) // vanished dropped, sorted
        XCTAssertEqual(plan.estimatedBytes, 1024 + 2048)
        XCTAssertEqual(plan.notices.count, 1) // one rule, one notice
        XCTAssertEqual(plan.notices[0].ownerAppName, "Owner App")
        XCTAssertEqual(plan.runningAppConflicts, [
            RunningAppConflict(bundleId: "com.example.owner", appName: "Owner App", itemCount: 1),
        ])
        // Boot volume always has a Trash.
        XCTAssertTrue(plan.itemsRequiringPermanent.isEmpty)
        XCTAssertFalse(plan.items[0].isDirectory)
    }

    // MARK: - Round trip (S3, S4, S5)

    func testRoundTripTrashAndRestore() async throws {
        let a = try makeFile("a.log", bytes: 1500)
        let b = try makeFile("b.log", bytes: 2500)
        let originalData = try Data(contentsOf: a)
        let executor = makeExecutor()

        let result = try await executor.execute(
            plan: plan([try finding(for: a), try finding(for: b)]))

        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.doneCount, 2)
        XCTAssertEqual(result.movedBytes, 4000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))

        let items = try history.items(runId: result.runId)
        XCTAssertEqual(items.map(\.status), [.done, .done])
        for item in items {
            let trash = try XCTUnwrap(item.trashURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: trash))
            XCTAssertNotNil(item.movedAt)
        }
        XCTAssertEqual(try history.run(result.runId)?.status, .completed)
        XCTAssertEqual(try history.undoAvailability(runId: result.runId), .available)

        let restore = try await executor.restore(runId: result.runId)
        XCTAssertEqual(restore.restoredCount, 2)
        XCTAssertTrue(restore.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: a), originalData)
        XCTAssertEqual(try history.run(result.runId)?.status, .restored)
        XCTAssertEqual(try history.undoAvailability(runId: result.runId), .unavailable(.alreadyRestored))
    }

    func testRestoreToOccupiedPathAddsSuffix() async throws {
        let file = try makeFile("report.log", bytes: 800)
        let original = try Data(contentsOf: file)
        let executor = makeExecutor()
        let result = try await executor.execute(plan: plan([try finding(for: file)]))
        XCTAssertEqual(result.doneCount, 1)

        try Data("newcomer".utf8).write(to: file) // occupy the original path

        let restore = try await executor.restore(runId: result.runId)
        XCTAssertEqual(restore.restoredCount, 1)
        let restored = home.appendingPathComponent("work/report (restored).log")
        XCTAssertEqual(try Data(contentsOf: restored), original)
        XCTAssertEqual(try Data(contentsOf: file), Data("newcomer".utf8))
    }

    // MARK: - Re-verification at clean time (S6)

    func testChangedFileIsSkipped() async throws {
        let file = try makeFile("c.log")
        let cleanPlan = plan([try finding(for: file)])
        try Data(repeating: 0xCD, count: 2048).write(to: file) // changed after planning

        let result = try await makeExecutor().execute(plan: cleanPlan)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(result.doneCount, 0)
        let item = try history.items(runId: result.runId)[0]
        XCTAssertEqual(item.status, .skipped)
        XCTAssertEqual(item.skipReason, .changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testVanishedFileIsSkipped() async throws {
        let file = try makeFile("v.log")
        let cleanPlan = plan([try finding(for: file)])
        try FileManager.default.removeItem(at: file)

        let result = try await makeExecutor().execute(plan: cleanPlan)
        XCTAssertEqual(result.doneCount, 0)
        XCTAssertEqual(try history.items(runId: result.runId)[0].skipReason, .vanished)
    }

    func testOpenFileIsSkipped() async throws {
        let file = try makeFile("open.log")
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        let result = try await makeExecutor().execute(plan: plan([try finding(for: file)]))
        XCTAssertEqual(result.doneCount, 0)
        let item = try history.items(runId: result.runId)[0]
        XCTAssertEqual(item.status, .skipped)
        guard case .inUse(let name)? = item.skipReason else {
            return XCTFail("expected inUse, got \(String(describing: item.skipReason))")
        }
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Journal before move (S4)

    func testCrashAfterJournalLeavesRunPendingAndRecoverable() async throws {
        let file = try makeFile("crash.log")
        let executor = makeExecutor()
        executor.onJournaled = { throw CocoaError(.fileWriteUnknown) }

        do {
            _ = try await executor.execute(plan: plan([try finding(for: file)]))
            XCTFail("expected execute to rethrow the injected failure")
        } catch {}

        let run = try XCTUnwrap(try history.runs().first)
        XCTAssertEqual(run.status, .pending)
        XCTAssertTrue(try history.items(runId: run.id).allSatisfy { $0.status == .pending })
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) // nothing moved

        // Next-launch recovery pass.
        XCTAssertEqual(try history.recoverInterruptedRuns(), 1)
        XCTAssertEqual(try history.run(run.id)?.status, .cancelled)
        let item = try history.items(runId: run.id)[0]
        XCTAssertEqual(item.status, .skipped)
        XCTAssertEqual(item.skipReason, .cancelled)
    }

    // MARK: - Cancellation

    func testCancelMidRunKeepsEarlierItemsRestorable() async throws {
        var findings: [Finding] = []
        for i in 0..<8 {
            findings.append(try finding(for: try makeFile(String(format: "bulk-%02d.log", i))))
        }
        let executor = makeExecutor()
        let result = try await executor.execute(plan: plan(findings)) { progress in
            if progress.itemsDone == 3 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(result.doneCount, 3)
        let items = try history.items(runId: result.runId)
        XCTAssertEqual(items.filter { $0.status == .done }.count, 3)
        XCTAssertEqual(items.filter { $0.skipReason == .cancelled }.count, 5)
        XCTAssertEqual(try history.undoAvailability(runId: result.runId), .available)

        let restore = try await executor.restore(runId: result.runId)
        XCTAssertEqual(restore.restoredCount, 3)
        XCTAssertEqual(try history.run(result.runId)?.status, .restored)
    }

    // MARK: - Trash by default, permanent only on request (S3)

    func testAutoCleanCannotBePermanent() {
        #if false
        // Must not compile: CleanRequest's init is private, and autoClean has
        // no disposal parameter — auto + permanent is unrepresentable.
        let bad = CleanRequest(mode: .auto, disposal: .permanent)
        #endif
        XCTAssertEqual(CleanRequest.autoClean.mode, .auto)
        XCTAssertEqual(CleanRequest.autoClean.disposal, .trash)
        XCTAssertEqual(CleanRequest.manual().disposal, .trash) // Trash unless asked
        XCTAssertEqual(CleanRequest.smart().disposal, .trash)
    }

    func testPermanentDeleteOnlyWhenRequested() async throws {
        let file = try makeFile("perm.log")
        let result = try await makeExecutor().execute(
            plan: plan([try finding(for: file)], request: .manual(disposal: .permanent)))

        XCTAssertEqual(result.doneCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let item = try history.items(runId: result.runId)[0]
        XCTAssertEqual(item.status, .irreversible)
        XCTAssertNil(item.trashURL)
        XCTAssertEqual(try history.undoAvailability(runId: result.runId), .unavailable(.permanentDelete))

        let restore = try await makeExecutor().restore(runId: result.runId)
        XCTAssertEqual(restore.restoredCount, 0)
    }

    // MARK: - Directory units

    func testDirectoryMovesAndRestoresAsUnit() async throws {
        let dir = home.appendingPathComponent("work/bundle-cache")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: dir.appendingPathComponent("one.bin"))
        try Data(repeating: 2, count: 200).write(to: dir.appendingPathComponent("two.bin"))

        let executor = makeExecutor()
        let cleanPlan = plan([try finding(for: dir, ruleId: "appcaches.generic")])
        XCTAssertTrue(cleanPlan.items[0].isDirectory)

        let result = try await executor.execute(plan: cleanPlan)
        XCTAssertEqual(result.doneCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        let restore = try await executor.restore(runId: result.runId)
        XCTAssertEqual(restore.restoredCount, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("one.bin")), Data(repeating: 1, count: 100))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("two.bin")), Data(repeating: 2, count: 200))
    }

    // MARK: - Skip-by-owner filter

    func testSkipBundleIdsFilterBeforeJournal() async throws {
        let keep = try makeFile("keep.log")
        let skip = try makeFile("skip.log")
        var cleanPlan = plan([
            try finding(for: keep),
            try finding(for: skip, owner: "com.example.owner"),
        ])
        cleanPlan.skipBundleIds = ["com.example.owner"]

        let executor = makeExecutor()
        let result = try await executor.execute(plan: cleanPlan)
        let items = try history.items(runId: result.runId)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].originalPath, keep.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skip.path))
        _ = try await executor.restore(runId: result.runId)
    }

    // MARK: - Retention

    func testRetentionNeverPrunesRestorableRuns() throws {
        let trashStandIn = try makeFile("fake-trashed.log", bytes: 10)
        let item = PlanItem(
            originalPath: home.appendingPathComponent("work/orig.log").path,
            size: 10, allocatedSize: 10, mtime: 0, inode: 1, volumeUUID: "",
            hash: nil, ruleId: "logs.general", ownerBundleId: nil,
            isDirectory: false, requiresPermanent: false)
        let old = Date(timeIntervalSinceNow: -100 * 86_400)
        let runId = try history.createRun(
            request: .manual(), estimatedBytes: 10, volumeFreeBefore: 0,
            items: [item], startedAt: old)
        let itemId = try history.items(runId: runId)[0].id
        try history.markItem(itemId, status: .done, trashURL: trashStandIn.path, movedAt: old)
        try history.finishRun(runId, status: .completed, movedBytes: 10, freedBytes: 0,
                              volumeFreeAfter: 0, finishedAt: old)

        // Old, but its item is still in the Trash: kept.
        XCTAssertEqual(try history.pruneExpiredRuns(olderThanDays: 30), 0)
        XCTAssertNotNil(try history.run(runId))

        // Trash emptied: now prunable.
        try FileManager.default.removeItem(at: trashStandIn)
        XCTAssertEqual(try history.pruneExpiredRuns(olderThanDays: 30), 1)
        XCTAssertNil(try history.run(runId))
        XCTAssertTrue(try history.items(runId: runId).isEmpty) // cascade
    }
}
