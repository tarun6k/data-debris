import Combine
import DebrisCore
import Network
import SwiftUI

/// The Continue gate: the ScrollView must have reached its end (latched — a
/// scroll back up does not re-lock) AND the box must be ticked. Fed by a
/// publisher of scroll positions so the rule is testable without a window.
@MainActor
final class PrivacySheetGate: ObservableObject {

    struct ScrollPosition: Equatable {
        /// Bottom edge of the content, in the scroll view's coordinate space.
        var contentMaxY: CGFloat
        var viewportHeight: CGFloat
    }

    /// Sub-pixel layout and rubber-banding: "at the end" within 8 pt.
    static let tolerance: CGFloat = 8

    /// Never pre-ticked (spec).
    @Published var ticked = false
    @Published private(set) var scrolledToEnd = false
    private var subscription: AnyCancellable?

    init<P: Publisher>(positions: P) where P.Output == ScrollPosition, P.Failure == Never {
        subscription = positions.sink { [weak self] in self?.scrollPositionChanged($0) }
    }

    static func reachedEnd(_ position: ScrollPosition) -> Bool {
        position.contentMaxY <= position.viewportHeight + tolerance
    }

    func scrollPositionChanged(_ position: ScrollPosition) {
        if Self.reachedEnd(position) { scrolledToEnd = true }
    }

    var continueEnabled: Bool {
        PrivacySecuritySheet.continueEnabled(scrolledToEnd: scrolledToEnd, ticked: ticked)
    }
}

/// Screen 12 — shown before any price, its copy hashed into the
/// acknowledgement (see PrivacySheetText). Continue unlocks only when the
/// ScrollView has reached the bottom AND the box is ticked. No price, no
/// countdown, no pre-tick, no skip.
struct PrivacySecuritySheet: View {

    let text: PrivacySheetText
    /// Settings > About shows the same sheet read-only: no checkbox, just Close.
    let readOnly: Bool
    let onContinue: () -> Void
    let onNotNow: () -> Void

    private let positions: PassthroughSubject<PrivacySheetGate.ScrollPosition, Never>
    @StateObject private var gate: PrivacySheetGate
    @State private var showingProtections = false
    @State private var legalDocument: LegalDocument?

    init(text: PrivacySheetText, readOnly: Bool = false,
         onContinue: @escaping () -> Void = {}, onNotNow: @escaping () -> Void = {}) {
        self.text = text
        self.readOnly = readOnly
        self.onContinue = onContinue
        self.onNotNow = onNotNow
        let positions = PassthroughSubject<PrivacySheetGate.ScrollPosition, Never>()
        self.positions = positions
        _gate = StateObject(wrappedValue: PrivacySheetGate(positions: positions))
    }

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
                            key: ScrollPositionKey.self,
                            value: PrivacySheetGate.ScrollPosition(
                                contentMaxY: inner.frame(in: .named("privacyScroll")).maxY,
                                viewportHeight: outer.size.height))
                    })
                }
                .coordinateSpace(name: "privacyScroll")
            }
            .onPreferenceChange(ScrollPositionKey.self) { position in
                if let position { gate.scrollPositionChanged(position) }
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
                Button(text.copy.linkLabel(document)) { open(document) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.teal)
            }
            Text(text.copy.linksSuffix)
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
                Toggle(text.checkboxLabel, isOn: $gate.ticked)
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
                    .disabled(!gate.continueEnabled)
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

private struct ScrollPositionKey: PreferenceKey {
    static var defaultValue: PrivacySheetGate.ScrollPosition?
    static func reduce(value: inout PrivacySheetGate.ScrollPosition?,
                       nextValue: () -> PrivacySheetGate.ScrollPosition?) {
        value = nextValue() ?? value
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

    var title: String {
        switch self {
        case .privacyPolicy: return "Privacy Policy"
        case .terms: return "Terms of Use"
        case .security: return "Security"
        }
    }

    var webURL: URL { webURL(in: .current) }

    func webURL(in config: AppConfig) -> URL {
        switch self {
        case .privacyPolicy: return config.privacyPolicyURL
        case .terms: return config.termsURL
        case .security: return config.securityURL
        }
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
