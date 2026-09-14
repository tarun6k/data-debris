import Foundation

/// User exclusions: excluded items are filtered out before matching and
/// never shown. Backed by a small JSON file next to the findings database.
public final class ExclusionStore: @unchecked Sendable {

    public struct Exclusions: Codable, Equatable, Sendable {
        public var paths: [String] = []
        public var folders: [String] = []
        public var bundleIds: [String] = []
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var exclusions: Exclusions

    public static func defaultFileURL() throws -> URL {
        try FindingsStore.defaultDatabaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("exclusions.json")
    }

    public init(fileURL: URL? = nil) throws {
        self.fileURL = try fileURL ?? Self.defaultFileURL()
        if let data = try? Data(contentsOf: self.fileURL) {
            exclusions = (try? JSONDecoder().decode(Exclusions.self, from: data)) ?? Exclusions()
        } else {
            exclusions = Exclusions()
        }
    }

    public func addPath(_ path: String) throws { try mutate { $0.paths.appendUnique(path) } }
    public func addFolder(_ path: String) throws { try mutate { $0.folders.appendUnique(path) } }
    public func addBundleId(_ id: String) throws { try mutate { $0.bundleIds.appendUnique(id) } }

    public func removePath(_ path: String) throws { try mutate { $0.paths.removeAll { $0 == path } } }
    public func removeFolder(_ path: String) throws { try mutate { $0.folders.removeAll { $0 == path } } }
    public func removeBundleId(_ id: String) throws { try mutate { $0.bundleIds.removeAll { $0 == id } } }

    public func list() -> Exclusions {
        lock.lock(); defer { lock.unlock() }
        return exclusions
    }

    public func isExcluded(_ url: URL) -> Bool {
        let path = url.path
        lock.lock(); defer { lock.unlock() }
        if exclusions.paths.contains(path) { return true }
        return exclusions.folders.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    public func excludesOwner(_ bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        lock.lock(); defer { lock.unlock() }
        return exclusions.bundleIds.contains(bundleId)
    }

    private func mutate(_ change: (inout Exclusions) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        change(&exclusions)
        let data = try JSONEncoder().encode(exclusions)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension Array where Element: Equatable {
    mutating func appendUnique(_ element: Element) {
        if !contains(element) { append(element) }
    }
}
