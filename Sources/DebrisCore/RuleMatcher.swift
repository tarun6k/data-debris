import Foundation

/// Matches a `FileRecord` against the catalogue. Allowlist only (S1):
/// protected paths never match, unknown paths never match.
public struct RuleMatcher {

    public enum NotReclaimableReason: Equatable, Sendable {
        case symlink
        case hardLink
        case cloudPlaceholder
    }

    public enum Evaluation: Equatable, Sendable {
        case matched(Rule)
        case protectedPath
        case notReclaimable(NotReclaimableReason)
        case unmatched
    }

    private let catalogue: Catalogue
    private let protectedPaths: ProtectedPaths
    private let home: URL
    private let isOwnerRunning: @Sendable (String) -> Bool

    public init(
        catalogue: Catalogue,
        protectedPaths: ProtectedPaths,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isOwnerRunning: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        self.catalogue = catalogue
        self.protectedPaths = protectedPaths
        self.home = home.standardizedFileURL
        self.isOwnerRunning = isOwnerRunning
    }

    public func match(_ record: FileRecord, now: Date = Date()) -> Rule? {
        if case .matched(let rule) = evaluate(record, now: now) { return rule }
        return nil
    }

    public func evaluate(_ record: FileRecord, now: Date = Date()) -> Evaluation {
        if record.isSymlink { return .notReclaimable(.symlink) }
        if record.isCloudPlaceholder { return .notReclaimable(.cloudPlaceholder) }
        // Directory link counts reflect entry counts, not hard links.
        if !record.isDirectory, record.linkCount > 1 { return .notReclaimable(.hardLink) }

        if protectedPaths.isProtected(record.url) { return .protectedPath }

        // S1 gate: a directory named like build output is claimable only when
        // its repo's .gitignore lists that name. Outside a repo it stays unknown.
        if record.isDirectory,
           ProtectedPaths.gitignoredBuildDirNames.contains(record.url.lastPathComponent),
           !protectedPaths.isGitignoredBuildDirectory(record.url) {
            return .unmatched
        }

        let path = record.url.standardizedFileURL.path
        for rule in catalogue.rules {
            // Duplicates are established by the duplicate engine (hashes),
            // never by path match; the rule carries config and copy only.
            if rule.category == .duplicates { continue }
            guard !rule.match.isEmpty else { continue }
            guard (rule.unit == .directory) == record.isDirectory else { continue }
            guard rule.match.contains(where: { Glob.matches(pattern: $0, path: path, home: home) }) else { continue }
            guard rule.predicates.allSatisfy({ satisfies($0, record: record, rule: rule, now: now) }) else { continue }
            return .matched(rule)
        }
        return .unmatched
    }

    private func satisfies(_ predicate: Predicate, record: FileRecord, rule: Rule, now: Date) -> Bool {
        switch predicate {
        case .mtimeOlderThanDays(let days):
            return now.timeIntervalSince(record.mtime) >= TimeInterval(days) * 86_400
        case .sizeAtLeastBytes(let bytes):
            return record.size >= bytes
        case .lastOpenedOlderThanDays(let days):
            let reference = record.lastOpened ?? record.mtime
            return now.timeIntervalSince(reference) >= TimeInterval(days) * 86_400
        case .ownerBundleRunning(let expected):
            guard let owner = rule.owner else { return false }
            return isOwnerRunning(owner) == expected
        }
    }
}
