import XCTest
import DebrisCore
@testable import DataDebris

@MainActor
final class AccessTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/sam")

    private func decide(_ path: String, debug: Bool = false) -> MoveToApplications.Decision {
        MoveToApplications.decision(bundleURL: URL(fileURLWithPath: path), home: home, isDebugBuild: debug)
    }

    // MARK: Move-to-Applications decision

    func testSystemApplicationsNeedsNoMove() {
        XCTAssertEqual(decide("/Applications/Data Debris.app"), .alreadyInApplications)
        XCTAssertEqual(decide("/Applications/Utilities/Data Debris.app"), .alreadyInApplications)
    }

    func testUserApplicationsNeedsNoMove() {
        XCTAssertEqual(decide("/Users/sam/Applications/Data Debris.app"), .alreadyInApplications)
    }

    func testDownloadsOffersMoveToSystemApplications() {
        XCTAssertEqual(
            decide("/Users/sam/Downloads/Data Debris.app"),
            .offer(destination: URL(fileURLWithPath: "/Applications/Data Debris.app")))
        XCTAssertEqual(
            decide("/Volumes/Data Debris/Data Debris.app"),
            .offer(destination: URL(fileURLWithPath: "/Applications/Data Debris.app")))
    }

    func testLookalikeFoldersStillOffer() {
        // "/ApplicationsOld/" and a folder merely named Applications deeper down.
        XCTAssertEqual(
            decide("/ApplicationsOld/Data Debris.app"),
            .offer(destination: URL(fileURLWithPath: "/Applications/Data Debris.app")))
        XCTAssertEqual(
            decide("/Users/sam/Desktop/Applications/Data Debris.app"),
            .offer(destination: URL(fileURLWithPath: "/Applications/Data Debris.app")))
    }

    func testDevelopmentBuildSkippedOnlyInDebug() {
        let xcode = "/Users/sam/Library/Developer/Xcode/DerivedData/DataDebris-abc/Build/Products/Debug/Data Debris.app"
        let make = "/Users/sam/Desktop/data/build/Build/Products/Debug/Data Debris.app"
        XCTAssertEqual(decide(xcode, debug: true), .developmentBuild)
        XCTAssertEqual(decide(make, debug: true), .developmentBuild)
        // A Release build launched from a build folder is a real install candidate.
        XCTAssertEqual(
            decide(make, debug: false),
            .offer(destination: URL(fileURLWithPath: "/Applications/Data Debris.app")))
    }

    func testNonBundleIsNeverOffered() {
        XCTAssertEqual(decide("/usr/local/bin/datadebris"), .notABundle)
        XCTAssertEqual(decide("/Users/sam/Downloads/Data Debris.app/Contents/MacOS/DataDebris"), .notABundle)
    }

    // MARK: Full Disk Access probe

    func testProbeReportsGrantedWhenTheProtectedFolderLists() {
        XCTAssertEqual(FullDiskAccess.probe(home: "/Users/sam", canList: { _ in true }), .granted)
        XCTAssertEqual(FullDiskAccess.probe(home: "/Users/sam", canList: { _ in false }), .denied)
    }

    func testProbeReadsSafariFolderOnly() {
        var asked: [String] = []
        _ = FullDiskAccess.probe(home: "/Users/sam", canList: { asked.append($0); return false })
        XCTAssertEqual(asked, ["/Users/sam/Library/Safari"])
    }

    // MARK: AppModel wiring

    private var granted = true

    private func makeModel(moveDecision: MoveToApplications.Decision = .notABundle,
                           justMoved: Bool = false) throws -> AppModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return AppModel(
            store: try FindingsStore(databaseURL: dir.appendingPathComponent("findings.sqlite")),
            history: try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite")),
            exclusions: try ExclusionStore(fileURL: dir.appendingPathComponent("exclusions.json")),
            catalogue: Catalogue(version: 1, rules: []),
            licenseStore: LicenseFixture.activeStore(),
            fdaProbe: { [unowned self] in self.granted },
            moveDecision: moveDecision,
            justMoved: justMoved)
    }

    override func setUp() {
        super.setUp()
        let defaults = AppPaths.userDefaults
        defaults.set(true, forKey: AppModel.welcomeCompletedKey)
        defaults.set(true, forKey: AppModel.fdaWasGrantedKey)
    }

    override func tearDown() {
        let defaults = AppPaths.userDefaults
        defaults.removeObject(forKey: AppModel.welcomeCompletedKey)
        defaults.removeObject(forKey: AppModel.fdaWasGrantedKey)
        super.tearDown()
    }

    func testRevocationMidSessionShowsBannerNotWelcome() throws {
        granted = true
        let model = try makeModel()
        XCTAssertTrue(model.fdaGranted)
        XCTAssertFalse(model.showWelcome)

        granted = false
        model.recheckFDA()
        XCTAssertFalse(model.fdaGranted, "the Home banner is driven by fdaGranted")
        XCTAssertFalse(model.showWelcome, "no re-onboarding mid-session")

        granted = true
        model.systemDidWake()
        XCTAssertTrue(model.fdaGranted, "wake re-probes")
    }

    func testRevocationSeenAtLaunchReopensWelcome() throws {
        granted = false
        let model = try makeModel()
        XCTAssertTrue(model.showWelcome)
        XCTAssertNil(model.movedNotice)
    }

    func testMovedCopyThatLostAccessGetsTheNoticeInsteadOfWelcome() throws {
        granted = false
        let model = try makeModel(justMoved: true)
        XCTAssertEqual(model.movedNotice, .fdaLost)
        XCTAssertFalse(model.showWelcome)
    }

    func testMovedCopyThatKeptAccessGetsNoNotice() throws {
        granted = true
        let model = try makeModel(justMoved: true)
        XCTAssertNil(model.movedNotice)
    }

    func testOfferDecisionPresentsTheSheet() throws {
        let destination = URL(fileURLWithPath: "/Applications/Data Debris.app")
        let model = try makeModel(moveDecision: .offer(destination: destination))
        XCTAssertEqual(model.moveOffer?.destination, destination)
        XCTAssertNil(try makeModel(moveDecision: .alreadyInApplications).moveOffer)
        XCTAssertNil(try makeModel(moveDecision: .developmentBuild).moveOffer)
    }
}
