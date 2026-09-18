import DebrisCore
import Foundation

/// The Paddle client token and the four price ids, plus the worker URL the
/// client talks to. Debug builds read the gitignored repo .env (values stay
/// in-process, never logged); release builds read Info.plist keys of the same
/// names, injected at archive time (Phase 8). URLs and hostnames live in
/// AppConfig; only LICENSE_WORKER_URL may override it, in Debug.
struct LicenseConfig {

    var workerURL: URL?
    var paddleClientToken: String?
    /// "sandbox" | "production" — picks the Paddle.js environment and API host.
    var paddleEnv: String
    /// Keyed "PADDLE_PRICE_{1Y|3Y}_{RECURRING|ONETIME}", same names as .env.
    var priceIds: [String: String]

    func priceId(plan: LicensePlan, autoRenew: Bool) -> String? {
        let key = "PADDLE_PRICE_\(plan == .oneYear ? "1Y" : "3Y")_\(autoRenew ? "RECURRING" : "ONETIME")"
        return priceIds[key]
    }

    var isConfigured: Bool { workerURL != nil }

    static let current = load()

    static func load(appConfig: AppConfig = .current) -> LicenseConfig {
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
        var workerURL = appConfig.licenseWorkerURL
        #if DEBUG
        if let override = values["LICENSE_WORKER_URL"].flatMap(URL.init(string:)) {
            workerURL = override
        }
        #endif
        return LicenseConfig(
            workerURL: workerURL,
            paddleClientToken: value("PADDLE_CLIENT_TOKEN"),
            paddleEnv: env,
            priceIds: prices)
    }
}
