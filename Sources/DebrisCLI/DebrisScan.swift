import DebrisCore
import Foundation

// Debug harness: scans the real home, prints per-category totals and the
// denied count. `clean --dry-run` additionally prints the CleanPlan for the
// current selection. This tool never deletes anything. Manual checks only —
// never shipped.
@main
struct DebrisScan {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let dryRun = arguments.first == "clean"
        if dryRun, !arguments.contains("--dry-run") {
            print("debris-scan clean only supports --dry-run; nothing is ever deleted from the CLI.")
            exit(1)
        }

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

        guard dryRun else { return }

        let selection = try store.findings(in: result.scanId)
            .filter { (try? store.isSelected($0.id)) == true }
        let plan = Planner().plan(selection: selection, request: .manual())

        print("\nDry-run clean plan — \(plan.items.count) items, \(formatter.string(fromByteCount: plan.estimatedBytes)) estimated (allocated)")
        for notice in plan.notices {
            let owner = notice.ownerAppName.map { " [\($0)]" } ?? ""
            print("  note: \(notice.consequence)\(owner)")
        }
        for conflict in plan.runningAppConflicts {
            print("  running: \(conflict.appName) owns \(conflict.itemCount) selected items")
        }
        if !plan.itemsRequiringPermanent.isEmpty {
            print("  no Trash on volume (would need permanent): \(plan.itemsRequiringPermanent.count) items")
        }
        for item in plan.items {
            print("  \(formatter.string(fromByteCount: item.allocatedSize).padding(toLength: 12, withPad: " ", startingAt: 0)) \(item.originalPath)")
        }
        print("Nothing was moved or deleted.")
    }
}
