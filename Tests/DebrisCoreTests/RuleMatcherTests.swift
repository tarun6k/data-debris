import XCTest
@testable import DebrisCore

final class RuleMatcherTests: XCTestCase {

    private static let fakeHome = URL(fileURLWithPath: "/Users/fixtureuser")

    private var tempRoot: URL!
    private var repoRoot: URL!
    private var catalogue: Catalogue!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebrisMatcher-\(UUID().uuidString)")
        repoRoot = tempRoot.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "node_modules/\nbuild/\n.build/\ntarget/\nDerivedData/\n"
            .write(to: repoRoot.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        catalogue = try Catalogue.bundled()
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func makeMatcher(
        catalogue: Catalogue? = nil,
        isOwnerRunning: @escaping @Sendable (String) -> Bool = { _ in false }
    ) -> RuleMatcher {
        RuleMatcher(
            catalogue: catalogue ?? self.catalogue,
            protectedPaths: ProtectedPaths(home: Self.fakeHome),
            home: Self.fakeHome,
            isOwnerRunning: isOwnerRunning)
    }

    private func record(
        _ path: String,
        isDirectory: Bool = false,
        size: Int64 = 0,
        mtimeDaysAgo: Double = 0,
        lastOpenedDaysAgo: Double? = nil,
        linkCount: Int = 1,
        isSymlink: Bool = false,
        isCloudPlaceholder: Bool = false,
        now: Date = Date()
    ) -> FileRecord {
        let resolved = path.hasPrefix("~/")
            ? Self.fakeHome.path + path.dropFirst(1)
            : path
        return FileRecord(
            url: URL(fileURLWithPath: resolved),
            size: size,
            allocatedSize: size,
            mtime: now.addingTimeInterval(-mtimeDaysAgo * 86_400),
            lastOpened: lastOpenedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
            linkCount: linkCount,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            isCloudPlaceholder: isCloudPlaceholder)
    }

    // MARK: - Trap paths (S1: unknown or protected means untouched)

    func testCacheFolderInsideApplicationSupportDoesNotMatch() {
        let matcher = makeMatcher()
        let rec = record("~/Library/Application Support/MyApp/cache", isDirectory: true)
        XCTAssertEqual(matcher.evaluate(rec), .protectedPath)
        XCTAssertNil(matcher.match(rec))
    }

    func testPreferencesPlistDoesNotMatch() {
        let matcher = makeMatcher()
        let rec = record("~/Library/Preferences/com.example.demo.plist", mtimeDaysAgo: 400)
        XCTAssertEqual(matcher.evaluate(rec), .protectedPath)
        XCTAssertNil(matcher.match(rec))
    }

    func testFileInsideAppBundleDoesNotMatch() {
        let matcher = makeMatcher()
        let rec = record("/Applications/Foo.app/Contents/Resources/big.bin",
                         size: 900_000_000, mtimeDaysAgo: 400, lastOpenedDaysAgo: 400)
        XCTAssertEqual(matcher.evaluate(rec), .protectedPath)
        XCTAssertNil(matcher.match(rec))
    }

    func testGitRepoSourceProtectedButGitignoredNodeModulesMatches() {
        let matcher = makeMatcher()

        let src = record(repoRoot.appendingPathComponent("src").path,
                         isDirectory: true, mtimeDaysAgo: 400)
        XCTAssertEqual(matcher.evaluate(src), .protectedPath)

        let nodeModules = record(repoRoot.appendingPathComponent("node_modules").path,
                                 isDirectory: true, mtimeDaysAgo: 120)
        XCTAssertEqual(matcher.match(nodeModules)?.id, "dev.projectbuild")
    }

    func testBuildDirOutsideAnyRepoDoesNotMatch() {
        let matcher = makeMatcher()
        let rec = record(tempRoot.appendingPathComponent("node_modules").path,
                         isDirectory: true, mtimeDaysAgo: 400)
        XCTAssertEqual(matcher.evaluate(rec), .unmatched)
    }

    func testPhotosLibraryContentsDoNotMatch() {
        let matcher = makeMatcher()
        let rec = record("~/Pictures/Photos Library.photoslibrary/originals/2/IMG_0001.HEIC",
                         size: 900_000_000, mtimeDaysAgo: 400, lastOpenedDaysAgo: 400)
        XCTAssertEqual(matcher.evaluate(rec), .protectedPath)
        XCTAssertNil(matcher.match(rec))
    }

    // MARK: - Browsers: caches only, never credentials or history

    func testChromeCacheMatchesButCookiesAndLoginDataDoNot() {
        let matcher = makeMatcher()

        let cache = record("~/Library/Caches/Google/Chrome/Default/Cache", isDirectory: true)
        XCTAssertEqual(matcher.match(cache)?.id, "appcaches.browser.chrome")

        let cookies = record("~/Library/Caches/Google/Chrome/Default/Cookies")
        XCTAssertNil(matcher.match(cookies))

        let loginData = record("~/Library/Application Support/Google/Chrome/Default/Login Data")
        XCTAssertNil(matcher.match(loginData))
    }

    // MARK: - Not reclaimable

    func testSymlinkNeverMatches() {
        let matcher = makeMatcher()
        let rec = record("~/Library/Caches/com.example.demo", isDirectory: true, isSymlink: true)
        XCTAssertEqual(matcher.evaluate(rec), .notReclaimable(.symlink))
        XCTAssertNil(matcher.match(rec))
    }

    func testHardLinkedFileNeverMatches() {
        let matcher = makeMatcher()
        let rec = record("~/Downloads/old-vm-image.dmg",
                         size: 900_000_000, mtimeDaysAgo: 400, lastOpenedDaysAgo: 400, linkCount: 2)
        XCTAssertEqual(matcher.evaluate(rec), .notReclaimable(.hardLink))
        XCTAssertNil(matcher.match(rec))
    }

    func testDirectoryLinkCountIsNotTreatedAsHardLink() {
        let matcher = makeMatcher()
        let rec = record("~/Library/Caches/com.example.demo", isDirectory: true, linkCount: 12)
        XCTAssertEqual(matcher.match(rec)?.id, "appcaches.generic")
    }

    func testCloudPlaceholderNeverMatches() {
        let matcher = makeMatcher()
        let rec = record("~/Downloads/big-project.zip",
                         size: 900_000_000, mtimeDaysAgo: 400, lastOpenedDaysAgo: 400,
                         isCloudPlaceholder: true)
        XCTAssertEqual(matcher.evaluate(rec), .notReclaimable(.cloudPlaceholder))
        XCTAssertNil(matcher.match(rec))
    }

    // MARK: - Directory-unit rules

    func testDirectoryRuleMatchesDirectoryOnceNeverChildren() {
        let matcher = makeMatcher()

        let dir = record("~/Library/Caches/com.spotify.client", isDirectory: true)
        XCTAssertEqual(matcher.match(dir)?.id, "appcaches.media.spotify")

        let childDir = record("~/Library/Caches/com.spotify.client/Storage", isDirectory: true)
        XCTAssertNil(matcher.match(childDir))

        let childFile = record("~/Library/Caches/com.spotify.client/Storage/blob.bin", size: 1000)
        XCTAssertNil(matcher.match(childFile))
    }

    func testUnitMismatchNeverMatches() {
        let matcher = makeMatcher()
        // A plain file where a directory rule points is not claimed.
        let rec = record("~/Library/Caches/com.spotify.client", isDirectory: false)
        XCTAssertNil(matcher.match(rec))
    }

    // MARK: - Predicates

    func testOwnerBundleRunningPredicate() {
        let rule = Rule(
            id: "test.owner",
            category: .appCaches,
            level: .safe,
            match: ["~/Library/Caches/com.test.demo"],
            unit: .directory,
            predicates: [.ownerBundleRunning(false)],
            owner: "com.test.demo",
            reason: "Test cache.",
            consequence: "None.",
            autoCleanEligible: true)
        let synthetic = Catalogue(version: 1, rules: [rule])
        let rec = record("~/Library/Caches/com.test.demo", isDirectory: true)

        let whileRunning = makeMatcher(catalogue: synthetic, isOwnerRunning: { _ in true })
        XCTAssertNil(whileRunning.match(rec))

        let whileQuit = makeMatcher(catalogue: synthetic, isOwnerRunning: { _ in false })
        XCTAssertEqual(whileQuit.match(rec)?.id, "test.owner")
    }

    func testDuplicatesRuleIsNeverPathMatched() {
        // Even a record engineered to look like a duplicate target is only
        // ever flagged by the hash engine, not the path matcher.
        let matcher = makeMatcher()
        let rec = record("~/Documents/Report copy.pdf", size: 5_000_000)
        XCTAssertNil(matcher.match(rec))
    }
}
