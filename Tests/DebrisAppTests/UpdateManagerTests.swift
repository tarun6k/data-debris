import XCTest
@testable import DataDebris

@MainActor
final class UpdateManagerTests: XCTestCase {
    func testPlaceholderKeyLeavesTheUpdaterOff() {
        XCTAssertFalse(UpdateManager.hasUsableKey(nil))
        XCTAssertFalse(UpdateManager.hasUsableKey(""))
        XCTAssertFalse(UpdateManager.hasUsableKey(UpdateManager.publicKeyPlaceholder))
        XCTAssertFalse(UpdateManager.hasUsableKey("bm90IGEga2V5"), "wrong length")
        XCTAssertTrue(UpdateManager.hasUsableKey(Data(repeating: 7, count: 32).base64EncodedString()))
    }

    @MainActor
    func testThisBuildShipsThePlaceholderAndStaysOff() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        XCTAssertEqual(key, UpdateManager.publicKeyPlaceholder, "8B replaces this with the real key")
        let manager = UpdateManager(config: AppConfig.current, start: false)
        XCTAssertFalse(manager.canCheck)
        XCTAssertNotNil(manager.unavailableReason)
        XCTAssertEqual(manager.feedURL, AppConfig.current.updateFeedURL)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool, true)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUScheduledCheckInterval") as? Int, 86_400)
    }

    func testAcknowledgementsAreBundled() {
        for item in Acknowledgement.all {
            XCTAssertTrue(item.licenseText.contains("Copyright"), item.name)
        }
    }
}
