import Foundation

/// Free/total are read live (cheap). The System/Apps/Documents split needs a
/// directory walk, so it is computed in the background and cached for an hour.
struct DiskSnapshot: Codable, Equatable {
    var total: Int64
    var free: Int64
    var system: Int64
    var apps: Int64
    var documents: Int64
    var computedAt: Date

    var used: Int64 { max(0, total - free) }
    var other: Int64 { max(0, used - system - apps - documents) }
    /// True until the background walk has filled the segments in.
    var hasSegments: Bool { system + apps + documents > 0 }
}

enum DiskUsage {
    private static let cacheKey = "diskSnapshot"

    static func freeAndTotal() -> (free: Int64, total: Int64) {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        return (Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0),
                Int64(values?.volumeTotalCapacity ?? 0))
    }

    static var volumeName: String {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName)
            ?? "Macintosh HD"
    }

    static func cached() -> DiskSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(DiskSnapshot.self, from: data)
    }

    /// Live free/total plus cached segments; recomputes segments only when the
    /// cache is missing or older than an hour.
    static func refresh() async -> DiskSnapshot {
        let (free, total) = freeAndTotal()
        if var snapshot = cached(), Date().timeIntervalSince(snapshot.computedAt) < 3600 {
            snapshot.free = free
            snapshot.total = total
            return snapshot
        }
        let home = NSHomeDirectory()
        // ponytail: full walks of /System and /Applications, hourly, off the
        // main thread; sample-and-extrapolate if this ever shows up in top.
        let snapshot = await Task.detached(priority: .utility) {
            DiskSnapshot(
                total: total,
                free: free,
                system: allocatedSize(paths: ["/System", "/Library", "/usr"]),
                apps: allocatedSize(paths: ["/Applications"]),
                documents: allocatedSize(paths: [
                    "\(home)/Documents", "\(home)/Desktop", "\(home)/Pictures",
                    "\(home)/Movies", "\(home)/Music",
                ]),
                computedAt: Date())
        }.value
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        return snapshot
    }

    private static func allocatedSize(paths: [String]) -> Int64 {
        var total: Int64 = 0
        for path in paths {
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                options: [],
                errorHandler: { _, _ in true })
            while let url = enumerator?.nextObject() as? URL {
                total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                    .totalFileAllocatedSize) ?? 0)
            }
        }
        return total
    }
}
