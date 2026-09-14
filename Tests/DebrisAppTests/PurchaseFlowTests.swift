import XCTest
import DebrisCore
@testable import DataDebris

/// The purchase coordinator: gate order, the acknowledgement hash, polling
/// lifecycle, activation outcomes and resuming the original action — all
/// against FakeLicenseService and in-memory license stores.
final class PurchaseFlowTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PurchaseFlowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    @MainActor
    private func makeModel(
        licenseStore: LicenseStore? = nil,
        service: FakeLicenseService = FakeLicenseService(),
        privacyText: PrivacySheetText = PrivacySheetText(updateHost: "u.example", licenseHost: "l.example")
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
            privacyText: privacyText)
    }

    /// A flow on its own, with every seam injected and a fast poll.
    @MainActor
    private func makeFlow(
        resume: PurchaseFlow.ResumeAction = .none,
        acknowledged: Bool = false,
        service: FakeLicenseService = FakeLicenseService(),
        store: LicenseStore = LicenseFixture.freeStore(),
        pollInterval: TimeInterval = 0.01,
        launchCheckout: @escaping (LicensePlan, Bool, String) -> Void = { _, _, _ in },
        recordAcknowledgement: @escaping () -> Void = {},
        onDone: @escaping (PurchaseFlow, PurchaseFlow.Outcome) -> Void = { _, _ in }
    ) -> PurchaseFlow {
        PurchaseFlow(
            resume: resume, acknowledged: acknowledged, service: service, store: store,
            machineId: "this-machine", machineName: "Test Mac", pollInterval: pollInterval,
            launchCheckout: launchCheckout, recordAcknowledgement: recordAcknowledgement,
            onDone: onDone)
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

    // MARK: - Gate order

    /// Locked action → privacy sheet first; Review does not open (S2 intact).
    @MainActor
    func testLockedCleanOpensPurchaseWithPrivacyFirst() throws {
        let model = try makeModel()
        try seedSelectedFinding(model)
        XCTAssertFalse(model.entitlementState.isEntitled)

        model.openReview()
        XCTAssertNil(model.cleanFlow)
        let flow = try XCTUnwrap(model.purchase)
        XCTAssertEqual(flow.step, .privacy)
        XCTAssertEqual(flow.resume, .openReview(.manual))
    }

    /// Fixed order: privacy → plan → checkout. A plan cannot be chosen while
    /// the privacy sheet is up, and checkout only launches from the plan step.
    @MainActor
    func testGateOrderPrivacyPlanCheckout() {
        var launches: [(plan: LicensePlan, autoRenew: Bool, reference: String)] = []
        var acknowledged = 0
        let flow = makeFlow(
            launchCheckout: { launches.append(($0, $1, $2)) },
            recordAcknowledgement: { acknowledged += 1 })

        XCTAssertEqual(flow.step, .privacy)
        flow.choosePlan(.oneYear) // out of order — must be a no-op
        XCTAssertTrue(launches.isEmpty)
        XCTAssertEqual(flow.step, .privacy)

        flow.acknowledgePrivacy()
        XCTAssertEqual(acknowledged, 1)
        XCTAssertEqual(flow.step, .plan)

        flow.choosePlan(.threeYears)
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches[0].plan, .threeYears)
        XCTAssertFalse(launches[0].autoRenew, "auto-renew is off by default")
        let short = String(launches[0].reference.prefix(8))
        XCTAssertEqual(flow.step, .waiting(shortReference: short))
        flow.cancel()
    }

    /// The privacy sheet is skipped only when the stored hash matches the
    /// current text; any text change re-triggers it once.
    @MainActor
    func testPrivacySkippedOnlyWhenTextHashMatches() throws {
        let model = try makeModel()
        model.startPurchase()
        model.purchase?.acknowledgePrivacy()
        model.purchase?.cancel()
        XCTAssertNil(model.purchase)
        XCTAssertTrue(model.privacyAcknowledged)

        model.startPurchase()
        XCTAssertEqual(model.purchase?.step, .plan, "same text: sheet skipped")
        model.purchase?.cancel()

        // Same settings.json, changed sheet text → shown again.
        let changed = try makeModel(
            privacyText: PrivacySheetText(updateHost: "u.example", licenseHost: "changed.example"))
        XCTAssertFalse(changed.privacyAcknowledged)
        changed.startPurchase()
        XCTAssertEqual(changed.purchase?.step, .privacy)
        changed.purchase?.cancel()
    }

    // MARK: - Price ids

    func testAutoRenewSelectsRecurringVersusOneTimePriceId() {
        let config = LicenseConfig(
            workerURL: nil, paddleClientToken: nil, paddleEnv: "sandbox",
            priceIds: [
                "PADDLE_PRICE_1Y_RECURRING": "pri-1r", "PADDLE_PRICE_1Y_ONETIME": "pri-1o",
                "PADDLE_PRICE_3Y_RECURRING": "pri-3r", "PADDLE_PRICE_3Y_ONETIME": "pri-3o",
            ],
            portalURL: URL(string: "https://example.com")!)
        XCTAssertEqual(config.priceId(plan: .oneYear, autoRenew: false), "pri-1o")
        XCTAssertEqual(config.priceId(plan: .oneYear, autoRenew: true), "pri-1r")
        XCTAssertEqual(config.priceId(plan: .threeYears, autoRenew: false), "pri-3o")
        XCTAssertEqual(config.priceId(plan: .threeYears, autoRenew: true), "pri-3r")
    }

    // MARK: - Polling

    @MainActor
    func testPollingStopsOnCancel() async throws {
        let service = FakeLicenseService()
        var outcome: PurchaseFlow.Outcome?
        let flow = makeFlow(service: service, onDone: { outcome = $1 })
        flow.acknowledgePrivacy()
        flow.choosePlan(.oneYear)

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(service.byReferenceCalls, 0, "polling is running")

        flow.cancel()
        if case .cancelled = outcome {} else { XCTFail("cancel reports cancelled") }
        // One check may already be in flight at cancel; let it drain, then quiet.
        try await Task.sleep(nanoseconds: 50_000_000)
        let after = service.byReferenceCalls
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(service.byReferenceCalls, after, "no polls after cancel")
    }

    @MainActor
    func testKeyArrivalActivatesStoresAndReportsPayload() async throws {
        let service = FakeLicenseService()
        let store = LicenseFixture.freeStore()
        var reference: String?
        var outcome: PurchaseFlow.Outcome?
        let done = expectation(description: "activated")
        let flow = makeFlow(
            service: service, store: store,
            launchCheckout: { _, _, ref in reference = ref },
            onDone: { outcome = $1; done.fulfill() })
        flow.acknowledgePrivacy()
        flow.choosePlan(.oneYear)
        service.keysByReference[try XCTUnwrap(reference)] = "DD-AAAAA-BBBBB-CCCCC-DDDDD"

        await fulfillment(of: [done], timeout: 2)
        guard case .activated(let payload)? = outcome else { return XCTFail("expected activation") }
        XCTAssertEqual(payload.key, "DD-AAAAA-BBBBB-CCCCC-DDDDD")
        XCTAssertEqual(service.activateCalls.first?.machineId, "this-machine")
        XCTAssertEqual(store.load()?.stored.licenseKey, "DD-AAAAA-BBBBB-CCCCC-DDDDD")
    }

    // MARK: - Activation outcomes

    @MainActor
    func testActivationLimitOffersManageMacsThenRetries() async {
        let service = FakeLicenseService()
        service.activateError = .activationLimit
        service.validatePayload = LicenseFixture.payload(machines: ["mac-a", "mac-b"])
        service.onDeactivate = { service.activateError = nil }
        var outcome: PurchaseFlow.Outcome?
        let flow = makeFlow(service: service, onDone: { outcome = $1 })

        await flow.enterKey("DD-LIMIT-LIMIT-LIMIT-LIMIT")
        XCTAssertEqual(flow.step, .activationLimit(
            key: "DD-LIMIT-LIMIT-LIMIT-LIMIT", machineIds: ["mac-a", "mac-b"]))

        await flow.deactivateMachine(key: "DD-LIMIT-LIMIT-LIMIT-LIMIT", machineId: "mac-a")
        XCTAssertEqual(service.deactivateCalls.first?.machineId, "mac-a")
        if case .activated = outcome {} else { XCTFail("slot freed, activation retried") }
    }

    // MARK: - Resume

    /// Success resumes the original action: Review reopens on the same
    /// (persisted) selection, and the toast names the expiry.
    @MainActor
    func testActivationResumesReview() async throws {
        let model = try makeModel()
        try seedSelectedFinding(model)
        model.openReview()
        let flow = try XCTUnwrap(model.purchase)
        flow.acknowledgePrivacy()
        await flow.enterKey("DD-AAAAA-BBBBB-CCCCC-DDDDD")

        XCTAssertNil(model.purchase)
        XCTAssertTrue(model.entitlementState.isEntitled)
        XCTAssertNotNil(model.cleanFlow, "Review reopened after activation")
        XCTAssertTrue(try XCTUnwrap(model.licenseToast).hasPrefix("Data Debris is active until "))
    }

    /// The Auto Clean toggle: gated while Free (config untouched), flipped on
    /// by the resume after activation — including the LaunchAgent.
    @MainActor
    func testActivationResumesAutoCleanToggle() async throws {
        let model = try makeModel()
        model.setAutoCleanEnabled(true)
        XCTAssertFalse(model.autoCleanConfig.enabled, "gated: nothing changed")
        let flow = try XCTUnwrap(model.purchase)
        XCTAssertEqual(flow.resume, .enableAutoClean)

        flow.acknowledgePrivacy()
        await flow.enterKey("DD-AAAAA-BBBBB-CCCCC-DDDDD")
        XCTAssertTrue(model.autoCleanConfig.enabled)
        let plist = dir.appendingPathComponent("LaunchAgents")
            .appendingPathComponent(LaunchAgentManager.label + ".plist")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
    }

    /// "Not now" / Esc at any step cancels and leaves everything unchanged.
    @MainActor
    func testCancelLeavesEverythingUnchanged() throws {
        let model = try makeModel()
        try seedSelectedFinding(model)
        let selectedBefore = model.selectedIds
        model.smartClean()
        let flow = try XCTUnwrap(model.purchase)
        XCTAssertEqual(flow.resume, .smartClean)
        XCTAssertEqual(model.selectedIds, selectedBefore, "gate fires before selection changes")

        flow.cancel()
        XCTAssertNil(model.purchase)
        XCTAssertNil(model.cleanFlow)
        XCTAssertFalse(model.entitlementState.isEntitled)
        XCTAssertFalse(model.privacyAcknowledged, "cancel on the privacy step records nothing")
    }
}
