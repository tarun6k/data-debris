import CryptoKit
import Foundation

/// The Ed25519 public key matching the license worker's LICENSE_SIGNING_KEY.
/// Raw 32 bytes, base64. Public by design — only the worker holds the private
/// half, so a valid signature proves the entitlement came from our service.
public enum LicensePublicKey {
    public static let production = Data(base64Encoded: "AocYNgpzIz7JNbN6O8TUQ7xM1z7yacZKE1vG9ioykt0=")!
}

public enum LicensePlan: String, Codable, Sendable {
    case oneYear, threeYears
}

public enum LicenseStatus: String, Codable, Sendable {
    case active, canceled, refunded
    case pastDue = "past_due"
}

/// What the worker signs. Dates are Unix epoch seconds — no ISO parsing on
/// either side.
public struct EntitlementPayload: Codable, Equatable, Sendable {
    public var key: String
    public var plan: LicensePlan
    public var expiresAt: Int
    public var status: LicenseStatus
    public var autoRenew: Bool
    public var machines: [String]
    public var issuedAt: Int
    public var machineId: String

    public init(key: String, plan: LicensePlan, expiresAt: Int, status: LicenseStatus,
                autoRenew: Bool, machines: [String], issuedAt: Int, machineId: String) {
        self.key = key
        self.plan = plan
        self.expiresAt = expiresAt
        self.status = status
        self.autoRenew = autoRenew
        self.machines = machines
        self.issuedAt = issuedAt
        self.machineId = machineId
    }

    public var expiryDate: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt)) }
}

/// "base64url(payload JSON).base64url(signature)" as issued by /activate and
/// /validate. Verification failure of any kind returns nil: the caller treats
/// that as Free, never as a soft error.
public enum SignedEntitlement {

    public static func verify(_ compact: String, publicKey: Data = LicensePublicKey.production) -> EntitlementPayload? {
        let parts = compact.split(separator: ".")
        guard parts.count == 2,
              let payload = base64urlDecode(String(parts[0])),
              let signature = base64urlDecode(String(parts[1])),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(signature, for: payload)
        else { return nil }
        return try? JSONDecoder().decode(EntitlementPayload.self, from: payload)
    }

    static func base64urlDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }
}

// MARK: - Entitlement state

public enum EntitlementState: Equatable, Sendable {
    case free
    case active(plan: LicensePlan, expiresAt: Date, autoRenew: Bool, machines: [String])
    case expiring(daysLeft: Int)
    case lapsed(since: Date)
    case offlineGrace(until: Date)
    case pastDue

    /// Cleaning, Auto Clean and Duplicates unlock in these states; everything
    /// else is Free (scans, results, History and Undo always work).
    public var isEntitled: Bool {
        switch self {
        case .active, .expiring, .offlineGrace: return true
        case .free, .lapsed, .pastDue: return false
        }
    }

    public static let validateInterval: TimeInterval = 24 * 3600
    public static let offlineGracePeriod: TimeInterval = 30 * 24 * 3600
    public static let expiringWindow: TimeInterval = 14 * 24 * 3600

    /// The whole policy in one pure function: a cached, signature-verified
    /// payload plus when it was last validated against the service.
    public static func derive(payload: EntitlementPayload?, lastValidatedAt: Date, now: Date) -> EntitlementState {
        guard let payload else { return .free }
        switch payload.status {
        case .refunded: return .free // entitlement ends immediately
        case .pastDue: return .pastDue
        case .active, .canceled: break // canceled runs to term
        }
        let expires = payload.expiryDate
        if expires <= now { return .lapsed(since: expires) }

        let graceEnds = lastValidatedAt.addingTimeInterval(offlineGracePeriod)
        if now >= graceEnds { return .lapsed(since: graceEnds) }
        if now.timeIntervalSince(lastValidatedAt) > validateInterval {
            return .offlineGrace(until: graceEnds)
        }
        if expires.timeIntervalSince(now) <= expiringWindow {
            return .expiring(daysLeft: Int(expires.timeIntervalSince(now) / 86_400))
        }
        return .active(plan: payload.plan, expiresAt: expires,
                       autoRenew: payload.autoRenew, machines: payload.machines)
    }
}

// MARK: - Gate

public enum LockedFeature: CaseIterable, Sendable {
    case clean, autoClean, duplicates
}

public enum GateResult: Equatable, Sendable {
    case allowed
    case needsPurchase
}
