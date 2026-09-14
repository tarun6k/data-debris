import DebrisCore
import SwiftUI

/// The three USD anchors and everything derived from them. The per-month
/// figures and the Save pill are computed, never hard-coded, so a price change
/// in one place updates the whole sheet.
enum PlanPricing {
    static let oneYearUSD = 20.0
    static let threeYearsUSD = 50.0

    static func months(_ plan: LicensePlan) -> Int { plan == .oneYear ? 12 : 36 }
    static func totalUSD(_ plan: LicensePlan) -> Double {
        plan == .oneYear ? oneYearUSD : threeYearsUSD
    }

    static func anchor(_ plan: LicensePlan) -> String {
        "$\(Int(totalUSD(plan)))"
    }

    static func perMonth(_ plan: LicensePlan) -> String {
        String(format: "$%.2f / month", totalUSD(plan) / Double(months(plan)))
    }

    static func savePercent(oneYearUSD: Double, threeYearsUSD: Double) -> Int {
        Int(((1 - (threeYearsUSD / 36) / (oneYearUSD / 12)) * 100).rounded())
    }

    static var saveLabel: String {
        "Save \(savePercent(oneYearUSD: oneYearUSD, threeYearsUSD: threeYearsUSD))%"
    }
}

/// Screen 13 — three cards, auto-renew off by default, checkout in the browser.
struct ChoosePlanSheet: View {
    @ObservedObject var flow: PurchaseFlow
    var config = LicenseConfig.current

    @State private var showingLicenseEntry = false
    /// priceId → localized total from Paddle's pricing preview; empty = USD.
    @State private var localized: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a plan")
                    .font(.system(size: 22, weight: .bold))
                Text("Scanning is always free. Pay only when you want to clean.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            HStack(alignment: .top, spacing: 14) {
                freeCard
                paidCard(.oneYear, bullets: [
                    "Clean · Undo · Duplicates", "Auto Clean",
                    "All updates for the term", "2 Macs",
                ])
                paidCard(.threeYears, bullets: [
                    "Everything in 1 Year", "For three years", "2 Macs",
                ])
            }
            .padding(.horizontal, 24)

            Toggle(isOn: $flow.autoRenew) {
                HStack(spacing: 6) {
                    Text("Renew automatically at the end of the term")
                        .font(.system(size: 13, weight: .medium))
                    Text("(we email you 14 days before)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            Divider()
            footer
        }
        .frame(width: 720)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showingLicenseEntry) {
            LicenseEntrySheet(
                onActivate: { await flow.enterKey($0) },
                onRecover: { await flow.recoverKey(email: $0) })
        }
        .task { localized = await PaddlePricing.localizedTotals(config: config) }
    }

    private var freeCard: some View {
        card(border: Color.gray.opacity(0.35), width: 1) {
            Text("Free").font(.system(size: 13, weight: .semibold))
            Text("$0").font(.system(size: 28, weight: .bold))
            Text("forever").font(.system(size: 12)).foregroundStyle(.secondary)
            bulletList(["Unlimited scans", "Full results with reasons",
                        "Exclusions & History viewer", "Cleaning locked"])
            Spacer(minLength: 12)
            Button("Keep Free") { flow.cancel() }
                .frame(maxWidth: .infinity)
        }
    }

    private func paidCard(_ plan: LicensePlan, bullets: [String]) -> some View {
        let highlighted = plan == .threeYears
        return card(border: highlighted ? Theme.teal : Color.gray.opacity(0.35),
                    width: highlighted ? 1.5 : 1) {
            HStack(spacing: 8) {
                Text(plan == .oneYear ? "1 Year" : "3 Years")
                    .font(.system(size: 13, weight: .semibold))
                if highlighted {
                    Text(PlanPricing.saveLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.teal)
                        .padding(.horizontal, 8)
                        .frame(height: 18)
                        .background(Color.green.opacity(0.15), in: Capsule())
                }
            }
            price(plan)
            Text(PlanPricing.perMonth(plan))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            bulletList(bullets)
            Spacer(minLength: 12)
            Button(plan == .oneYear ? "Get 1 Year" : "Get 3 Years") {
                flow.choosePlan(plan)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.teal)
            .frame(maxWidth: .infinity)
        }
    }

    /// Localized total when Paddle's preview answered for this country, with
    /// the USD anchor as the tooltip; plain USD otherwise.
    @ViewBuilder
    private func price(_ plan: LicensePlan) -> some View {
        let priceId = config.priceId(plan: plan, autoRenew: flow.autoRenew) ?? ""
        if let local = localized[priceId] {
            Text(local)
                .font(.system(size: 28, weight: .bold))
                .help("\(PlanPricing.anchor(plan)) USD")
        } else {
            Text(PlanPricing.anchor(plan))
                .font(.system(size: 28, weight: .bold))
        }
    }

    private func card(border: Color, width: CGFloat,
                      @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 236, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8)
                .stroke(border, lineWidth: width))
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(Color.secondary.opacity(0.5)).frame(width: 3, height: 3)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
                    Text(item).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 6)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text("Checkout opens in your browser · 14-day refund · VAT/GST shown at checkout ·")
                .foregroundStyle(.secondary)
            Button("Already have a license?") { showingLicenseEntry = true }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.teal)
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

// MARK: - License entry

/// "Already have a license?" — activate an existing key or recover it by
/// email. Closure-driven so the plan sheet and Settings share it.
struct LicenseEntrySheet: View {
    var onActivate: (String) async -> Void
    var onRecover: (String) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var key = ""
    @State private var busy = false
    @State private var recoverySent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter your license")
                .font(.system(size: 16, weight: .bold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Email").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("License key").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("DD-XXXXX-XXXXX-XXXXX-XXXXX", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            HStack {
                Button("Recover my key by email") {
                    let address = email
                    Task { await onRecover(address); recoverySent = true }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.teal)
                .disabled(!email.contains("@"))
                Spacer()
            }
            if recoverySent {
                Text("Sent. If that address bought a license, the key is in its inbox.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Activate") {
                    busy = true
                    let entered = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await onActivate(entered)
                        busy = false
                        // Success tears the presenting sheet down too; an
                        // error surfaces behind this (step or toast).
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.teal)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .overlay { if busy { ProgressView() } }
    }
}

// MARK: - Paddle pricing preview

/// Best-effort localized prices via Paddle's pricing-preview endpoint, which
/// accepts the client-side token and geolocates by request IP. Any failure or
/// a USD answer means the cards just show the USD anchors.
enum PaddlePricing {

    static func localizedTotals(config: LicenseConfig) async -> [String: String] {
        guard let token = config.paddleClientToken else { return [:] }
        let ids = Array(Set(config.priceIds.values)).sorted()
        guard !ids.isEmpty else { return [:] }
        let host = config.paddleEnv == "sandbox" ? "sandbox-api.paddle.com" : "api.paddle.com"
        var request = URLRequest(url: URL(string: "https://\(host)/pricing-preview")!,
                                 timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "items": ids.map { ["price_id": $0, "quantity": 1] },
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [:] }
        return parse(data) ?? [:]
    }

    /// nil on unexpected shape; empty when the preview is already in USD.
    static func parse(_ data: Data) -> [String: String]? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let preview = try? decoder.decode(Preview.self, from: data) else { return nil }
        guard preview.data.currencyCode != "USD" else { return [:] }
        return Dictionary(uniqueKeysWithValues: preview.data.details.lineItems.map {
            ($0.price.id, $0.formattedTotals.total)
        })
    }

    private struct Preview: Decodable {
        struct Payload: Decodable {
            let currencyCode: String
            let details: Details
        }
        struct Details: Decodable { let lineItems: [Item] }
        struct Item: Decodable {
            let price: Price
            let formattedTotals: Totals
        }
        struct Price: Decodable { let id: String }
        struct Totals: Decodable { let total: String }
        let data: Payload
    }
}
