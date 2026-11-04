import XCTest
@testable import DebrisCore

/// The Docker rule: parser against the canned `docker system df -v` sample
/// in catalogue-fixtures.json, the "no findings, not an error" conditions,
/// per-object removal, and the S2/S9 guarantees. Docker itself is never
/// required: every test that spawns anything runs a stand-in `docker` script.
final class DockerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("debris-docker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    // MARK: - Fixture and helpers

    private struct Sample {
        let json: Data
        let positives: [(path: String, bytes: Int64)]
        let negatives: [String]
    }

    private func loadSample() throws -> Sample {
        let bundle = Bundle(for: DockerTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "catalogue-fixtures", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let fixtures = try XCTUnwrap(root["fixtures"] as? [[String: Any]])
        let entry = try XCTUnwrap(fixtures.first { $0["ruleID"] as? String == DockerAnalyzer.ruleId })
        let df = try XCTUnwrap(entry["dockerSystemDF"], "fixture needs a dockerSystemDF sample")
        let positives = try XCTUnwrap(entry["positive"] as? [[String: Any]]).map {
            (path: $0["path"] as! String, bytes: ($0["sizeBytes"] as! NSNumber).int64Value)
        }
        let negatives = try XCTUnwrap(entry["negative"] as? [[String: Any]]).map { $0["path"] as! String }
        return Sample(json: try JSONSerialization.data(withJSONObject: df), positives: positives, negatives: negatives)
    }

    private func dockerRule() throws -> Rule {
        try XCTUnwrap(try Catalogue.bundled().rules.first { $0.id == DockerAnalyzer.ruleId })
    }

    private func sampleFindings() throws -> [Finding] {
        try DockerAnalyzer.parse(try loadSample().json, rule: try dockerRule())
    }

    private func makeHistory() throws -> HistoryStore {
        try HistoryStore(databaseURL: tempDir.appendingPathComponent("history-\(UUID().uuidString).sqlite"))
    }

    private func makeStore() throws -> FindingsStore {
        try FindingsStore(databaseURL: tempDir.appendingPathComponent("findings-\(UUID().uuidString).sqlite"))
    }

    private func plan(_ findings: [Finding]) -> CleanPlan {
        Planner(runningApplications: { [] }).plan(selection: findings, request: .manual())
    }

    private struct FakeDocker {
        let cli: DockerCLI
        let log: URL

        /// One line per invocation: the arguments docker was given.
        func calls() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
    }

    private static let contextCall = "context inspect --format {{.Endpoints.docker.Host}}"
    private static let diskUsageCall = "system df -v --format json"

    /// A stand-in `docker`: logs every argv line, answers `context inspect`
    /// with `host`, `system df` with the sample, and removals the way the
    /// real client prints them on success.
    private func fakeDocker(
        host: String = "unix:///var/run/docker.sock",
        df: Data? = nil,
        dfFailure: String = "",
        dfSleep: Int = 0,
        removeFailure: String = "",
        pruneRemovesNothing: Bool = false
    ) throws -> FakeDocker {
        let dir = tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("argv.log")
        let dfFile = dir.appendingPathComponent("df.json")
        try (df ?? Data()).write(to: dfFile)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        case "$1 $2" in
          "context inspect") printf '%s\\n' '\(host)' ;;
          "system df")
            if [ \(dfSleep) -gt 0 ]; then exec sleep \(dfSleep); fi
            if [ -n '\(dfFailure)' ]; then printf '%s\\n' '\(dfFailure)' >&2; exit 1; fi
            cat '\(dfFile.path)' ;;
          "image rm")
            if [ -n '\(removeFailure)' ]; then printf '%s\\n' '\(removeFailure)' >&2; exit 1; fi
            printf 'Deleted: sha256:%s\\n' "$3" ;;
          "builder prune")
            if [ -n '\(removeFailure)' ]; then printf '%s\\n' '\(removeFailure)' >&2; exit 1; fi
            if [ \(pruneRemovesNothing ? 1 : 0) -eq 0 ]; then printf 'Deleted build cache objects:\\n%sffffffffffff\\n' "${6#id=}"; fi
            printf 'Total reclaimed space: 0B\\n' ;;
        esac
        exit 0
        """
        let path = dir.appendingPathComponent("docker")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        return FakeDocker(cli: DockerCLI(executable: path), log: log)
    }

    // MARK: - Parser against the fixture

    func testParserFindsDanglingImagesAndUnusedCacheWithDockerSizes() throws {
        let sample = try loadSample()
        let rule = try dockerRule()
        let findings = try DockerAnalyzer.parse(sample.json, rule: rule)
        let byPath = Dictionary(uniqueKeysWithValues: findings.map { ($0.storedPath, $0) })

        XCTAssertEqual(findings.count, sample.positives.count, "exactly the positives, nothing else")
        for positive in sample.positives {
            let finding = try XCTUnwrap(byPath[positive.path], positive.path)
            // S10: the reclaimable size docker reports — UniqueSize for an
            // image, never its virtual size.
            XCTAssertEqual(finding.size, positive.bytes, positive.path)
            XCTAssertEqual(finding.allocatedSize, positive.bytes, positive.path)
            XCTAssertTrue(finding.isReclaimable)
            XCTAssertEqual(finding.ruleId, rule.id)
            XCTAssertEqual(finding.level, .review)
            XCTAssertEqual(finding.category, .developer)
            XCTAssertEqual(finding.consequence, "Images re-pulled on next run.")
            XCTAssertNil(finding.ownerBundleId, "no owner: Docker never shows as a running-app conflict")
            XCTAssertNotNil(finding.dockerObject)
        }
        for negative in sample.negatives {
            XCTAssertNil(byPath[negative], "\(negative) must not be reported")
        }

        let image = try XCTUnwrap(byPath["docker://image/3f2a1b9c0d4e"])
        XCTAssertEqual(image.mtime, DockerAnalyzer.date(fromGoTime: "2026-05-01 10:00:00 +0000 UTC"))
        XCTAssertNil(image.lastOpened)
        let cache = try XCTUnwrap(byPath["docker://build-cache/k2l3m4n5o6p7"])
        XCTAssertEqual(cache.lastOpened, DockerAnalyzer.date(fromGoTime: "2026-09-15 08:30:00 +0000 UTC"))
        XCTAssertTrue(cache.reason.contains("regular"))
        XCTAssertEqual(findings.first?.storedPath, "docker://image/3f2a1b9c0d4e", "largest first")
    }

    func testHumanSizesParseAsDockerPrintsThem() {
        XCTAssertEqual(DockerAnalyzer.bytes(fromHumanSize: "1.23GB"), 1_230_000_000)
        XCTAssertEqual(DockerAnalyzer.bytes(fromHumanSize: "456MB"), 456_000_000)
        XCTAssertEqual(DockerAnalyzer.bytes(fromHumanSize: "77.5MB"), 77_500_000)
        XCTAssertEqual(DockerAnalyzer.bytes(fromHumanSize: "3.2kB"), 3_200)
        XCTAssertEqual(DockerAnalyzer.bytes(fromHumanSize: "0B"), 0)
        XCTAssertEqual(DockerAnalyzer.bytes(fromHumanSize: "2.5 TB"), 2_500_000_000_000)
        XCTAssertEqual(DockerAnalyzer.bytes(fromHumanSize: "1.5GiB"), 1_610_612_736)
        XCTAssertNil(DockerAnalyzer.bytes(fromHumanSize: "N/A"))
        XCTAssertNil(DockerAnalyzer.bytes(fromHumanSize: ""))
        XCTAssertNil(DockerAnalyzer.bytes(fromHumanSize: "12 parsecs"))
    }

    func testGoTimestampsParse() throws {
        let utc = try XCTUnwrap(DockerAnalyzer.date(fromGoTime: "2026-05-01 10:00:00 +0000 UTC"))
        XCTAssertEqual(utc.timeIntervalSince1970, 1_777_629_600)
        let local = try XCTUnwrap(DockerAnalyzer.date(fromGoTime: "2026-05-01 15:30:00.123456789 +0530 IST"))
        XCTAssertEqual(local, utc)
        XCTAssertNil(DockerAnalyzer.date(fromGoTime: "yesterday"))
        XCTAssertNil(DockerAnalyzer.date(fromGoTime: ""))
    }

    func testParserTakesOnlyTheDockerObject() throws {
        let rule = try dockerRule()
        XCTAssertEqual(try DockerAnalyzer.parse(Data("{}".utf8), rule: rule), [])
        XCTAssertThrowsError(try DockerAnalyzer.parse(Data("[]".utf8), rule: rule))
        XCTAssertThrowsError(try DockerAnalyzer.parse(Data("not json".utf8), rule: rule))
        // An image without the reclaimable number is unknown, and unknown is untouched (S1).
        let noUnique = #"{"Images":[{"ID":"abc123abc123","Repository":"<none>","Tag":"<none>","Containers":"0","Size":"10MB"}]}"#
        XCTAssertEqual(try DockerAnalyzer.parse(Data(noUnique.utf8), rule: rule), [])
        let unknownContainers = #"{"Images":[{"ID":"abc123abc123","Repository":"<none>","Tag":"<none>","Containers":"N/A","UniqueSize":"10MB"}]}"#
        XCTAssertEqual(try DockerAnalyzer.parse(Data(unknownContainers.utf8), rule: rule), [])
    }

    // MARK: - Nothing, not an error

    func testNoDockerYieldsNoFindings() async throws {
        let rule = try dockerRule()
        let none = await DockerAnalyzer(rule: rule, cli: nil).findings()
        XCTAssertEqual(none, [])

        let missing = DockerCLI(executable: tempDir.appendingPathComponent("not-here/docker"))
        let found = await DockerAnalyzer(rule: rule, cli: missing).findings()
        XCTAssertEqual(found, [])
        XCTAssertThrowsError(try missing.run(["version"], timeout: 1)) { error in
            XCTAssertEqual(error as? DockerCLI.Failure, .notInstalled)
        }
        XCTAssertNil(DockerCLI.locate(home: tempDir), "nothing installed under an empty home")
    }

    func testDaemonNotRunningYieldsNoFindings() async throws {
        let fake = try fakeDocker(
            dfFailure: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?")
        let found = await DockerAnalyzer(rule: try dockerRule(), cli: fake.cli).findings()
        XCTAssertEqual(found, [])
        XCTAssertEqual(fake.calls(), [Self.contextCall, Self.diskUsageCall],
                       "the daemon was asked and its refusal swallowed")
    }

    func testTimeoutYieldsNoFindingsPromptly() async throws {
        let fake = try fakeDocker(df: try loadSample().json, dfSleep: 30)
        let started = Date()
        let found = await DockerAnalyzer(rule: try dockerRule(), cli: fake.cli, timeout: 0.5).findings()
        XCTAssertEqual(found, [])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testRemoteContextIsNeverQueried() async throws {
        // A context on tcp:// or ssh:// would reach a host the Privacy &
        // Security sheet never promised; it counts as "no docker".
        let fake = try fakeDocker(host: "tcp://10.0.0.5:2376", df: try loadSample().json)
        let found = await DockerAnalyzer(rule: try dockerRule(), cli: fake.cli).findings()
        XCTAssertEqual(found, [])
        XCTAssertEqual(fake.calls(), [Self.contextCall])
    }

    func testAnalyzerAsksOnlyForDiskUsage() async throws {
        let sample = try loadSample()
        let fake = try fakeDocker(df: sample.json)
        let found = await DockerAnalyzer(rule: try dockerRule(), cli: fake.cli).findings()
        XCTAssertEqual(Set(found.map(\.storedPath)), Set(sample.positives.map(\.path)))
        XCTAssertEqual(fake.calls(), [Self.contextCall, Self.diskUsageCall])
    }

    // MARK: - The rule (S9) and the one gate (S2)

    func testRuleIsReviewOnlyAndOffForAutoClean() throws {
        let rule = try dockerRule()
        XCTAssertEqual(rule.category, .developer)
        XCTAssertEqual(rule.level, .review)
        XCTAssertFalse(rule.autoCleanEligible, "S9: ships unticked, and never qualifies")
        XCTAssertEqual(rule.match, [], "analyzer-driven, never matched by path")
        XCTAssertEqual(rule.consequence, "Images re-pulled on next run.")

        // S2: Auto Clean strips the rule even if a profile names it.
        let config = AutoCleanConfig(enabled: true, enabledRuleIds: [rule.id, "logs.general"])
        XCTAssertEqual(config.validated(against: try Catalogue.bundled()).enabledRuleIds, ["logs.general"])
    }

    func testScanStoresDockerItemsUntickedAndHonoursExclusions() async throws {
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        let sample = try loadSample()
        let fake = try fakeDocker(df: sample.json)
        let store = try makeStore()
        let exclusions = try ExclusionStore(fileURL: tempDir.appendingPathComponent("exclusions.json"))
        try exclusions.addPath("docker://image/9b8c7d6e5f4a")
        let runner = ScanRunner(
            scope: ScanScope(roots: [home]), catalogue: try Catalogue.bundled(), store: store,
            exclusions: exclusions, protectedPaths: ProtectedPaths(home: home), home: home,
            docker: fake.cli)
        runner.skipDuplicates()
        let result = try await runner.run()

        let scan = try XCTUnwrap(store.lastScan())
        let docker = try store.findings(in: scan.id).filter { $0.dockerObject != nil }
        XCTAssertEqual(
            Set(docker.map(\.storedPath)),
            Set(sample.positives.map(\.path)).subtracting(["docker://image/9b8c7d6e5f4a"]),
            "excluded objects stay out")
        // S2: review level, so nothing docker is pre-ticked; the user ticks
        // each one in Results and confirms in Review.
        XCTAssertEqual(try store.selectedFindingIds(in: scan.id).intersection(docker.map(\.id)), [])
        XCTAssertEqual(result.bytesFound, docker.reduce(0) { $0 + $1.allocatedSize })
        XCTAssertEqual(try store.totals()[.developer]?.count, docker.count)
        XCTAssertEqual(fake.calls(), [Self.contextCall, Self.diskUsageCall])
    }

    func testCatalogueWithoutTheRuleNeverRunsDocker() async throws {
        // AutoCleanRunner scans with the catalogue cut down to the ticked,
        // eligible rules; the docker rule is never among them, so Auto Clean
        // never spawns docker (S2) even when a CLI is wired in.
        let eligible = try Catalogue.bundled().rules.filter(\.autoCleanEligible)
        XCTAssertFalse(eligible.contains { $0.id == DockerAnalyzer.ruleId })
        let home = tempDir.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fake = try fakeDocker(df: try loadSample().json)
        let store = try makeStore()
        let runner = ScanRunner(
            scope: ScanScope(roots: [home]), catalogue: Catalogue(version: 2, rules: eligible),
            store: store, protectedPaths: ProtectedPaths(home: home), home: home, docker: fake.cli)
        runner.skipDuplicates()
        _ = try await runner.run()
        XCTAssertEqual(fake.calls(), [], "no rule, no docker call")
        let scan = try XCTUnwrap(store.lastScan())
        XCTAssertTrue(try store.findings(in: scan.id).allSatisfy { $0.dockerObject == nil })
    }

    // MARK: - Planner and executor

    func testPlannerKeepsDockerItemsWithoutStat() throws {
        let findings = try sampleFindings()
        let plan = plan(findings)
        XCTAssertEqual(plan.items.count, findings.count)
        XCTAssertEqual(Set(plan.items.map(\.volumeUUID)), ["docker"])
        XCTAssertTrue(plan.items.allSatisfy { !$0.requiresPermanent && $0.inode == 0 && !$0.isDirectory })
        XCTAssertEqual(plan.estimatedBytes, findings.reduce(0) { $0 + $1.allocatedSize })
        XCTAssertEqual(plan.itemsRequiringPermanent, [])
        XCTAssertEqual(plan.runningAppConflicts, [])
        XCTAssertEqual(plan.notices.map(\.ruleId), [DockerAnalyzer.ruleId])
    }

    func testExecutorRemovesEachObjectByIdAndReportsNoUndo() async throws {
        let sample = try loadSample()
        let fake = try fakeDocker(df: sample.json)
        let findings = try sampleFindings()
        let history = try makeHistory()
        let executor = Executor(history: history, docker: fake.cli)
        let plan = plan(findings)
        let result = try await executor.execute(plan: plan)

        XCTAssertEqual(result.doneCount, findings.count)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.movedBytes, plan.estimatedBytes)
        let items = try history.items(runId: result.runId)
        XCTAssertEqual(Set(items.map(\.status)), [.irreversible], "journaled like permanent delete")
        XCTAssertTrue(items.allSatisfy { $0.trashURL == nil && $0.movedAt != nil })

        // One explicit call per object, never a blanket prune.
        let removals = Array(fake.calls().dropFirst())
        XCTAssertEqual(fake.calls().first, Self.contextCall)
        XCTAssertEqual(Set(removals), [
            "image rm 3f2a1b9c0d4e",
            "image rm 9b8c7d6e5f4a",
            "builder prune --force --all --filter id=k2l3m4n5o6p7",
            "builder prune --force --all --filter id=s0urce000001",
        ])
        XCTAssertEqual(removals.count, 4)
        XCTAssertFalse(fake.calls().contains { $0.hasPrefix("system prune") })

        // Undo is reported unavailable the way permanent delete is, and a
        // restore attempt brings nothing back.
        XCTAssertEqual(try history.undoAvailability(runId: result.runId), .unavailable(.permanentDelete))
        let restore = try await executor.restore(runId: result.runId)
        XCTAssertEqual(restore.restoredCount, 0)
        XCTAssertEqual(Set(try history.items(runId: result.runId).map(\.status)), [.irreversible])
    }

    func testExecutorSkipsWhatDockerRefuses() async throws {
        let sample = try loadSample()
        let conflict = "Error response from daemon: conflict: unable to delete 3f2a1b9c0d4e (must be forced) - image is being used by stopped container 7a7a7a7a7a7a"
        let fake = try fakeDocker(df: sample.json, removeFailure: conflict)
        let findings = try sampleFindings()
        let history = try makeHistory()
        let result = try await Executor(history: history, docker: fake.cli).execute(plan: plan(findings))

        XCTAssertEqual(result.doneCount, 0)
        XCTAssertEqual(result.skippedCount, findings.count)
        let items = try history.items(runId: result.runId)
        XCTAssertEqual(Set(items.map(\.status)), [.skipped])
        XCTAssertTrue(items.allSatisfy { $0.skipReason == .dockerFailed(conflict) })
        XCTAssertEqual(try history.undoAvailability(runId: result.runId), .unavailable(.nothingMoved))
    }

    func testExecutorWithoutDockerSkipsEveryObject() async throws {
        let findings = try sampleFindings()
        let history = try makeHistory()
        let result = try await Executor(history: history, docker: nil).execute(plan: plan(findings))
        XCTAssertEqual(result.doneCount, 0)
        let items = try history.items(runId: result.runId)
        XCTAssertEqual(items.count, findings.count)
        XCTAssertTrue(items.allSatisfy { $0.skipReason == .dockerFailed("docker is not installed") })
    }

    func testExecutorRefusesRemoteContext() async throws {
        let sample = try loadSample()
        let fake = try fakeDocker(host: "ssh://build-box", df: sample.json)
        let history = try makeHistory()
        let result = try await Executor(history: history, docker: fake.cli).execute(plan: plan(try sampleFindings()))
        XCTAssertEqual(result.doneCount, 0)
        let items = try history.items(runId: result.runId)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.skipReason == .dockerFailed("docker context is not a local socket") })
        XCTAssertEqual(fake.calls(), [Self.contextCall], "checked once, nothing removed")
    }

    func testVanishedImageAndSilentPruneAreSkippedHonestly() async throws {
        let sample = try loadSample()
        let findings = try sampleFindings()
        let image = try XCTUnwrap(findings.first { $0.storedPath == "docker://image/3f2a1b9c0d4e" })
        let cache = try XCTUnwrap(findings.first { $0.storedPath == "docker://build-cache/k2l3m4n5o6p7" })

        // "No such image" is "already gone", like a vanished file.
        let gone = try fakeDocker(df: sample.json,
                                  removeFailure: "Error response from daemon: No such image: 3f2a1b9c0d4e:latest")
        let goneHistory = try makeHistory()
        let goneRun = try await Executor(history: goneHistory, docker: gone.cli).execute(plan: plan([image]))
        XCTAssertEqual(try goneHistory.items(runId: goneRun.runId).first?.skipReason, .vanished)

        // builder prune exits 0 even when the filter matched nothing: that is
        // a skip, not a removal (S10).
        let silent = try fakeDocker(df: sample.json, pruneRemovesNothing: true)
        let silentHistory = try makeHistory()
        let silentRun = try await Executor(history: silentHistory, docker: silent.cli).execute(plan: plan([cache]))
        let item = try XCTUnwrap(silentHistory.items(runId: silentRun.runId).first)
        XCTAssertEqual(item.status, .skipped)
        XCTAssertEqual(item.skipReason, .dockerFailed("not removed: in use or already gone"))
        XCTAssertEqual(silentRun.movedBytes, 0)
    }

    func testExcludedDockerObjectIsSkippedAtCleanTime() async throws {
        // S1 re-check: excluded between Review and the run → hands off.
        let sample = try loadSample()
        let fake = try fakeDocker(df: sample.json)
        let findings = try sampleFindings()
        let image = try XCTUnwrap(findings.first { $0.storedPath == "docker://image/3f2a1b9c0d4e" })
        let exclusions = try ExclusionStore(fileURL: tempDir.appendingPathComponent("exclusions.json"))
        try exclusions.addPath(image.storedPath)
        let history = try makeHistory()
        let result = try await Executor(history: history, exclusions: exclusions, docker: fake.cli)
            .execute(plan: plan([image]))
        XCTAssertEqual(result.doneCount, 0)
        XCTAssertEqual(try history.items(runId: result.runId).first?.skipReason, .protected)
        XCTAssertFalse(fake.calls().contains { $0.hasPrefix("image rm") })
    }

    // MARK: - Plumbing

    func testDockerObjectURLsRoundTrip() {
        let image = DockerObject.image(id: "3f2a1b9c0d4e")
        XCTAssertEqual(image.storedPath, "docker://image/3f2a1b9c0d4e")
        XCTAssertEqual(DockerObject(storedPath: image.storedPath), image)
        XCTAssertEqual(DockerObject(url: image.url), image)
        XCTAssertEqual(image.displayName, "Docker image 3f2a1b9c0d4e")
        XCTAssertEqual(image.removalArguments, ["image", "rm", "3f2a1b9c0d4e"])

        let cache = DockerObject.buildCache(id: "k2l3m4n5o6p7")
        XCTAssertEqual(cache.storedPath, "docker://build-cache/k2l3m4n5o6p7")
        XCTAssertEqual(DockerObject(storedPath: cache.storedPath), cache)
        XCTAssertEqual(cache.displayName, "Docker build cache k2l3m4n5o6p7")
        XCTAssertEqual(cache.removalArguments,
                       ["builder", "prune", "--force", "--all", "--filter", "id=k2l3m4n5o6p7"])

        XCTAssertNil(DockerObject(storedPath: "/Users/me/docker://image/x"))
        XCTAssertNil(DockerObject(storedPath: "docker://volume/pgdata"))
        XCTAssertNil(DockerObject(storedPath: "docker://image/"))
        XCTAssertNil(DockerObject(storedPath: "docker://image/a/b"))
        XCTAssertNil(DockerObject(url: URL(fileURLWithPath: "/tmp/x")))

        // File findings are untouched by the stored-path scheme.
        let file = URL(fileURLWithPath: "/Users/me/Library/Logs/x.log")
        XCTAssertEqual(Finding.storedPath(for: file), file.path)
        XCTAssertEqual(Finding.url(forStoredPath: file.path), file)
        XCTAssertEqual(Finding.url(forStoredPath: image.storedPath), image.url)
    }

    func testDockerFindingSurvivesTheStoreAndFileIdsAreUnchanged() throws {
        let store = try makeStore()
        let findings = try sampleFindings()
        let scanId = try store.beginScan()
        try store.upsert(findings, scanId: scanId)
        try store.finishScan(scanId, status: .complete, deniedCount: 0)
        let back = try store.findings(in: scanId)
        XCTAssertEqual(back.sorted { $0.id < $1.id }, findings.sorted { $0.id < $1.id })
        XCTAssertTrue(back.allSatisfy { $0.dockerObject != nil && $0.url.scheme == "docker" })

        let file = Finding(
            ruleId: "logs.general", url: URL(fileURLWithPath: "/tmp/a.log"), size: 1, allocatedSize: 1,
            mtime: Date(), lastOpened: nil, level: .safe, category: .logs, reason: "r", consequence: "c")
        XCTAssertEqual(file.id, Finding.stableID(ruleId: "logs.general", path: "/tmp/a.log"))
    }

    func testDockerSkipReasonRoundTrips() {
        let reason = SkipReason.dockerFailed("conflict: image is being used by stopped container")
        XCTAssertEqual(reason.stored, "dockerFailed:conflict: image is being used by stopped container")
        XCTAssertEqual(SkipReason(stored: reason.stored), reason)
    }
}
