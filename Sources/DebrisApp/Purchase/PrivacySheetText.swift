import CryptoKit
import Foundation

/// Every string on the Privacy & Security sheet (Screen 12), in display
/// order. The acknowledgement stores a SHA-256 over all of them, so any copy
/// change — including a different license hostname — re-shows the sheet once.
struct PrivacySheetText: Equatable {

    struct Section: Equatable {
        let number: Int
        let title: String
        let body: String
        let pill: String
        var link: String?
    }

    let kicker = "BEFORE YOU PAY"
    let title = "How this app treats your Mac"
    let sections: [Section]
    let linksRow = "Privacy Policy · Terms · Security page — also available offline under About"
    let checkboxLabel = "I've read how this app handles my data"

    init(updateHost: String = LicenseConfig.updateHost,
         licenseHost: String = LicenseConfig.current.licenseHost) {
        sections = [
            Section(
                number: 1, title: "What we can see",
                body: "Your home folder, app caches in ~/Library (with Full Disk Access), "
                    + "and volumes you opt in.",
                pill: "Scope", link: "See the never-touch list"),
            Section(
                number: 2, title: "What leaves your Mac",
                body: "Nothing about your files. Two network calls only: a signed update "
                    + "check (\(updateHost)) and a license check (\(licenseHost)). "
                    + "No telemetry by default.",
                pill: "Private"),
            Section(
                number: 3, title: "How deletion works",
                body: "Trash by default · logged before anything moves · one-click Undo · "
                    + "no system folders · no admin password, ever.",
                pill: "Reversible"),
            Section(
                number: 4, title: "Your payment",
                body: "Handled by Paddle, our payment provider; we never see card details. "
                    + "14-day refund. When a plan ends, scanning stays free and nothing "
                    + "is deleted.",
                pill: "Refundable"),
        ]
    }

    /// Order matters: the hash is over the rendered text, top to bottom.
    var allStrings: [String] {
        [kicker, title]
            + sections.flatMap { [$0.title, $0.body, $0.pill] + ($0.link.map { [$0] } ?? []) }
            + [linksRow, checkboxLabel]
    }

    var textHash: String {
        SHA256.hash(data: Data(allStrings.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
