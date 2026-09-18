import XCTest
import Security
@testable import DebrisCore

final class KeychainSecretStoreTests: XCTestCase {
    /// Uses a throwaway account under the test-suffixed service so the real
    /// license item is never touched (the scheme sets APP_SUPPORT_OVERRIDE).
    func testLicenseItemRoundTripsAndIsAfterFirstUnlockThisDeviceOnly() throws {
        let store = KeychainSecretStore(account: "test-\(UUID().uuidString)")
        defer { store.delete() }
        do {
            try store.write(Data("x".utf8))
        } catch LicenseStoreError.keychain(let status) where status == errSecInteractionNotAllowed
            || status == errSecNotAvailable {
            throw XCTSkip("Keychain not available in this test session (\(status))")
        }
        XCTAssertEqual(store.read(), Data("x".utf8))
        try store.write(Data("y".utf8))
        XCTAssertEqual(store.read(), Data("y".utf8), "update path")
        store.delete()
        XCTAssertNil(store.read())

        try store.write(Data("z".utf8))
        guard let accessibility = store.accessibility() else {
            // Ad-hoc signed test host: the file-based login keychain took the
            // item and keeps no accessibility class. Re-run after 8B signing.
            throw XCTSkip("file-based keychain in use (no application identifier); class not verifiable")
        }
        XCTAssertEqual(accessibility, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}
