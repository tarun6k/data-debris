import Foundation
import Security

/// One opaque blob in, one out — the Keychain behind a seam the tests can fake.
public protocol SecretStore {
    func read() -> Data?
    func write(_ data: Data) throws
    func delete()
}

public enum LicenseStoreError: Error, Equatable {
    case keychain(OSStatus)
    case badEntitlement
}

/// kSecClassGenericPassword under the app's license service. Not synchronized:
/// the 2-Mac limit is per machine, an iCloud-synced key would defeat it.
public struct KeychainSecretStore: SecretStore {
    public static let service = "com.tarunkumar.datadebris.license"
    private let account: String

    public init(account: String = "license") {
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    public func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func write(_ data: Data) throws {
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LicenseStoreError.keychain(status) }
    }

    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// The license key, the latest signed entitlement and when the service last
/// confirmed it. The signature is verified on every read — a blob that fails
/// for any reason is Free, not an error state.
public struct LicenseStore {

    public struct Stored: Codable, Equatable {
        public var licenseKey: String
        public var entitlement: String
        public var lastValidatedAt: Date
    }

    private let backing: SecretStore
    /// Exposed so the purchase flow can verify server answers (the machines
    /// list on an activation-limit) against the same key this store trusts.
    public let publicKey: Data

    public init(backing: SecretStore = KeychainSecretStore(),
                publicKey: Data = LicensePublicKey.production) {
        self.backing = backing
        self.publicKey = publicKey
    }

    public func load() -> (payload: EntitlementPayload, stored: Stored)? {
        guard let data = backing.read(),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let payload = SignedEntitlement.verify(stored.entitlement, publicKey: publicKey)
        else { return nil }
        return (payload, stored)
    }

    /// Refuses an entitlement that does not verify — a server bug surfaces
    /// here instead of as a silent fallback to Free on the next read.
    public func save(licenseKey: String, entitlement: String, lastValidatedAt: Date) throws {
        guard SignedEntitlement.verify(entitlement, publicKey: publicKey) != nil else {
            throw LicenseStoreError.badEntitlement
        }
        let stored = Stored(licenseKey: licenseKey, entitlement: entitlement,
                            lastValidatedAt: lastValidatedAt)
        try backing.write(try JSONEncoder().encode(stored))
    }

    public func clear() {
        backing.delete()
    }
}
