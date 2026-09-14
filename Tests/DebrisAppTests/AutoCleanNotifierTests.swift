import XCTest
import DebrisCore
@testable import DataDebris

/// The pure parts of the Auto Clean notification: content text, the notify
/// setting, the Undo/Open History category, and the headless-arg parsing.
/// Actual delivery is exercised in the Phase 6 live run.
final class AutoCleanNotifierTests: XCTestCase {

    func testContentTextAndUndoAction() throws {
        let content = try XCTUnwrap(AutoCleanNotifier.content(
            runId: 7, movedBytes: 1_900_000_000, itemCount: 402, notify: .always))
        XCTAssertEqual(content.title, "Auto Clean")
        XCTAssertEqual(content.body, "1.9 GB moved to Trash · 402 items")
        XCTAssertEqual(content.categoryIdentifier, AutoCleanNotifier.categoryId)
        XCTAssertEqual((content.userInfo["runId"] as? NSNumber)?.int64Value, 7)

        let actions = AutoCleanNotifier.category.actions
        XCTAssertEqual(actions.map(\.identifier),
                       [AutoCleanNotifier.undoActionId, AutoCleanNotifier.openHistoryActionId])
        XCTAssertEqual(actions.first?.title, "Undo")
        XCTAssertFalse(actions[0].options.contains(.foreground)) // Undo stays in place
        XCTAssertTrue(actions[1].options.contains(.foreground))  // Open History opens the app
    }

    func testSingleItemUsesSingular() throws {
        let content = try XCTUnwrap(AutoCleanNotifier.content(
            runId: 1, movedBytes: 512_000, itemCount: 1, notify: .always))
        XCTAssertTrue(content.body.hasSuffix("1 item"))
    }

    func testNotifySettingSuppresses() {
        XCTAssertNil(AutoCleanNotifier.content(
            runId: 1, movedBytes: 5_000_000_000, itemCount: 9, notify: .never))
        XCTAssertNil(AutoCleanNotifier.content(
            runId: 1, movedBytes: 900_000_000, itemCount: 9, notify: .overOneGB))
        XCTAssertNotNil(AutoCleanNotifier.content(
            runId: 1, movedBytes: 1_100_000_000, itemCount: 9, notify: .overOneGB))
    }

    func testHeadlessArgumentParsing() {
        let bin = "/Applications/DataDebris.app/Contents/MacOS/DataDebris"
        XCTAssertEqual(Main.autoCleanReason([bin, "--auto-clean", "scheduled"]), .scheduled)
        XCTAssertEqual(Main.autoCleanReason([bin, "--auto-clean", "lowspace"]), .lowSpace)
        XCTAssertEqual(Main.autoCleanReason([bin, "--auto-clean", "manual"]), .manual)
        XCTAssertNil(Main.autoCleanReason([bin]))
        XCTAssertNil(Main.autoCleanReason([bin, "--auto-clean"]))
        XCTAssertNil(Main.autoCleanReason([bin, "--auto-clean", "nonsense"]))
    }
}
