import XCTest
import GRDB
@testable import DebrisCore

final class DebrisCoreTests: XCTestCase {
    func testGRDBOpensInMemoryDatabase() throws {
        let queue = try DatabaseQueue()
        let one = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT 1")
        }
        XCTAssertEqual(one, 1)
    }
}
