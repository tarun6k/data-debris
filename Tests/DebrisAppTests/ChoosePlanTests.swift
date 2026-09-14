import XCTest
@testable import DataDebris
import DebrisCore

final class ChoosePlanTests: XCTestCase {

    /// "Save 17%" is derived from the two prices, never hard-coded: a
    /// different price pair yields a different pill.
    func testSavePercentComputedFromPrices() {
        XCTAssertEqual(PlanPricing.savePercent(oneYearUSD: 20, threeYearsUSD: 50), 17)
        XCTAssertEqual(PlanPricing.savePercent(oneYearUSD: 20, threeYearsUSD: 40), 33)
        XCTAssertEqual(PlanPricing.savePercent(oneYearUSD: 20, threeYearsUSD: 60), 0)
        XCTAssertEqual(PlanPricing.saveLabel, "Save 17%")
    }

    /// The exact card strings from ChoosePlan.png.
    func testPerMonthAndAnchorStrings() {
        XCTAssertEqual(PlanPricing.anchor(.oneYear), "$20")
        XCTAssertEqual(PlanPricing.anchor(.threeYears), "$50")
        XCTAssertEqual(PlanPricing.perMonth(.oneYear), "$1.67 / month")
        XCTAssertEqual(PlanPricing.perMonth(.threeYears), "$1.39 / month")
    }

    /// A localized preview maps price ids to formatted totals; a USD answer is
    /// deliberately empty (the anchors already say USD); junk is nil.
    func testPricingPreviewParsing() {
        let euro = """
        {"data":{"currency_code":"EUR","details":{"line_items":[
          {"price":{"id":"pri_1y"},"formatted_totals":{"total":"€18.99"}},
          {"price":{"id":"pri_3y"},"formatted_totals":{"total":"€46.99"}}]}}}
        """
        XCTAssertEqual(PaddlePricing.parse(Data(euro.utf8)),
                       ["pri_1y": "€18.99", "pri_3y": "€46.99"])

        let usd = """
        {"data":{"currency_code":"USD","details":{"line_items":[
          {"price":{"id":"pri_1y"},"formatted_totals":{"total":"$20.00"}}]}}}
        """
        XCTAssertEqual(PaddlePricing.parse(Data(usd.utf8)), [:])

        XCTAssertNil(PaddlePricing.parse(Data("{\"error\":{}}".utf8)))
    }
}
