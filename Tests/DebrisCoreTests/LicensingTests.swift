import CryptoKit
import XCTest
@testable import DebrisCore

/// Entitlement state machine, Keychain round-trip against a fake, signature
/// checks, the feature gate and the LaunchAgent-on-lapse policy — all against
/// an ephemeral Ed25519 keypair standing in for the license worker's.
final class LicensingTests: XCTestCase {

    private final class FakeSecretStore: SecretStore {
        var blob: Data?
        func read() -> Data? { blob }
        func write(_ data: Data) throws { blob = data }
        func delete() { blob = nil }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var clock: FixedClock!
    private let signingKey = Curve25519.Signing.PrivateKey()
    private var publicKey: Data { signingKey.publicKey.rawRepresentation }
    private var backing: FakeSecretStore!

    override func setUp() {
        backing = FakeSecretStore()
        clock = FixedClock(now)
    }

    // MARK: - Helpers

    private func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func compact(_ payload: EntitlementPayload) throws -> String {
        let body = try JSONEncoder().encode(payload)
        let signature = try signingKey.signature(for: body)
        return "\(b64url(body)).\(b64url(signature))"
    }

    private func payload(
        status: LicenseStatus = .active,
        expiresIn: TimeInterval,
        plan: LicensePlan = .oneYear,
        autoRenew: Bool = false,
        machines: [LicensedMachine] = [LicensedMachine(id: "m1", name: "Studio", activatedAt: 1_799_990_000)]
    ) -> EntitlementPayload {
        EntitlementPayload(
            key: "DD-TESTKEY", plan: plan,
            expiresAt: Int(now.addingTimeInterval(expiresIn).timeIntervalSince1970),
            status: status, autoRenew: autoRenew, machines: machines,
            issuedAt: Int(now.timeIntervalSince1970), machineId: "m1")
    }

    private func store() -> LicenseStore {
        LicenseStore(backing: backing, publicKey: publicKey, clock: clock)
    }

    private func entitlements(_ p: EntitlementPayload?, validatedAgo: TimeInterval = 0) throws -> Entitlements {
        let s = store()
        if let p {
            try s.save(licenseKey: p.key, entitlement: try compact(p),
                       lastValidatedAt: now.addingTimeInterval(-validatedAgo))
        }
        return Entitlements(store: s, clock: clock)
    }

    private func derive(_ p: EntitlementPayload?, validatedAgo: TimeInterval = 0) -> EntitlementState {
        EntitlementState.derive(payload: p, lastValidatedAt: now.addingTimeInterval(-validatedAgo), now: now)
    }

    // MARK: - State machine

    func testNoEntitlementIsFree() throws {
        XCTAssertEqual(derive(nil), .free)
        XCTAssertEqual(try entitlements(nil).state, .free)
    }

    func testActive() throws {
        let p = payload(expiresIn: 200 * 86_400, plan: .threeYears, autoRenew: true)
        XCTAssertEqual(derive(p), .active(plan: .threeYears, expiresAt: p.expiryDate,
                                          autoRenew: true, machines: p.machines))
        XCTAssertEqual(try entitlements(p).state, derive(p))
    }

    func testExpiringWindowIsFourteenDays() {
        XCTAssertEqual(derive(payload(expiresIn: 13.5 * 86_400)), .expiring(daysLeft: 13))
        if case .active = derive(payload(expiresIn: 15 * 86_400)) {} else {
            XCTFail("15 days out is still plain active")
        }
        XCTAssertTrue(derive(payload(expiresIn: 13.5 * 86_400)).isEntitled)
    }

    func testLapsedAfterExpiry() {
        let p = payload(expiresIn: -3_600)
        XCTAssertEqual(derive(p), .lapsed(since: p.expiryDate))
        XCTAssertFalse(derive(p).isEntitled)
    }

    func testRefundedIsFreeImmediately() {
        XCTAssertEqual(derive(payload(status: .refunded, expiresIn: 200 * 86_400)), .free)
    }

    func testPastDueLocks() {
        let state = derive(payload(status: .pastDue, expiresIn: 200 * 86_400))
        XCTAssertEqual(state, .pastDue)
        XCTAssertFalse(state.isEntitled)
    }

    func testCanceledKeepsAccessUntilExpiry() {
        let running = derive(payload(status: .canceled, expiresIn: 100 * 86_400))
        XCTAssertTrue(running.isEntitled)
        let over = payload(status: .canceled, expiresIn: -60)
        XCTAssertEqual(derive(over), .lapsed(since: over.expiryDate))
    }

    func testOfflineGraceAfterOverdueValidation() {
        let state = derive(payload(expiresIn: 200 * 86_400), validatedAgo: 25 * 3_600)
        let graceEnds = now.addingTimeInterval(-25 * 3_600)
            .addingTimeInterval(EntitlementState.offlineGracePeriod)
        XCTAssertEqual(state, .offlineGrace(until: graceEnds))
        XCTAssertTrue(state.isEntitled)
    }

    func testOfflineGraceExpiryLapses() {
        let p = payload(expiresIn: 200 * 86_400)
        let justInside = derive(p, validatedAgo: EntitlementState.offlineGracePeriod - 60)
        if case .offlineGrace = justInside {} else { XCTFail("still inside grace") }
        let justPast = derive(p, validatedAgo: EntitlementState.offlineGracePeriod + 60)
        if case .lapsed = justPast {} else { XCTFail("grace ran out, must lapse") }
        XCTAssertFalse(justPast.isEntitled)
    }

    // MARK: - Store and signatures

    func testKeychainRoundTrip() throws {
        let p = payload(expiresIn: 100 * 86_400)
        let s = store()
        try s.save(licenseKey: p.key, entitlement: try compact(p), lastValidatedAt: now)
        let loaded = try XCTUnwrap(s.load())
        XCTAssertEqual(loaded.payload, p)
        XCTAssertEqual(loaded.stored.licenseKey, "DD-TESTKEY")
        XCTAssertEqual(loaded.stored.lastValidatedAt, now)
        s.clear()
        XCTAssertNil(s.load())
    }

    func testTamperedEntitlementIsFree() throws {
        let p = payload(expiresIn: 100 * 86_400)
        let good = try compact(p)
        // Flip one character inside the signed payload half.
        var chars = Array(good)
        chars[2] = chars[2] == "A" ? "B" : "A"
        let bad = String(chars)

        XCTAssertNil(SignedEntitlement.verify(bad, publicKey: publicKey))
        XCTAssertThrowsError(try store().save(licenseKey: p.key, entitlement: bad, lastValidatedAt: now))

        // A tampered blob already in the Keychain reads back as Free.
        let stored = LicenseStore.Stored(licenseKey: p.key, entitlement: bad, lastValidatedAt: now)
        backing.blob = try JSONEncoder().encode(stored)
        XCTAssertNil(store().load())
        XCTAssertEqual(Entitlements(store: store(), clock: clock).state, .free)
    }

    /// The worker's JSON shape: machines as {id, name, activatedAt}.
    func testNamedMachinesRoundTripThroughTheWire() throws {
        let json = """
        {"key":"DD-TESTKEY","plan":"oneYear","expiresAt":1900000000,"status":"active",
         "autoRenew":false,"issuedAt":1800000000,"machineId":"m1",
         "machines":[{"id":"m1","name":"Studio","activatedAt":1799990000},
                     {"id":"m2","name":"","activatedAt":1799995000}]}
        """
        let decoded = try JSONDecoder().decode(EntitlementPayload.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.machines, [
            LicensedMachine(id: "m1", name: "Studio", activatedAt: 1_799_990_000),
            LicensedMachine(id: "m2", name: "", activatedAt: 1_799_995_000),
        ])
        XCTAssertEqual(decoded.machines[0].displayName, "Studio")
        XCTAssertEqual(decoded.machines[1].displayName, "Mac \u{2026}m2")
        XCTAssertEqual(decoded.machines[0].activatedDate, Date(timeIntervalSince1970: 1_799_990_000))
        // Signed as-is, it verifies and reads back identical.
        let signed = try compact(decoded)
        XCTAssertEqual(SignedEntitlement.verify(signed, publicKey: publicKey), decoded)
    }

    /// Entitlements issued before names existed carry plain ids. They are
    /// still validly signed and must keep working — as unnamed machines.
    func testLegacyIdOnlyMachinesStillDecode() throws {
        let json = """
        {"key":"DD-TESTKEY","plan":"oneYear","expiresAt":1900000000,"status":"active",
         "autoRenew":false,"issuedAt":1800000000,"machineId":"m1","machines":["m1","m2"]}
        """
        let decoded = try JSONDecoder().decode(EntitlementPayload.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.machines, [LicensedMachine(id: "m1"), LicensedMachine(id: "m2")])
        XCTAssertNil(decoded.machines[0].activatedAt)
        // Signed in the legacy shape, the store still trusts it.
        let body = Data(json.utf8)
        let legacy = "\(b64url(body)).\(b64url(try signingKey.signature(for: body)))"
        let s = store()
        try s.save(licenseKey: "DD-TESTKEY", entitlement: legacy, lastValidatedAt: now)
        XCTAssertEqual(try XCTUnwrap(s.load()).payload.machines.map(\.id), ["m1", "m2"])
        XCTAssertTrue(Entitlements(store: s, clock: clock).state.isEntitled)
    }

    func testSignatureFromAnotherKeyIsRejected() throws {
        let good = try compact(payload(expiresIn: 100 * 86_400))
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertNotNil(SignedEntitlement.verify(good, publicKey: publicKey))
        XCTAssertNil(SignedEntitlement.verify(good, publicKey: otherKey))
    }

    // MARK: - Gate

    func testGateBlocksAllLockedFeaturesWhenFree() throws {
        let free = try entitlements(nil)
        for feature in LockedFeature.allCases {
            XCTAssertEqual(free.require(feature), .needsPurchase)
        }
    }

    func testGateAllowsAllLockedFeaturesWhenActive() throws {
        let active = try entitlements(payload(expiresIn: 200 * 86_400))
        for feature in LockedFeature.allCases {
            XCTAssertEqual(active.require(feature), .allowed)
        }
    }

    // MARK: - Validation policy

    func testValidateSkippedWithinTwentyFourHours() async throws {
        let e = try entitlements(payload(expiresIn: 200 * 86_400), validatedAgo: 3_600)
        var calls = 0
        await e.validateIfNeeded(machineId: "m1") { _, _ in
            calls += 1
            return try self.compact(self.payload(expiresIn: 200 * 86_400))
        }
        XCTAssertEqual(calls, 0)
    }

    func testValidateRefreshesEntitlementAndTimestamp() async throws {
        let e = try entitlements(payload(expiresIn: 20 * 86_400), validatedAgo: 25 * 3_600)
        let renewed = payload(expiresIn: 385 * 86_400)
        await e.validateIfNeeded(machineId: "m1") { key, machineId in
            XCTAssertEqual(key, "DD-TESTKEY")
            XCTAssertEqual(machineId, "m1")
            return try self.compact(renewed)
        }
        let loaded = try XCTUnwrap(store().load())
        XCTAssertEqual(loaded.payload, renewed)
        XCTAssertEqual(loaded.stored.lastValidatedAt, now)
        XCTAssertTrue(e.state.isEntitled)
    }

    /// The state machine follows the injected clock: the same cached
    /// entitlement is active, then expiring, then lapsed as time is advanced,
    /// and a save without a stamp uses the clock too.
    func testStateFollowsTheClock() throws {
        let s = store()
        try s.save(licenseKey: "DD-TESTKEY", entitlement: try compact(payload(expiresIn: 40 * 86_400)))
        XCTAssertEqual(try XCTUnwrap(s.load()).stored.lastValidatedAt, now, "stamped by the clock")
        let e = Entitlements(store: s, clock: clock)
        XCTAssertEqual(e.state, .active(plan: .oneYear,
                                        expiresAt: now.addingTimeInterval(40 * 86_400),
                                        autoRenew: false,
                                        machines: payload(expiresIn: 0).machines))

        clock.advance(by: 20 * 86_400)
        if case .offlineGrace = e.state {} else { XCTFail("20 days without validation: grace, got \(e.state)") }
        XCTAssertTrue(e.state.isEntitled)

        clock.advance(by: 21 * 86_400) // day 41: past expiry
        if case .lapsed = e.state {} else { XCTFail("expected lapsed, got \(e.state)") }
        XCTAssertFalse(e.state.isEntitled)
    }

    func testValidateInactiveAnswerClearsToFree() async throws {
        let e = try entitlements(payload(expiresIn: 200 * 86_400), validatedAgo: 25 * 3_600)
        await e.validateIfNeeded(machineId: "m1") { _, _ in throw LicenseClientError.inactive }
        XCTAssertNil(backing.blob)
        XCTAssertEqual(e.state, .free)
    }

    func testValidateNetworkFailureKeepsCachedEntitlement() async throws {
        let e = try entitlements(payload(expiresIn: 200 * 86_400), validatedAgo: 25 * 3_600)
        await e.validateIfNeeded(machineId: "m1") { _, _ in throw URLError(.notConnectedToInternet) }
        if case .offlineGrace = e.state {} else { XCTFail("network failure keeps the cache in grace") }
        XCTAssertTrue(e.state.isEntitled)
    }

    // MARK: - LaunchAgent on lapse

    func testLaunchAgentRemovedOnLapseAndBackOnRenewal() throws {
        let agentsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("debris-license-agents-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: agentsDir) }
        let agents = LaunchAgentManager(agentsDirectory: agentsDir, programPath: "/tmp/dd",
                                        uid: 501, launchctl: { _ in 0 })
        var config = AutoCleanConfig()
        config.enabled = true
        try agents.install(schedule: config.schedule, lowSpaceTrigger: false)
        let plist = agents.plistURL(LaunchAgentManager.label).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist))

        let lapsed = try entitlements(payload(expiresIn: -3_600))
        lapsed.reconcileAutoCleanAgent(config: config, agents: agents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist))

        backing.blob = nil
        let renewed = try entitlements(payload(expiresIn: 200 * 86_400))
        renewed.reconcileAutoCleanAgent(config: config, agents: agents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist), "user had it on; renewal restores it")
    }

    // MARK: - Machine identity

    func testMachineIdIsAStableHashNotTheRawUUID() {
        let id = MachineIdentity.machineId()
        XCTAssertEqual(id.count, 64)
        XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertEqual(MachineIdentity.machineId(), id)
    }
}
