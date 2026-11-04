import Foundation

/// A Docker object a finding points at instead of a file. It travels through
/// the stores and the journal as a URL — `docker://image/<id>` or
/// `docker://build-cache/<id>` — so ids, selection and history work
/// unchanged; nothing on disk has that path. Removal goes through the docker
/// CLI one object per call and cannot be undone: there is no Trash for
/// images, so such items are journaled as irreversible.
public enum DockerObject: Equatable, Hashable, Sendable {
    case image(id: String)
    case buildCache(id: String)

    public static let scheme = "docker"
    private static let imageHost = "image"
    private static let buildCacheHost = "build-cache"
    private static let idCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":._-"))

    public init?(url: URL) {
        guard url.scheme == Self.scheme, let host = url.host else { return nil }
        let id = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard Self.isValid(id: id) else { return nil }
        switch host {
        case Self.imageHost: self = .image(id: id)
        case Self.buildCacheHost: self = .buildCache(id: id)
        default: return nil
        }
    }

    /// From what FindingsStore and the journal hold.
    public init?(storedPath: String) {
        guard storedPath.hasPrefix(Self.scheme + "://"), let url = URL(string: storedPath) else { return nil }
        self.init(url: url)
    }

    public static func isValid(id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { idCharacters.contains($0) }
    }

    public var id: String {
        switch self {
        case .image(let id), .buildCache(let id): return id
        }
    }

    public var url: URL {
        switch self {
        case .image(let id): return URL(string: "\(Self.scheme)://\(Self.imageHost)/\(id)")!
        case .buildCache(let id): return URL(string: "\(Self.scheme)://\(Self.buildCacheHost)/\(id)")!
        }
    }

    public var storedPath: String { url.absoluteString }

    public var displayName: String {
        switch self {
        case .image(let id): return "Docker image \(id)"
        case .buildCache(let id): return "Docker build cache \(id)"
        }
    }

    /// Arguments after `docker`, naming this one object. Never a bare
    /// `system prune` or `builder prune`.
    public var removalArguments: [String] {
        switch self {
        case .image(let id):
            // No --force: docker itself refuses an image that gained a tag or
            // a container since the scan — the S6 re-check, done daemon-side.
            return ["image", "rm", id]
        case .buildCache(let id):
            // --all widens the eligible cache types (to buildkit a regular
            // layer record is not "dangling"); the id filter keeps the call
            // to this one record. --force only skips the terminal prompt.
            return ["builder", "prune", "--force", "--all", "--filter", "id=\(id)"]
        }
    }
}

extension Finding {
    /// The string the stores and the journal persist: the file path, or the
    /// docker URL for an object that is not a file.
    public var storedPath: String { Finding.storedPath(for: url) }

    public static func storedPath(for url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }

    public static func url(forStoredPath path: String) -> URL {
        DockerObject(storedPath: path)?.url ?? URL(fileURLWithPath: path)
    }

    public var dockerObject: DockerObject? { DockerObject(url: url) }
}
