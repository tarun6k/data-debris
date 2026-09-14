import Foundation

/// A single filesystem entry as seen by the scanner, with the attributes
/// the rule matcher and analyzers need.
public struct FileRecord: Equatable, Sendable {
    public let url: URL
    public let size: Int64
    public let allocatedSize: Int64
    public let mtime: Date
    public let lastOpened: Date?
    public let inode: UInt64
    public let linkCount: Int
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isCloudPlaceholder: Bool

    public init(
        url: URL,
        size: Int64 = 0,
        allocatedSize: Int64? = nil,
        mtime: Date = .distantPast,
        lastOpened: Date? = nil,
        inode: UInt64 = 0,
        linkCount: Int = 1,
        isDirectory: Bool = false,
        isSymlink: Bool = false,
        isCloudPlaceholder: Bool = false
    ) {
        self.url = url
        self.size = size
        self.allocatedSize = allocatedSize ?? size
        self.mtime = mtime
        self.lastOpened = lastOpened
        self.inode = inode
        self.linkCount = linkCount
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isCloudPlaceholder = isCloudPlaceholder
    }
}
