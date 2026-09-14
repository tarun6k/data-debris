import Foundation

/// Component-wise glob matching for catalogue path patterns.
///
/// - `*` matches exactly one path component (with `fnmatch` wildcards inside
///   a component, e.g. `*.xcarchive`).
/// - `**` matches zero or more components, except as the final pattern
///   component, where it requires at least one — so `~/Library/Logs/**`
///   matches children of Logs but never Logs itself.
enum Glob {
    static func matches(pattern: String, path: String, home: URL) -> Bool {
        match(components(expand(pattern, home: home))[...], components(path)[...])
    }

    /// True when `pattern` could match something strictly inside `directory`:
    /// the pattern consumes every directory component with components left
    /// over. Used to stop a broad directory rule from claiming a folder whose
    /// contents a more specific rule distinguishes (e.g. Chrome's Cache vs
    /// Cookies under ~/Library/Caches/Google).
    static func couldMatchWithin(pattern: String, directory: String, home: URL) -> Bool {
        prefixMatch(components(expand(pattern, home: home))[...], components(directory)[...])
    }

    private static func expand(_ pattern: String, home: URL) -> String {
        if pattern == "~" { return home.path }
        if pattern.hasPrefix("~/") { return home.path + pattern.dropFirst(1) }
        return pattern
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static func match(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard let head = pattern.first else { return path.isEmpty }
        if head == "**" {
            if pattern.count == 1 { return !path.isEmpty }
            if match(pattern.dropFirst(), path) { return true }
            guard !path.isEmpty else { return false }
            return match(pattern, path.dropFirst())
        }
        guard let pathHead = path.first, componentMatches(head, pathHead) else { return false }
        return match(pattern.dropFirst(), path.dropFirst())
    }

    private static func prefixMatch(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard !path.isEmpty else { return !pattern.isEmpty }
        guard let head = pattern.first else { return false }
        if head == "**" {
            if prefixMatch(pattern.dropFirst(), path) { return true }
            return prefixMatch(pattern, path.dropFirst())
        }
        guard let pathHead = path.first, componentMatches(head, pathHead) else { return false }
        return prefixMatch(pattern.dropFirst(), path.dropFirst())
    }

    private static func componentMatches(_ pattern: String, _ name: String) -> Bool {
        if pattern == name { return true }
        guard pattern.contains("*") || pattern.contains("?") || pattern.contains("[") else { return false }
        return fnmatch(pattern, name, 0) == 0
    }
}
