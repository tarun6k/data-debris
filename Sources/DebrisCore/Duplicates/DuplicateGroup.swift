import Foundation

/// Where a copy lives, for the canonical keeper rule (§7): media folders
/// beat other home folders, which beat Desktop, which beats Downloads;
/// external volumes come last.
public enum HomeLocation: String, Sendable, Equatable, CaseIterable {
    case pictures, documents, music, movies, desktop, downloads, otherHome, external

    var canonicalRank: Int {
        switch self {
        case .pictures, .documents, .music, .movies: return 0
        case .otherHome: return 1
        case .desktop: return 2
        case .downloads: return 3
        case .external: return 4
        }
    }

    public static func classify(_ url: URL, home: URL) -> HomeLocation {
        let homePath = home.standardizedFileURL.path
        let path = url.path
        guard path.hasPrefix(homePath + "/") else { return .external }
        let first = path.dropFirst(homePath.count + 1).split(separator: "/").first.map(String.init)
        switch first {
        case "Pictures": return .pictures
        case "Documents": return .documents
        case "Music": return .music
        case "Movies": return .movies
        case "Desktop": return .desktop
        case "Downloads": return .downloads
        default: return .otherHome
        }
    }
}

public struct DuplicateCopy: Identifiable, Equatable, Sendable {
    /// Matches the Finding this copy becomes when it is not the keeper, so
    /// selection state joins up.
    public let findingId: String
    public let url: URL
    public let mtime: Date
    public let size: Int64
    public let allocatedSize: Int64
    public let location: HomeLocation

    public var id: String { findingId }

    public init(url: URL, mtime: Date, size: Int64, allocatedSize: Int64, location: HomeLocation) {
        self.findingId = Finding.stableID(ruleId: DuplicateGroup.ruleId, path: url.path)
        self.url = url
        self.mtime = mtime
        self.size = size
        self.allocatedSize = allocatedSize
        self.location = location
    }
}

public enum DuplicateError: Error, Equatable {
    /// S7: the keeper must always be one of the group's copies.
    case unknownCopy
}

public enum KeeperRule: Equatable, Sendable {
    case canonical, oldest, newest, shortestPath
    case inFolder(URL)
}

/// One set of byte-identical files. `keeperId` is always a member copy —
/// the type has no way to represent zero keepers (S7).
public struct DuplicateGroup: Identifiable, Equatable, Sendable {
    public static let ruleId = "duplicates.identical"

    public let hash: String
    /// Logical size of one copy; all copies are byte-identical.
    public let size: Int64
    public let copies: [DuplicateCopy]
    public private(set) var keeperId: String

    public var id: String { hash }

    /// Fails when `copies` has fewer than two members: a single file is not
    /// a duplicate of anything.
    public init?(hash: String, copies: [DuplicateCopy], keeperRule: KeeperRule = .canonical) {
        guard copies.count >= 2 else { return nil }
        self.hash = hash
        self.size = copies[0].size
        self.copies = copies
        self.keeperId = copies[0].findingId
        if let chosen = Self.choose(rule: keeperRule, among: copies) {
            self.keeperId = chosen
        }
    }

    /// Restores a persisted group; keeper must be a member.
    public init?(hash: String, copies: [DuplicateCopy], keeperId: String) {
        guard copies.count >= 2, copies.contains(where: { $0.findingId == keeperId }) else { return nil }
        self.hash = hash
        self.size = copies[0].size
        self.copies = copies
        self.keeperId = keeperId
    }

    public var keeper: DuplicateCopy {
        copies.first { $0.findingId == keeperId } ?? copies[0]
    }

    public var others: [DuplicateCopy] {
        copies.filter { $0.findingId != keeperId }
    }

    /// S10: allocated bytes of the removable copies, not logical size.
    public var reclaimableBytes: Int64 {
        others.reduce(0) { $0 + $1.allocatedSize }
    }

    /// S7: the only way to change the keeper; an id outside the group is an
    /// error, so a group can never end up keeperless.
    public mutating func setKeeper(_ id: String) throws {
        guard copies.contains(where: { $0.findingId == id }) else { throw DuplicateError.unknownCopy }
        keeperId = id
    }

    /// The copy `rule` would keep; nil when the rule does not apply
    /// (`.inFolder` with no copy in that folder).
    public func keeper(under rule: KeeperRule) -> String? {
        Self.choose(rule: rule, among: copies)
    }

    private static func choose(rule: KeeperRule, among copies: [DuplicateCopy]) -> String? {
        func oldestFirst(_ a: DuplicateCopy, _ b: DuplicateCopy) -> Bool {
            (a.mtime, a.url.path) < (b.mtime, b.url.path)
        }
        switch rule {
        case .canonical:
            return copies.min {
                ($0.location.canonicalRank, $0.mtime, $0.url.path)
                    < ($1.location.canonicalRank, $1.mtime, $1.url.path)
            }?.findingId
        case .oldest:
            return copies.min(by: oldestFirst)?.findingId
        case .newest:
            return copies.max(by: oldestFirst)?.findingId
        case .shortestPath:
            return copies.min { ($0.url.path.count, $0.url.path) < ($1.url.path.count, $1.url.path) }?.findingId
        case .inFolder(let folder):
            let prefix = folder.standardizedFileURL.path + "/"
            let inside = copies.filter { $0.url.path.hasPrefix(prefix) }
            guard !inside.isEmpty else { return nil }
            return inside.min {
                ($0.location.canonicalRank, $0.mtime, $0.url.path)
                    < ($1.location.canonicalRank, $1.mtime, $1.url.path)
            }?.findingId
        }
    }

    /// Every non-keeper copy as a removable Finding; the keeper never gets
    /// one, so nothing upstream can select it (S7).
    public func findings(home: URL) -> [Finding] {
        let keeperPath = tilde(keeper.url, home: home)
        return others.map { copy in
            Finding(
                ruleId: Self.ruleId,
                url: copy.url,
                size: copy.size,
                allocatedSize: copy.allocatedSize,
                mtime: copy.mtime,
                lastOpened: nil,
                level: .review,
                category: .duplicates,
                reason: "Identical to \(keeperPath)",
                consequence: "The kept copy stays where it is.")
        }
    }

    private func tilde(_ url: URL, home: URL) -> String {
        let homePath = home.standardizedFileURL.path
        let path = url.path
        return path.hasPrefix(homePath) ? "~" + path.dropFirst(homePath.count) : path
    }
}
