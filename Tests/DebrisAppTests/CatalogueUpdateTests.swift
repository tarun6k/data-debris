import XCTest
import DebrisCore
@testable import DataDebris

/// An app update ships a new bundled catalogue. It must not change Auto
/// Clean selections, exclusions or the privacy acknowledgement, must leave
/// new rules unticked (S9), and shows the what's-new sheet exactly once.
@MainActor
final class CatalogueUpdateTests: XCTestCase {
    private var dir: URL!

    private func rule(_ id: String) -> Rule {
        Rule(id: id, category: .appCaches, level: .safe, match: ["~/Library/Caches/\(id)"],
             unit: .directory, reason: "r", consequence: "c", autoCleanEligible: true)
    }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogueUpdateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        AppPaths.userDefaults.set(true, forKey: AppModel.welcomeCompletedKey)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        AppPaths.userDefaults.removeObject(forKey: AppModel.welcomeCompletedKey)
        AppPaths.userDefaults.removeObject(forKey: AppModel.catalogueSeenKey)
    }

    private func seen(_ record: CatalogueSeen?) throws {
        if let record {
            AppPaths.userDefaults.set(try JSONEncoder().encode(record), forKey: AppModel.catalogueSeenKey)
        } else {
            AppPaths.userDefaults.removeObject(forKey: AppModel.catalogueSeenKey)
        }
    }

    private func makeModel(catalogue: Catalogue,
                           moveDecision: MoveToApplications.Decision = .notABundle) throws -> AppModel {
        AppModel(
            store: try FindingsStore(databaseURL: dir.appendingPathComponent("findings.sqlite")),
            history: try HistoryStore(databaseURL: dir.appendingPathComponent("history.sqlite")),
            exclusions: try ExclusionStore(fileURL: dir.appendingPathComponent("exclusions.json")),
            catalogue: catalogue,
            edition: .licensed, // purchases enabled: these tests protect the 1.0 path
            autoCleanConfigURL: dir.appendingPathComponent("settings.json"),
            launchAgents: LaunchAgentManager(
                agentsDirectory: dir.appendingPathComponent("LaunchAgents"),
                programPath: "/bin/true", uid: 501, launchctl: { _ in 0 }),
            licenseStore: LicenseFixture.activeStore(),
            fdaProbe: { true },
            moveDecision: moveDecision)
    }

    func testUpdateKeepsSelectionsAndListsNewRulesOnce() throws {
        let ack = PrivacyAcknowledgement(textHash: "abc", acknowledgedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try AutoCleanConfig(enabled: true, enabledRuleIds: ["a"], privacyAcknowledgement: ack)
            .save(to: dir.appendingPathComponent("settings.json"))
        try seen(CatalogueSeen(version: 1, ruleIds: ["a", "b"]))

        let v2 = Catalogue(version: 2, rules: [rule("a"), rule("b"), rule("c")])
        let model = try makeModel(catalogue: v2)

        XCTAssertEqual(model.catalogueChanges?.added.map(\.id), ["c"])
        XCTAssertEqual(model.catalogueChanges?.removedIds, [])
        XCTAssertEqual(model.autoCleanConfig.enabledRuleIds, ["a"], "new rule c is unticked (S9)")
        XCTAssertTrue(model.autoCleanConfig.enabled)
        XCTAssertEqual(model.autoCleanConfig.privacyAcknowledgement, ack)

        // Recorded: the next launch of the same version shows nothing.
        let again = try makeModel(catalogue: v2)
        XCTAssertNil(again.catalogueChanges)
    }

    func testFirstLaunchRecordsSilently() throws {
        try seen(nil)
        let model = try makeModel(catalogue: Catalogue(version: 1, rules: [rule("a")]))
        XCTAssertNil(model.catalogueChanges)
        let stored = try XCTUnwrap(AppPaths.userDefaults.data(forKey: AppModel.catalogueSeenKey))
        XCTAssertEqual(try JSONDecoder().decode(CatalogueSeen.self, from: stored),
                       CatalogueSeen(version: 1, ruleIds: ["a"]))
    }

    func testWhatsNewWaitsBehindTheMoveSheet() throws {
        try seen(CatalogueSeen(version: 1, ruleIds: ["a"]))
        let model = try makeModel(
            catalogue: Catalogue(version: 2, rules: [rule("a"), rule("b")]),
            moveDecision: .offer(destination: URL(fileURLWithPath: "/Applications/Data Debris.app")))
        XCTAssertNotNil(model.moveOffer)
        XCTAssertNil(model.catalogueChanges, "one sheet at a time")
        model.moveOffer = nil
        XCTAssertEqual(model.catalogueChanges?.added.map(\.id), ["b"])
    }
}
