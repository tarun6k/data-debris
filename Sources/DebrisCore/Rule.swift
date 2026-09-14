import Foundation

public enum Category: String, Codable, Equatable, Sendable, CaseIterable {
    case appCaches
    case logs
    case developer
    case duplicates
    case largeOld
    case trash
}

public enum Level: String, Codable, Equatable, Sendable {
    case safe
    case review
    case manual
}

public enum Unit: String, Codable, Equatable, Sendable {
    case file
    case directory
}

/// A predicate encoded in catalogue.json as a single-key object,
/// e.g. `{ "mtimeOlderThanDays": 2 }`.
public enum Predicate: Codable, Equatable, Sendable {
    case mtimeOlderThanDays(Int)
    case sizeAtLeastBytes(Int64)
    case lastOpenedOlderThanDays(Int)
    case ownerBundleRunning(Bool)

    private enum CodingKeys: String, CodingKey {
        case mtimeOlderThanDays, sizeAtLeastBytes, lastOpenedOlderThanDays, ownerBundleRunning
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let days = try container.decodeIfPresent(Int.self, forKey: .mtimeOlderThanDays) {
            self = .mtimeOlderThanDays(days)
        } else if let bytes = try container.decodeIfPresent(Int64.self, forKey: .sizeAtLeastBytes) {
            self = .sizeAtLeastBytes(bytes)
        } else if let days = try container.decodeIfPresent(Int.self, forKey: .lastOpenedOlderThanDays) {
            self = .lastOpenedOlderThanDays(days)
        } else if let running = try container.decodeIfPresent(Bool.self, forKey: .ownerBundleRunning) {
            self = .ownerBundleRunning(running)
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Predicate object has no recognized key"
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .mtimeOlderThanDays(let days): try container.encode(days, forKey: .mtimeOlderThanDays)
        case .sizeAtLeastBytes(let bytes): try container.encode(bytes, forKey: .sizeAtLeastBytes)
        case .lastOpenedOlderThanDays(let days): try container.encode(days, forKey: .lastOpenedOlderThanDays)
        case .ownerBundleRunning(let running): try container.encode(running, forKey: .ownerBundleRunning)
        }
    }
}

/// One positive match rule from the catalogue (product spec §6).
/// A path is removable only if a rule claims it (S1).
public struct Rule: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let category: Category
    public let level: Level
    /// Globs relative to `~` or absolute. An empty array means the rule is
    /// analyzer-driven (duplicates) and never matched by path.
    public let match: [String]
    public let unit: Unit
    public let predicates: [Predicate]
    public let owner: String?
    public let reason: String
    public let consequence: String
    public let autoCleanEligible: Bool

    private enum CodingKeys: String, CodingKey {
        case id, category, level, match, unit, predicates, owner, reason, consequence, autoCleanEligible
    }

    public init(
        id: String,
        category: Category,
        level: Level,
        match: [String],
        unit: Unit,
        predicates: [Predicate] = [],
        owner: String? = nil,
        reason: String,
        consequence: String,
        autoCleanEligible: Bool
    ) {
        self.id = id
        self.category = category
        self.level = level
        self.match = match
        self.unit = unit
        self.predicates = predicates
        self.owner = owner
        self.reason = reason
        self.consequence = consequence
        self.autoCleanEligible = autoCleanEligible
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        category = try container.decode(Category.self, forKey: .category)
        level = try container.decode(Level.self, forKey: .level)
        match = try container.decode([String].self, forKey: .match)
        unit = try container.decode(Unit.self, forKey: .unit)
        predicates = try container.decodeIfPresent([Predicate].self, forKey: .predicates) ?? []
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        reason = try container.decode(String.self, forKey: .reason)
        consequence = try container.decode(String.self, forKey: .consequence)
        autoCleanEligible = try container.decode(Bool.self, forKey: .autoCleanEligible)
    }
}
