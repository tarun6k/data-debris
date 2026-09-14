import XCTest
@testable import DebrisCore

/// Runs every record in Tests/Fixtures/catalogue-fixtures.json through the
/// matcher and fails if any catalogue rule lacks fixture coverage.
final class FixtureTests: XCTestCase {

    private struct RecordSpec: Decodable {
        let path: String
        let isDirectory: Bool
        let sizeBytes: Int64
        let mtimeDaysAgo: Double
        let lastOpenedDaysAgo: Double?
        let linkCount: Int
        let isSymlink: Bool
        let isCloudPlaceholder: Bool

        private enum CodingKeys: String, CodingKey {
            case path, isDirectory, sizeBytes, mtimeDaysAgo, lastOpenedDaysAgo,
                 linkCount, isSymlink, isCloudPlaceholder
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            isDirectory = try c.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
            sizeBytes = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
            mtimeDaysAgo = try c.decodeIfPresent(Double.self, forKey: .mtimeDaysAgo) ?? 0
            lastOpenedDaysAgo = try c.decodeIfPresent(Double.self, forKey: .lastOpenedDaysAgo)
            linkCount = try c.decodeIfPresent(Int.self, forKey: .linkCount) ?? 1
            isSymlink = try c.decodeIfPresent(Bool.self, forKey: .isSymlink) ?? false
            isCloudPlaceholder = try c.decodeIfPresent(Bool.self, forKey: .isCloudPlaceholder) ?? false
        }
    }

    private struct FixtureEntry: Decodable {
        let ruleID: String
        let analyzerOnly: Bool
        let positive: [RecordSpec]
        let negative: [RecordSpec]

        private enum CodingKeys: String, CodingKey {
            case ruleID, analyzerOnly, positive, negative
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ruleID = try c.decode(String.self, forKey: .ruleID)
            analyzerOnly = try c.decodeIfPresent(Bool.self, forKey: .analyzerOnly) ?? false
            positive = try c.decode([RecordSpec].self, forKey: .positive)
            negative = try c.decode([RecordSpec].self, forKey: .negative)
        }
    }

    private struct FixtureFile: Decodable {
        let fixtures: [FixtureEntry]
    }

    private static let fakeHome = URL(fileURLWithPath: "/Users/fixtureuser")

    private var tempRoot: URL!
    private var repoRoot: URL!
    private var plainRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebrisFixtures-\(UUID().uuidString)")
        repoRoot = tempRoot.appendingPathComponent("repo")
        plainRoot = tempRoot.appendingPathComponent("plain")
        try FileManager.default.createDirectory(
            at: repoRoot.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plainRoot, withIntermediateDirectories: true)
        try "node_modules/\nbuild/\n.build/\ntarget/\nDerivedData/\n"
            .write(to: repoRoot.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func loadFixtures() throws -> [FixtureEntry] {
        let bundle = Bundle(for: FixtureTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "catalogue-fixtures", withExtension: "json"),
            "catalogue-fixtures.json missing from test bundle")
        return try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url)).fixtures
    }

    private func makeMatcher(catalogue: Catalogue) -> RuleMatcher {
        RuleMatcher(
            catalogue: catalogue,
            protectedPaths: ProtectedPaths(home: Self.fakeHome),
            home: Self.fakeHome)
    }

    private func resolve(_ path: String) -> String {
        var p = path
        if p == "~" {
            p = Self.fakeHome.path
        } else if p.hasPrefix("~/") {
            p = Self.fakeHome.path + p.dropFirst(1)
        }
        p = p.replacingOccurrences(of: "$TMPREPO", with: repoRoot.path)
        p = p.replacingOccurrences(of: "$TMPPLAIN", with: plainRoot.path)
        return p
    }

    private func record(from spec: RecordSpec, now: Date) -> FileRecord {
        FileRecord(
            url: URL(fileURLWithPath: resolve(spec.path)),
            size: spec.sizeBytes,
            allocatedSize: spec.sizeBytes,
            mtime: now.addingTimeInterval(-spec.mtimeDaysAgo * 86_400),
            lastOpened: spec.lastOpenedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
            linkCount: spec.linkCount,
            isDirectory: spec.isDirectory,
            isSymlink: spec.isSymlink,
            isCloudPlaceholder: spec.isCloudPlaceholder)
    }

    /// Fails listing every rule id that lacks at least one positive and one
    /// negative fixture, and every fixture that names an unknown rule.
    func testEveryRuleHasFixtures() throws {
        let catalogue = try Catalogue.bundled()
        let fixtures = try loadFixtures()
        let entriesByID = Dictionary(grouping: fixtures, by: \.ruleID)

        var problems: [String] = []
        for rule in catalogue.rules {
            guard let entries = entriesByID[rule.id] else {
                problems.append("\(rule.id): no fixtures")
                continue
            }
            if entries.flatMap(\.positive).isEmpty { problems.append("\(rule.id): no positive fixture") }
            if entries.flatMap(\.negative).isEmpty { problems.append("\(rule.id): no negative fixture") }
        }
        let knownIDs = Set(catalogue.rules.map(\.id))
        for entry in fixtures where !knownIDs.contains(entry.ruleID) {
            problems.append("\(entry.ruleID): fixture references unknown rule")
        }
        XCTAssertTrue(problems.isEmpty, "Fixture coverage gaps:\n" + problems.joined(separator: "\n"))
    }

    func testPositiveFixturesMatchTheirRule() throws {
        let catalogue = try Catalogue.bundled()
        let matcher = makeMatcher(catalogue: catalogue)
        let now = Date()

        for entry in try loadFixtures() {
            let rule = try XCTUnwrap(catalogue.rules.first { $0.id == entry.ruleID })
            for spec in entry.positive {
                let matched = matcher.match(record(from: spec, now: now), now: now)
                if entry.analyzerOnly {
                    // Duplicates come from the hash engine, never a path match,
                    // but the positive record must clear the rule's size floor.
                    XCTAssertNil(matched, "\(spec.path) must not path-match any rule")
                    XCTAssertTrue(satisfiesSizePredicates(rule, sizeBytes: spec.sizeBytes),
                                  "\(spec.path) should satisfy \(entry.ruleID) size predicate")
                } else {
                    XCTAssertEqual(matched?.id, entry.ruleID,
                                   "\(spec.path) should match \(entry.ruleID), got \(matched?.id ?? "nil")")
                }
            }
        }
    }

    func testNegativeFixturesDoNotMatchTheirRule() throws {
        let catalogue = try Catalogue.bundled()
        let matcher = makeMatcher(catalogue: catalogue)
        let now = Date()

        for entry in try loadFixtures() {
            let rule = try XCTUnwrap(catalogue.rules.first { $0.id == entry.ruleID })
            for spec in entry.negative {
                let matched = matcher.match(record(from: spec, now: now), now: now)
                XCTAssertNotEqual(matched?.id, entry.ruleID,
                                  "\(spec.path) must not match \(entry.ruleID)")
                if entry.analyzerOnly {
                    XCTAssertNil(matched, "\(spec.path) must not path-match any rule")
                    XCTAssertFalse(satisfiesSizePredicates(rule, sizeBytes: spec.sizeBytes),
                                   "\(spec.path) should fail \(entry.ruleID) size predicate")
                }
            }
        }
    }

    private func satisfiesSizePredicates(_ rule: Rule, sizeBytes: Int64) -> Bool {
        rule.predicates.allSatisfy { predicate in
            if case .sizeAtLeastBytes(let bytes) = predicate { return sizeBytes >= bytes }
            return true
        }
    }
}
