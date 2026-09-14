import DebrisCore
import Foundation

// Debug harness: scans the real home, prints per-category totals and the
// denied count. Manual checks only — never shipped.
@main
struct DebrisScan {
    static func main() async throws {
        let catalogue = try Catalogue.bundled()
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("debris-scan-\(ProcessInfo.processInfo.processIdentifier).sqlite")
        let store = try FindingsStore(databaseURL: dbURL)
        let runner = ScanRunner(scope: ScanScope(), catalogue: catalogue, store: store)

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        print("Scanning \(FileManager.default.homeDirectoryForCurrentUser.path) …")
        let result = try await runner.run()
        let totals = try store.totals()

        for category in Category.allCases {
            let (bytes, count) = totals[category] ?? (0, 0)
            let name = category.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
            print("  \(name) \(formatter.string(fromByteCount: bytes))  (\(count) items)")
        }
        print("  trash total  \(formatter.string(fromByteCount: result.trashBytes))  (\(result.trashCount) files)")
        print("Records: \(result.recordCount)  Findings: \(result.findingCount)  Denied dirs: \(result.deniedCount)")
        print("Status: \(result.status.rawValue)  Time: \(String(format: "%.1f", result.duration)) s")
    }
}
