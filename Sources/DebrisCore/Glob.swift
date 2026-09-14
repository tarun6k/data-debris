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
        let expanded: String
        if pattern == "~" {
            expanded = home.path
        } else if pattern.hasPrefix("~/") {
            expanded = home.path + pattern.dropFirst(1)
        } else {
            expanded = pattern
        }
        return match(components(expanded)[...], components(path)[...])
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

    private static func componentMatches(_ pattern: String, _ name: String) -> Bool {
        if pattern == name { return true }
        guard pattern.contains("*") || pattern.contains("?") || pattern.contains("[") else { return false }
        return fnmatch(pattern, name, 0) == 0
    }
}
