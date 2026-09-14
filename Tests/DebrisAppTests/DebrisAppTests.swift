import XCTest
@testable import DataDebris

final class DebrisAppTests: XCTestCase {
    func testSidebarItemsMatchSpecOrder() {
        XCTAssertEqual(
            SidebarItem.allCases.map(\.title),
            ["Home", "Results", "Duplicates", "Auto Clean", "History", "Settings"]
        )
    }
}
