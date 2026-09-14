import XCTest
import DebrisCore
@testable import DataDebris

private typealias Category = DebrisCore.Category

/// Screen 8's model surface: ticking categories writes eligible rule ids
/// only, the enable toggle drives the LaunchAgent, and the status line.
final class AutoCleanViewTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoCleanViewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    private func makeModel() throws -> AppModel {
        AppModel(
            store: try FindingsStore(databaseURL: dir.appendingPathComponent("findings.sqlite")),
            history: try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite")),
            exclusions: try ExclusionStore(fileURL: dir.appendingPathComponent("exclusions.json")),
            catalogue: try Catalogue.bundled(),
            autoCleanConfigURL: dir.appendingPathComponent("settings.json"),
            launchAgents: LaunchAgentManager(
                agentsDirectory: dir.appendingPathComponent("LaunchAgents"),
                programPath: "/Applications/DataDebris.app/Contents/MacOS/DataDebris",
                uid: 501, launchctl: { _ in 0 }))
    }

    /// Only categories with eligible rules are offered, and a tick writes
    /// exactly that category's eligible rule ids (S2/S9).
    @MainActor
    func testTogglingCategoryTicksOnlyEligibleRuleIds() throws {
        let model = try makeModel()

        XCTAssertEqual(model.autoCleanConfig.enabledRuleIds, []) // S9 default
        XCTAssertFalse(model.autoCleanCategories.contains(.duplicates))
        XCTAssertFalse(model.autoCleanCategories.contains(.largeOld))
        XCTAssertFalse(model.autoCleanCategories.contains(.trash))

        model.toggleAutoCleanCategory(.logs)
        XCTAssertEqual(Set(model.autoCleanConfig.enabledRuleIds),
                       ["logs.general", "logs.diagnosticreports"])
        XCTAssertEqual(model.autoCleanState(for: .logs), .all)
        XCTAssertEqual(model.autoCleanState(for: .appCaches), CategoryState.none)

        model.toggleAutoCleanCategory(.logs)
        XCTAssertEqual(model.autoCleanConfig.enabledRuleIds, [])
    }

    /// The toggle installs/uninstalls the agent and persists the config.
    @MainActor
    func testEnableInstallsAgentAndDisableRemovesIt() throws {
        let model = try makeModel()
        let plist = dir.appendingPathComponent("LaunchAgents")
            .appendingPathComponent(LaunchAgentManager.label + ".plist")

        model.setAutoCleanEnabled(true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertTrue(AutoCleanConfig.load(from: dir.appendingPathComponent("settings.json")).enabled)
        XCTAssertTrue(model.autoCleanStatusLine.hasPrefix("Next run "))

        model.setAutoCleanEnabled(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertEqual(model.autoCleanStatusLine, "Not scheduled")
    }
}
