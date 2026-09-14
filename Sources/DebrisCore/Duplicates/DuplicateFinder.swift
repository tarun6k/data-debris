import CryptoKit
import Foundation
import IOKit.ps

public struct DuplicateProgress: Sendable {
    public let candidates: Int
    public let filesHashed: Int
    public let bytesHashed: Int64
    public let currentPath: String
}

public struct DuplicateScanSummary: Sendable {
    public let groups: [DuplicateGroup]
    /// Same-hash pairs that already share storage (APFS clones); dropped
    /// from groups and reported honestly instead (S10).
    public let clonePairsIgnored: Int
    public let filesHashed: Int
    public let bytesHashed: Int64
    /// How many times hashing waited for battery or thermal headroom.
    public let pauseEvents: Int
    public let duration: TimeInterval
}

/// §7: size groups → 64 KB prefix hash → full streaming SHA-256, with
/// hard links, APFS clones and iCloud placeholders excluded. Feed it the
/// scan's `FileRecord` stream via `observe`, then call `findGroups()` —
/// hashing runs after the walk, never during it.
public final class DuplicateFinder: @unchecked Sendable { // counters behind `lock`

    struct Candidate: Sendable {
        let path: String
        let size: Int64
        let allocatedSize: Int64
        let mtime: Date
        let inode: UInt64
    }

    private let minBytes: Int64
    private let home: URL
    private let cache: FindingsStore?
    private let widthOverride: Int?
    private let isPaused: @Sendable () -> Bool
    private let pausePollNanoseconds: UInt64

    private var candidates: [Candidate] = []
    /// linkCount > 1 files sharing an inode collapse to one candidate: the
    /// other names free nothing. ponytail: keyed by inode alone — a cross-
    /// volume inode collision needs the pair hard-linked AND byte-identical.
    private var seenLinkedInodes: Set<UInt64> = []

    private let lock = NSLock()
    private var filesHashed = 0
    private var bytesHashed: Int64 = 0
    private var pauseEvents = 0

    public var candidateCount: Int { candidates.count }

    public init(
        thresholds: Thresholds = Thresholds(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        cache: FindingsStore? = nil,
        maxConcurrentOverride: Int? = nil,
        isPaused: (@Sendable () -> Bool)? = nil,
        pausePollNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.minBytes = thresholds.duplicateMinBytes
        self.home = home.standardizedFileURL
        self.cache = cache
        self.widthOverride = maxConcurrentOverride
        self.isPaused = isPaused ?? { PowerStatus.constrained }
        self.pausePollNanoseconds = pausePollNanoseconds
    }

    // MARK: - Candidate collection (during the walk)

    /// The scanner already prunes protected paths, excluded folders and VCS
    /// trees from the stream, so only the per-file filters live here.
    public func observe(_ record: FileRecord) {
        guard !record.isDirectory, !record.isSymlink,
              !record.isCloudPlaceholder,           // never trigger a download
              record.size >= minBytes else { return }
        if record.linkCount > 1 {
            guard seenLinkedInodes.insert(record.inode).inserted else { return }
        }
        candidates.append(Candidate(
            path: record.url.path,
            size: record.size,
            allocatedSize: record.allocatedSize,
            mtime: record.mtime,
            inode: record.inode))
    }

    // MARK: - Pipeline

    public func findGroups(
        shouldAbort: (@Sendable () -> Bool)? = nil,
        onProgress: (@Sendable (DuplicateProgress) -> Void)? = nil
    ) async throws -> DuplicateScanSummary {
        let started = Date()

        // Stage 1: exact size; a unique size cannot have a duplicate.
        let sizeGroups = Dictionary(grouping: candidates, by: \.size)
            .values.filter { $0.count >= 2 }

        // Cache: (path, size, mtime, inode) hits skip hashing entirely.
        let cached = (try? cache?.hashCacheLookup(
            paths: sizeGroups.flatMap { $0.map(\.path) })) ?? [:]
        func cachedHash(_ candidate: Candidate) -> String? {
            guard let entry = cached[candidate.path],
                  entry.size == candidate.size,
                  entry.inode == candidate.inode,
                  entry.mtime == candidate.mtime.timeIntervalSince1970 else { return nil }
            return entry.hash
        }

        let width = widthOverride ?? Self.concurrencyWidth(
            probing: sizeGroups.first?.max { $0.size < $1.size })

        var fullHashes: [String: String] = [:] // path → hash
        var needFull: [Candidate] = []

        // Stage 2: 64 KB prefix hash splits the uncached members of each
        // size group; cached members already carry a full hash.
        for group in sizeGroups {
            var uncached: [Candidate] = []
            var hasCached = false
            for candidate in group {
                if let hash = cachedHash(candidate) {
                    fullHashes[candidate.path] = hash
                    hasCached = true
                } else {
                    uncached.append(candidate)
                }
            }
            guard !uncached.isEmpty else { continue }
            let prefixes = try await hash(
                uncached, limit: 65_536, width: width,
                shouldAbort: shouldAbort, onProgress: onProgress)
            let buckets = Dictionary(grouping: uncached) { prefixes[$0.path] ?? "" }
            for (prefix, members) in buckets where !prefix.isEmpty {
                // A lone new file can still match a cached copy, so it needs
                // its full hash whenever cached members exist in the group.
                if members.count >= 2 || hasCached { needFull.append(contentsOf: members) }
            }
        }

        // Stage 3: full streaming SHA-256.
        let hashed = try await hash(
            needFull, limit: nil, width: width,
            shouldAbort: shouldAbort, onProgress: onProgress)
        fullHashes.merge(hashed) { _, new in new }
        try? cache?.hashCacheStore(needFull.compactMap { candidate in
            hashed[candidate.path].map {
                (candidate.path, candidate.size, candidate.mtime.timeIntervalSince1970, candidate.inode, $0)
            }
        })

        // Regroup by full hash; drop clones (same physical first extent on
        // the same device — they already share storage).
        var groups: [DuplicateGroup] = []
        var clonePairs = 0
        let byHash = Dictionary(grouping: candidates.filter { fullHashes[$0.path] != nil }) {
            fullHashes[$0.path]!
        }
        for (hash, members) in byHash where members.count >= 2 {
            var kept: [Candidate] = []
            var seenExtents: Set<UInt64> = []
            for member in members.sorted(by: { $0.path < $1.path }) {
                if let extent = Self.firstExtentKey(member.path),
                   !seenExtents.insert(extent).inserted {
                    clonePairs += 1
                    continue
                }
                kept.append(member)
            }
            let copies = kept.map { candidate in
                DuplicateCopy(
                    url: URL(fileURLWithPath: candidate.path),
                    mtime: candidate.mtime,
                    size: candidate.size,
                    allocatedSize: candidate.allocatedSize,
                    location: HomeLocation.classify(URL(fileURLWithPath: candidate.path), home: home))
            }
            if let group = DuplicateGroup(hash: hash, copies: copies) {
                groups.append(group)
            }
        }
        groups.sort { $0.reclaimableBytes > $1.reclaimableBytes }

        lock.lock()
        let summary = DuplicateScanSummary(
            groups: groups,
            clonePairsIgnored: clonePairs,
            filesHashed: filesHashed,
            bytesHashed: bytesHashed,
            pauseEvents: pauseEvents,
            duration: Date().timeIntervalSince(started))
        lock.unlock()
        return summary
    }

    // MARK: - Hashing

    /// Hashes `files` (whole file, or the first `limit` bytes) with at most
    /// `width` concurrent readers at .background QoS, pausing while the
    /// machine is constrained.
    private func hash(
        _ files: [Candidate],
        limit: Int64?,
        width: Int,
        shouldAbort: (@Sendable () -> Bool)?,
        onProgress: (@Sendable (DuplicateProgress) -> Void)?
    ) async throws -> [String: String] {
        guard !files.isEmpty else { return [:] }
        var results: [String: String] = [:]
        var iterator = files.makeIterator()

        try await withThrowingTaskGroup(of: (String, String)?.self) { group in
            var running = 0
            func add(_ candidate: Candidate) {
                group.addTask(priority: .background) { [self] in
                    while isPaused() {
                        if shouldAbort?() == true { throw CancellationError() }
                        lock.lock(); pauseEvents += 1; lock.unlock()
                        try await Task.sleep(nanoseconds: pausePollNanoseconds)
                    }
                    if shouldAbort?() == true { throw CancellationError() }
                    guard let (digest, bytes) = Self.sha256(path: candidate.path, limit: limit) else {
                        return nil // unreadable or changed since the walk: not a duplicate
                    }
                    lock.lock()
                    filesHashed += 1
                    bytesHashed += bytes
                    let progress = DuplicateProgress(
                        candidates: candidates.count, filesHashed: filesHashed,
                        bytesHashed: bytesHashed, currentPath: candidate.path)
                    lock.unlock()
                    onProgress?(progress)
                    return (candidate.path, digest)
                }
                running += 1
            }
            while running < width, let next = iterator.next() { add(next) }
            while let finished = try await group.next() {
                running -= 1
                if let (path, digest) = finished { results[path] = digest }
                if let next = iterator.next() { add(next) }
            }
            return
        }
        return results
    }

    private static func sha256(path: String, limit: Int64?) -> (hash: String, bytes: Int64)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? .max
        var total: Int64 = 0
        while remaining > 0 {
            let chunkSize = Int(min(1_048_576, remaining)) // 1 MB reads
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
            remaining -= Int64(chunk.count)
        }
        guard total > 0 else { return nil }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    // MARK: - Clone detection

    /// Physical offset of the file's first extent (F_LOG2PHYS), keyed with
    /// the device id. Two same-hash files with the same key occupy the same
    /// blocks — an APFS clone (or another hard-link name). Errors (compressed
    /// or empty files) mean "treat as distinct", which only ever over-lists.
    private static func firstExtentKey(_ path: String) -> UInt64? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var l2p = log2phys()
        guard fcntl(fd, F_LOG2PHYS, &l2p) == 0, l2p.l2p_devoffset >= 0 else { return nil }
        // Fold dev in so identical offsets on different volumes never match.
        return UInt64(bitPattern: l2p.l2p_devoffset) ^ (UInt64(st.st_dev) &* 0x9E37_79B9_7F4A_7C15)
    }

    // MARK: - Concurrency width

    /// 2 readers on rotational media, 6 on solid state. Chosen detection: a
    /// one-shot read-throughput probe (first 8 MB of the largest candidate,
    /// ≥ 150 MB/s ⇒ SSD) — simpler than the IOKit registry walk and it works
    /// for any volume, external disks included. No candidate to probe ⇒ 6:
    /// internal Apple silicon storage is always solid state, and a scan that
    /// small finishes instantly either way.
    private static func concurrencyWidth(probing sample: Candidate?) -> Int {
        guard let sample, let handle = FileHandle(forReadingAtPath: sample.path) else { return 6 }
        defer { try? handle.close() }
        let started = Date()
        guard let data = try? handle.read(upToCount: 8_388_608), data.count > 1_048_576 else { return 6 }
        let seconds = max(Date().timeIntervalSince(started), 0.000_001)
        let mbPerSecond = Double(data.count) / 1_048_576 / seconds
        return mbPerSecond >= 150 ? 6 : 2
    }
}

/// Battery and thermal gate for background hashing (§7: paused on low
/// battery, resumed automatically).
enum PowerStatus {
    static var constrained: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical { return true }
        return onBatteryBelow(percent: 20)
    }

    static func onBatteryBelow(percent: Int) -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return false } // desktops have no battery source
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                info[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                let current = info[kIOPSCurrentCapacityKey] as? Int,
                let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return current * 100 / max < percent
        }
        return false
    }
}
