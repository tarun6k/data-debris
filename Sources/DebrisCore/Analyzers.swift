import Foundation

/// Matches every record against the catalogue. For directory-unit rules it
/// aggregates the sizes of the directory's contents (which the scanner emits
/// depth-first, immediately after the directory itself) into one finding.
public final class RuleAnalyzer {

    private struct OpenDirectory {
        let record: FileRecord
        let rule: Rule
        var bytes: Int64 = 0
        var allocated: Int64 = 0
    }

    private let catalogue: Catalogue
    private let matcher: RuleMatcher
    private let home: URL
    private var open: OpenDirectory?

    public init(catalogue: Catalogue, matcher: RuleMatcher, home: URL) {
        self.catalogue = catalogue
        self.matcher = matcher
        self.home = home.standardizedFileURL
    }

    /// `claimed` is true when this analyzer owns the record (matched, or
    /// counted into an open directory finding); the pipeline then skips
    /// the other analyzers for it.
    public func process(_ record: FileRecord, now: Date = Date()) -> (findings: [Finding], claimed: Bool) {
        var out: [Finding] = []
        if let current = open {
            if record.url.path.hasPrefix(current.record.url.path + "/") {
                // S10: hard links, placeholders and symlinks add no freeable bytes.
                if !record.isDirectory, !record.isSymlink, record.linkCount == 1, !record.isCloudPlaceholder {
                    open?.bytes += record.size
                    open?.allocated += record.allocatedSize
                }
                return (out, true)
            }
            out.append(finalize(current))
            open = nil
        }

        // Large-and-old is analyzer-driven (thresholds), like duplicates.
        guard let rule = matcher.match(record, now: now), rule.category != .largeOld else {
            return (out, false)
        }

        if rule.unit == .directory {
            if moreSpecificRuleReachesInside(rule, directory: record.url.path) {
                return (out, false)
            }
            open = OpenDirectory(record: record, rule: rule)
            return (out, true)
        }

        out.append(makeFinding(rule: rule, record: record, size: record.size, allocated: record.allocatedSize))
        return (out, true)
    }

    /// Flush the trailing open directory. Call once after the stream ends;
    /// skip on cancellation, when its size would be incomplete.
    public func finish() -> [Finding] {
        defer { open = nil }
        return open.map { [finalize($0)] } ?? []
    }

    /// A directory is claimed whole only if no earlier (more specific) rule
    /// distinguishes contents inside it — e.g. appcaches.generic must not
    /// swallow ~/Library/Caches/Google, where the Chrome rule separates
    /// Cache from Cookies.
    private func moreSpecificRuleReachesInside(_ rule: Rule, directory: String) -> Bool {
        guard let index = catalogue.rules.firstIndex(where: { $0.id == rule.id }) else { return false }
        return catalogue.rules[..<index].contains { earlier in
            earlier.match.contains { Glob.couldMatchWithin(pattern: $0, directory: directory, home: home) }
        }
    }

    private func finalize(_ open: OpenDirectory) -> Finding {
        makeFinding(rule: open.rule, record: open.record, size: open.bytes, allocated: open.allocated)
    }

    private func makeFinding(rule: Rule, record: FileRecord, size: Int64, allocated: Int64) -> Finding {
        Finding(
            ruleId: rule.id,
            url: record.url,
            size: size,
            allocatedSize: allocated,
            mtime: record.mtime,
            lastOpened: record.lastOpened,
            level: rule.level,
            category: rule.category,
            reason: rule.reason,
            consequence: rule.consequence,
            ownerBundleId: rule.owner,
            isReclaimable: true)
    }
}

/// Threshold-driven: regular files at least `largeFileBytes` not opened for
/// `oldDays`. Carries the catalogue's largeOld copy so Results shows the
/// same reason text either way.
public struct LargeOldAnalyzer {
    private let thresholds: Thresholds
    private let ruleId: String
    private let consequence: String
    private let reason: String

    public init(thresholds: Thresholds, catalogue: Catalogue) {
        self.thresholds = thresholds
        let rule = catalogue.rules.first { $0.category == .largeOld }
        ruleId = rule?.id ?? "largeold.files"
        consequence = rule?.consequence ?? "No automatic consequence; this file is yours to judge."
        reason = "Large file not opened in \(max(1, thresholds.oldDays / 30)) months"
    }

    public func process(_ record: FileRecord, now: Date = Date()) -> Finding? {
        guard !record.isDirectory, !record.isSymlink,
              record.size >= thresholds.largeFileBytes else { return nil }
        let opened = record.lastOpened ?? record.mtime
        guard now.timeIntervalSince(opened) >= Double(thresholds.oldDays) * 86_400 else { return nil }
        return Finding(
            ruleId: ruleId,
            url: record.url,
            size: record.size,
            allocatedSize: record.allocatedSize,
            mtime: record.mtime,
            lastOpened: record.lastOpened,
            level: .manual,
            category: .largeOld,
            reason: reason,
            consequence: consequence,
            isReclaimable: record.linkCount <= 1 && !record.isCloudPlaceholder)
    }
}

/// Totals what already sits in the Trash (home and external volumes).
public final class TrashAnalyzer {
    private let homeTrashPrefix: String
    public private(set) var totalBytes: Int64 = 0
    public private(set) var totalAllocated: Int64 = 0
    public private(set) var count = 0

    public init(home: URL) {
        homeTrashPrefix = home.standardizedFileURL.path + "/.Trash/"
    }

    public func observe(_ record: FileRecord) {
        guard !record.isDirectory, !record.isSymlink else { return }
        let path = record.url.path
        guard path.hasPrefix(homeTrashPrefix) || path.contains("/.Trashes/") else { return }
        totalBytes += record.size
        totalAllocated += record.allocatedSize
        count += 1
    }
}
