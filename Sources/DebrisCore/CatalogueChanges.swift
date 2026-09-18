import Foundation

/// What the app last showed the user: the bundled catalogue version and its
/// rule ids. Stored in the profile so an update can be diffed against it.
public struct CatalogueSeen: Codable, Equatable, Sendable {
    public var version: Int
    public var ruleIds: [String]

    public init(version: Int, ruleIds: [String]) {
        self.version = version
        self.ruleIds = ruleIds
    }
}

/// Rules that appeared or vanished between two catalogue versions. Shown once
/// after an update; new rules are never ticked for Auto Clean by it (S9).
public struct CatalogueChanges: Equatable, Sendable {
    public let fromVersion: Int
    public let toVersion: Int
    public let added: [Rule]
    public let removedIds: [String]

    public init(fromVersion: Int, toVersion: Int, added: [Rule], removedIds: [String]) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.added = added
        self.removedIds = removedIds
    }

    public var isEmpty: Bool { added.isEmpty && removedIds.isEmpty }
}

extension Catalogue {
    public var seen: CatalogueSeen {
        CatalogueSeen(version: version, ruleIds: rules.map(\.id))
    }

    /// nil on a first launch (nothing to compare) and when the version is
    /// unchanged; otherwise the diff, which may be empty for a pure bump.
    public func changes(since previous: CatalogueSeen?) -> CatalogueChanges? {
        guard let previous, previous.version != version else { return nil }
        let before = Set(previous.ruleIds)
        let now = Set(rules.map(\.id))
        return CatalogueChanges(
            fromVersion: previous.version,
            toVersion: version,
            added: rules.filter { !before.contains($0.id) },
            removedIds: previous.ruleIds.filter { !now.contains($0) })
    }
}
