import XCTest
@testable import DebrisCore

/// One test per bullet of product spec §3 (What it never does).
final class ProtectedPathsTests: XCTestCase {

    private static let fakeHome = URL(fileURLWithPath: "/Users/fixtureuser")

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebrisProtected-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func makeSubject() -> ProtectedPaths {
        ProtectedPaths(home: Self.fakeHome)
    }

    private func home(_ rel: String) -> URL {
        Self.fakeHome.appendingPathComponent(rel)
    }

    /// Creates a directory containing the given VCS metadata folder and an
    /// optional .gitignore, returning the repo root.
    private func makeRepo(named name: String, vcsDir: String, gitignore: String?) throws -> URL {
        let root = tempRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(vcsDir), withIntermediateDirectories: true)
        if let gitignore {
            try gitignore.write(
                to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        }
        return root
    }

    // MARK: - System folders

    func testSystemRootsAreProtected() {
        let subject = makeSubject()
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")))
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/usr/bin/ls")))
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/bin/ls")))
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/sbin/mount")))
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/Library/Preferences/com.apple.loginwindow.plist")))
    }

    func testPrivateVarIsProtectedExceptUserTmpFolders() {
        let subject = makeSubject()
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/private/var/db/dslocal")))
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/var/db/dslocal")))
        XCTAssertFalse(subject.isProtected(URL(fileURLWithPath: "/private/var/folders/ab/xyz123/T/scratch.txt")))
        XCTAssertFalse(subject.isProtected(URL(fileURLWithPath: "/var/folders/ab/xyz123/T/scratch.txt")))
    }

    func testDataVolumeFirmlinkPrefixIsCanonicalized() {
        let subject = makeSubject()
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/System/Volumes/Data/Library/Caches/anything")))
        XCTAssertFalse(subject.isProtected(
            URL(fileURLWithPath: "/System/Volumes/Data/Users/fixtureuser/Library/Caches/com.example.demo")))
    }

    // MARK: - Other users

    func testOtherUsersHomesAreProtected() {
        let subject = makeSubject()
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/Users/otheruser/Documents/report.pdf")))
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/Users/Shared/stuff.zip")))
        XCTAssertFalse(subject.isProtected(home("Documents/report.pdf")))
    }

    // MARK: - App bundles

    func testAppBundlesAreProtected() {
        let subject = makeSubject()
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/Applications/Foo.app")))
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/Applications/Foo.app/Contents/Resources/big.bin")))
        XCTAssertTrue(subject.isProtected(home("Applications/Bar.app/Contents/MacOS/Bar")))
    }

    // MARK: - Media libraries

    func testMediaLibrariesAreProtected() {
        let subject = makeSubject()
        XCTAssertTrue(subject.isProtected(home("Pictures/Photos Library.photoslibrary")))
        XCTAssertTrue(subject.isProtected(home("Pictures/Photos Library.photoslibrary/originals/2/IMG_0001.HEIC")))
        XCTAssertTrue(subject.isProtected(home("Movies/Untitled.fcpbundle/Event/orig.mov")))
        XCTAssertTrue(subject.isProtected(home("Pictures/Lightroom/Catalog.lrcat")))
        XCTAssertTrue(subject.isProtected(home("Music/Music")))
        XCTAssertTrue(subject.isProtected(home("Music/iTunes/iTunes Media/song.m4a")))
        XCTAssertTrue(subject.isProtected(home("Movies/TV/Media.localized/show.mp4")))
        XCTAssertFalse(subject.isProtected(home("Movies/screen-recording.mov")))
    }

    // MARK: - App state in ~/Library

    func testProtectedLibrarySubfoldersAreProtected() {
        let subject = makeSubject()
        for sub in ["Application Support", "Preferences", "Containers", "Group Containers",
                    "Keychains", "Mobile Documents", "Mail"] {
            XCTAssertTrue(subject.isProtected(home("Library/\(sub)/anything")), sub)
        }
        // A folder literally named "cache" inside Application Support stays protected.
        XCTAssertTrue(subject.isProtected(home("Library/Application Support/MyApp/cache")))
        XCTAssertFalse(subject.isProtected(home("Library/Caches/com.example.demo")))
        XCTAssertFalse(subject.isProtected(home("Library/Logs/app.log")))
    }

    // MARK: - Backups

    func testTimeMachineBackupsAreProtected() {
        let subject = makeSubject()
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/Volumes/TM/Backups.backupdb/Mac/2025-01-01/file")))
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/Volumes/.timemachine/UUID/snap")))
        XCTAssertTrue(subject.isProtected(URL(fileURLWithPath: "/Volumes/TM/com.apple.TimeMachine.localsnapshots/x")))
        XCTAssertFalse(subject.isProtected(URL(fileURLWithPath: "/Volumes/External/movies/big.mkv")))
    }

    // MARK: - Home-root dot entries

    func testHomeDotEntriesAreProtectedExceptKnownCaches() {
        let subject = makeSubject()
        XCTAssertTrue(subject.isProtected(home(".ssh/id_ed25519")))
        XCTAssertTrue(subject.isProtected(home(".gnupg/pubring.kbx")))
        XCTAssertTrue(subject.isProtected(home(".zshrc")))
        XCTAssertTrue(subject.isProtected(home(".config/git/config")))
        XCTAssertFalse(subject.isProtected(home(".npm/_cacache")))
        XCTAssertFalse(subject.isProtected(home(".yarn/cache")))
        XCTAssertFalse(subject.isProtected(home(".gradle/caches")))
        XCTAssertFalse(subject.isProtected(home(".cargo/registry/cache")))
        XCTAssertFalse(subject.isProtected(home(".Trash/deleted.pdf")))
    }

    // MARK: - VCS working trees

    func testGitWorkingTreeIsProtectedExceptGitignoredBuildDirs() throws {
        let repo = try makeRepo(named: "gitrepo", vcsDir: ".git",
                                gitignore: "node_modules/\n.build/\n# comment\nsecrets.env\n")
        let subject = makeSubject()
        XCTAssertTrue(subject.isProtected(repo.appendingPathComponent("src/main.swift")))
        XCTAssertTrue(subject.isProtected(repo.appendingPathComponent(".git/config")))
        XCTAssertFalse(subject.isProtected(repo.appendingPathComponent("node_modules")))
        XCTAssertFalse(subject.isProtected(repo.appendingPathComponent("node_modules/pkg/index.js")))
        XCTAssertFalse(subject.isProtected(repo.appendingPathComponent(".build")))
        // "build" is not listed in this repo's .gitignore, so it stays protected.
        XCTAssertTrue(subject.isProtected(repo.appendingPathComponent("build")))
        XCTAssertTrue(subject.isGitignoredBuildDirectory(repo.appendingPathComponent("node_modules")))
        XCTAssertFalse(subject.isGitignoredBuildDirectory(repo.appendingPathComponent("build")))
    }

    func testRepoWithoutGitignoreIsFullyProtected() throws {
        let repo = try makeRepo(named: "bare", vcsDir: ".git", gitignore: nil)
        let subject = makeSubject()
        XCTAssertTrue(subject.isProtected(repo.appendingPathComponent("node_modules")))
        XCTAssertFalse(subject.isGitignoredBuildDirectory(repo.appendingPathComponent("node_modules")))
    }

    func testMercurialAndSubversionTreesAreProtected() throws {
        let hg = try makeRepo(named: "hgrepo", vcsDir: ".hg", gitignore: nil)
        let svn = try makeRepo(named: "svnrepo", vcsDir: ".svn", gitignore: nil)
        let subject = makeSubject()
        XCTAssertTrue(subject.isProtected(hg.appendingPathComponent("src/lib.py")))
        XCTAssertTrue(subject.isProtected(svn.appendingPathComponent("trunk/file.c")))
    }

    func testPathOutsideAnyRepoIsNotProtected() {
        let subject = makeSubject()
        XCTAssertFalse(subject.isProtected(tempRoot.appendingPathComponent("loose/notes.txt")))
    }

    // MARK: - Settings display

    func testBuiltInProtectionsDescribeEverySection() {
        XCTAssertGreaterThanOrEqual(ProtectedPaths.builtInProtections.count, 9)
        for protection in ProtectedPaths.builtInProtections {
            XCTAssertFalse(protection.name.isEmpty)
            XCTAssertFalse(protection.reason.isEmpty)
        }
    }
}
