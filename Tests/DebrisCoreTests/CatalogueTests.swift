import XCTest
@testable import DebrisCore

final class CatalogueTests: XCTestCase {

    private func bundled() throws -> Catalogue {
        try Catalogue.bundled()
    }

    func testBundledCatalogueLoads() throws {
        let catalogue = try bundled()
        XCTAssertGreaterThanOrEqual(catalogue.version, 1)
        XCTAssertEqual(catalogue.rules.count, 23)
    }

    func testRuleIDsAreUnique() throws {
        let ids = try bundled().rules.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testEveryRuleHasReasonAndConsequence() throws {
        for rule in try bundled().rules {
            XCTAssertFalse(rule.reason.isEmpty, rule.id)
            XCTAssertFalse(rule.consequence.isEmpty, rule.id)
            // Copy rules: calm, factual, no exclamation marks.
            XCTAssertFalse(rule.reason.contains("!"), rule.id)
            XCTAssertFalse(rule.consequence.contains("!"), rule.id)
        }
    }

    func testBrowserRulesNeverTouchCredentialsOrHistory() throws {
        let forbidden = ["Cookies", "Local Storage", "Login Data", "History",
                         "Bookmarks", "Web Data", "places.sqlite"]
        for rule in try bundled().rules {
            for pattern in rule.match {
                for term in forbidden {
                    XCTAssertFalse(pattern.contains(term), "\(rule.id): \(pattern)")
                }
            }
        }
    }

    func testOnlySafeRulesAreAutoCleanEligible() throws {
        for rule in try bundled().rules where rule.level != .safe {
            XCTAssertFalse(rule.autoCleanEligible, rule.id)
        }
    }

    func testTrashIsNeverAutoCleanEligible() throws {
        let trash = try XCTUnwrap(bundled().rules.first { $0.category == .trash })
        XCTAssertFalse(trash.autoCleanEligible)
    }

    func testDuplicatesRuleIsAnalyzerOnly() throws {
        let duplicates = try XCTUnwrap(bundled().rules.first { $0.category == .duplicates })
        XCTAssertTrue(duplicates.match.isEmpty)
        XCTAssertFalse(duplicates.autoCleanEligible)
    }

    /// First match wins, so specific rules must precede generic ones and the
    /// catch-all large-and-old rule must come last.
    func testRuleOrderingIsSpecificBeforeGeneric() throws {
        let ids = try bundled().rules.map(\.id)
        let index = { (id: String) in try XCTUnwrap(ids.firstIndex(of: id), id) }
        XCTAssertLessThan(try index("dev.packagecaches"), try index("appcaches.generic"))
        XCTAssertLessThan(try index("logs.diagnosticreports"), try index("logs.general"))
        for browser in ["safari", "chrome", "edge", "brave", "arc", "firefox"] {
            XCTAssertLessThan(try index("appcaches.browser.\(browser)"), try index("appcaches.generic"))
        }
        XCTAssertEqual(ids.last, "largeold.files")
    }

    func testCatalogueRoundTripsThroughCodable() throws {
        let catalogue = try bundled()
        let data = try JSONEncoder().encode(catalogue)
        let decoded = try Catalogue.load(from: data)
        XCTAssertEqual(decoded, catalogue)
    }
}
