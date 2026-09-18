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
/// The service is ".debug"-suffixed under APP_SUPPORT_OVERRIDE (see AppPaths).
/// One generic-password item per install (service + account "license").
///
/// The item goes to the data-protection keychain when the build can use it,
/// with AfterFirstUnlock + ThisDeviceOnly: the LaunchAgent must read the
/// entitlement while the screen is locked, and the item must never travel in
/// an iCloud Keychain or a Migration Assistant transfer (the entitlement is
/// bound to this machine id anyway). The data-protection keychain needs an
/// application identifier, which only a team-signed build carries; an
/// ad-hoc ("Sign to Run Locally") build gets errSecMissingEntitlement and
/// falls back to the file-based login keychain, which ignores the class.
///
/// Signing note: the Keychain ACL is keyed on the app's code-signing
/// designated requirement. Ad-hoc builds get a new one on every build, so
/// each rebuild is a stranger to the item and macOS re-prompts (or denies)
/// the read. Once the app is signed with a Developer ID identity the
/// requirement is stable (team id + bundle id), repeated builds read the
/// same item without a prompt, and the data-protection path above is taken.
/// Nothing in this file changes for that; the service name stays as is.
public struct KeychainSecretStore: SecretStore {
    public static var service: String { AppPaths.keychainService }
    public static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    private let account: String

    public init(account: String = "license") {
        self.account = account
    }

    private func query(dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: Self.service,
                                kSecAttrAccount as String: account]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    public func read() -> Data? {
        for dataProtection in [true, false] {
            var q = query(dataProtection: dataProtection)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data {
                return data
            }
        }
        return nil
    }

    public func write(_ data: Data) throws {
        var status = write(data, dataProtection: true)
        if status == errSecMissingEntitlement || status == errSecNotAvailable
            || status == errSecParam {
            status = write(data, dataProtection: false)
        } else if status == errSecSuccess {
            // An item left by an earlier ad-hoc build must not shadow this one.
            SecItemDelete(query(dataProtection: false) as CFDictionary)
        }
        guard status == errSecSuccess else { throw LicenseStoreError.keychain(status) }
    }

    private func write(_ data: Data, dataProtection: Bool) -> OSStatus {
        let base = query(dataProtection: dataProtection)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: Self.accessible]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = Self.accessible
        return SecItemAdd(add as CFDictionary, nil)
    }

    public func delete() {
        SecItemDelete(query(dataProtection: true) as CFDictionary)
        SecItemDelete(query(dataProtection: false) as CFDictionary)
    }

    /// The stored accessibility class; nil on the file-based keychain, which
    /// does not keep one. For tests and diagnostics.
    public func accessibility() -> String? {
        var q = query(dataProtection: true)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessible as String] as? String
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
    private let clock: Clock

    public init(backing: SecretStore = KeychainSecretStore(),
                publicKey: Data = LicensePublicKey.production,
                clock: Clock = SystemClock()) {
        self.backing = backing
        self.publicKey = publicKey
        self.clock = clock
    }

    public func load() -> (payload: EntitlementPayload, stored: Stored)? {
        guard let data = backing.read(),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let payload = SignedEntitlement.verify(stored.entitlement, publicKey: publicKey)
        else { return nil }
        return (payload, stored)
    }

    /// A fresh answer from the service: validated as of now (by the clock).
    public func save(licenseKey: String, entitlement: String) throws {
        try save(licenseKey: licenseKey, entitlement: entitlement, lastValidatedAt: clock.now())
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
