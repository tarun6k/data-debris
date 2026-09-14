import Foundation
import GRDB

public enum RunMode: String, Sendable {
    case manual, auto, smart
}

public enum Disposal: String, Sendable {
    case trash, permanent
}

/// What kind of clean run to perform. The only way to obtain one is through
/// the static constructors, and the Auto Clean one has no disposal parameter
/// — an auto + permanent run is unrepresentable (S3).
public struct CleanRequest: Equatable, Sendable {
    public let mode: RunMode
    public let disposal: Disposal

    private init(mode: RunMode, disposal: Disposal) {
        self.mode = mode
        self.disposal = disposal
    }

    public static func manual(disposal: Disposal = .trash) -> CleanRequest {
        CleanRequest(mode: .manual, disposal: disposal)
    }

    public static func smart(disposal: Disposal = .trash) -> CleanRequest {
        CleanRequest(mode: .smart, disposal: disposal)
    }

    /// Auto Clean always goes to the Trash (S3).
    public static let autoClean = CleanRequest(mode: .auto, disposal: .trash)
}

public enum RunStatus: String, Sendable {
    case pending, running, completed, cancelled, restored, partiallyRestored
    /// An Auto Clean that never ran: 24 h of deferrals (see `note`).
    case skipped
}

public enum ItemStatus: String, Sendable {
    case pending, done, skipped, restored, irreversible
}

public enum SkipReason: Equatable, Sendable {
    case changed, vanished, protected, noTrash, cancelled, trashEmptied
    case inUse(String)      // process name
    case moveFailed(String) // unexpected error text

    var stored: String {
        switch self {
        case .changed: return "changed"
        case .vanished: return "vanished"
        case .protected: return "protected"
        case .noTrash: return "noTrash"
        case .cancelled: return "cancelled"
        case .trashEmptied: return "trashEmptied"
        case .inUse(let name): return "inUse:\(name)"
        case .moveFailed(let text): return "moveFailed:\(text)"
        }
    }

    init?(stored: String) {
        switch stored {
        case "changed": self = .changed
        case "vanished": self = .vanished
        case "protected": self = .protected
        case "noTrash": self = .noTrash
        case "cancelled": self = .cancelled
        case "trashEmptied": self = .trashEmptied
        default:
            if stored.hasPrefix("inUse:") { self = .inUse(String(stored.dropFirst(6))) }
            else if stored.hasPrefix("moveFailed:") { self = .moveFailed(String(stored.dropFirst(11))) }
            else { return nil }
        }
    }
}

public struct RunRecord: Sendable {
    public let id: Int64
    public let mode: RunMode
    public let startedAt: Date
    public let finishedAt: Date?
    public let disposal: Disposal
    public let status: RunStatus
    public let estimatedBytes: Int64
    public let movedBytes: Int64
    public let freedBytes: Int64
    public let volumeFreeBefore: Int64
    public let volumeFreeAfter: Int64
    /// Only on skipped Auto Clean runs: why nothing happened.
    public let note: String?
}

public struct ItemRecord: Sendable {
    public let id: Int64
    public let runId: Int64
    public let originalPath: String
    public let size: Int64
    public let allocatedSize: Int64
    /// Epoch seconds as a Double, stored REAL so it round-trips exactly.
    public let mtime: Double
    public let inode: UInt64
    public let volumeUUID: String
    public let hash: String?
    public let ruleId: String
    public let isDirectory: Bool
    public let status: ItemStatus
    public let skipReason: SkipReason?
    public let trashURL: String?
    public let movedAt: Date?
}

/// The journal (product spec §8). WAL with synchronous=FULL: every commit is
/// fsync'd, so the item rows are durable before any file moves (S4).
public final class HistoryStore: @unchecked Sendable {

    private let pool: DatabasePool

    public static func defaultDatabaseURL() throws -> URL {
        try FindingsStore.defaultDatabaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("history.sqlite")
    }

    public init(databaseURL: URL? = nil) throws {
        let url = try databaseURL ?? Self.defaultDatabaseURL()
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        pool = try DatabasePool(path: url.path, configuration: config)

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "runs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("mode", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("disposal", .text).notNull()
                t.column("status", .text).notNull()
                t.column("estimatedBytes", .integer).notNull().defaults(to: 0)
                t.column("movedBytes", .integer).notNull().defaults(to: 0)
                t.column("freedBytes", .integer).notNull().defaults(to: 0)
                t.column("volumeFreeBefore", .integer).notNull().defaults(to: 0)
                t.column("volumeFreeAfter", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "items") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("runId", .integer).notNull().references("runs", onDelete: .cascade)
                t.column("originalPath", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("allocatedSize", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("inode", .integer).notNull()
                t.column("volumeUUID", .text).notNull()
                t.column("hash", .text)
                t.column("ruleId", .text).notNull()
                t.column("isDirectory", .boolean).notNull()
                t.column("status", .text).notNull()
                t.column("skipReason", .text)
                t.column("trashURL", .text)
                t.column("movedAt", .datetime)
            }
        }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "runs") { t in
                t.add(column: "note", .text)
            }
        }
        try migrator.migrate(pool)
    }

    /// A lightweight History row for an Auto Clean that gave up after 24 h of
    /// deferrals — no items, nothing moved, just the reason.
    @discardableResult
    public func createSkippedAutoRun(note: String, at date: Date = Date()) throws -> Int64 {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO runs (mode, startedAt, finishedAt, disposal, status, note)
                VALUES ('auto', ?, ?, 'trash', 'skipped', ?)
                """, arguments: [date, date, note])
            return db.lastInsertedRowID
        }
    }

    // MARK: - Journal (S4: run + all items land in one durable transaction)

    public func createRun(
        request: CleanRequest,
        estimatedBytes: Int64,
        volumeFreeBefore: Int64,
        items: [PlanItem],
        startedAt: Date = Date()
    ) throws -> Int64 {
        let runId = try pool.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO runs (mode, startedAt, disposal, status, estimatedBytes, volumeFreeBefore)
                VALUES (?, ?, ?, 'pending', ?, ?)
                """, arguments: [request.mode.rawValue, startedAt, request.disposal.rawValue,
                                 estimatedBytes, volumeFreeBefore])
            let runId = db.lastInsertedRowID
            for item in items {
                try db.execute(sql: """
                    INSERT INTO items (runId, originalPath, size, allocatedSize, mtime, inode,
                                       volumeUUID, hash, ruleId, isDirectory, status)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending')
                    """, arguments: [runId, item.originalPath, item.size, item.allocatedSize,
                                     item.mtime, Int64(bitPattern: item.inode), item.volumeUUID,
                                     item.hash, item.ruleId, item.isDirectory])
            }
            return runId
        }
        // Belt and braces on top of synchronous=FULL: force the WAL into the
        // main database file before the first move.
        try pool.writeWithoutTransaction { db in
            _ = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(FULL)")
        }
        return runId
    }

    public func setRunStatus(_ runId: Int64, _ status: RunStatus) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE runs SET status = ? WHERE id = ?",
                           arguments: [status.rawValue, runId])
        }
    }

    public func finishRun(
        _ runId: Int64,
        status: RunStatus,
        movedBytes: Int64,
        freedBytes: Int64,
        volumeFreeAfter: Int64,
        finishedAt: Date = Date()
    ) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE runs SET status = ?, movedBytes = ?, freedBytes = ?,
                                volumeFreeAfter = ?, finishedAt = ?
                WHERE id = ?
                """, arguments: [status.rawValue, movedBytes, freedBytes,
                                 volumeFreeAfter, finishedAt, runId])
        }
    }

    public func markItem(
        _ itemId: Int64,
        status: ItemStatus,
        skipReason: SkipReason? = nil,
        trashURL: String? = nil,
        movedAt: Date? = nil
    ) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE items SET status = ?, skipReason = ?,
                                 trashURL = COALESCE(?, trashURL),
                                 movedAt = COALESCE(?, movedAt)
                WHERE id = ?
                """, arguments: [status.rawValue, skipReason?.stored, trashURL, movedAt, itemId])
        }
    }

    public func skipRemainingPendingItems(runId: Int64, reason: SkipReason) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE items SET status = 'skipped', skipReason = ?
                WHERE runId = ? AND status = 'pending'
                """, arguments: [reason.stored, runId])
        }
    }

    // MARK: - Reads

    public func run(_ runId: Int64) throws -> RunRecord? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM runs WHERE id = ?", arguments: [runId])
                .flatMap(Self.runRecord)
        }
    }

    public func runs() throws -> [RunRecord] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM runs ORDER BY id DESC").compactMap(Self.runRecord)
        }
    }

    public func items(runId: Int64) throws -> [ItemRecord] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM items WHERE runId = ? ORDER BY id", arguments: [runId])
                .compactMap(Self.itemRecord)
        }
    }

    public func item(_ itemId: Int64) throws -> ItemRecord? {
        try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM items WHERE id = ?", arguments: [itemId])
                .flatMap(Self.itemRecord)
        }
    }

    // MARK: - Recovery & retention

    /// Call at launch: runs left pending/running by a crash become cancelled;
    /// their moved items stay done and restorable.
    @discardableResult
    public func recoverInterruptedRuns(now: Date = Date()) throws -> Int {
        try pool.write { db in
            let ids = try Int64.fetchAll(
                db, sql: "SELECT id FROM runs WHERE status IN ('pending','running')")
            for runId in ids {
                try db.execute(sql: """
                    UPDATE items SET status = 'skipped', skipReason = 'cancelled'
                    WHERE runId = ? AND status = 'pending'
                    """, arguments: [runId])
                try db.execute(sql: "UPDATE runs SET status = 'cancelled', finishedAt = ? WHERE id = ?",
                               arguments: [now, runId])
            }
            return ids.count
        }
    }

    /// Deletes runs older than the retention window — but never a run with a
    /// done item still present in the Trash, however old.
    @discardableResult
    public func pruneExpiredRuns(olderThanDays days: Int, now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let candidates = try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id FROM runs
                WHERE COALESCE(finishedAt, startedAt) < ? AND status NOT IN ('pending','running')
                """, arguments: [cutoff]).map { $0["id"] as Int64 }
        }
        var pruned = 0
        for runId in candidates {
            let restorable = try items(runId: runId).contains { item in
                item.status == .done && item.trashURL.map { FileManager.default.fileExists(atPath: $0) } == true
            }
            guard !restorable else { continue }
            try pool.write { db in
                try db.execute(sql: "DELETE FROM runs WHERE id = ?", arguments: [runId])
            }
            pruned += 1
        }
        return pruned
    }

    // MARK: - Row mapping

    private static func runRecord(_ row: Row) -> RunRecord? {
        guard let mode = RunMode(rawValue: row["mode"]),
              let disposal = Disposal(rawValue: row["disposal"]),
              let status = RunStatus(rawValue: row["status"]) else { return nil }
        return RunRecord(
            id: row["id"], mode: mode, startedAt: row["startedAt"], finishedAt: row["finishedAt"],
            disposal: disposal, status: status, estimatedBytes: row["estimatedBytes"],
            movedBytes: row["movedBytes"], freedBytes: row["freedBytes"],
            volumeFreeBefore: row["volumeFreeBefore"], volumeFreeAfter: row["volumeFreeAfter"],
            note: row["note"])
    }

    private static func itemRecord(_ row: Row) -> ItemRecord? {
        guard let status = ItemStatus(rawValue: row["status"]) else { return nil }
        return ItemRecord(
            id: row["id"], runId: row["runId"], originalPath: row["originalPath"],
            size: row["size"], allocatedSize: row["allocatedSize"], mtime: row["mtime"],
            inode: UInt64(bitPattern: row["inode"]), volumeUUID: row["volumeUUID"],
            hash: row["hash"], ruleId: row["ruleId"], isDirectory: row["isDirectory"],
            status: status,
            skipReason: (row["skipReason"] as String?).flatMap(SkipReason.init(stored:)),
            trashURL: row["trashURL"], movedAt: row["movedAt"])
    }
}
