import XCTest
import DebrisCore
@testable import DataDebris

/// PurchasesEnabled=false: the free edition. Every locked feature proceeds
/// without a purchase sheet, Settings shows no plan UI, and no LicenseClient
/// exists, so the license host is never contacted. The licensed edition keeps
/// the 1.0 gate (PurchaseFlowTests cover it in depth).
final class FreeEditionTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreeEditionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    private func makeModel(
        edition: Edition,
        licenseStore: LicenseStore? = nil,
        service: LicenseService? = nil
    ) throws -> AppModel {
        AppModel(
            store: try FindingsStore(databaseURL: dir.appendingPathComponent("findings.sqlite")),
            history: try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite")),
            exclusions: try ExclusionStore(fileURL: dir.appendingPathComponent("exclusions.json")),
            catalogue: Catalogue(version: 1, rules: []),
            edition: edition,
            autoCleanConfigURL: dir.appendingPathComponent("settings.json"),
            launchAgents: LaunchAgentManager(
                agentsDirectory: dir.appendingPathComponent("LaunchAgents"),
                programPath: "/Applications/DataDebris.app/Contents/MacOS/DataDebris",
                uid: 501, launchctl: { _ in 0 }),
            licenseStore: licenseStore ?? LicenseFixture.freeStore(),
            licenseService: service,
            privacyText: PrivacySheetText(updateHost: "u.example", licenseHost: "l.example"),
            clock: LicenseFixture.clock())
    }

    @MainActor
    private func seedSelectedFinding(_ model: AppModel) throws {
        let scanId = try model.store.beginScan()
        let path = dir.path + "/cache.dat"
        FileManager.default.createFile(atPath: path, contents: Data("cache".utf8))
        let finding = Finding(
            ruleId: "test.appCaches", url: URL(fileURLWithPath: path),
            size: 1_000, allocatedSize: 1_000, mtime: Date(), lastOpened: nil,
            level: .safe, category: .appCaches, reason: "test", consequence: "test")
        try model.store.upsert([finding], scanId: scanId)
        try model.store.finishScan(scanId, status: .complete, deniedCount: 0)
        model.refresh()
    }

    private var agentPlist: URL {
        dir.appendingPathComponent("LaunchAgents")
            .appendingPathComponent(LaunchAgentManager.label + ".plist")
    }

    // MARK: - Gates

    /// Clean, Smart Clean and the Auto Clean toggle all proceed with no
    /// license and no sheet. Review still opens first (S2).
    @MainActor
    func testLockedFeaturesProceedWithoutASheet() throws {
        let model = try makeModel(edition: .free)
        try seedSelectedFinding(model)
        XCTAssertEqual(model.entitlementState, .free)
        XCTAssertTrue(model.isEntitled)
        for feature in LockedFeature.allCases {
            XCTAssertTrue(model.requireEntitled(feature, toResume: .none), "\(feature)")
        }
        XCTAssertNil(model.purchase)

        model.openReview()
        XCTAssertNotNil(model.cleanFlow, "Review is the gate, not a plan sheet")
        XCTAssertNil(model.purchase)
        model.cleanFlow = nil

        model.smartClean()
        XCTAssertNotNil(model.cleanFlow)
        XCTAssertNil(model.purchase)
        model.cleanFlow = nil

        model.setAutoCleanEnabled(true)
        XCTAssertTrue(model.autoCleanConfig.enabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: agentPlist.path))
        XCTAssertNil(model.purchase)

        model.startPurchase()
        XCTAssertNil(model.purchase, "no Choose Plan or Privacy & Security sheet in the free edition")
        XCTAssertNil(model.licenseToast)
    }

    /// The same model with purchases enabled and no license hits the gate:
    /// the switch, not deleted code, is what makes the beta free.
    @MainActor
    func testLicensedEditionStillGates() throws {
        let model = try makeModel(edition: .licensed, service: FakeLicenseService())
        try seedSelectedFinding(model)
        XCTAssertFalse(model.isEntitled)
        model.openReview()
        XCTAssertNil(model.cleanFlow)
        XCTAssertEqual(model.purchase?.step, .privacy)
        model.purchase?.cancel()
    }

    // MARK: - License service

    /// No client is built, even when one is handed in, so nothing in the
    /// model can reach the license host.
    @MainActor
    func testNoLicenseClientIsCreatedAndNoRequestIsMade() async throws {
        let fake = FakeLicenseService()
        let model = try makeModel(edition: .free, licenseStore: LicenseFixture.activeStore(),
                                  service: fake)
        XCTAssertNil(model.licenseService)

        try seedSelectedFinding(model)
        model.licenseHousekeeping()
        model.startPurchase()
        model.openReview()
        model.cleanFlow = nil
        model.setAutoCleanEnabled(true)
        model.runAutoCleanNow()
        await model.enterLicenseKey("DD-AAAAA-BBBBB-CCCCC-DDDDD")
        await model.deactivateThisMac()
        await model.recoverLicenseKey(email: "someone@example.com")

        XCTAssertEqual(fake.byReferenceCalls, 0)
        XCTAssertTrue(fake.activateCalls.isEmpty)
        XCTAssertTrue(fake.deactivateCalls.isEmpty)
        XCTAssertTrue(fake.recoveredEmails.isEmpty)
        XCTAssertNil(model.purchase)

        // With purchases enabled the same init builds the real client.
        let licensed = try makeModel(edition: .licensed)
        XCTAssertTrue(licensed.licenseService is LicenseClient)
    }

    /// A license left in the store by an earlier build changes nothing: the
    /// state stays .free, no banner can fire, and housekeeping leaves the
    /// Auto Clean agent alone (the licensed path would remove it as unpaid).
    @MainActor
    func testCachedLicenseStateIsIgnoredAndAgentsFollowTheConfig() throws {
        let lapsed = LicenseFixture.payload(expiresIn: -86_400)
        let model = try makeModel(edition: .free,
                                  licenseStore: LicenseFixture.activeStore(payload: lapsed))
        model.refreshEntitlement()
        XCTAssertEqual(model.entitlementState, .free)
        XCTAssertTrue(model.isEntitled)
        XCTAssertNil(model.licensePayload)

        model.setAutoCleanEnabled(true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: agentPlist.path))
        model.licenseHousekeeping()
        XCTAssertTrue(FileManager.default.fileExists(atPath: agentPlist.path),
                      "housekeeping must not uninstall the agent for lack of a license")
    }

    // MARK: - Settings and About

    /// Settings renders one line and nothing else from the license UI; the
    /// About hosts list keeps the license host, marked as unused.
    @MainActor
    func testSettingsShowsNoPlanUI() throws {
        XCTAssertEqual(SettingsView.licenseSectionKind(edition: .free, licensed: false), .freeEdition)
        XCTAssertEqual(SettingsView.licenseSectionKind(edition: .free, licensed: true), .freeEdition)
        XCTAssertEqual(SettingsView.licenseSectionKind(edition: .licensed, licensed: true), .activeLicense)
        XCTAssertEqual(SettingsView.licenseSectionKind(edition: .licensed, licensed: false), .plans)
        XCTAssertEqual(SettingsView.freeEditionLine, "Free during the beta")

        let model = try makeModel(edition: .free, licenseStore: LicenseFixture.activeStore())
        XCTAssertNil(model.licensePayload, "no plan, expiry or Macs to show")

        XCTAssertEqual(AboutSection.licenseHostPurpose(edition: .free),
                       "License service: not used in this edition.")
        XCTAssertFalse(AboutSection.licenseHostPurpose(edition: .licensed).contains("not used"))
        XCTAssertEqual(AboutSection.networkHeading(edition: .free), "Network: one host in this edition")
        XCTAssertEqual(AboutSection.networkHeading(edition: .licensed), "Network: exactly two hosts")
    }
}
