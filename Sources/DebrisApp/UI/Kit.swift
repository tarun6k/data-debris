import SwiftUI
import DebrisCore

/// AppKit also exports a `Category`; ours wins module-wide.
typealias Category = DebrisCore.Category

// MARK: - Theme

enum Theme {
    /// The teal used for primary buttons and selected checkboxes in the design.
    static let teal = Color(red: 0.09, green: 0.42, blue: 0.50)
}

// MARK: - Formatting

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file // Finder-style GB/MB
        return f
    }()

    static func bytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    static func count(_ n: Int) -> String {
        n.formatted()
    }

    static func tildePath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// "2 days ago" for recent files, "Jun 3" beyond a week.
    static func modified(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 7 * 86_400 { return relative(date) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Display names for engine enums

extension Category {
    var displayName: String {
        switch self {
        case .appCaches: return "App caches"
        case .logs: return "Logs & crash reports"
        case .developer: return "Developer junk"
        case .duplicates: return "Duplicates"
        case .largeOld: return "Large & old files"
        case .trash: return "Trash"
        }
    }

    /// The pill shown on a category row (matches the catalogue's rule levels).
    var defaultLevel: Level {
        switch self {
        case .appCaches, .logs, .trash: return .safe
        case .developer, .duplicates: return .review
        case .largeOld: return .manual
        }
    }
}

extension Level {
    var label: String {
        switch self {
        case .safe: return "Safe"
        case .review: return "Review"
        case .manual: return "Manual"
        }
    }

    var color: Color {
        switch self {
        case .safe: return .green
        case .review: return .orange
        case .manual: return .red
        }
    }

    var sortRank: Int {
        switch self {
        case .safe: return 0
        case .review: return 1
        case .manual: return 2
        }
    }
}

// MARK: - SafetyPill

/// The only semantic colour in the app: Safe green, Review amber, Manual red.
struct SafetyPill: View {
    let level: Level

    var body: some View {
        Text(level.label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(level.color)
            .padding(.horizontal, 8)
            .frame(height: 18)
            .background(level.color.opacity(0.16), in: Capsule())
            .accessibilityLabel("Safety: \(level.label)")
    }
}

// MARK: - TriStateCheckbox

struct TriStateCheckbox: View {
    let state: CategoryState
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(state == .none ? Color.clear : Theme.teal)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(state == .none ? Color.secondary.opacity(0.6) : Theme.teal, lineWidth: 1)
                if state == .all {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                } else if state == .some {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        // .isToggle trait is macOS 14+; button role + value reads fine in VoiceOver.
        .accessibilityValue(state == .all ? "checked" : state == .some ? "mixed" : "unchecked")
    }
}

/// Two-state convenience over the same control for item rows.
struct ItemCheckbox: View {
    let checked: Bool
    let toggle: () -> Void

    var body: some View {
        TriStateCheckbox(state: checked ? .all : CategoryState.none, toggle: toggle)
    }
}

// MARK: - ByteText

struct ByteText: View {
    let bytes: Int64
    var weight: Font.Weight = .semibold

    var body: some View {
        Text(Format.bytes(bytes))
            .fontWeight(weight)
            .monospacedDigit()
    }
}

// MARK: - PathText

struct PathText: View {
    let url: URL

    var body: some View {
        Text(Format.tildePath(url))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(url.path)
    }
}

// MARK: - AmountButton

/// The only way to build a clean/restore button: the amount is part of the
/// title, so it can never be omitted ("Clean 9.7 GB").
struct AmountButton: View {
    let verb: String
    var bytes: Int64 = 0
    /// Count-flavoured amount ("Restore 1,318 items"); wins over bytes.
    var count: Int?
    var ellipsis = false
    /// Trails the amount: "Delete 9.7 GB permanently".
    var suffix: String?
    var destructive = false
    let action: () -> Void

    static func title(verb: String, bytes: Int64, ellipsis: Bool = false,
                      suffix: String? = nil) -> String {
        var title = "\(verb) \(Format.bytes(bytes))"
        if let suffix { title += " \(suffix)" }
        return title + (ellipsis ? "…" : "")
    }

    static func title(verb: String, count: Int) -> String {
        "\(verb) \(Format.count(count)) \(count == 1 ? "item" : "items")"
    }

    var body: some View {
        let title = count.map { Self.title(verb: verb, count: $0) }
            ?? Self.title(verb: verb, bytes: bytes, ellipsis: ellipsis, suffix: suffix)
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .tint(destructive ? .red : Theme.teal)
    }
}
