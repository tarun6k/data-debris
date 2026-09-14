import DebrisCore
import Foundation

/// Where the purchase flow finds the license worker, the Paddle client token
/// and the four price ids. Debug builds read the gitignored repo .env (values
/// stay in-process, never logged); release builds read Info.plist keys of the
/// same names, injected at archive time (Phase 8).
struct LicenseConfig {

    var workerURL: URL?
    var paddleClientToken: String?
    /// "sandbox" | "production" — picks the Paddle.js environment and API host.
    var paddleEnv: String
    /// Keyed "PADDLE_PRICE_{1Y|3Y}_{RECURRING|ONETIME}", same names as .env.
    var priceIds: [String: String]
    var portalURL: URL

    /// The two hostnames the Privacy & Security sheet promises are the only
    /// network calls. Sparkle arrives in Phase 8; the feed host is fixed now
    /// so the promise (and its text hash) does not change under users later.
    static let updateHost = "updates.datadebris.app"
    var licenseHost: String { workerURL?.host ?? "not configured" }

    func priceId(plan: LicensePlan, autoRenew: Bool) -> String? {
        let key = "PADDLE_PRICE_\(plan == .oneYear ? "1Y" : "3Y")_\(autoRenew ? "RECURRING" : "ONETIME")"
        return priceIds[key]
    }

    var isConfigured: Bool { workerURL != nil }

    static let current = load()

    static func load() -> LicenseConfig {
        var values: [String: String] = [:]
        #if DEBUG
        // …/Sources/DebrisApp/Purchase/LicenseConfig.swift → repo root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        if let env = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8) {
            for line in env.split(separator: "\n") {
                guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
                values[String(line[..<eq])] = String(line[line.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        #endif
        let info = Bundle.main.infoDictionary ?? [:]
        func value(_ name: String) -> String? {
            let v = values[name] ?? (info[name] as? String)
            return (v?.isEmpty == false) ? v : nil
        }
        let env = value("PADDLE_ENV") ?? "sandbox"
        var prices: [String: String] = [:]
        for plan in ["1Y", "3Y"] {
            for kind in ["RECURRING", "ONETIME"] {
                let key = "PADDLE_PRICE_\(plan)_\(kind)"
                prices[key] = value(key)
            }
        }
        let portal = value("PADDLE_PORTAL_URL").flatMap(URL.init(string:))
            ?? URL(string: env == "sandbox"
                ? "https://sandbox-customer-portal.paddle.com/"
                : "https://customer-portal.paddle.com/")!
        return LicenseConfig(
            workerURL: value("LICENSE_WORKER_URL").flatMap(URL.init(string:)),
            paddleClientToken: value("PADDLE_CLIENT_TOKEN"),
            paddleEnv: env,
            priceIds: prices,
            portalURL: portal)
    }
}
