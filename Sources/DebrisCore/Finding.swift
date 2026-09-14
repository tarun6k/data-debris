import CryptoKit
import Foundation

/// One removable (or explained) item produced by an analyzer.
public struct Finding: Equatable, Sendable, Identifiable {
    /// Stable across scans: SHA-256 of rule id + path.
    public let id: String
    public let ruleId: String
    public let url: URL
    public let size: Int64
    public let allocatedSize: Int64
    public let mtime: Date
    public let lastOpened: Date?
    public let level: Level
    public let category: Category
    public let reason: String
    public let consequence: String
    public let ownerBundleId: String?
    /// False for hard links and iCloud placeholders: removing them frees nothing.
    public let isReclaimable: Bool

    public init(
        ruleId: String,
        url: URL,
        size: Int64,
        allocatedSize: Int64,
        mtime: Date,
        lastOpened: Date?,
        level: Level,
        category: Category,
        reason: String,
        consequence: String,
        ownerBundleId: String? = nil,
        isReclaimable: Bool = true
    ) {
        self.id = Finding.stableID(ruleId: ruleId, path: url.path)
        self.ruleId = ruleId
        self.url = url
        self.size = size
        self.allocatedSize = allocatedSize
        self.mtime = mtime
        self.lastOpened = lastOpened
        self.level = level
        self.category = category
        self.reason = reason
        self.consequence = consequence
        self.ownerBundleId = ownerBundleId
        self.isReclaimable = isReclaimable
    }

    public static func stableID(ruleId: String, path: String) -> String {
        let digest = SHA256.hash(data: Data("\(ruleId)\n\(path)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
