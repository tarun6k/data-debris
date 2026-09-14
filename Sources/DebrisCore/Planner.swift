import AppKit
import Foundation

/// One entry of a CleanPlan. Scan-time size/mtime plus plan-time inode and
/// volume, so the executor can detect any change since either point (S6).
public struct PlanItem: Equatable, Sendable {
    public let originalPath: String
    public let size: Int64
    public let allocatedSize: Int64
    /// Epoch seconds; kept as Double end to end so comparisons are exact.
    public let mtime: Double
    public let inode: UInt64
    public let volumeUUID: String
    public let hash: String?
    public let ruleId: String
    public let ownerBundleId: String?
    public let isDirectory: Bool
    /// True when the item's volume has no usable Trash (see Planner heuristic).
    public let requiresPermanent: Bool
}

public struct ConsequenceNotice: Equatable, Sendable {
    public let ruleId: String
    public let consequence: String
    public let ownerBundleId: String?
    public let ownerAppName: String?
}

public struct RunningAppConflict: Equatable, Sendable {
    public let bundleId: String
    public let appName: String
    public let itemCount: Int
}

public struct RunningAppInfo: Equatable, Sendable {
    public let bundleId: String
    public let name: String

    public init(bundleId: String, name: String) {
        self.bundleId = bundleId
        self.name = name
    }
}

/// What Review & Confirm renders and the executor consumes.
public struct CleanPlan: Sendable {
    public let request: CleanRequest
    /// Ordered by volume, then path.
    public let items: [PlanItem]
    /// One notice per rule, not per item.
    public let notices: [ConsequenceNotice]
    public let runningAppConflicts: [RunningAppConflict]
    /// Allocated bytes (S10).
    public let estimatedBytes: Int64
    public let itemsRequiringPermanent: [PlanItem]
    /// "Skip Safari items": the executor drops these before journaling.
    public var skipBundleIds: Set<String> = []
    /// User approved falling back to permanent delete for the items in
    /// `itemsRequiringPermanent` (surfaced per item in Review, S3).
    public var permanentApprovedForNoTrash = false
}

public struct Planner {

    private let runningApplications: @Sendable () -> [RunningAppInfo]

    public init(
        runningApplications: @escaping @Sendable () -> [RunningAppInfo] = {
            NSWorkspace.shared.runningApplications.compactMap { app in
                app.bundleIdentifier.map { RunningAppInfo(bundleId: $0, name: app.localizedName ?? $0) }
            }
        }
    ) {
        self.runningApplications = runningApplications
    }

    public func plan(selection: [Finding], request: CleanRequest) -> CleanPlan {
        var items: [PlanItem] = []
        for finding in selection {
            // Already gone since the scan: nothing to clean, drop it here.
            guard let item = makeItem(finding) else { continue }
            items.append(item)
        }
        items.sort { ($0.volumeUUID, $0.originalPath) < ($1.volumeUUID, $1.originalPath) }

        let running = runningApplications()
        var conflictCounts: [String: Int] = [:]
        for finding in selection {
            if let owner = finding.ownerBundleId { conflictCounts[owner, default: 0] += 1 }
        }
        let conflicts = running
            .filter { conflictCounts[$0.bundleId] != nil }
            .map { RunningAppConflict(bundleId: $0.bundleId, appName: $0.name, itemCount: conflictCounts[$0.bundleId]!) }
            .sorted { $0.appName < $1.appName }

        var seenRules = Set<String>()
        var notices: [ConsequenceNotice] = []
        for finding in selection where seenRules.insert(finding.ruleId).inserted {
            notices.append(ConsequenceNotice(
                ruleId: finding.ruleId,
                consequence: finding.consequence,
                ownerBundleId: finding.ownerBundleId,
                ownerAppName: finding.ownerBundleId.map { owner in
                    running.first { $0.bundleId == owner }?.name ?? appName(forBundleId: owner)
                }))
        }

        return CleanPlan(
            request: request,
            items: items,
            notices: notices,
            runningAppConflicts: conflicts,
            estimatedBytes: items.reduce(0) { $0 + $1.allocatedSize },
            itemsRequiringPermanent: items.filter(\.requiresPermanent))
    }

    private func makeItem(_ finding: Finding) -> PlanItem? {
        var st = stat()
        guard lstat(finding.url.path, &st) == 0 else { return nil }
        let values = try? finding.url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        return PlanItem(
            originalPath: finding.url.path,
            size: finding.size,
            allocatedSize: finding.allocatedSize,
            mtime: finding.mtime.timeIntervalSince1970,
            inode: st.st_ino,
            volumeUUID: values?.volumeUUIDString ?? "",
            hash: nil, // duplicates fill this in Phase 5
            ruleId: finding.ruleId,
            ownerBundleId: finding.ownerBundleId,
            isDirectory: (st.st_mode & S_IFMT) == S_IFDIR,
            requiresPermanent: !volumeHasTrash(finding.url, volumeRoot: values?.volume))
    }

    /// Heuristic for "this volume has no Trash": anything on the boot/home
    /// volume (volume root "/" or a path under the user's home) can always be
    /// trashed. Any other volume qualifies only if its mount root has a
    /// .Trashes directory that is writable or already contains this uid's
    /// folder. We never create .Trashes ourselves; if the check fails and
    /// trashItem later disagrees, the executor's per-item error handling wins.
    private func volumeHasTrash(_ url: URL, volumeRoot: URL?) -> Bool {
        guard let volumeRoot else { return true } // unknown: assume trash, executor verifies
        if volumeRoot.path == "/" { return true }
        if url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/") { return true }
        let trashes = volumeRoot.appendingPathComponent(".Trashes").path
        let uidTrash = trashes + "/\(getuid())"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: uidTrash, isDirectory: &isDir), isDir.boolValue { return true }
        return FileManager.default.fileExists(atPath: trashes, isDirectory: &isDir)
            && isDir.boolValue && FileManager.default.isWritableFile(atPath: trashes)
    }

    private func appName(forBundleId bundleId: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return bundleId
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}
