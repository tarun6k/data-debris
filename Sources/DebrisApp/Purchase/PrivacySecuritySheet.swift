import DebrisCore
import Network
import SwiftUI

/// Screen 12 — shown before any price, every word hashed into the
/// acknowledgement. Continue unlocks only when the ScrollView has reached the
/// bottom AND the box is ticked. No price, no countdown, no pre-tick, no skip.
struct PrivacySecuritySheet: View {

    let text: PrivacySheetText
    /// Settings > About shows the same sheet read-only: no checkbox, just Close.
    var readOnly = false
    var onContinue: () -> Void = {}
    var onNotNow: () -> Void = {}

    @State private var ticked = false
    @State private var scrolledToEnd = false
    @State private var showingProtections = false
    @State private var legalDocument: LegalDocument?

    static func continueEnabled(scrolledToEnd: Bool, ticked: Bool) -> Bool {
        scrolledToEnd && ticked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(text.kicker)
                    .font(.system(size: 11, weight: .bold))
                    .kerning(0.8)
                    .foregroundStyle(Theme.teal)
                Text(text.title)
                    .font(.system(size: 22, weight: .bold))
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            GeometryReader { outer in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(text.sections, id: \.number) { section in
                            if section.number > 1 { Divider().padding(.horizontal, 24) }
                            row(section)
                        }
                    }
                    .background(GeometryReader { inner in
                        Color.clear.preference(
                            key: ReachedEndKey.self,
                            value: inner.frame(in: .named("privacyScroll")).maxY
                                <= outer.size.height + 8)
                    })
                }
                .coordinateSpace(name: "privacyScroll")
            }
            .onPreferenceChange(ReachedEndKey.self) { reached in
                if reached { scrolledToEnd = true } // latches; scrolling back up is fine
            }

            Divider()
            linksRow
            Divider()
            footer
        }
        .frame(width: 680, height: 560)
        .sheet(item: $legalDocument) { LegalSheet(document: $0) }
    }

    private func row(_ section: PrivacySheetText.Section) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(section.number)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.secondary.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
                // Copy rule: paths in monospace ("~/Library").
                Text(.init(section.body.replacingOccurrences(
                    of: "~/Library", with: "`~/Library`")))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let link = section.link {
                    Button(link) { showingProtections = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.teal)
                        .popover(isPresented: $showingProtections) { ProtectionsList() }
                }
            }
            Spacer(minLength: 12)
            Text(section.pill)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(section.number == 1 ? Theme.teal : .green)
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background((section.number == 1 ? Theme.teal : Color.green).opacity(0.14),
                            in: Capsule())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var linksRow: some View {
        HStack(spacing: 4) {
            ForEach(Array(LegalDocument.allCases.enumerated()), id: \.element) { index, document in
                if index > 0 { Text("·").foregroundStyle(.secondary) }
                Button(document.linkTitle) { open(document) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.teal)
            }
            Text("— also available offline under About")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !readOnly {
                Toggle(text.checkboxLabel, isOn: $ticked)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
            }
            Spacer()
            if readOnly {
                Button("Close", action: onNotNow)
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Not now", action: onNotNow)
                    .keyboardShortcut(.cancelAction)
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.teal)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Self.continueEnabled(scrolledToEnd: scrolledToEnd, ticked: ticked))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    /// The sheet's promise in miniature: online opens the website, offline
    /// falls back to the bundled copy.
    private func open(_ document: LegalDocument) {
        if Connectivity.shared.isOnline {
            NSWorkspace.shared.open(document.webURL)
        } else {
            legalDocument = document
        }
    }
}

private struct ReachedEndKey: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// The hard-coded never-touch list (also shown in Settings > Built-in
/// protections). Never a preference — display only.
struct ProtectionsList: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Never touched, not configurable")
                    .font(.system(size: 12, weight: .semibold))
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
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 360, height: 320)
    }
}

// MARK: - Legal documents

/// Bundled Markdown copies of the website pages, for offline and About.
enum LegalDocument: String, CaseIterable, Identifiable {
    case privacyPolicy = "privacy-policy"
    case terms
    case security

    var id: String { rawValue }

    var linkTitle: String {
        switch self {
        case .privacyPolicy: return "Privacy Policy"
        case .terms: return "Terms"
        case .security: return "Security page"
        }
    }

    var title: String {
        switch self {
        case .privacyPolicy: return "Privacy Policy"
        case .terms: return "Terms of Use"
        case .security: return "Security"
        }
    }

    var webURL: URL {
        let slug = self == .privacyPolicy ? "privacy" : rawValue
        return URL(string: "https://datadebris.app/\(slug)")!
    }

    var bundledText: String {
        let url = Bundle.main.url(forResource: rawValue, withExtension: "md", subdirectory: "Legal")
            ?? Bundle.main.url(forResource: rawValue, withExtension: "md")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "The bundled copy is missing. The current version lives at \(webURL.absoluteString)."
    }
}

struct LegalSheet: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(document.bundledText.split(separator: "\n", omittingEmptySubsequences: true).enumerated()),
                            id: \.offset) { _, line in
                        styled(String(line))
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 480)
    }

    @ViewBuilder
    private func styled(_ line: String) -> some View {
        if line.hasPrefix("# ") {
            Text(line.dropFirst(2)).font(.system(size: 18, weight: .bold))
        } else if line.hasPrefix("## ") {
            Text(line.dropFirst(3)).font(.system(size: 14, weight: .semibold)).padding(.top, 6)
        } else {
            Text(.init(line)).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Connectivity

/// ponytail: one process-wide monitor with a benignly racy Bool — a stale
/// reading only changes which fallback (browser vs bundled copy) appears.
final class Connectivity {
    static let shared = Connectivity()
    private let monitor = NWPathMonitor()
    private(set) var isOnline = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.isOnline = path.status == .satisfied
        }
        monitor.start(queue: DispatchQueue(label: "com.tarunkumar.datadebris.connectivity"))
    }
}
