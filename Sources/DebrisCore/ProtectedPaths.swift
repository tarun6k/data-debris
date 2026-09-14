import Foundation

/// One entry in the "Built-in protections" list shown in Settings.
public struct Protection: Equatable, Sendable {
    public let name: String
    public let reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }
}

/// The hard-coded never-touch list (product spec §3). These are not
/// preferences; `isProtected` prunes at directory level so enumeration
/// never descends into a protected subtree.
public final class ProtectedPaths: @unchecked Sendable {

    /// Build-output directory names that developer rules may claim inside a
    /// VCS working tree — but only when the repo's .gitignore lists them.
    public static let gitignoredBuildDirNames: Set<String> = [
        "node_modules", "build", ".build", "target", "DerivedData",
    ]

    /// Home-root dot-entries that catalogue rules claim (package caches and
    /// the Trash). Every other dot-entry in the home root is protected.
    private static let allowedHomeDotDirectories: Set<String> = [
        ".Trash", ".npm", ".yarn", ".gradle", ".cargo",
    ]

    private static let protectedLibrarySubfolders: Set<String> = [
        "Application Support", "Preferences", "Containers", "Group Containers",
        "Keychains", "Mobile Documents", "Mail",
    ]

    private static let mediaLibraryExtensions: Set<String> = [
        "photoslibrary", "musiclibrary", "tvlibrary", "aplibrary", "imovielibrary",
        "booklibrary", "fcpbundle", "logicx", "lrcat", "lrdata", "lrlibrary",
    ]

    private static let backupComponents: Set<String> = [
        "Backups.backupdb", ".timemachine", "com.apple.TimeMachine.localsnapshots", ".MobileBackups",
    ]

    private static let vcsMetadataNames: Set<String> = [".git", ".hg", ".svn"]

    private let home: URL
    private let homeComponents: [String]
    private let fileManager: FileManager
    private let lock = NSLock()
    private var repoRootCache: [String: String?] = [:]
    private var gitignoreCache: [String: Set<String>] = [:]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.home = home.standardizedFileURL
        self.homeComponents = Glob.components(Self.canonicalPath(self.home.path))
        self.fileManager = fileManager
    }

    public func isProtected(_ url: URL) -> Bool {
        let path = Self.canonicalPath(url.standardizedFileURL.path)
        let comps = Glob.components(path)
        guard !comps.isEmpty else { return false }

        // System roots and other users' homes.
        switch comps[0] {
        case "System", "usr", "bin", "sbin", "Library":
            return true
        case "private":
            if comps.count == 1 { return true }
            if comps[1] == "var" {
                // User-scoped tmp lives in /private/var/folders.
                if comps.count < 3 || comps[2] != "folders" { return true }
            }
        case "Users":
            if comps.count >= 2 {
                let isOwnHome = homeComponents.count >= 2
                    && homeComponents[0] == "Users"
                    && comps[1] == homeComponents[1]
                if !isOwnHome { return true }
            }
        default:
            break
        }

        // Bundles, media libraries, backups and VCS metadata, at any depth.
        for component in comps {
            if component.hasSuffix(".app") { return true }
            let ext = (component as NSString).pathExtension.lowercased()
            if !ext.isEmpty, Self.mediaLibraryExtensions.contains(ext) { return true }
            if Self.backupComponents.contains(component) { return true }
            if Self.vcsMetadataNames.contains(component) { return true }
        }

        // Inside the current user's home.
        if comps.count > homeComponents.count, Array(comps.prefix(homeComponents.count)) == homeComponents {
            let rel = Array(comps.dropFirst(homeComponents.count))
            let first = rel[0]
            if first.hasPrefix("."), !Self.allowedHomeDotDirectories.contains(first) { return true }
            if first == "Library", rel.count >= 2, Self.protectedLibrarySubfolders.contains(rel[1]) { return true }
            if rel.count >= 2, first == "Music", rel[1] == "Music" || rel[1] == "iTunes" { return true }
            if rel.count >= 2, first == "Movies", rel[1] == "TV" { return true }
        }

        // VCS working trees: everything inside is protected except build
        // directories the repo's own .gitignore excludes from source control.
        if let repoRoot = nearestRepositoryRoot(above: url) {
            return !hasGitignoredBuildAncestor(url, repoRoot: repoRoot)
        }

        return false
    }

    /// True when `url` is a build directory (node_modules, build, .build,
    /// target, DerivedData) inside a VCS working tree whose .gitignore lists
    /// that name. Only such directories may be claimed by developer rules.
    public func isGitignoredBuildDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard Self.gitignoredBuildDirNames.contains(name) else { return false }
        guard let repoRoot = nearestRepositoryRoot(above: url) else { return false }
        return gitignorePatterns(repoRoot: repoRoot).contains(name)
    }

    // MARK: - VCS detection

    private func nearestRepositoryRoot(above url: URL) -> String? {
        let stops: Set<String> = [
            "/", "/Users", "/Volumes", "/private", "/private/var", "/var", "/tmp", "/private/tmp",
            home.path,
        ]
        var dir = url.standardizedFileURL.deletingLastPathComponent()
        var visited: [String] = []
        var found: String?

        while true {
            let path = dir.path
            if path.isEmpty || stops.contains(path) { break }

            lock.lock()
            let cached = repoRootCache[path]
            lock.unlock()
            if let cached {
                found = cached
                break
            }

            visited.append(path)
            if isRepositoryRoot(path) {
                found = path
                break
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == path { break }
            dir = parent
        }

        lock.lock()
        for path in visited { repoRootCache[path] = found }
        lock.unlock()
        return found
    }

    private func isRepositoryRoot(_ path: String) -> Bool {
        for name in Self.vcsMetadataNames where fileManager.fileExists(atPath: path + "/" + name) {
            return true
        }
        return false
    }

    private func hasGitignoredBuildAncestor(_ url: URL, repoRoot: String) -> Bool {
        var names: [String] = []
        var dir = url.standardizedFileURL
        while dir.path != repoRoot, dir.path != "/" {
            names.append(dir.lastPathComponent)
            dir.deleteLastPathComponent()
        }
        let candidates = names.filter { Self.gitignoredBuildDirNames.contains($0) }
        guard !candidates.isEmpty else { return false }
        let listed = gitignorePatterns(repoRoot: repoRoot)
        return candidates.contains { listed.contains($0) }
    }

    /// Parses the repo's .gitignore for the known build-directory names only;
    /// every other pattern is ignored.
    private func gitignorePatterns(repoRoot: String) -> Set<String> {
        lock.lock()
        if let cached = gitignoreCache[repoRoot] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var listed: Set<String> = []
        if let text = try? String(contentsOfFile: repoRoot + "/.gitignore", encoding: .utf8) {
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
                var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty || line.hasPrefix("#") { continue }
                var negated = false
                if line.hasPrefix("!") {
                    negated = true
                    line = String(line.dropFirst())
                }
                if line.hasSuffix("/**") { line = String(line.dropLast(3)) }
                if line.hasSuffix("/") { line = String(line.dropLast()) }
                if line.hasPrefix("**/") { line = String(line.dropFirst(3)) }
                if line.hasPrefix("/") { line = String(line.dropFirst()) }
                guard Self.gitignoredBuildDirNames.contains(line) else { continue }
                if negated {
                    listed.remove(line)
                } else {
                    listed.insert(line)
                }
            }
        }

        lock.lock()
        gitignoreCache[repoRoot] = listed
        lock.unlock()
        return listed
    }

    // MARK: - Canonicalization

    private static func canonicalPath(_ path: String) -> String {
        var p = path
        if p == "/System/Volumes/Data" {
            p = "/"
        } else if p.hasPrefix("/System/Volumes/Data/") {
            p = String(p.dropFirst("/System/Volumes/Data".count))
        }
        if p == "/var" || p.hasPrefix("/var/") { p = "/private" + p }
        if p == "/tmp" || p.hasPrefix("/tmp/") { p = "/private" + p }
        return p
    }

    // MARK: - Settings display

    /// Shown under "Built-in protections" in Settings (product spec §3).
    public static let builtInProtections: [Protection] = [
        Protection(
            name: "macOS system folders",
            reason: "/System, /usr, /bin, /sbin, /private/var and the Preboot and Recovery volumes are SIP-protected or OS-critical; macOS manages them."
        ),
        Protection(
            name: "System-wide /Library and other users' home folders",
            reason: "Outside your user account's authority. The app never asks for root."
        ),
        Protection(
            name: "Application bundles (.app)",
            reason: "Deleting inside a bundle breaks its code signature; uninstalling is out of scope."
        ),
        Protection(
            name: "Photos, Music, TV, Books, Final Cut and Logic libraries; Lightroom catalogs; Mail data",
            reason: "App-managed databases with internal references. Duplicates inside them are managed by the owning app."
        ),
        Protection(
            name: "Git, Mercurial and Subversion working trees",
            reason: "Source is never junk. Only build output the repo's own .gitignore excludes may be offered."
        ),
        Protection(
            name: "App state in ~/Library",
            reason: "Application Support, Preferences, Containers, Group Containers, Keychains and Mobile Documents hold app state, settings, credentials and iCloud Drive. A folder named \"cache\" inside them is still not touched."
        ),
        Protection(
            name: "Time Machine backups and local APFS snapshots",
            reason: "Backups are not junk. Snapshots are explained, not deleted."
        ),
        Protection(
            name: "Files open or memory-mapped by a running process",
            reason: "Checked again at clean time and skipped with the reason \"in use\"."
        ),
        Protection(
            name: "Hidden dot-files in the home root",
            reason: "Configuration and secrets (.ssh, .gnupg, .zshrc). Only known package caches (.npm, .yarn, .gradle, .cargo) and the Trash are scanned."
        ),
    ]
}
