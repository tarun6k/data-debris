import XCTest
@testable import DataDebris

final class AppInfoTests: XCTestCase {

    /// Settings shows "Beta" next to any 0.x version and nothing from 1.0 on.
    func testBetaLabelFollowsTheMarketingVersion() {
        XCTAssertTrue(AppInfo.isBeta("0.9.0"))
        XCTAssertTrue(AppInfo.isBeta("0.10"))
        XCTAssertFalse(AppInfo.isBeta("1.0"))
        XCTAssertFalse(AppInfo.isBeta("10.0"))
        XCTAssertFalse(AppInfo.isBeta("dev"))
    }

    /// The hosted test app carries the real Info.plist, so the version comes
    /// from MARKETING_VERSION and the Beta flag follows it.
    func testBundleVersionDrivesTheBetaFlag() {
        XCTAssertNotEqual(AppInfo.version, "dev")
        XCTAssertEqual(AppInfo.isBeta, AppInfo.version.hasPrefix("0"))
        XCTAssertEqual(AppInfo.versionString, "\(AppInfo.version) (\(AppInfo.build))")
    }
}
