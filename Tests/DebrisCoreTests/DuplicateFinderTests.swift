import XCTest
@testable import DebrisCore

final class DuplicateFinderTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(at: home) }
        home = nil
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ relative: String, _ data: Data, daysAgo: Double = 0) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        if daysAgo > 0 {
            let seconds = Int(Date().addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970)
            var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
            utimes(url.path, &times)
        }
        return url
    }

    private func record(at url: URL, placeholder: Bool = false) throws -> FileRecord {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return FileRecord(
            url: url,
            size: Int64(st.st_size),
            allocatedSize: Int64(st.st_blocks) * 512,
            mtime: Date(timeIntervalSince1970:
                Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9),
            inode: UInt64(st.st_ino),
            linkCount: Int(st.st_nlink),
            isCloudPlaceholder: placeholder)
    }

    private func makeFinder(
        cache: FindingsStore? = nil,
        isPaused: (@Sendable () -> Bool)? = nil,
        pausePollNanoseconds: UInt64 = 1_000_000
    ) -> DuplicateFinder {
        DuplicateFinder(
            home: home, cache: cache, maxConcurrentOverride: 4,
            isPaused: isPaused ?? { false }, pausePollNanoseconds: pausePollNanoseconds)
    }

    private func groups(
        _ finder: DuplicateFinder, observing urls: [URL]
    ) async throws -> DuplicateScanSummary {
        for url in urls { finder.observe(try record(at: url)) }
        return try await finder.findGroups()
    }

    private func payload(_ seed: UInt8, bytes: Int = 1_200_000) -> Data {
        Data(repeating: seed, count: bytes)
    }

    // MARK: - Grouping

    func testIdenticalTrioCanonicalKeeperIsPictures() async throws {
        let data = payload(1)
        let pictures = try write("Pictures/photo.jpg", data, daysAgo: 300)
        let downloads = try write("Downloads/photo.jpg", data, daysAgo: 10)
        let desktop = try write("Desktop/photo.jpg", data, daysAgo: 100)

        let summary = try await groups(makeFinder(), observing: [pictures, downloads, desktop])

        XCTAssertEqual(summary.groups.count, 1)
        let group = try XCTUnwrap(summary.groups.first)
        XCTAssertEqual(group.copies.count, 3)
        XCTAssertEqual(group.keeper.url, pictures)
        XCTAssertEqual(group.keeper.location, .pictures)
        XCTAssertEqual(
            group.reclaimableBytes,
            group.others.reduce(0) { $0 + $1.allocatedSize })
        XCTAssertEqual(summary.clonePairsIgnored, 0)

        // Findings: one per non-keeper, none for the keeper (S7).
        let findings = group.findings(home: home)
        XCTAssertEqual(findings.count, 2)
        XCTAssertFalse(findings.contains { $0.url == pictures })
        for finding in findings {
            XCTAssertEqual(finding.level, .review)
            XCTAssertEqual(finding.category, .duplicates)
            XCTAssertEqual(finding.reason, "Identical to ~/Pictures/photo.jpg")
        }
    }

    func testSameSizeSamePrefixDifferentTailNotGrouped() async throws {
        // Identical first 64 KB forces the full-hash stage to separate them.
        var a = Data(repeating: 9, count: 1_200_000)
        var b = a
        a[1_199_999] = 1
        b[1_199_999] = 2
        let urlA = try write("Documents/a.bin", a)
        let urlB = try write("Documents/b.bin", b)

        let summary = try await groups(makeFinder(), observing: [urlA, urlB])
        XCTAssertTrue(summary.groups.isEmpty)
        XCTAssertGreaterThan(summary.bytesHashed, 0) // both stages actually ran
    }

    func testHardLinkedPairIgnored() async throws {
        let original = try write("Documents/linked.bin", payload(2))
        let link = home.appendingPathComponent("Downloads/linked.bin")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: original, to: link)

        let summary = try await groups(makeFinder(), observing: [original, link])
        XCTAssertTrue(summary.groups.isEmpty)
        XCTAssertEqual(summary.filesHashed, 0) // lone candidate: size stage prunes it
    }

    func testClonePairIgnoredAndCounted() async throws {
        let original = try write("Documents/movie.mov", payload(3))
        let clone = home.appendingPathComponent("Desktop/movie.mov")
        try FileManager.default.createDirectory(
            at: clone.deletingLastPathComponent(), withIntermediateDirectories: true)
        let cp = Process()
        cp.executableURL = URL(fileURLWithPath: "/bin/cp")
        cp.arguments = ["-c", original.path, clone.path]
        try cp.run()
        cp.waitUntilExit()
        guard cp.terminationStatus == 0 else {
            throw XCTSkip("cp -c failed; tmp is not on APFS")
        }

        let summary = try await groups(makeFinder(), observing: [original, clone])
        XCTAssertTrue(summary.groups.isEmpty, "clones share storage; nothing to reclaim")
        XCTAssertEqual(summary.clonePairsIgnored, 1)
    }

    func testCloudPlaceholderNeverHashed() async throws {
        let real = try write("Documents/synced.dat", payload(4))
        let finder = makeFinder()
        finder.observe(try record(at: real))
        finder.observe(try record(at: real, placeholder: true)) // evicted twin
        let summary = try await finder.findGroups()
        XCTAssertTrue(summary.groups.isEmpty)
        XCTAssertEqual(summary.filesHashed, 0, "placeholders must never be read")
    }

    func testBelowThresholdSkipped() async throws {
        let data = payload(5, bytes: 500_000) // under the 1 MB default
        let a = try write("Documents/small-a.dat", data)
        let b = try write("Documents/small-b.dat", data)
        let finder = makeFinder()
        let summary = try await groups(finder, observing: [a, b])
        XCTAssertEqual(finder.candidateCount, 0)
        XCTAssertTrue(summary.groups.isEmpty)
    }

    // MARK: - Keeper rules and S7

    private func makeGroup() -> DuplicateGroup {
        func copy(_ relative: String, daysAgo: Double) -> DuplicateCopy {
            let url = home.appendingPathComponent(relative)
            return DuplicateCopy(
                url: url, mtime: Date().addingTimeInterval(-daysAgo * 86_400),
                size: 100, allocatedSize: 100,
                location: HomeLocation.classify(url, home: home))
        }
        return DuplicateGroup(hash: "h", copies: [
            copy("Pictures/deep/nested/p.jpg", daysAgo: 100),
            copy("Downloads/p.jpg", daysAgo: 300),
            copy("Desktop/p.jpg", daysAgo: 10),
        ])!
    }

    func testKeeperRules() {
        let group = makeGroup()
        func path(_ rule: KeeperRule) -> String? {
            group.keeper(under: rule).flatMap { id in
                group.copies.first { $0.findingId == id }?.url.path
            }
        }
        XCTAssertTrue(path(.canonical)!.hasSuffix("Pictures/deep/nested/p.jpg"))
        XCTAssertTrue(path(.oldest)!.hasSuffix("Downloads/p.jpg"))
        XCTAssertTrue(path(.newest)!.hasSuffix("Desktop/p.jpg"))
        XCTAssertTrue(path(.shortestPath)!.hasSuffix("Desktop/p.jpg"))
        XCTAssertTrue(path(.inFolder(home.appendingPathComponent("Downloads")))!.hasSuffix("Downloads/p.jpg"))
        XCTAssertNil(path(.inFolder(home.appendingPathComponent("Music"))), "no copy there: rule does not apply")
    }

    func testS7NeverZeroKeepers() {
        let lone = DuplicateCopy(
            url: home.appendingPathComponent("one.jpg"), mtime: Date(),
            size: 1, allocatedSize: 1, location: .otherHome)
        XCTAssertNil(DuplicateGroup(hash: "x", copies: [lone]), "one file is not a duplicate group")

        var group = makeGroup()
        let before = group.keeperId
        XCTAssertThrowsError(try group.setKeeper("not-a-member")) {
            XCTAssertEqual($0 as? DuplicateError, .unknownCopy)
        }
        XCTAssertEqual(group.keeperId, before, "failed setKeeper must not move the keeper")
        XCTAssertNoThrow(try group.setKeeper(group.others[0].findingId))
    }

    // MARK: - Cache

    func testSecondRunHitsCacheAndRehashesOnChange() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-cache-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let store = try FindingsStore(databaseURL: dbURL)
        let data = payload(6)
        let a = try write("Documents/report.pdf", data)
        let b = try write("Downloads/report.pdf", data)

        let first = try await groups(makeFinder(cache: store), observing: [a, b])
        XCTAssertEqual(first.groups.count, 1)
        XCTAssertGreaterThan(first.bytesHashed, 0)

        let second = try await groups(makeFinder(cache: store), observing: [a, b])
        XCTAssertEqual(second.groups.count, 1)
        XCTAssertEqual(second.bytesHashed, 0, "unchanged files must not be rehashed")
        XCTAssertEqual(second.filesHashed, 0)

        // Same size, new content and mtime: the cache entry is stale.
        var changed = data
        changed[0] = 99
        try changed.write(to: b)
        let third = try await groups(makeFinder(cache: store), observing: [a, b])
        XCTAssertTrue(third.groups.isEmpty)
        XCTAssertGreaterThan(third.bytesHashed, 0, "stale cache entry must be ignored")
    }

    // MARK: - Pause gate

    func testPauseGateDelaysHashingThenResumes() async throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = true
            func takeOnce() -> Bool {
                lock.lock(); defer { lock.unlock() }
                let was = value; value = false; return was
            }
        }
        let flag = Flag()
        let data = payload(7)
        let a = try write("Documents/p-a.dat", data)
        let b = try write("Documents/p-b.dat", data)
        let finder = makeFinder(isPaused: { flag.takeOnce() })
        let summary = try await groups(finder, observing: [a, b])
        XCTAssertEqual(summary.groups.count, 1, "hashing resumes after the pause")
        XCTAssertGreaterThanOrEqual(summary.pauseEvents, 1)
    }

    // MARK: - Pipeline integration

    func testProtectedLibraryNeverGroupedAndFindingsPersist() async throws {
        let data = payload(8)
        try write("Pictures/Photos Library.photoslibrary/originals/img.dat", data)
        try write("Pictures/Photos Library.photoslibrary/resources/img.dat", data)
        let downloads = try write("Downloads/img.dat", data)
        let desktop = try write("Desktop/img.dat", data)

        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-scan-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let store = try FindingsStore(databaseURL: dbURL)
        let runner = ScanRunner(
            scope: ScanScope(roots: [home]),
            catalogue: try Catalogue.bundled(),
            store: store,
            protectedPaths: ProtectedPaths(home: home),
            home: home)
        let result = try await runner.run()

        let summary = try XCTUnwrap(result.duplicates)
        XCTAssertEqual(summary.groups.count, 1)
        let group = try XCTUnwrap(summary.groups.first)
        XCTAssertEqual(Set(group.copies.map(\.url)), [downloads, desktop])
        XCTAssertFalse(group.copies.contains { $0.url.path.contains("photoslibrary") })

        // Persisted round trip: copies, keeper, findings, clone count.
        let stored = try store.duplicates(in: result.scanId, home: home)
        XCTAssertEqual(stored.groups.count, 1)
        XCTAssertEqual(stored.groups[0].keeperId, group.keeperId)
        XCTAssertEqual(stored.status, "done")
        let findings = try store.findings(in: result.scanId).filter { $0.category == .duplicates }
        XCTAssertEqual(findings.count, 1, "one non-keeper copy outside the library")
        XCTAssertEqual(findings[0].level, .review)

        // Review-level duplicates default to unselected (S2).
        XCTAssertFalse(try store.selectedFindingIds(in: result.scanId).contains(findings[0].id))
    }
}
