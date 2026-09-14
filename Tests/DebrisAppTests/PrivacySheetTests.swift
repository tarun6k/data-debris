import XCTest
@testable import DataDebris

/// Screen 12 rules that must never regress: no price on the sheet, the exact
/// hostnames listed, Continue's two conditions, and the hash re-trigger.
final class PrivacySheetTests: XCTestCase {

    private let text = PrivacySheetText(updateHost: "updates.datadebris.app",
                                        licenseHost: "license.datadebris.app")

    /// No price anywhere on this sheet — asserted on the rendered strings.
    func testNoPriceStringAppearsOnThePrivacySheet() {
        for string in text.allStrings {
            XCTAssertFalse(string.contains("$"), string)
            XCTAssertFalse(string.localizedCaseInsensitiveContains("price"), string)
            XCTAssertFalse(string.localizedCaseInsensitiveContains("per month"), string)
        }
    }

    /// "Two network calls only" names both hostnames from configuration.
    func testBothHostnamesAreListed() {
        let joined = text.allStrings.joined(separator: "\n")
        XCTAssertTrue(joined.contains("updates.datadebris.app"))
        XCTAssertTrue(joined.contains("license.datadebris.app"))
        XCTAssertTrue(joined.contains("No telemetry by default"))
    }

    /// Continue needs scrolled-to-end AND ticked — never either alone.
    func testContinueEnabledOnlyWhenScrolledToEndAndTicked() {
        XCTAssertFalse(PrivacySecuritySheet.continueEnabled(scrolledToEnd: false, ticked: false))
        XCTAssertFalse(PrivacySecuritySheet.continueEnabled(scrolledToEnd: true, ticked: false))
        XCTAssertFalse(PrivacySecuritySheet.continueEnabled(scrolledToEnd: false, ticked: true))
        XCTAssertTrue(PrivacySecuritySheet.continueEnabled(scrolledToEnd: true, ticked: true))
    }

    /// Any copy change — even one hostname — changes the hash, which re-shows
    /// the sheet once (the model check is in PurchaseFlowTests).
    func testHashChangesWhenAnyStringChanges() {
        let sameText = PrivacySheetText(updateHost: "updates.datadebris.app",
                                        licenseHost: "license.datadebris.app")
        XCTAssertEqual(text.textHash, sameText.textHash)
        let changed = PrivacySheetText(updateHost: "updates.datadebris.app",
                                       licenseHost: "other.example")
        XCTAssertNotEqual(text.textHash, changed.textHash)
        XCTAssertEqual(text.textHash.count, 64)
    }

    /// The fixed section order and the exact copy the task specifies.
    func testSectionOrderAndCopy() {
        XCTAssertEqual(text.sections.map(\.title), [
            "What we can see", "What leaves your Mac", "How deletion works", "Your payment",
        ])
        XCTAssertEqual(text.sections.map(\.pill), ["Scope", "Private", "Reversible", "Refundable"])
        XCTAssertEqual(text.sections[0].link, "See the never-touch list")
        XCTAssertTrue(text.sections[3].body.hasPrefix("Handled by Paddle, our payment provider"))
        XCTAssertTrue(text.sections[2].body.contains("no admin password, ever"))
        for string in text.allStrings {
            XCTAssertFalse(string.contains("!"), "no exclamation marks: \(string)")
        }
    }

    /// Bundled legal copies exist for offline reading.
    func testBundledLegalDocumentsLoad() {
        for document in LegalDocument.allCases {
            XCTAssertFalse(document.bundledText.contains("bundled copy is missing"),
                           document.rawValue)
        }
    }
}
