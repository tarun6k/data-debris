import Combine
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

    /// The gate the sheet actually binds to, driven by a fake scroll-position
    /// publisher: Continue stays off until the content's bottom edge is inside
    /// the viewport AND the box is ticked; reaching the end latches.
    @MainActor
    func testContinueGateFollowsScrollPositionAndTick() {
        let positions = PassthroughSubject<PrivacySheetGate.ScrollPosition, Never>()
        let gate = PrivacySheetGate(positions: positions)
        XCTAssertFalse(gate.ticked, "never pre-ticked")
        XCTAssertFalse(gate.continueEnabled)

        // Tall content, scrolled to the top: the bottom edge is far below the viewport.
        positions.send(.init(contentMaxY: 1_400, viewportHeight: 420))
        XCTAssertFalse(gate.scrolledToEnd)
        gate.ticked = true
        XCTAssertFalse(gate.continueEnabled, "ticked but not scrolled to the end")

        positions.send(.init(contentMaxY: 700, viewportHeight: 420)) // halfway
        XCTAssertFalse(gate.continueEnabled)
        positions.send(.init(contentMaxY: 426, viewportHeight: 420)) // within 8 pt tolerance
        XCTAssertTrue(gate.scrolledToEnd)
        XCTAssertTrue(gate.continueEnabled)

        positions.send(.init(contentMaxY: 1_400, viewportHeight: 420)) // scrolled back up
        XCTAssertTrue(gate.scrolledToEnd, "reaching the end latches")
        XCTAssertTrue(gate.continueEnabled)

        gate.ticked = false
        XCTAssertFalse(gate.continueEnabled, "unticking re-locks")

        // The other order: end first, then tick.
        let positions2 = PassthroughSubject<PrivacySheetGate.ScrollPosition, Never>()
        let gate2 = PrivacySheetGate(positions: positions2)
        positions2.send(.init(contentMaxY: 400, viewportHeight: 420))
        XCTAssertTrue(gate2.scrolledToEnd)
        XCTAssertFalse(gate2.continueEnabled, "scrolled but not ticked")
        gate2.ticked = true
        XCTAssertTrue(gate2.continueEnabled)
        // Just outside the tolerance is not the end.
        let positions3 = PassthroughSubject<PrivacySheetGate.ScrollPosition, Never>()
        let gate3 = PrivacySheetGate(positions: positions3)
        positions3.send(.init(contentMaxY: 429, viewportHeight: 420))
        XCTAssertFalse(gate3.scrolledToEnd)
    }

    /// The hash covers the copy only: moving the worker or the update feed
    /// changes what is rendered but not the acknowledgement.
    func testHashIgnoresHostnames() {
        let sameText = PrivacySheetText(updateHost: "updates.datadebris.app",
                                        licenseHost: "license.datadebris.app")
        XCTAssertEqual(text.textHash, sameText.textHash)
        XCTAssertEqual(text.textHash.count, 64)

        let moved = PrivacySheetText(updateHost: "u.example", licenseHost: "other.example")
        XCTAssertEqual(text.textHash, moved.textHash)
        XCTAssertNotEqual(text.allStrings, moved.allStrings, "the rendered text did change")
        XCTAssertTrue(moved.allStrings.joined().contains("other.example"))
        for string in text.hashedStrings {
            XCTAssertFalse(string.contains("datadebris.app"), "hostname in hash input: \(string)")
            XCTAssertFalse(string.contains("https://"), "URL in hash input: \(string)")
        }
    }

    /// Any change to a sentence, a pill or a link label changes the hash,
    /// which re-shows the sheet once (the model check is in PurchaseFlowTests).
    func testHashChangesWhenASentenceChanges() {
        var sentence = PrivacySheetText.Copy.current
        sentence.deletionBody += " Nothing is ever shredded."
        XCTAssertNotEqual(text.textHash, PrivacySheetText(copy: sentence).textHash)

        var pill = PrivacySheetText.Copy.current
        pill.paymentPill = "Refund"
        XCTAssertNotEqual(text.textHash, PrivacySheetText(copy: pill).textHash)

        var label = PrivacySheetText.Copy.current
        label.securityLink = "Security"
        XCTAssertNotEqual(text.textHash, PrivacySheetText(copy: label).textHash)

        var network = PrivacySheetText.Copy.current
        network.networkBody = network.networkBody.replacingOccurrences(
            of: "No telemetry by default.", with: "No telemetry.")
        XCTAssertNotEqual(text.textHash, PrivacySheetText(copy: network).textHash)
    }

    /// The fixed section order and the exact copy the task specifies.
    func testSectionOrderAndCopy() {
        XCTAssertEqual(text.sections.map(\.title), [
            "What we can see", "What leaves your Mac", "How deletion works", "Your payment",
        ])
        XCTAssertEqual(text.sections.map(\.pill), ["Scope", "Private", "Reversible", "Refundable"])
        XCTAssertEqual(text.sections[0].link, "See the never-touch list")
        XCTAssertEqual(text.linksRow,
                       "Privacy Policy · Terms · Security page — also available offline under About")
        XCTAssertFalse(text.sections[1].body.contains("{"), "placeholders must be filled")
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
