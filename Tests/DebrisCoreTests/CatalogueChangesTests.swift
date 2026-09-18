import XCTest
@testable import DebrisCore

final class CatalogueChangesTests: XCTestCase {
    private func rule(_ id: String, eligible: Bool = true) -> Rule {
        Rule(id: id, category: .appCaches, level: .safe, match: ["~/Library/Caches/\(id)"],
             unit: .directory, reason: "r", consequence: "c", autoCleanEligible: eligible)
    }

    func testFirstLaunchAndUnchangedVersionShowNothing() {
        let v1 = Catalogue(version: 1, rules: [rule("a"), rule("b")])
        XCTAssertNil(v1.changes(since: nil))
        XCTAssertNil(v1.changes(since: v1.seen))
        XCTAssertNil(v1.changes(since: CatalogueSeen(version: 1, ruleIds: ["a"])),
                     "same version: rule-level drift is not an update")
    }

    func testUpdateListsAddedAndRemovedRules() throws {
        let seen = CatalogueSeen(version: 1, ruleIds: ["a", "b", "old"])
        let v2 = Catalogue(version: 2, rules: [rule("a"), rule("b"), rule("c"), rule("d")])
        let changes = try XCTUnwrap(v2.changes(since: seen))
        XCTAssertEqual(changes.fromVersion, 1)
        XCTAssertEqual(changes.toVersion, 2)
        XCTAssertEqual(changes.added.map(\.id), ["c", "d"])
        XCTAssertEqual(changes.removedIds, ["old"])
        XCTAssertFalse(changes.isEmpty)
    }

    func testPureVersionBumpIsEmpty() throws {
        let v1 = Catalogue(version: 1, rules: [rule("a")])
        let v2 = Catalogue(version: 2, rules: [rule("a")])
        XCTAssertTrue(try XCTUnwrap(v2.changes(since: v1.seen)).isEmpty)
    }

    /// S9: a new eligible rule is not ticked by the update; the user's
    /// selection survives as long as its rules still exist.
    func testNewRulesArriveUntickedAndSelectionsSurvive() {
        let config = AutoCleanConfig(enabled: true, enabledRuleIds: ["a"])
        let v2 = Catalogue(version: 2, rules: [rule("a"), rule("c")])
        let validated = config.validated(against: v2)
        XCTAssertEqual(validated.enabledRuleIds, ["a"])
        XCTAssertTrue(validated.enabled)

        let v3 = Catalogue(version: 3, rules: [rule("c")])
        XCTAssertEqual(config.validated(against: v3).enabledRuleIds, [], "removed rule is dropped")
    }

    func testSeenRecordRoundTrips() throws {
        let seen = Catalogue(version: 4, rules: [rule("x"), rule("y")]).seen
        let data = try JSONEncoder().encode(seen)
        XCTAssertEqual(try JSONDecoder().decode(CatalogueSeen.self, from: data), seen)
        XCTAssertEqual(seen, CatalogueSeen(version: 4, ruleIds: ["x", "y"]))
    }
}
