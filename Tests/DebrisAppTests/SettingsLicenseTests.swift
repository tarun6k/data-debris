import XCTest
import DebrisCore
@testable import DataDebris

/// Settings > License actions against the fake service: key entry, deactivate
/// (server first, cache second) and recovery.
final class SettingsLicenseTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsLicenseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    private func makeModel(
        licenseStore: LicenseStore? = nil,
        service: FakeLicenseService = FakeLicenseService()
    ) throws -> AppModel {
        AppModel(
            store: try FindingsStore(databaseURL: dir.appendingPathComponent("findings.sqlite")),
            history: try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite")),
            exclusions: try ExclusionStore(fileURL: dir.appendingPathComponent("exclusions.json")),
            catalogue: Catalogue(version: 1, rules: []),
            autoCleanConfigURL: dir.appendingPathComponent("settings.json"),
            launchAgents: LaunchAgentManager(
                agentsDirectory: dir.appendingPathComponent("LaunchAgents"),
                programPath: "/Applications/DataDebris.app/Contents/MacOS/DataDebris",
                uid: 501, launchctl: { _ in 0 }),
            licenseStore: licenseStore ?? LicenseFixture.freeStore(),
            licenseService: service,
            privacyText: PrivacySheetText(updateHost: "u.example", licenseHost: "l.example"))
    }

    @MainActor
    func testEnterLicenseKeyActivatesAndToasts() async throws {
        let service = FakeLicenseService()
        let model = try makeModel(service: service)
        XCTAssertNil(model.licensePayload)

        await model.enterLicenseKey("DD-AAAAA-BBBBB-CCCCC-DDDDD")

        XCTAssertEqual(model.licensePayload?.key, "DD-AAAAA-BBBBB-CCCCC-DDDDD")
        XCTAssertTrue(model.entitlementState.isEntitled)
        XCTAssertEqual(model.licenseToast?.hasPrefix("Data Debris is active until "), true)
        XCTAssertEqual(service.activateCalls.count, 1)
    }

    @MainActor
    func testEnterUnknownKeyLeavesFreeAndExplains() async throws {
        let service = FakeLicenseService()
        service.activateError = .unknownKey
        let model = try makeModel(service: service)

        await model.enterLicenseKey("DD-WRONG-WRONG-WRONG-WRONG")

        XCTAssertNil(model.licensePayload)
        XCTAssertFalse(model.entitlementState.isEntitled)
        XCTAssertEqual(model.licenseToast?.contains("not found"), true)
    }

    @MainActor
    func testDeactivateThisMacFreesServerSlotThenClearsCache() async throws {
        let service = FakeLicenseService()
        let model = try makeModel(licenseStore: LicenseFixture.activeStore(), service: service)
        XCTAssertNotNil(model.licensePayload)

        await model.deactivateThisMac()

        XCTAssertEqual(service.deactivateCalls.count, 1)
        XCTAssertEqual(service.deactivateCalls.first?.key, LicenseFixture.payload().key)
        XCTAssertNil(model.licensePayload)
        XCTAssertFalse(model.entitlementState.isEntitled)
    }

    /// Settings > License lists Macs by the name they sent to the service,
    /// marks this one, and falls back to the id tail for an unnamed slot.
    func testMachineRowsAreNamedAndThisMacIsMarked() {
        let mine = LicensedMachine(id: "abc123def456", name: "Studio", activatedAt: 1_800_000_000)
        let other = LicensedMachine(id: "fedcba987654", name: "Laptop", activatedAt: nil)
        let unnamed = LicensedMachine(id: "0000000000009f3c", name: "")
        XCTAssertEqual(SettingsView.machineLabel(mine, thisMachineId: mine.id), "Studio (this Mac)")
        XCTAssertEqual(SettingsView.machineLabel(other, thisMachineId: mine.id), "Laptop")
        XCTAssertEqual(SettingsView.machineLabel(unnamed, thisMachineId: mine.id), "Mac \u{2026}9f3c")
    }

    /// The name this Mac reports is what the service stores and echoes back.
    @MainActor
    func testEnterLicenseKeySendsThisMacsNameAndItComesBack() async throws {
        let service = FakeLicenseService()
        let model = try makeModel(service: service)
        await model.enterLicenseKey("DD-AAAAA-BBBBB-CCCCC-DDDDD")
        let sent = try XCTUnwrap(service.activateCalls.first)
        XCTAssertEqual(sent.machineName, MachineIdentity.machineName())
        let payload = try XCTUnwrap(model.licensePayload)
        XCTAssertEqual(payload.machines.map(\.name), [MachineIdentity.machineName()])
        XCTAssertEqual(payload.machines.map(\.id), [MachineIdentity.machineId()])
    }

    @MainActor
    func testRecoverSendsTheEmail() async throws {
        let service = FakeLicenseService()
        let model = try makeModel(service: service)

        await model.recoverLicenseKey(email: "someone@example.com")

        XCTAssertEqual(service.recoveredEmails, ["someone@example.com"])
    }
}
