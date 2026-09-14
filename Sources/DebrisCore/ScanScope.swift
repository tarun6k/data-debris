import Foundation

public struct Thresholds: Equatable, Sendable {
    public var largeFileBytes: Int64
    public var oldDays: Int
    public var duplicateMinBytes: Int64

    public init(
        largeFileBytes: Int64 = 500_000_000,
        oldDays: Int = 180,
        duplicateMinBytes: Int64 = 1_000_000
    ) {
        self.largeFileBytes = largeFileBytes
        self.oldDays = oldDays
        self.duplicateMinBytes = duplicateMinBytes
    }
}

public struct ScanScope: Sendable {
    public var roots: [URL]
    public var includeExternalVolumeUUIDs: [String]
    public var thresholds: Thresholds

    public init(
        roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser],
        includeExternalVolumeUUIDs: [String] = [],
        thresholds: Thresholds = Thresholds()
    ) {
        self.roots = roots
        self.includeExternalVolumeUUIDs = includeExternalVolumeUUIDs
        self.thresholds = thresholds
    }
}
