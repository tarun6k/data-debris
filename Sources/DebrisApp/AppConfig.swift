import Foundation

/// Which edition this build is. Decided once at launch from the
/// PurchasesEnabled key in AppConfig.plist and handed to AppModel; nothing
/// else reads the key. `.free` ships every feature unlocked, with no purchase
/// flow and no contact with the license service. `.licensed` is the 1.0 path:
/// Entitlements gate Clean, Auto Clean and Duplicates behind a license.
/// The safety invariants S1–S10 do not depend on the edition.
enum Edition: Equatable {
    case free
    case licensed

    init(purchasesEnabled: Bool) {
        self = purchasesEnabled ? .licensed : .free
    }
}

/// The one place for every URL and hostname the app shows or calls: the
/// legal pages, Paddle's customer portal, the update feed host and the
/// license worker. Read from Resources/AppConfig.plist, which carries a
/// Debug and a Release variant; the build configuration picks one.
struct AppConfig: Equatable {

    enum Variant: String {
        case debug = "Debug"
        case release = "Release"
    }

    enum LoadError: Error, Equatable {
        case missingResource
        case missingVariant(String)
        case missingKey(String)
        case badURL(String)
        /// Present but not the expected type (PurchasesEnabled must be a Bool).
        case badValue(String)
    }

    var privacyPolicyURL: URL
    var termsURL: URL
    var securityURL: URL
    var customerPortalURL: URL
    /// The Sparkle feed host; named on the privacy sheet and About.
    var updateHost: String
    /// The appcast Sparkle fetches; must live on `updateHost`.
    var updateFeedURL: URL
    var licenseWorkerURL: URL
    /// Where "Report a problem" and About send people.
    var supportEmail: String
    /// From PurchasesEnabled; the only place the key is read is init(plist:).
    var edition: Edition

    /// The second hostname the privacy sheet promises ("a license check").
    var licenseHost: String {
        licenseWorkerURL.host ?? licenseWorkerURL.absoluteString
    }

    #if DEBUG
    static let variant = Variant.debug
    #else
    static let variant = Variant.release
    #endif

    /// A bundle without a valid config is a broken build, not a runtime
    /// condition to fall back from.
    static let current: AppConfig = {
        do { return try load() } catch { fatalError("AppConfig.plist: \(error)") }
    }()

    static func load(variant: Variant = Self.variant, bundle: Bundle = .main) throws -> AppConfig {
        guard let url = bundle.url(forResource: "AppConfig", withExtension: "plist"),
              let root = NSDictionary(contentsOf: url) as? [String: Any]
        else { throw LoadError.missingResource }
        guard let values = root[variant.rawValue] as? [String: Any] else {
            throw LoadError.missingVariant(variant.rawValue)
        }
        return try AppConfig(plist: values)
    }

    init(plist: [String: Any]) throws {
        func string(_ key: String) throws -> String {
            guard let value = plist[key] as? String, !value.isEmpty else {
                throw LoadError.missingKey(key)
            }
            return value
        }
        func url(_ key: String) throws -> URL {
            let value = try string(key)
            guard let url = URL(string: value), url.scheme != nil, url.host != nil else {
                throw LoadError.badURL(key)
            }
            return url
        }
        privacyPolicyURL = try url("PrivacyPolicyURL")
        termsURL = try url("TermsURL")
        securityURL = try url("SecurityURL")
        customerPortalURL = try url("CustomerPortalURL")
        updateHost = try string("UpdateHost")
        updateFeedURL = try url("UpdateFeedURL")
        guard updateFeedURL.host == updateHost, updateFeedURL.scheme == "https" else {
            throw LoadError.badURL("UpdateFeedURL")
        }
        licenseWorkerURL = try url("LicenseWorkerURL")
        supportEmail = try string("SupportEmail")
        guard supportEmail.contains("@") else { throw LoadError.badURL("SupportEmail") }
        guard let purchases = plist["PurchasesEnabled"] else {
            throw LoadError.missingKey("PurchasesEnabled")
        }
        // NSNumber bridges <true/>/<false/> to Bool; an <integer> or <string>
        // in that slot is a mistake, not a configuration.
        guard let number = purchases as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw LoadError.badValue("PurchasesEnabled")
        }
        edition = Edition(purchasesEnabled: number.boolValue)
    }

    init(privacyPolicyURL: URL, termsURL: URL, securityURL: URL, customerPortalURL: URL,
         updateHost: String, updateFeedURL: URL? = nil, licenseWorkerURL: URL,
         supportEmail: String = "support@example.test", edition: Edition = .licensed) {
        self.privacyPolicyURL = privacyPolicyURL
        self.termsURL = termsURL
        self.securityURL = securityURL
        self.customerPortalURL = customerPortalURL
        self.updateHost = updateHost
        self.updateFeedURL = updateFeedURL ?? URL(string: "https://\(updateHost)/appcast.xml")!
        self.licenseWorkerURL = licenseWorkerURL
        self.supportEmail = supportEmail
        self.edition = edition
    }
}
