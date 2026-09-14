import Foundation
import GRDB

public enum ScanStatus: String, Sendable {
    case complete, partial, cancelled
}

public enum CategoryState: String, Sendable {
    case all, some, none
}

public struct ScanInfo: Sendable {
    public let id: Int64
    public let startedAt: Date
    public let finishedAt: Date?
    public let status: ScanStatus?
    public let deniedCount: Int
}

/// SQLite-backed store for scans, findings and the user's selection.
/// Selection persists across scans by finding id (rule id + path hash),
/// so a re-scan keeps the user's choices.
public final class FindingsStore: @unchecked Sendable { // DatabasePool is thread-safe

    private let pool: DatabasePool

    public static func defaultDatabaseURL() throws -> URL {
        let dir = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("DataDebris", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("findings.sqlite")
    }

    public init(databaseURL: URL? = nil) throws {
        let url = try databaseURL ?? Self.defaultDatabaseURL()
        pool = try DatabasePool(path: url.path) // WAL by default

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "scans") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("status", .text)
                t.column("deniedCount", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "findings") { t in
                t.column("scanId", .integer).notNull().references("scans", onDelete: .cascade)
                t.column("id", .text).notNull()
                t.column("ruleId", .text).notNull()
                t.column("path", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("allocatedSize", .integer).notNull()
                t.column("mtime", .datetime).notNull()
                t.column("lastOpened", .datetime)
                t.column("level", .text).notNull()
                t.column("category", .text).notNull()
                t.column("reason", .text).notNull()
                t.column("consequence", .text).notNull()
                t.column("owner", .text)
                t.column("reclaimable", .boolean).notNull()
                t.primaryKey(["scanId", "id"])
            }
            try db.create(table: "selection") { t in
                t.column("findingId", .text).primaryKey()
                t.column("selected", .boolean).notNull()
            }
            try db.create(table: "categorySelection") { t in
                t.column("category", .text).primaryKey()
                t.column("state", .text).notNull()
            }
        }
        try migrator.migrate(pool)
    }

    // MARK: - Scans

    public func beginScan(startedAt: Date = Date()) throws -> Int64 {
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO scans (startedAt, deniedCount) VALUES (?, 0)",
                arguments: [startedAt])
            return db.lastInsertedRowID
        }
    }

    public func finishScan(_ scanId: Int64, status: ScanStatus, deniedCount: Int, finishedAt: Date = Date()) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE scans SET finishedAt = ?, status = ?, deniedCount = ? WHERE id = ?",
                arguments: [finishedAt, status.rawValue, deniedCount, scanId])
        }
    }

    public func lastScan() throws -> ScanInfo? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM scans ORDER BY id DESC LIMIT 1") else {
                return nil
            }
            return ScanInfo(
                id: row["id"],
                startedAt: row["startedAt"],
                finishedAt: row["finishedAt"],
                status: (row["status"] as String?).flatMap(ScanStatus.init),
                deniedCount: row["deniedCount"])
        }
    }

    // MARK: - Findings

    public func upsert(_ findings: [Finding], scanId: Int64) throws {
        guard !findings.isEmpty else { return }
        try pool.write { db in
            for finding in findings {
                try db.execute(sql: """
                    INSERT INTO findings
                        (scanId, id, ruleId, path, size, allocatedSize, mtime, lastOpened,
                         level, category, reason, consequence, owner, reclaimable)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(scanId, id) DO UPDATE SET
                        size = excluded.size, allocatedSize = excluded.allocatedSize,
                        mtime = excluded.mtime, lastOpened = excluded.lastOpened,
                        reclaimable = excluded.reclaimable
                    """, arguments: [
                        scanId, finding.id, finding.ruleId, finding.url.path,
                        finding.size, finding.allocatedSize, finding.mtime, finding.lastOpened,
                        finding.level.rawValue, finding.category.rawValue,
                        finding.reason, finding.consequence, finding.ownerBundleId,
                        finding.isReclaimable,
                    ])
                // S2 default: safe pre-selected, review and manual not. Existing
                // choices win (OR IGNORE); non-reclaimable items get no row at all.
                if finding.isReclaimable {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO selection (findingId, selected) VALUES (?, ?)",
                        arguments: [finding.id, finding.level == .safe])
                }
            }
            try Self.refreshCategoryStates(db, scanId: scanId)
        }
    }

    public func findings(in scanId: Int64) throws -> [Finding] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM findings WHERE scanId = ? ORDER BY path", arguments: [scanId])
                .compactMap { row in
                    guard let level = Level(rawValue: row["level"]),
                          let category = Category(rawValue: row["category"]) else { return nil }
                    return Finding(
                        ruleId: row["ruleId"],
                        url: URL(fileURLWithPath: row["path"]),
                        size: row["size"],
                        allocatedSize: row["allocatedSize"],
                        mtime: row["mtime"],
                        lastOpened: row["lastOpened"],
                        level: level,
                        category: category,
                        reason: row["reason"],
                        consequence: row["consequence"],
                        ownerBundleId: row["owner"],
                        isReclaimable: row["reclaimable"])
                }
        }
    }

    // MARK: - Selection

    public func setSelected(_ findingIds: [String], _ selected: Bool) throws {
        guard !findingIds.isEmpty else { return }
        try pool.write { db in
            // Joining through findings keeps non-reclaimable items untouched.
            let placeholders = databaseQuestionMarks(count: findingIds.count)
            var arguments: [DatabaseValueConvertible] = [selected]
            arguments.append(contentsOf: findingIds as [DatabaseValueConvertible])
            try db.execute(sql: """
                INSERT INTO selection (findingId, selected)
                SELECT DISTINCT id, ? FROM findings WHERE id IN (\(placeholders)) AND reclaimable = 1
                ON CONFLICT(findingId) DO UPDATE SET selected = excluded.selected
                """, arguments: StatementArguments(arguments))
            if let scanId = try Self.latestScanId(db) {
                try Self.refreshCategoryStates(db, scanId: scanId)
            }
        }
    }

    public func setCategory(_ category: Category, state: CategoryState) throws {
        try pool.write { db in
            if state != .some, let scanId = try Self.latestScanId(db) {
                try db.execute(sql: """
                    UPDATE selection SET selected = ? WHERE findingId IN
                        (SELECT id FROM findings WHERE scanId = ? AND category = ? AND reclaimable = 1)
                    """, arguments: [state == .all, scanId, category.rawValue])
            }
            try db.execute(sql: """
                INSERT INTO categorySelection (category, state) VALUES (?, ?)
                ON CONFLICT(category) DO UPDATE SET state = excluded.state
                """, arguments: [category.rawValue, state.rawValue])
        }
    }

    public func isSelected(_ findingId: String) throws -> Bool? {
        try pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT selected FROM selection WHERE findingId = ?", arguments: [findingId])
        }
    }

    /// Bulk read for the UI: every selected finding id in one query.
    public func selectedFindingIds(in scanId: Int64) throws -> Set<String> {
        try pool.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT f.id FROM findings f JOIN selection s ON s.findingId = f.id
                WHERE f.scanId = ? AND s.selected = 1
                """, arguments: [scanId]))
        }
    }

    public func categoryState(_ category: Category) throws -> CategoryState {
        try pool.read { db in
            let raw = try String.fetchOne(
                db, sql: "SELECT state FROM categorySelection WHERE category = ?",
                arguments: [category.rawValue])
            return raw.flatMap(CategoryState.init) ?? .none
        }
    }

    // MARK: - Totals (S10: allocated bytes, reclaimable only, latest scan)

    public func totals() throws -> [Category: (bytes: Int64, count: Int)] {
        try pool.read { db in
            guard let scanId = try Self.latestScanId(db) else { return [:] }
            var result: [Category: (bytes: Int64, count: Int)] = [:]
            let rows = try Row.fetchAll(db, sql: """
                SELECT category, IFNULL(SUM(allocatedSize), 0) AS bytes, COUNT(*) AS count
                FROM findings WHERE scanId = ? AND reclaimable = 1 GROUP BY category
                """, arguments: [scanId])
            for row in rows {
                guard let category = Category(rawValue: row["category"]) else { continue }
                result[category] = (row["bytes"], row["count"])
            }
            return result
        }
    }

    public func selectedTotals() throws -> (bytes: Int64, count: Int) {
        try pool.read { db in
            guard let scanId = try Self.latestScanId(db) else { return (0, 0) }
            let row = try Row.fetchOne(db, sql: """
                SELECT IFNULL(SUM(f.allocatedSize), 0) AS bytes, COUNT(*) AS count
                FROM findings f JOIN selection s ON s.findingId = f.id
                WHERE f.scanId = ? AND f.reclaimable = 1 AND s.selected = 1
                """, arguments: [scanId])!
            return (row["bytes"], row["count"])
        }
    }

    // MARK: - Helpers

    private static func latestScanId(_ db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM scans")
    }

    /// The category tri-state is derived from the selection rows of the
    /// latest scan and cached for the UI.
    private static func refreshCategoryStates(_ db: Database, scanId: Int64) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT f.category,
                   SUM(CASE WHEN s.selected THEN 1 ELSE 0 END) AS selected,
                   COUNT(*) AS total
            FROM findings f LEFT JOIN selection s ON s.findingId = f.id
            WHERE f.scanId = ? AND f.reclaimable = 1
            GROUP BY f.category
            """, arguments: [scanId])
        for row in rows {
            let selected: Int = row["selected"]
            let total: Int = row["total"]
            let state: CategoryState = selected == 0 ? .none : (selected == total ? .all : .some)
            try db.execute(sql: """
                INSERT INTO categorySelection (category, state) VALUES (?, ?)
                ON CONFLICT(category) DO UPDATE SET state = excluded.state
                """, arguments: [row["category"] as String, state.rawValue])
        }
    }
}
