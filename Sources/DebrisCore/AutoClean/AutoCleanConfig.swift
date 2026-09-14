import Foundation
import os.log

public enum AutoCleanFrequency: String, Codable, CaseIterable, Sendable {
    case daily, weekly, monthly
}

public struct AutoCleanSchedule: Codable, Equatable, Sendable {
    public var frequency: AutoCleanFrequency
    /// Calendar convention: 1 = Sunday … 7 = Saturday. Weekly only; monthly
    /// runs on the 1st of the month.
    public var weekday: Int
    public var hour: Int
    public var minute: Int

    public init(frequency: AutoCleanFrequency = .weekly, weekday: Int = 1, hour: Int = 3, minute: Int = 0) {
        self.frequency = frequency
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
    }
}

public enum AutoCleanNotify: String, Codable, CaseIterable, Sendable {
    case always, overOneGB, never
}

/// The Privacy & Security sheet acknowledgement (Screen 12): the SHA-256 of
/// the sheet's strings at the time the user ticked the box. A text change in
/// an update changes the hash and re-triggers the sheet once.
public struct PrivacyAcknowledgement: Codable, Equatable, Sendable {
    public var textHash: String
    public var acknowledgedAt: Date

    public init(textHash: String, acknowledgedAt: Date) {
        self.textHash = textHash
        self.acknowledgedAt = acknowledgedAt
    }
}

/// The Auto Clean settings (Screen 8), persisted as settings.json next to the
/// databases. Nothing is ticked until the user ticks it (S9).
public struct AutoCleanConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var schedule: AutoCleanSchedule
    public var lowSpaceTriggerGB: Int?
    /// Only ids of rules with autoCleanEligible == true belong here; the
    /// validator strips anything else (S2).
    public var enabledRuleIds: [String]
    public var notify: AutoCleanNotify
    /// Sub-option: leave browser caches alone even when App caches is ticked.
    public var browserCachesExcluded: Bool
    /// Sub-option: raise the age floor on developer-junk rules.
    public var developerMinAgeDays: Int?
    /// Screen 12: set once the user scrolls to the end and ticks the box;
    /// nil (or a stale hash) means the sheet is shown before any price.
    public var privacyAcknowledgement: PrivacyAcknowledgement?

    public init(
        enabled: Bool = false,
        schedule: AutoCleanSchedule = AutoCleanSchedule(),
        lowSpaceTriggerGB: Int? = nil,
        enabledRuleIds: [String] = [],
        notify: AutoCleanNotify = .always,
        browserCachesExcluded: Bool = false,
        developerMinAgeDays: Int? = nil,
        privacyAcknowledgement: PrivacyAcknowledgement? = nil
    ) {
        self.enabled = enabled
        self.schedule = schedule
        self.lowSpaceTriggerGB = lowSpaceTriggerGB
        self.enabledRuleIds = enabledRuleIds
        self.notify = notify
        self.browserCachesExcluded = browserCachesExcluded
        self.developerMinAgeDays = developerMinAgeDays
        self.privacyAcknowledgement = privacyAcknowledgement
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, schedule, lowSpaceTriggerGB, enabledRuleIds, notify
        case browserCachesExcluded, developerMinAgeDays, privacyAcknowledgement
    }

    public init(from decoder: Decoder) throws {
        // decodeIfPresent throughout: a settings.json from an older build
        // must never fail to load and silently reset to defaults.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        schedule = try c.decodeIfPresent(AutoCleanSchedule.self, forKey: .schedule) ?? AutoCleanSchedule()
        lowSpaceTriggerGB = try c.decodeIfPresent(Int.self, forKey: .lowSpaceTriggerGB)
        enabledRuleIds = try c.decodeIfPresent([String].self, forKey: .enabledRuleIds) ?? []
        notify = try c.decodeIfPresent(AutoCleanNotify.self, forKey: .notify) ?? .always
        browserCachesExcluded = try c.decodeIfPresent(Bool.self, forKey: .browserCachesExcluded) ?? false
        developerMinAgeDays = try c.decodeIfPresent(Int.self, forKey: .developerMinAgeDays)
        privacyAcknowledgement = try c.decodeIfPresent(PrivacyAcknowledgement.self, forKey: .privacyAcknowledgement)
    }

    // MARK: - Validation (S2: only autoCleanEligible rules can be ticked)

    /// Strips rule ids the catalogue does not mark autoCleanEligible — a
    /// hand-edited settings.json cannot widen Auto Clean's scope.
    public func validated(against catalogue: Catalogue) -> AutoCleanConfig {
        let eligible = Set(catalogue.rules.filter(\.autoCleanEligible).map(\.id))
        let stripped = enabledRuleIds.filter { !eligible.contains($0) }
        guard !stripped.isEmpty else { return self }
        Logger(subsystem: "com.tarunkumar.datadebris", category: "autoclean")
            .warning("Stripped ineligible rule ids from Auto Clean config: \(stripped.joined(separator: ", "))")
        var copy = self
        copy.enabledRuleIds = enabledRuleIds.filter(eligible.contains)
        return copy
    }

    /// What a run actually cleans: validated ids minus excluded sub-options.
    public func effectiveRuleIds(catalogue: Catalogue) -> Set<String> {
        var ids = Set(validated(against: catalogue).enabledRuleIds)
        if browserCachesExcluded {
            ids = ids.filter { !$0.hasPrefix("appcaches.browser.") }
        }
        return ids
    }

    // MARK: - Persistence

    public static func defaultFileURL() throws -> URL {
        try FindingsStore.defaultDatabaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("settings.json")
    }

    /// Missing or unreadable file = defaults; settings never block a launch.
    public static func load(from url: URL) -> AutoCleanConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AutoCleanConfig.self, from: data)
        else { return AutoCleanConfig() }
        return config
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
