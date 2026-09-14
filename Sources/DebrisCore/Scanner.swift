import Foundation

/// One pass over the in-scope roots. Emits `FileRecord`s into an async
/// stream, pruning protected and excluded subtrees at directory level.
/// Cancellation stops enumeration; everything emitted so far stays valid.
public final class Scanner: @unchecked Sendable {

    private let scope: ScanScope
    private let protectedPaths: ProtectedPaths
    private let home: URL
    private let isExcluded: @Sendable (URL) -> Bool

    private let lock = NSLock()
    private var _deniedCount = 0

    /// Valid while scanning and after the stream finishes.
    public var deniedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _deniedCount
    }

    public init(
        scope: ScanScope,
        protectedPaths: ProtectedPaths = ProtectedPaths(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExcluded: @escaping @Sendable (URL) -> Bool = { _ in false }
    ) {
        self.scope = scope
        self.protectedPaths = protectedPaths
        self.home = home.standardizedFileURL
        self.isExcluded = isExcluded
    }

    public func records() -> AsyncThrowingStream<FileRecord, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) { [self] in
                do {
                    for root in scope.roots where shouldScan(root: root) {
                        try scanRoot(root) { continuation.yield($0) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Enumeration

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
        .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        .contentModificationDateKey, .contentAccessDateKey,
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    private func scanRoot(_ root: URL, yield: (FileRecord) -> Void) throws {
        let rootPath = root.standardizedFileURL.path
        // realpath, not resolvingSymlinksInPath: the latter strips /private
        // again, hiding the very difference we need to detect.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedRootPath = realpath(rootPath, &buffer).map { String(cString: $0) } ?? rootPath
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: [],
            errorHandler: { [weak self] _, error in
                self?.noteError(error)
                return true
            }
        ) else { return }

        for case let rawURL as URL in enumerator {
            try Task.checkCancellation()
            var url = rawURL
            // The enumerator resolves the base (/var → /private/var); map
            // paths back to the caller's form so every prefix comparison
            // downstream sees one consistent spelling.
            if resolvedRootPath != rootPath, rawURL.path.hasPrefix(resolvedRootPath) {
                url = URL(fileURLWithPath: rootPath + rawURL.path.dropFirst(resolvedRootPath.count))
            }
            let values = try? url.resourceValues(forKeys: Self.resourceKeys)
            let isSymlink = values?.isSymbolicLink ?? false
            let isDirectory = (values?.isDirectory ?? false) && !isSymlink

            if isDirectory, protectedPaths.isProtected(url) || isExcluded(url) {
                enumerator.skipDescendants()
                continue
            }
            if isExcluded(url) || protectedPaths.isProtected(url) { continue }

            yield(makeRecord(url: url, values: values, isDirectory: isDirectory, isSymlink: isSymlink))
        }
    }

    private func makeRecord(url: URL, values: URLResourceValues?, isDirectory: Bool, isSymlink: Bool) -> FileRecord {
        let size = Int64(values?.fileSize ?? 0)
        var inode: UInt64 = 0
        var linkCount = 1
        if !isDirectory, !isSymlink, values?.isRegularFile == true {
            var st = stat()
            if lstat(url.path, &st) == 0 {
                inode = st.st_ino
                linkCount = Int(st.st_nlink)
            }
        }
        let placeholder = values?.ubiquitousItemDownloadingStatus == .notDownloaded
        return FileRecord(
            url: url,
            size: size,
            allocatedSize: (values?.totalFileAllocatedSize ?? values?.fileAllocatedSize).map(Int64.init),
            mtime: values?.contentModificationDate ?? .distantPast,
            lastOpened: values?.contentAccessDate,
            inode: inode,
            linkCount: linkCount,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            isCloudPlaceholder: placeholder)
    }

    private func noteError(_ error: Error) {
        let ns = error as NSError
        let denied = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError)
            || (ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)))
        guard denied else { return }
        lock.lock()
        _deniedCount += 1
        lock.unlock()
    }

    // MARK: - Mount table (S9: external volumes opt-in, never block on a vanished disk)

    private func shouldScan(root: URL) -> Bool {
        let path = root.standardizedFileURL.path
        if path == home.path || path.hasPrefix(home.path + "/") { return true }

        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return false }

        var bestMountPoint: String?
        var bestIsLocal = false
        for i in 0..<Int(count) {
            var entry = mounts[i]
            let mountPoint = withUnsafePointer(to: &entry.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let covers = path == mountPoint || mountPoint == "/" || path.hasPrefix(mountPoint + "/")
            if covers, mountPoint.count > (bestMountPoint?.count ?? -1) {
                bestMountPoint = mountPoint
                bestIsLocal = entry.f_flags & UInt32(MNT_LOCAL) != 0
            }
        }

        guard let mountPoint = bestMountPoint else { return false } // not mounted
        guard bestIsLocal else { return false }                     // network volume
        if mountPoint == "/" || mountPoint == "/System/Volumes/Data" { return true }
        guard let uuid = try? URL(fileURLWithPath: mountPoint)
            .resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else { return false }
        return scope.includeExternalVolumeUUIDs.contains(uuid)
    }
}
