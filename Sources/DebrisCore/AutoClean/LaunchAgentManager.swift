import Foundation

public enum LaunchAgentError: Error, Equatable {
    case bootstrapFailed(label: String, status: Int32)
    case noProgramPath
}

/// Installs and removes the Auto Clean LaunchAgents in the user's gui domain
/// — plain launchctl as the current user, no daemon, no root, ever (S8).
public struct LaunchAgentManager {

    public static let label = "com.tarunkumar.datadebris.autoclean"
    public static let lowSpaceLabel = label + ".lowspace"
    public static let retryLabel = label + ".retry"

    private let agentsDirectory: URL
    private let programPath: String?
    private let uid: uid_t
    private let launchctl: ([String]) -> Int32

    public init(
        agentsDirectory: URL? = nil,
        programPath: String? = Bundle.main.executablePath,
        uid: uid_t = getuid(),
        launchctl: @escaping ([String]) -> Int32 = LaunchAgentManager.systemLaunchctl
    ) {
        self.agentsDirectory = agentsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.programPath = programPath
        self.uid = uid
        self.launchctl = launchctl
    }

    public static func systemLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    public func plistURL(_ label: String) -> URL {
        agentsDirectory.appendingPathComponent(label + ".plist")
    }

    // MARK: - Plist content

    /// launchd calendar dict. Weekday is launchd's 0 = Sunday, converted from
    /// the config's Calendar-style 1 = Sunday. Monthly runs on the 1st.
    static func calendarInterval(for schedule: AutoCleanSchedule) -> [String: Int] {
        var interval = ["Hour": schedule.hour, "Minute": schedule.minute]
        switch schedule.frequency {
        case .daily: break
        case .weekly: interval["Weekday"] = schedule.weekday - 1
        case .monthly: interval["Day"] = 1
        }
        return interval
    }

    static func plist(label: String, programPath: String, reason: AutoCleanReason,
                      trigger: [String: Any]) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [programPath, "--auto-clean", reason.rawValue],
            "RunAtLoad": false,
            "ProcessType": "Background",
        ]
        plist.merge(trigger) { current, _ in current }
        return plist
    }

    // MARK: - Install / uninstall

    /// Enabling the toggle or changing the schedule: (re)writes and
    /// (re)bootstraps the agents. The low-space agent polls hourly and the
    /// binary decides whether space is actually low.
    public func install(schedule: AutoCleanSchedule, lowSpaceTrigger: Bool) throws {
        try write(label: Self.label, reason: .scheduled,
                  trigger: ["StartCalendarInterval": Self.calendarInterval(for: schedule)])
        if lowSpaceTrigger {
            try write(label: Self.lowSpaceLabel, reason: .lowSpace,
                      trigger: ["StartInterval": 3600])
        } else {
            remove(label: Self.lowSpaceLabel)
        }
    }

    /// Disabling the toggle: every agent goes, including a pending retry.
    public func uninstall() {
        for label in [Self.label, Self.lowSpaceLabel, Self.retryLabel] {
            remove(label: label)
        }
    }

    /// One-shot retry after a deferral. The calendar entry would recur, but
    /// the next run always removes it (success and give-up both call
    /// removeRetry), so it fires at most once.
    public func installRetry(at date: Date) throws {
        let parts = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        try write(label: Self.retryLabel, reason: .scheduled, trigger: [
            "StartCalendarInterval": [
                "Month": parts.month ?? 1, "Day": parts.day ?? 1,
                "Hour": parts.hour ?? 0, "Minute": parts.minute ?? 0,
            ],
        ])
    }

    public func removeRetry() {
        remove(label: Self.retryLabel)
    }

    /// Call at launch while enabled: if the app bundle moved since the plist
    /// was written, the agent points at nothing — rewrite it.
    public func repairIfMoved(schedule: AutoCleanSchedule, lowSpaceTrigger: Bool) throws {
        guard let data = try? Data(contentsOf: plistURL(Self.label)),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String]
        else { return }
        if arguments.first != programPath {
            try install(schedule: schedule, lowSpaceTrigger: lowSpaceTrigger)
        }
    }

    // MARK: - Private

    private func write(label: String, reason: AutoCleanReason, trigger: [String: Any]) throws {
        guard let programPath else { throw LaunchAgentError.noProgramPath }
        try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        // Rewrites need the old definition gone first; "not loaded" is fine.
        _ = launchctl(["bootout", "gui/\(uid)/\(label)"])
        let data = try PropertyListSerialization.data(
            fromPropertyList: Self.plist(label: label, programPath: programPath,
                                         reason: reason, trigger: trigger),
            format: .xml, options: 0)
        try data.write(to: plistURL(label), options: .atomic)
        let status = launchctl(["bootstrap", "gui/\(uid)", plistURL(label).path])
        guard status == 0 else {
            throw LaunchAgentError.bootstrapFailed(label: label, status: status)
        }
    }

    private func remove(label: String) {
        _ = launchctl(["bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL(label))
    }
}
