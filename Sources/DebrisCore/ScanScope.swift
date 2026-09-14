import Foundation

public struct Thresholds: Equatable, Sendable {
    public var largeFileBytes: Int64
    public var oldDays: Int

    public init(largeFileBytes: Int64 = 500_000_000, oldDays: Int = 180) {
        self.largeFileBytes = largeFileBytes
        self.oldDays = oldDays
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
