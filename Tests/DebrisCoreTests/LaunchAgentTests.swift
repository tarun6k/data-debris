import XCTest
@testable import DebrisCore

/// Plist generation and the launchctl choreography, against a temp
/// LaunchAgents directory and a recorded fake launchctl — the real gui
/// domain is exercised in the Phase 6 live run.
final class LaunchAgentTests: XCTestCase {

    private final class FakeLaunchctl {
        var calls: [[String]] = []
        var status: Int32 = 0
        func run(_ args: [String]) -> Int32 {
            calls.append(args)
            return status
        }
    }

    private var agentsDir: URL!
    private var launchctl: FakeLaunchctl!

    override func setUpWithError() throws {
        agentsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("debris-agents-\(UUID().uuidString)", isDirectory: true)
        launchctl = FakeLaunchctl()
    }

    override func tearDownWithError() throws {
        if let agentsDir { try? FileManager.default.removeItem(at: agentsDir) }
        agentsDir = nil
        launchctl = nil
    }

    private func makeManager(programPath: String? = "/Applications/DataDebris.app/Contents/MacOS/DataDebris") -> LaunchAgentManager {
        LaunchAgentManager(agentsDirectory: agentsDir, programPath: programPath,
                           uid: 501, launchctl: launchctl.run)
    }

    private func loadPlist(_ label: String) throws -> [String: Any] {
        let data = try Data(contentsOf: agentsDir.appendingPathComponent(label + ".plist"))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    // MARK: - Calendar intervals

    func testCalendarIntervalPerFrequency() {
        let daily = AutoCleanSchedule(frequency: .daily, weekday: 4, hour: 3, minute: 30)
        XCTAssertEqual(LaunchAgentManager.calendarInterval(for: daily), ["Hour": 3, "Minute": 30])

        // Config weekday is Calendar's 1 = Sunday; launchd wants 0 = Sunday.
        let weekly = AutoCleanSchedule(frequency: .weekly, weekday: 1, hour: 3, minute: 0)
        XCTAssertEqual(LaunchAgentManager.calendarInterval(for: weekly),
                       ["Weekday": 0, "Hour": 3, "Minute": 0])

        let monthly = AutoCleanSchedule(frequency: .monthly, weekday: 1, hour: 22, minute: 15)
        XCTAssertEqual(LaunchAgentManager.calendarInterval(for: monthly),
                       ["Day": 1, "Hour": 22, "Minute": 15])
    }

    // MARK: - Install / uninstall round trip

    func testInstallWritesPlistsAndBootstrapsGuiDomain() throws {
        let manager = makeManager()
        try manager.install(
            schedule: AutoCleanSchedule(frequency: .weekly, weekday: 2, hour: 4, minute: 45),
            lowSpaceTrigger: true)

        let main = try loadPlist(LaunchAgentManager.label)
        XCTAssertEqual(main["Label"] as? String, LaunchAgentManager.label)
        XCTAssertEqual(main["ProgramArguments"] as? [String],
                       ["/Applications/DataDebris.app/Contents/MacOS/DataDebris",
                        "--auto-clean", "scheduled"])
        XCTAssertEqual(main["StartCalendarInterval"] as? [String: Int],
                       ["Weekday": 1, "Hour": 4, "Minute": 45])
        XCTAssertEqual(main["RunAtLoad"] as? Bool, false)

        let lowSpace = try loadPlist(LaunchAgentManager.lowSpaceLabel)
        XCTAssertEqual((lowSpace["ProgramArguments"] as? [String])?.last, "lowspace")
        XCTAssertEqual(lowSpace["StartInterval"] as? Int, 3600)

        // bootout-then-bootstrap per label, always in gui/<uid> (S8: no sudo,
        // no system domain).
        XCTAssertEqual(launchctl.calls.map { $0[0] },
                       ["bootout", "bootstrap", "bootout", "bootstrap"])
        for call in launchctl.calls {
            XCTAssertTrue(call[1].hasPrefix("gui/501"), "\(call) must stay in the user's gui domain")
        }
        XCTAssertEqual(launchctl.calls[1][2],
                       agentsDir.appendingPathComponent(LaunchAgentManager.label + ".plist").path)
    }

    func testUninstallBootsOutAndDeletesEverything() throws {
        let manager = makeManager()
        try manager.install(schedule: AutoCleanSchedule(), lowSpaceTrigger: true)
        try manager.installRetry(at: Date())
        launchctl.calls = []

        manager.uninstall()

        let labels = [LaunchAgentManager.label, LaunchAgentManager.lowSpaceLabel,
                      LaunchAgentManager.retryLabel]
        XCTAssertEqual(launchctl.calls,
                       labels.map { ["bootout", "gui/501/\($0)"] })
        for label in labels {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: agentsDir.appendingPathComponent(label + ".plist").path))
        }
    }

    func testInstallWithoutLowSpaceRemovesTheLowSpaceAgent() throws {
        let manager = makeManager()
        try manager.install(schedule: AutoCleanSchedule(), lowSpaceTrigger: true)
        try manager.install(schedule: AutoCleanSchedule(), lowSpaceTrigger: false)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: agentsDir.appendingPathComponent(LaunchAgentManager.lowSpaceLabel + ".plist").path))
    }

    // MARK: - Retry

    func testRetryPlistTargetsTheGivenMoment() throws {
        let manager = makeManager()
        let date = try XCTUnwrap(Calendar.current.date(
            from: DateComponents(year: 2026, month: 9, day: 14, hour: 18, minute: 5)))
        try manager.installRetry(at: date)
        let plist = try loadPlist(LaunchAgentManager.retryLabel)
        XCTAssertEqual(plist["StartCalendarInterval"] as? [String: Int],
                       ["Month": 9, "Day": 14, "Hour": 18, "Minute": 5])
        XCTAssertEqual((plist["ProgramArguments"] as? [String])?.last, "scheduled")

        manager.removeRetry()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: agentsDir.appendingPathComponent(LaunchAgentManager.retryLabel + ".plist").path))
    }

    // MARK: - Failure & repair

    func testBootstrapFailureThrows() {
        launchctl.status = 5
        XCTAssertThrowsError(
            try makeManager().install(schedule: AutoCleanSchedule(), lowSpaceTrigger: false)
        ) { error in
            XCTAssertEqual(error as? LaunchAgentError,
                           .bootstrapFailed(label: LaunchAgentManager.label, status: 5))
        }
    }

    func testRepairRewritesOnlyWhenTheBundleMoved() throws {
        try makeManager(programPath: "/old/DataDebris").install(
            schedule: AutoCleanSchedule(), lowSpaceTrigger: false)

        // Same path: nothing to do.
        launchctl.calls = []
        let samePlace = makeManager(programPath: "/old/DataDebris")
        try samePlace.repairIfMoved(schedule: AutoCleanSchedule(), lowSpaceTrigger: false)
        XCTAssertTrue(launchctl.calls.isEmpty)

        // Moved: the plist is rewritten with the new path.
        let moved = makeManager(programPath: "/new/DataDebris")
        try moved.repairIfMoved(schedule: AutoCleanSchedule(), lowSpaceTrigger: false)
        let plist = try loadPlist(LaunchAgentManager.label)
        XCTAssertEqual((plist["ProgramArguments"] as? [String])?.first, "/new/DataDebris")
    }
}
