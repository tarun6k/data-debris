import AppKit
import Combine
import Sparkle

/// Sparkle 2, and the only place that imports it. The updater is the one
/// network call besides the license client (NetworkHostsTests enforces it).
///
/// Rules an update must respect (product spec §13): it never changes Auto
/// Clean selections, exclusions or the privacy acknowledgement — those live
/// in the profile, not the bundle — and new catalogue rules arrive unticked
/// for Auto Clean (S9) and are listed once by CatalogueWhatsNewSheet.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    /// Info.plist SUPublicEDKey until 8B generates the real key pair.
    static let publicKeyPlaceholder = "REPLACE_WITH_ED_PUBLIC_KEY"

    let feedURL: URL
    /// Why "Check for updates…" is disabled, or nil when it works.
    let unavailableReason: String?
    @Published private(set) var canCheck = false
    private var controller: SPUStandardUpdaterController?

    init(config: AppConfig, bundle: Bundle = .main, start: Bool = true) {
        feedURL = config.updateFeedURL
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        unavailableReason = Self.hasUsableKey(key)
            ? nil : "Updates are not configured in this build (no signing key yet)."
        super.init()
        guard unavailableReason == nil, start else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        canCheck = true
    }

    static func live() -> UpdateManager { UpdateManager(config: AppConfig.current) }

    static func hasUsableKey(_ key: String?) -> Bool {
        guard let key, !key.isEmpty, key != publicKeyPlaceholder else { return false }
        return Data(base64Encoded: key)?.count == 32
    }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }
}

extension UpdateManager: SPUUpdaterDelegate {
    /// AppConfig, not Info.plist, owns the feed URL.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        feedURL.absoluteString
    }
}
