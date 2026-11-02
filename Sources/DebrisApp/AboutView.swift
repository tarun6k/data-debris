import DebrisCore
import SwiftUI

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
    /// "1.0 (1)"
    static var versionString: String { "\(version) (\(build))" }
    /// A 0.x version is a beta: Settings shows a Beta label next to it, and
    /// the label disappears with the first 1.0 build without a code change.
    static var isBeta: Bool { isBeta(version) }
    static func isBeta(_ version: String) -> Bool { version.hasPrefix("0") }
    static var macOSVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
    static let author = "Tarun Kumar"
}

/// Third-party code shipped in the bundle, with its licence text. Read from
/// Resources/Acknowledgements/<name>.txt, copied verbatim from the packages.
struct Acknowledgement: Identifiable {
    let name: String
    let purpose: String
    var id: String { name }

    static let all = [
        Acknowledgement(name: "GRDB", purpose: "SQLite access for findings, history and exclusions"),
        Acknowledgement(name: "Sparkle", purpose: "Software updates"),
    ]

    var licenseText: String {
        let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "Acknowledgements")
            ?? Bundle.main.url(forResource: name, withExtension: "txt")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "The bundled licence text for \(name) is missing."
    }
}

/// Settings > About. Documents the exact two hosts the app talks to, by name
/// and purpose, next to the human behind it and the support address (§12).
struct AboutSection: View {
    @EnvironmentObject var updates: UpdateManager
    let config: AppConfig
    let onPrivacySheet: () -> Void
    let onProtections: () -> Void
    let onAcknowledgements: () -> Void
    let onLegal: (LegalDocument) -> Void
    let linkLabel: (LegalDocument) -> String

    var body: some View {
        Section("About") {
            HStack(spacing: 8) {
                Text("Version")
                Spacer()
                if AppInfo.isBeta {
                    Text("Beta")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.teal)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Theme.teal.opacity(0.12), in: Capsule())
                        .accessibilityLabel("Beta build")
                }
                Text(AppInfo.versionString).foregroundStyle(.secondary)
            }
            HStack {
                Text("Data Debris by \(AppInfo.author)")
                Spacer()
                Button(config.supportEmail) {
                    if let url = URL(string: "mailto:\(config.supportEmail)") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Network: exactly two hosts").font(.system(size: 12, weight: .semibold))
                endpoint(config.updateHost,
                         "Update check: fetches the signed appcast once a day, and an update only after you approve it.")
                endpoint(config.licenseHost,
                         "License service: activates and re-checks your license, and relays localised prices for the plan cards.")
                Text("Nothing else. Your file list never leaves this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            HStack(spacing: 10) {
                Button("Built-in protections") { onProtections() }
                Button("How this app treats your Mac") { onPrivacySheet() }
            }
            HStack(spacing: 10) {
                ForEach(LegalDocument.allCases) { document in
                    Button(linkLabel(document)) { onLegal(document) }
                }
            }
            HStack(spacing: 10) {
                Button("Check for updates") { updates.checkForUpdates() }
                    .disabled(!updates.canCheck)
                Text(updateStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Acknowledgements") { onAcknowledgements() }
            }
        }
    }

    private var updateStatus: String {
        if let reason = updates.unavailableReason { return reason }
        if let last = updates.lastCheck {
            return "Last checked \(last.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Checks daily, installs only with your OK"
    }

    private func endpoint(_ host: String, _ purpose: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(host)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 190, alignment: .leading)
            Text(purpose)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

struct AcknowledgementsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedName = Acknowledgement.all[0].name

    private var selected: Acknowledgement {
        Acknowledgement.all.first { $0.name == selectedName } ?? Acknowledgement.all[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Acknowledgements").font(.system(size: 17, weight: .semibold))
            Picker("Library", selection: $selectedName) {
                ForEach(Acknowledgement.all) { Text($0.name).tag($0.name) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(selected.purpose).font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                Text(selected.licenseText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 320)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

struct ProtectionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Built-in protections").font(.system(size: 17, weight: .semibold))
            ProtectionsList()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
