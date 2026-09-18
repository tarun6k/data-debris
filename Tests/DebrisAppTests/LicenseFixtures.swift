import CryptoKit
import DebrisCore
import Foundation
@testable import DataDebris

/// In-memory license fixtures for app tests: an ephemeral keypair standing in
/// for the worker's, and stores pre-seeded Free or Active — never the real
/// Keychain (this Mac may hold a real license).
enum LicenseFixture {

    final class MemorySecretStore: SecretStore {
        var blob: Data?
        func read() -> Data? { blob }
        func write(_ data: Data) throws { blob = data }
        func delete() { blob = nil }
    }

    static let signingKey = Curve25519.Signing.PrivateKey()
    static var publicKey: Data { signingKey.publicKey.rawRepresentation }

    /// "Now" for every app test: 2027-01-15 — never the wall clock.
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    static func clock() -> FixedClock { FixedClock(epoch) }

    static func payload(
        now: Date = epoch,
        expiresIn: TimeInterval = 200 * 86_400,
        plan: LicensePlan = .oneYear,
        status: LicenseStatus = .active,
        autoRenew: Bool = false,
        machines: [LicensedMachine] = [LicensedMachine(id: "machine-1", name: "Test Mac")],
        key: String = "DD-TESTK-EYFOR-APPXX-TESTS"
    ) -> EntitlementPayload {
        EntitlementPayload(
            key: key, plan: plan,
            expiresAt: Int(now.addingTimeInterval(expiresIn).timeIntervalSince1970),
            status: status, autoRenew: autoRenew, machines: machines,
            issuedAt: Int(now.timeIntervalSince1970), machineId: machines[0].id)
    }

    static func compact(_ payload: EntitlementPayload) -> String {
        func b64url(_ d: Data) -> String {
            d.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let body = try! JSONEncoder().encode(payload)
        return "\(b64url(body)).\(b64url(try! signingKey.signature(for: body)))"
    }

    static func freeStore(clock: Clock = FixedClock(epoch)) -> LicenseStore {
        LicenseStore(backing: MemorySecretStore(), publicKey: publicKey, clock: clock)
    }

    static func activeStore(payload: EntitlementPayload? = nil,
                            clock: Clock = FixedClock(epoch)) -> LicenseStore {
        let store = freeStore(clock: clock)
        let p = payload ?? self.payload()
        try! store.save(licenseKey: p.key, entitlement: compact(p), lastValidatedAt: clock.now())
        return store
    }
}

/// Scriptable stand-in for the worker; every call is recorded.
final class FakeLicenseService: LicenseService {
    var clock: Clock = FixedClock(LicenseFixture.epoch)
    var keysByReference: [String: String] = [:]
    var activateError: LicenseClientError?
    var validatePayload: EntitlementPayload?
    var byReferenceCalls = 0
    var activateCalls: [(key: String, machineId: String, machineName: String)] = []
    var deactivateCalls: [(key: String, machineId: String)] = []
    var recoveredEmails: [String] = []
    var onDeactivate: (() -> Void)?

    func byReference(_ reference: String) async throws -> String? {
        byReferenceCalls += 1
        return keysByReference[reference]
    }

    func activate(key: String, machineId: String, machineName: String) async throws -> String {
        activateCalls.append((key, machineId, machineName))
        if let error = activateError { throw error }
        return LicenseFixture.compact(LicenseFixture.payload(
            machines: [LicensedMachine(id: machineId, name: machineName,
                                       activatedAt: Int(clock.now().timeIntervalSince1970))],
            key: key))
    }

    func validate(key: String, machineId: String) async throws -> String {
        guard let payload = validatePayload else { throw LicenseClientError.badResponse(0) }
        return LicenseFixture.compact(payload)
    }

    func deactivate(key: String, machineId: String) async throws {
        deactivateCalls.append((key, machineId))
        onDeactivate?()
    }

    func recover(email: String) async throws {
        recoveredEmails.append(email)
    }
}
