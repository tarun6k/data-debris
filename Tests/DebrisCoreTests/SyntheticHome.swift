import Foundation

/// Builds a throwaway home directory in tmp with known debris, traps and
/// edge cases for the scan pipeline tests.
enum SyntheticHome {

    /// Creates the home and returns its URL. `bulkLogs` adds that many old
    /// log files (for the cancellation test, which needs a steady stream of
    /// individual findings).
    static func build(bulkLogs: Int = 0) throws -> URL {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("debris-home-\(UUID().uuidString)", isDirectory: true)

        @discardableResult
        func file(_ relative: String, bytes: Int = 1_024, daysAgo: Double = 0) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x44, count: bytes).write(to: url)
            if daysAgo > 0 { backdate(url, daysAgo: daysAgo) }
            return url
        }

        // App caches: a generic one, and Chrome with the Cookies trap.
        try file("Library/Caches/com.example.demo/blob", bytes: 5_000_000)
        try file("Library/Caches/Google/Chrome/Default/Cache/data_1", bytes: 1_000_000)
        try file("Library/Caches/Google/Chrome/Default/Cookies", bytes: 200_000)

        // Logs: one old (finding), one new (not).
        try file("Library/Logs/old.log", bytes: 100_000, daysAgo: 30)
        try file("Library/Logs/new.log", bytes: 100_000, daysAgo: 1)
        for i in 0..<bulkLogs {
            try file("Library/Logs/bulk/log-\(i).log", bytes: 1_000, daysAgo: 30)
        }

        // Xcode DerivedData, 5 days old.
        try file("Library/Developer/Xcode/DerivedData/Proj-abc/Build/app.o", bytes: 300_000, daysAgo: 5)

        // Git repo: src is protected, node_modules is gitignored build output.
        try file("code/proj/.git/config", bytes: 64)
        try file("code/proj/src/main.swift", bytes: 2_000)
        try file("code/proj/node_modules/pkg/index.js", bytes: 50_000, daysAgo: 120)
        try "node_modules/\nbuild/\n.build/\ntarget/\nDerivedData/\n"
            .write(to: home.appendingPathComponent("code/proj/.gitignore"), atomically: true, encoding: .utf8)

        // Trap: a folder named "cache" inside Application Support.
        try file("Library/Application Support/Game/cache/save.dat", bytes: 400_000)

        // Large old file (sparse, so it costs no real disk space).
        try sparse(home.appendingPathComponent("big/dataset.bin"), logicalBytes: 600_000_000, daysAgo: 200)

        // Hard-linked pair, both large and old.
        let linkA = home.appendingPathComponent("linked/link-a")
        try sparse(linkA, logicalBytes: 600_000_000, daysAgo: 200)
        try fm.linkItem(at: linkA, to: home.appendingPathComponent("linked/link-b"))

        // Symlink into /System — must never be followed or claimed.
        try fm.createDirectory(at: home.appendingPathComponent("sym"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            at: home.appendingPathComponent("sym/system-link"),
            withDestinationURL: URL(fileURLWithPath: "/System"))

        // Something already in the Trash.
        try file(".Trash/old.zip", bytes: 2_000_000)

        // Directory mtimes last: creating children bumps the parent's mtime.
        backdate(home.appendingPathComponent("code/proj/node_modules/pkg"), daysAgo: 120)
        backdate(home.appendingPathComponent("code/proj/node_modules"), daysAgo: 120)
        backdate(home.appendingPathComponent("Library/Developer/Xcode/DerivedData/Proj-abc"), daysAgo: 5)

        return home
    }

    private static func sparse(_ url: URL, logicalBytes: Int64, daysAgo: Double) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64(logicalBytes - 1))
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        backdate(url, daysAgo: daysAgo)
    }

    private static func backdate(_ url: URL, daysAgo: Double) {
        let seconds = Int(Date().addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        utimes(url.path, &times)
    }
}
