import XCTest
@testable import DebrisCore

/// Phase 6 engine: config validation, eligibility, preconditions, deferral
/// bookkeeping and the Trash-only run path (S2, S3, S9).
final class AutoCleanTests: XCTestCase {

    private var home: URL!
    private var dataDir: URL!
    private var history: HistoryStore!
    private var catalogue: Catalogue!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("debris-autoclean-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        dataDir = base.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        history = try HistoryStore(databaseURL: dataDir.appendingPathComponent("history.sqlite"))
        catalogue = try Catalogue.bundled()
    }

    override func tearDownWithError() throws {
        // Anything a test moved to the real Trash gets removed.
        if let history {
            for run in try history.runs() {
                for item in try history.items(runId: run.id) where item.status == .done {
                    if let trash = item.trashURL {
                        try? FileManager.default.removeItem(atPath: trash)
                    }
                }
            }
        }
        if let home { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }
        history = nil
        home = nil
        dataDir = nil
    }

    // MARK: - Helpers

    @discardableResult
    private func makeFile(_ relative: String, bytes: Int = 4096, daysAgo: Double = 0) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
        if daysAgo > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-daysAgo * 86_400)],
                ofItemAtPath: url.path)
        }
        return url
    }

    private func makeRunner(
        config: AutoCleanConfig,
        preconditions: AutoCleanPreconditions = AutoCleanPreconditions(
            onACPowerOrCharged: { true },
            noFullScreenApp: { true },
            noTimeMachineBackup: { true },
            volumeHealthy: { true }),
        freeSpaceBytes: (() -> Int64)? = nil
    ) throws -> AutoCleanRunner {
        try AutoCleanRunner(
            config: config,
            catalogue: catalogue,
            history: history,
            preconditions: preconditions,
            scope: ScanScope(roots: [home]),
            home: home,
            protectedPaths: ProtectedPaths(home: home),
            lockURL: dataDir.appendingPathComponent("run.lock"),
            stateURL: dataDir.appendingPathComponent("autoclean-state.json"),
            freeSpaceBytes: freeSpaceBytes,
            runningApplications: { [] })
    }

    // MARK: - Config & eligibility (S2, S9)

    func testValidatorStripsIneligibleRuleIds() {
        let config = AutoCleanConfig(enabledRuleIds: [
            "logs.general", "duplicates.identical", "largeold.files",
            "dev.xcode.archives", "trash.user", "no.such.rule",
        ])
        XCTAssertEqual(config.validated(against: catalogue).enabledRuleIds, ["logs.general"])
    }

    func testCatalogueMarksManualCategoriesIneligible() throws {
        for id in ["duplicates.identical", "largeold.files", "dev.xcode.archives"] {
            let rule = try XCTUnwrap(catalogue.rules.first { $0.id == id }, id)
            XCTAssertFalse(rule.autoCleanEligible, "\(id) must never be Auto Clean eligible")
        }
        // Belt and braces: no rule in those categories is eligible either.
        for rule in catalogue.rules
        where rule.category == .duplicates || rule.category == .largeOld {
            XCTAssertFalse(rule.autoCleanEligible, rule.id)
        }
    }

    func testDefaultsAreOffAndEmpty() {
        let config = AutoCleanConfig()
        XCTAssertFalse(config.enabled)
        XCTAssertTrue(config.enabledRuleIds.isEmpty, "nothing ticked until the user ticks it (S9)")
    }

    func testConfigRoundTripAndCorruptFileFallsBackToDefaults() throws {
        let url = dataDir.appendingPathComponent("settings.json")
        var config = AutoCleanConfig(enabledRuleIds: ["logs.general"])
        config.enabled = true
        config.lowSpaceTriggerGB = 20
        config.notify = .overOneGB
        try config.save(to: url)
        XCTAssertEqual(AutoCleanConfig.load(from: url), config)

        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(AutoCleanConfig.load(from: url), AutoCleanConfig())
    }

    /// Phase 7B: the privacy acknowledgement rides in settings.json; an older
    /// file without it still loads (decodeIfPresent), and it round-trips.
    func testPrivacyAcknowledgementRoundTripAndOlderFileLoads() throws {
        let url = dataDir.appendingPathComponent("settings.json")
        var config = AutoCleanConfig()
        config.privacyAcknowledgement = PrivacyAcknowledgement(
            textHash: "abc123", acknowledgedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try config.save(to: url)
        XCTAssertEqual(AutoCleanConfig.load(from: url), config)

        try Data(#"{"enabled": true}"#.utf8).write(to: url)
        let older = AutoCleanConfig.load(from: url)
        XCTAssertTrue(older.enabled)
        XCTAssertNil(older.privacyAcknowledgement)
    }

    func testBrowserCachesSubOptionStripsBrowserRules() {
        var config = AutoCleanConfig(enabledRuleIds: catalogue.rules
            .filter { $0.autoCleanEligible && $0.category == .appCaches }
            .map(\.id))
        config.browserCachesExcluded = true
        let effective = config.effectiveRuleIds(catalogue: catalogue)
        XCTAssertFalse(effective.isEmpty)
        XCTAssertFalse(effective.contains { $0.hasPrefix("appcaches.browser.") })
    }

    // MARK: - Trash-only (S3, reaffirming the Phase 3 type assertion)

    func testAutoCleanRequestIsTrashOnlyByConstruction() {
        XCTAssertEqual(CleanRequest.autoClean.mode, .auto)
        XCTAssertEqual(CleanRequest.autoClean.disposal, .trash)
    }

    // MARK: - Preconditions

    func testEachPreconditionDefersWithItsReason() async throws {
        let untouched = try makeFile("Library/Logs/old.log", daysAgo: 30)
        let cases: [(AutoCleanPreconditions, AutoCleanDeferralReason)] = [
            (AutoCleanPreconditions(onACPowerOrCharged: { false }, noFullScreenApp: { true },
                                    noTimeMachineBackup: { true }, volumeHealthy: { true }),
             .onBattery),
            (AutoCleanPreconditions(onACPowerOrCharged: { true }, noFullScreenApp: { false },
                                    noTimeMachineBackup: { true }, volumeHealthy: { true }),
             .fullScreenApp),
            (AutoCleanPreconditions(onACPowerOrCharged: { true }, noFullScreenApp: { true },
                                    noTimeMachineBackup: { false }, volumeHealthy: { true }),
             .timeMachineBackup),
            (AutoCleanPreconditions(onACPowerOrCharged: { true }, noFullScreenApp: { true },
                                    noTimeMachineBackup: { true }, volumeHealthy: { false }),
             .volumeUnavailable),
        ]
        for (preconditions, expected) in cases {
            // Fresh state file per case so gaveUp stays false.
            try? FileManager.default.removeItem(
                at: dataDir.appendingPathComponent("autoclean-state.json"))
            let runner = try makeRunner(
                config: AutoCleanConfig(enabledRuleIds: ["logs.general"]),
                preconditions: preconditions)
            let outcome = try await runner.run(reason: .scheduled)
            XCTAssertEqual(outcome, .deferred(expected, gaveUp: false))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.path),
                      "a deferred run must not touch files")
        XCTAssertTrue(try history.runs().isEmpty, "a deferred run writes no History row")
    }

    func testHeldLockDefersAnotherRunActive() async throws {
        let lock = try XCTUnwrap(RunLock.acquire(at: dataDir.appendingPathComponent("run.lock")))
        defer { lock.release() }
        let runner = try makeRunner(config: AutoCleanConfig(enabledRuleIds: ["logs.general"]))
        let outcome = try await runner.run(reason: .scheduled)
        XCTAssertEqual(outcome, .deferred(.anotherRunActive, gaveUp: false))
    }

    // MARK: - Retry window (give up after 24 h)

    func testDeferralsGiveUpAfter24HoursAndWriteSkippedNote() async throws {
        let onBattery = AutoCleanPreconditions(
            onACPowerOrCharged: { false }, noFullScreenApp: { true },
            noTimeMachineBackup: { true }, volumeHealthy: { true })
        let runner = try makeRunner(
            config: AutoCleanConfig(enabledRuleIds: ["logs.general"]),
            preconditions: onBattery)

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for hours in [0.0, 1, 23.9] {
            let outcome = try await runner.run(reason: .scheduled, now: t0.addingTimeInterval(hours * 3600))
            XCTAssertEqual(outcome, .deferred(.onBattery, gaveUp: false))
        }
        let gaveUp = try await runner.run(reason: .scheduled, now: t0.addingTimeInterval(25 * 3600))
        XCTAssertEqual(gaveUp, .deferred(.onBattery, gaveUp: true))

        let runs = try history.runs()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].mode, .auto)
        XCTAssertEqual(runs[0].status, .skipped)
        XCTAssertEqual(runs[0].note, "Skipped: on battery power")
        XCTAssertTrue(try history.items(runId: runs[0].id).isEmpty)

        // Giving up resets the clock: the next deferral starts a new window.
        let next = try await runner.run(reason: .scheduled, now: t0.addingTimeInterval(26 * 3600))
        XCTAssertEqual(next, .deferred(.onBattery, gaveUp: false))
        XCTAssertEqual(try history.runs().count, 1)
    }

    // MARK: - Run path (S2: only ticked + eligible rules; S3: Trash only)

    func testSuccessfulRunCleansOnlyTickedRulesAndWritesAutoHistory() async throws {
        let oldLog = try makeFile("Library/Logs/old.log", bytes: 8192, daysAgo: 30)
        let newLog = try makeFile("Library/Logs/new.log", daysAgo: 1) // too young for the rule
        let cache = try makeFile("Library/Caches/com.example.demo/blob", bytes: 500_000) // not ticked

        let runner = try makeRunner(config: AutoCleanConfig(enabledRuleIds: ["logs.general"]))
        let outcome = try await runner.run(reason: .manual)

        guard case .completed(let runId, let movedBytes, let itemCount) = outcome else {
            return XCTFail("expected .completed, got \(outcome)")
        }
        XCTAssertEqual(itemCount, 1)
        XCTAssertGreaterThan(movedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLog.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newLog.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path),
                      "an unticked category must never be cleaned (S2)")

        let run = try XCTUnwrap(history.run(runId))
        XCTAssertEqual(run.mode, .auto)
        XCTAssertEqual(run.disposal, .trash, "Auto Clean is Trash-only (S3)")
        XCTAssertEqual(run.status, .completed)
        let items = try history.items(runId: runId)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].originalPath, oldLog.path)
        XCTAssertEqual(items[0].status, .done)
        let trashURL = try XCTUnwrap(items[0].trashURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL), "in the Trash, not gone")

        // Undo works on the auto run (S5).
        let executor = Executor(history: history, protectedPaths: ProtectedPaths(home: home))
        let restore = try await executor.restore(runId: runId)
        XCTAssertEqual(restore.restoredCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldLog.path))
    }

    func testEmptyTickListCleansNothingButStillWritesTheRun() async throws {
        let untouched = try makeFile("Library/Logs/old.log", daysAgo: 30)
        let runner = try makeRunner(config: AutoCleanConfig())
        let outcome = try await runner.run(reason: .manual)
        guard case .completed(let runId, let movedBytes, let itemCount) = outcome else {
            return XCTFail("expected .completed, got \(outcome)")
        }
        XCTAssertEqual(itemCount, 0)
        XCTAssertEqual(movedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.path))
        XCTAssertEqual(try history.run(runId)?.mode, .auto)
    }

    // MARK: - Low-space trigger

    func testLowSpaceAboveThresholdIsNotNeeded() async throws {
        var config = AutoCleanConfig(enabledRuleIds: ["logs.general"])
        config.lowSpaceTriggerGB = 10
        let runner = try makeRunner(config: config, freeSpaceBytes: { 100_000_000_000 })
        let outcome = try await runner.run(reason: .lowSpace)
        XCTAssertEqual(outcome, .notNeeded)
        XCTAssertTrue(try history.runs().isEmpty)
    }

    func testLowSpaceBelowThresholdProceedsToPreconditions() async throws {
        var config = AutoCleanConfig(enabledRuleIds: ["logs.general"])
        config.lowSpaceTriggerGB = 10
        let onBattery = AutoCleanPreconditions(
            onACPowerOrCharged: { false }, noFullScreenApp: { true },
            noTimeMachineBackup: { true }, volumeHealthy: { true })
        let runner = try makeRunner(config: config, preconditions: onBattery,
                                    freeSpaceBytes: { 5_000_000_000 })
        let outcome = try await runner.run(reason: .lowSpace)
        XCTAssertEqual(outcome, .deferred(.onBattery, gaveUp: false))
    }
}
