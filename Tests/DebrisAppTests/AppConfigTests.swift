import XCTest
@testable import DataDebris

/// Resources/AppConfig.plist is the only source of the app's URLs and
/// hostnames; both variants must load and point where the product says.
final class AppConfigTests: XCTestCase {

    func testBothVariantsLoadFromTheBundle() throws {
        let debug = try AppConfig.load(variant: .debug)
        let release = try AppConfig.load(variant: .release)

        for config in [debug, release] {
            for url in [config.privacyPolicyURL, config.termsURL, config.securityURL,
                        config.customerPortalURL] {
                XCTAssertEqual(url.scheme, "https", url.absoluteString)
            }
            XCTAssertEqual(config.privacyPolicyURL.host, "datadebris.app")
            XCTAssertEqual(config.termsURL.host, "datadebris.app")
            XCTAssertEqual(config.securityURL.host, "datadebris.app")
            XCTAssertEqual(config.updateHost, "updates.datadebris.app")
            XCTAssertEqual(config.updateFeedURL.absoluteString,
                           "https://updates.datadebris.app/appcast.xml")
            XCTAssertEqual(config.supportEmail, "support@datadebris.app")
            // The beta ships the free edition in both configurations.
            XCTAssertEqual(config.edition, .free)
        }
        // Debug talks to `wrangler dev` and the sandbox portal; Release to production.
        XCTAssertEqual(debug.licenseWorkerURL.host, "127.0.0.1")
        XCTAssertEqual(debug.customerPortalURL.host, "sandbox-customer-portal.paddle.com")
        XCTAssertEqual(release.licenseWorkerURL.absoluteString, "https://license.datadebris.app")
        XCTAssertEqual(release.licenseHost, "license.datadebris.app")
        XCTAssertEqual(release.customerPortalURL.host, "customer-portal.paddle.com")
    }

    func testCurrentFollowsTheBuildConfiguration() throws {
        #if DEBUG
        XCTAssertEqual(AppConfig.current, try AppConfig.load(variant: .debug))
        #else
        XCTAssertEqual(AppConfig.current, try AppConfig.load(variant: .release))
        #endif
    }

    /// The legal links and the customer-portal buttons read AppConfig, not
    /// literals: swapping the config swaps every URL.
    func testLegalDocumentsFollowTheConfig() throws {
        let config = AppConfig(
            privacyPolicyURL: URL(string: "https://example.test/p")!,
            termsURL: URL(string: "https://example.test/t")!,
            securityURL: URL(string: "https://example.test/s")!,
            customerPortalURL: URL(string: "https://example.test/portal")!,
            updateHost: "u.example.test",
            licenseWorkerURL: URL(string: "https://l.example.test")!)
        XCTAssertEqual(LegalDocument.privacyPolicy.webURL(in: config).path, "/p")
        XCTAssertEqual(LegalDocument.terms.webURL(in: config).path, "/t")
        XCTAssertEqual(LegalDocument.security.webURL(in: config).path, "/s")
        XCTAssertEqual(LegalDocument.privacyPolicy.webURL, AppConfig.current.privacyPolicyURL)
        XCTAssertEqual(config.licenseHost, "l.example.test")
    }

    /// The worker URL the client uses comes from the config (Debug may
    /// override it from .env, which the fixture below has no access to).
    func testLicenseConfigTakesTheWorkerURLFromAppConfig() {
        let config = AppConfig(
            privacyPolicyURL: URL(string: "https://example.test/p")!,
            termsURL: URL(string: "https://example.test/t")!,
            securityURL: URL(string: "https://example.test/s")!,
            customerPortalURL: URL(string: "https://example.test/portal")!,
            updateHost: "u.example.test",
            licenseWorkerURL: URL(string: "https://l.example.test")!)
        let license = LicenseConfig.load(appConfig: config)
        #if DEBUG
        // The repo .env may override in Debug; either way it is never nil.
        XCTAssertNotNil(license.workerURL)
        #else
        XCTAssertEqual(license.workerURL, config.licenseWorkerURL)
        #endif
    }

    func testMissingOrMalformedKeysFailLoudly() {
        XCTAssertThrowsError(try AppConfig(plist: [:])) {
            XCTAssertEqual($0 as? AppConfig.LoadError, .missingKey("PrivacyPolicyURL"))
        }
        XCTAssertThrowsError(try AppConfig(plist: [
            "PrivacyPolicyURL": "https://example.test/p", "TermsURL": "https://example.test/t",
            "SecurityURL": "https://example.test/s", "CustomerPortalURL": "not a url",
            "UpdateHost": "u", "LicenseWorkerURL": "https://l.example.test",
        ])) {
            XCTAssertEqual($0 as? AppConfig.LoadError, .badURL("CustomerPortalURL"))
        }
        // The feed must sit on the host the privacy sheet names.
        XCTAssertThrowsError(try AppConfig(plist: [
            "PrivacyPolicyURL": "https://example.test/p", "TermsURL": "https://example.test/t",
            "SecurityURL": "https://example.test/s", "CustomerPortalURL": "https://example.test/c",
            "UpdateHost": "u.example.test", "UpdateFeedURL": "https://other.example.test/appcast.xml",
            "LicenseWorkerURL": "https://l.example.test", "SupportEmail": "support@example.test",
        ])) {
            XCTAssertEqual($0 as? AppConfig.LoadError, .badURL("UpdateFeedURL"))
        }
        XCTAssertThrowsError(try AppConfig.load(variant: .release, bundle: Bundle(for: XCTestCase.self))) {
            XCTAssertEqual($0 as? AppConfig.LoadError, .missingResource)
        }
    }

    /// PurchasesEnabled is required and must be a real boolean: a missing key
    /// or a "false" string must not silently ship the licensed edition.
    func testPurchasesEnabledIsRequiredAndMustBeABoolean() throws {
        var plist: [String: Any] = [
            "PrivacyPolicyURL": "https://example.test/p", "TermsURL": "https://example.test/t",
            "SecurityURL": "https://example.test/s", "CustomerPortalURL": "https://example.test/c",
            "UpdateHost": "u.example.test", "UpdateFeedURL": "https://u.example.test/appcast.xml",
            "LicenseWorkerURL": "https://l.example.test", "SupportEmail": "support@example.test",
        ]
        XCTAssertThrowsError(try AppConfig(plist: plist)) {
            XCTAssertEqual($0 as? AppConfig.LoadError, .missingKey("PurchasesEnabled"))
        }
        for wrong: Any in ["false", 1, 0] {
            plist["PurchasesEnabled"] = wrong
            XCTAssertThrowsError(try AppConfig(plist: plist), "\(wrong)") {
                XCTAssertEqual($0 as? AppConfig.LoadError, .badValue("PurchasesEnabled"))
            }
        }
        plist["PurchasesEnabled"] = false
        XCTAssertEqual(try AppConfig(plist: plist).edition, .free)
        plist["PurchasesEnabled"] = true
        XCTAssertEqual(try AppConfig(plist: plist).edition, .licensed)
        XCTAssertEqual(Edition(purchasesEnabled: false), .free)
        XCTAssertEqual(Edition(purchasesEnabled: true), .licensed)
    }
}
