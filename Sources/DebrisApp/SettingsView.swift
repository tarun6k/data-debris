import SwiftUI
import DebrisCore

extension LicensePlan {
    var displayName: String { self == .oneYear ? "1 Year" : "3 Years" }
}

/// Settings: General, License, the hard-coded never-touch list, and About
/// with the read-only privacy sheet and the offline legal copies.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("showInMenuBar") private var showInMenuBar = false

    @State private var showingLicenseEntry = false
    @State private var showingPrivacySheet = false
    @State private var legalDocument: LegalDocument?
    @State private var confirmingDeactivate = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show in menu bar", isOn: $showInMenuBar)
            }
            licenseSection
            protectionsSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { model.refreshEntitlement() }
        .sheet(isPresented: $showingLicenseEntry) {
            LicenseEntrySheet(
                onActivate: { await model.enterLicenseKey($0) },
                onRecover: { await model.recoverLicenseKey(email: $0) })
        }
        .sheet(isPresented: $showingPrivacySheet) {
            PrivacySecuritySheet(text: model.privacyText, readOnly: true,
                                 onNotNow: { showingPrivacySheet = false })
        }
        .sheet(item: $legalDocument) { LegalSheet(document: $0) }
        .confirmationDialog("Deactivate this Mac?",
                            isPresented: $confirmingDeactivate) {
            Button("Deactivate — cleaning locks on this Mac", role: .destructive) {
                Task { await model.deactivateThisMac() }
            }
        } message: {
            Text("The license slot frees up for another Mac. Scans, History and Undo keep working.")
        }
    }

    // MARK: - License

    @ViewBuilder
    private var licenseSection: some View {
        if let payload = model.licensePayload {
            Section("License") {
                row("Plan", payload.plan.displayName)
                row(payload.expiryDate > Date() ? "Expires" : "Expired",
                    payload.expiryDate.formatted(date: .long, time: .omitted))
                row("Auto-renew", payload.autoRenew ? "On" : "Off")
                machines(payload)
                HStack(spacing: 10) {
                    Button("Deactivate this Mac") { confirmingDeactivate = true }
                    Button("Manage subscription") { open(LicenseConfig.current.portalURL) }
                    Button("Request refund") { open(LicenseConfig.current.portalURL) }
                }
                HStack(spacing: 10) {
                    Button("Enter a different key") { showingLicenseEntry = true }
                    Button("Recover my key by email") { showingLicenseEntry = true }
                }
            }
        } else {
            Section("License") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Free plan").font(.system(size: 13, weight: .semibold))
                    planLine("Free — $0 forever",
                             "unlimited scans · full results with reasons · History and Undo")
                    planLine("1 Year — $20 (\(PlanPricing.perMonth(.oneYear)))",
                             "Clean · Undo · Duplicates · Auto Clean · 2 Macs")
                    planLine("3 Years — $50 (\(PlanPricing.perMonth(.threeYears)))",
                             "everything in 1 Year · \(PlanPricing.saveLabel)")
                }
                HStack(spacing: 10) {
                    Button("Choose a plan") { model.startPurchase() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.teal)
                    Button("Already have a license?") { showingLicenseEntry = true }
                }
            }
        }
    }

    /// No price before the privacy sheet is acknowledged — the summary lists
    /// only features until then; "Choose a plan" shows the sheet first.
    private func planLine(_ priced: String, _ features: String) -> some View {
        let name = model.privacyAcknowledged
            ? priced : String(priced.prefix(while: { $0 != "—" })).trimmingCharacters(in: .whitespaces)
        return Text("\(name) · \(features)")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    private func machines(_ payload: EntitlementPayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Macs used (\(payload.machines.count) of 2)")
            ForEach(payload.machines, id: \.self) { machine in
                HStack(spacing: 8) {
                    Text(machine)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    if machine == MachineIdentity.machineId() {
                        Text("this Mac")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.teal)
                    }
                }
            }
        }
    }

    // MARK: - Protections

    private var protectionsSection: some View {
        Section("Built-in protections") {
            Text("Never touched, not configurable.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ForEach(ProtectedPaths.builtInProtections, id: \.name) { protection in
                VStack(alignment: .leading, spacing: 2) {
                    Text(protection.name)
                        .font(.system(size: 12, weight: .medium))
                    Text(protection.reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            row("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                as? String ?? "dev")
            Button("How this app treats your Mac") { showingPrivacySheet = true }
            HStack(spacing: 10) {
                ForEach(LegalDocument.allCases) { document in
                    Button(document.linkTitle) { legalDocument = document }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
