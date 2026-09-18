import XCTest
@testable import DebrisCore

/// APP_SUPPORT_OVERRIDE moves every on-disk location and suffixes every
/// system-visible name, and a debug route without it is refused.
final class AppPathsTests: XCTestCase {

    private var saved: String?

    override func setUp() {
        saved = getenv(AppPaths.overrideKey).map { String(cString: $0) }
    }

    override func tearDown() {
        if let saved { setenv(AppPaths.overrideKey, saved, 1) } else { unsetenv(AppPaths.overrideKey) }
    }

    func testWithoutOverrideEverythingIsTheRealProfile() throws {
        unsetenv(AppPaths.overrideKey)
        XCTAssertFalse(AppPaths.isOverridden)
        let support = try AppPaths.applicationSupportDirectory()
        XCTAssertTrue(support.path.hasSuffix("/Library/Application Support/DataDebris"), support.path)
        XCTAssertTrue(AppPaths.launchAgentsDirectory().path.hasSuffix("/Library/LaunchAgents"))
        XCTAssertEqual(AppPaths.keychainService, "com.tarunkumar.datadebris.license")
        XCTAssertEqual(AppPaths.launchAgentLabel, "com.tarunkumar.datadebris.autoclean")
        XCTAssertEqual(LaunchAgentManager.label, "com.tarunkumar.datadebris.autoclean")
        XCTAssertEqual(LaunchAgentManager.lowSpaceLabel, "com.tarunkumar.datadebris.autoclean.lowspace")
        XCTAssertEqual(KeychainSecretStore.service, "com.tarunkumar.datadebris.license")
        XCTAssertTrue(AppPaths.userDefaults === UserDefaults.standard)
    }

    func testOverrideRelocatesAndSuffixesEverything() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPathsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        setenv(AppPaths.overrideKey, scratch.path, 1)

        XCTAssertTrue(AppPaths.isOverridden)
        XCTAssertEqual(try AppPaths.applicationSupportDirectory().path, scratch.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path), "created on resolve")
        XCTAssertEqual(try FindingsStore.defaultDatabaseURL().path, scratch.path + "/findings.sqlite")
        XCTAssertEqual(try AutoCleanConfig.defaultFileURL().deletingLastPathComponent().path, scratch.path)
        XCTAssertEqual(AppPaths.launchAgentsDirectory().path, scratch.path + "/LaunchAgents")
        XCTAssertEqual(AppPaths.keychainService, "com.tarunkumar.datadebris.license.debug")
        XCTAssertEqual(KeychainSecretStore.service, "com.tarunkumar.datadebris.license.debug")
        XCTAssertEqual(LaunchAgentManager.label, "com.tarunkumar.datadebris.autoclean.debug")
        XCTAssertEqual(LaunchAgentManager.retryLabel, "com.tarunkumar.datadebris.autoclean.debug.retry")
        XCTAssertFalse(AppPaths.userDefaults === UserDefaults.standard)

        // A debug-profile agent carries the override to its headless run.
        let plist = LaunchAgentManager.plist(
            label: LaunchAgentManager.label, programPath: "/tmp/DataDebris",
            reason: .scheduled, trigger: [:])
        XCTAssertEqual(plist["EnvironmentVariables"] as? [String: String],
                       [AppPaths.overrideKey: scratch.path])
    }

    /// The predicate behind the Debug-build precondition: a --screen or
    /// --drive launch with no override is refused; anything else is fine.
    func testDebugRouteWithoutOverrideIsRefused() {
        let none: URL? = nil
        let some = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        XCTAssertTrue(AppPaths.unsandboxedDebugRoute(arguments: ["app", "--screen", "plan"], override: none))
        XCTAssertTrue(AppPaths.unsandboxedDebugRoute(arguments: ["app", "--drive-clean", "m"], override: none))
        XCTAssertTrue(AppPaths.unsandboxedDebugRoute(arguments: ["app", "--drive-autoclean", "status"], override: none))
        XCTAssertFalse(AppPaths.unsandboxedDebugRoute(arguments: ["app", "--screen", "plan"], override: some))
        XCTAssertFalse(AppPaths.unsandboxedDebugRoute(arguments: ["app"], override: none))
        XCTAssertFalse(AppPaths.unsandboxedDebugRoute(arguments: ["app", "--age-license"], override: none))
        XCTAssertFalse(AppPaths.unsandboxedDebugRoute(arguments: ["app", "--auto-clean", "scheduled"], override: none))
    }
}
