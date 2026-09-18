import CryptoKit
import Foundation

/// Every string on the Privacy & Security sheet (Screen 12), in display
/// order. The acknowledgement stores a SHA-256 over the *copy* — the fixed
/// sentences, pills and link labels — so a changed sentence re-shows the
/// sheet once. Hostnames and URLs are configuration, not copy: they are
/// rendered into section 2 but never hashed, so moving the license worker
/// or a legal page does not re-trigger the sheet.
struct PrivacySheetText: Equatable {

    /// The fixed copy. Section 2's body is a template; the two placeholders
    /// are filled with the configured hostnames at render time.
    struct Copy: Equatable {
        static let updateHostPlaceholder = "{updateHost}"
        static let licenseHostPlaceholder = "{licenseHost}"

        var kicker = "BEFORE YOU PAY"
        var title = "How this app treats your Mac"

        var scopeTitle = "What we can see"
        var scopeBody = "Your home folder, app caches in ~/Library (with Full Disk Access), "
            + "and volumes you opt in."
        var scopePill = "Scope"
        var scopeLink = "See the never-touch list"

        var networkTitle = "What leaves your Mac"
        var networkBody = "Nothing about your files. Two network calls only: a signed update "
            + "check (\(updateHostPlaceholder)) and a license check (\(licenseHostPlaceholder)). "
            + "No telemetry by default."
        var networkPill = "Private"

        var deletionTitle = "How deletion works"
        var deletionBody = "Trash by default · logged before anything moves · one-click Undo · "
            + "no system folders · no admin password, ever."
        var deletionPill = "Reversible"

        var paymentTitle = "Your payment"
        var paymentBody = "Handled by Paddle, our payment provider; we never see card details. "
            + "14-day refund. When a plan ends, scanning stays free and nothing "
            + "is deleted."
        var paymentPill = "Refundable"

        var privacyPolicyLink = "Privacy Policy"
        var termsLink = "Terms"
        var securityLink = "Security page"
        var linksSuffix = "— also available offline under About"
        var checkboxLabel = "I've read how this app handles my data"

        static let current = Copy()

        func linkLabel(_ document: LegalDocument) -> String {
            switch document {
            case .privacyPolicy: return privacyPolicyLink
            case .terms: return termsLink
            case .security: return securityLink
            }
        }

        var linkLabels: [String] { LegalDocument.allCases.map(linkLabel) }
    }

    struct Section: Equatable {
        let number: Int
        let title: String
        /// What the sheet shows, hostnames filled in.
        let body: String
        /// What the hash covers: the body template with placeholders intact.
        let hashedBody: String
        let pill: String
        var link: String?
    }

    let copy: Copy
    let updateHost: String
    let licenseHost: String

    init(copy: Copy = .current,
         updateHost: String = AppConfig.current.updateHost,
         licenseHost: String = AppConfig.current.licenseHost) {
        self.copy = copy
        self.updateHost = updateHost
        self.licenseHost = licenseHost
    }

    var kicker: String { copy.kicker }
    var title: String { copy.title }
    var checkboxLabel: String { copy.checkboxLabel }
    var linksRow: String { copy.linkLabels.joined(separator: " · ") + " " + copy.linksSuffix }

    var sections: [Section] {
        let networkBody = copy.networkBody
            .replacingOccurrences(of: Copy.updateHostPlaceholder, with: updateHost)
            .replacingOccurrences(of: Copy.licenseHostPlaceholder, with: licenseHost)
        return [
            Section(number: 1, title: copy.scopeTitle, body: copy.scopeBody,
                    hashedBody: copy.scopeBody, pill: copy.scopePill, link: copy.scopeLink),
            Section(number: 2, title: copy.networkTitle, body: networkBody,
                    hashedBody: copy.networkBody, pill: copy.networkPill),
            Section(number: 3, title: copy.deletionTitle, body: copy.deletionBody,
                    hashedBody: copy.deletionBody, pill: copy.deletionPill),
            Section(number: 4, title: copy.paymentTitle, body: copy.paymentBody,
                    hashedBody: copy.paymentBody, pill: copy.paymentPill),
        ]
    }

    /// Everything the user reads, top to bottom, hostnames included.
    var allStrings: [String] {
        [kicker, title]
            + sections.flatMap { [$0.title, $0.body, $0.pill] + ($0.link.map { [$0] } ?? []) }
            + [linksRow, checkboxLabel]
    }

    /// The hash input: the same order as `allStrings`, but the static copy
    /// only — section 2's template, not the rendered hostnames, and the
    /// links' labels, never their URLs.
    var hashedStrings: [String] {
        [kicker, title]
            + sections.flatMap { [$0.title, $0.hashedBody, $0.pill] + ($0.link.map { [$0] } ?? []) }
            + copy.linkLabels + [copy.linksSuffix, checkboxLabel]
    }

    var textHash: String {
        SHA256.hash(data: Data(hashedStrings.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
