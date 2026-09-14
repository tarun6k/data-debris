import AppKit
import Foundation
import os.log

public enum AutoCleanReason: String, Sendable {
    case scheduled
    case lowSpace = "lowspace"
    case manual
}

public enum AutoCleanDeferralReason: String, Codable, Equatable, Sendable {
    case onBattery, fullScreenApp, timeMachineBackup, volumeUnavailable, anotherRunActive

    public var displayText: String {
        switch self {
        case .onBattery: return "on battery power"
        case .fullScreenApp: return "an app was in full screen"
        case .timeMachineBackup: return "a Time Machine backup was running"
        case .volumeUnavailable: return "the volume was unavailable"
        case .anotherRunActive: return "another clean was already running"
        }
    }
}

public enum AutoCleanOutcome: Equatable, Sendable {
    /// gaveUp: 24 h of consecutive deferrals — a skipped note is in History
    /// and no further retry should be scheduled until the next regular run.
    case deferred(AutoCleanDeferralReason, gaveUp: Bool)
    case completed(runId: Int64, movedBytes: Int64, itemCount: Int)
    /// Low-space trigger fired but free space is above the threshold.
    case notNeeded
}

// MARK: - Preconditions (each injectable for tests)

public struct AutoCleanPreconditions: Sendable {
    public var onACPowerOrCharged: @Sendable () -> Bool
    public var noFullScreenApp: @Sendable () -> Bool
    public var noTimeMachineBackup: @Sendable () -> Bool
    public var volumeHealthy: @Sendable () -> Bool

    public init(
        onACPowerOrCharged: @escaping @Sendable () -> Bool = { Self.onACPowerOrBatteryAbove20() },
        noFullScreenApp: @escaping @Sendable () -> Bool = { !Self.frontmostIsFullScreenOrPresenting() },
        noTimeMachineBackup: @escaping @Sendable () -> Bool = { !Self.timeMachineIsRunning() },
        volumeHealthy: @escaping @Sendable () -> Bool = {
            Self.volumeIsHealthy(FileManager.default.homeDirectoryForCurrentUser)
        }
    ) {
        self.onACPowerOrCharged = onACPowerOrCharged
        self.noFullScreenApp = noFullScreenApp
        self.noTimeMachineBackup = noTimeMachineBackup
        self.volumeHealthy = volumeHealthy
    }

    public static let live = AutoCleanPreconditions()

    /// Reuses the duplicate finder's IOPS power check.
    public static func onACPowerOrBatteryAbove20() -> Bool {
        !PowerStatus.onBatteryBelow(percent: 20)
    }

    /// True when the frontmost app is showing a screen-sized window, or is a
    /// presentation/conferencing app that may be sharing the screen.
    /// ponytail: window-size == screen-size heuristic; window *names* would
    /// need Screen Recording permission, bounds do not.
    public static func frontmostIsFullScreenOrPresenting() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let presenters = ["com.apple.iWork.Keynote", "com.microsoft.Powerpoint", "us.zoom.xos"]
        if let bundleId = front.bundleIdentifier, presenters.contains(bundleId) { return true }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let screenSizes = NSScreen.screens.map(\.frame.size)
        for window in windows
        where window[kCGWindowOwnerPID as String] as? pid_t == front.processIdentifier {
            guard let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if screenSizes.contains(where: {
                abs($0.width - bounds.width) < 1 && abs($0.height - bounds.height) < 1
            }) { return true }
        }
        return false
    }

    public static func timeMachineIsRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["status"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return false } // no tmutil: no backup
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.contains("Running = 1")
    }

    public static func volumeIsHealthy(_ volume: URL) -> Bool {
        (try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity != nil
    }
}

// MARK: - Run lock

/// Cross-process "a clean is running" lock. flock is released by the kernel
/// when the process exits, so a crash can never wedge Auto Clean.
public final class RunLock {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    public static func defaultURL() throws -> URL {
        try FindingsStore.defaultDatabaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("run.lock")
    }

    /// nil when the lock is held elsewhere — or cannot even be opened, which
    /// is treated as "locked" because not running is the safe direction.
    public static func acquire(at url: URL) -> RunLock? {
        let fd = open(url.path, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return RunLock(fd: fd)
    }

    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

// MARK: - Runner

/// One unattended clean: preconditions → scan restricted to the ticked rules
/// → plan → journal → execute to Trash (S3). Never permanent, never Empty
/// Trash, never anything the user did not tick (S2, S9).
public final class AutoCleanRunner {

    /// Deferral bookkeeping across headless launches.
    struct State: Codable {
        var firstDeferralAt: Date?
    }

    private let config: AutoCleanConfig
    private let catalogue: Catalogue
    private let history: HistoryStore
    private let exclusions: ExclusionStore?
    private let preconditions: AutoCleanPreconditions
    private let scope: ScanScope
    private let home: URL
    private let protectedPaths: ProtectedPaths
    private let lockURL: URL
    private let stateURL: URL
    private let freeSpaceBytes: () -> Int64
    private let runningApplications: @Sendable () -> [RunningAppInfo]

    public init(
        config: AutoCleanConfig,
        catalogue: Catalogue,
        history: HistoryStore,
        exclusions: ExclusionStore? = nil,
        preconditions: AutoCleanPreconditions = .live,
        scope: ScanScope = ScanScope(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        protectedPaths: ProtectedPaths = ProtectedPaths(),
        lockURL: URL? = nil,
        stateURL: URL? = nil,
        freeSpaceBytes: (() -> Int64)? = nil,
        runningApplications: (@Sendable () -> [RunningAppInfo])? = nil
    ) throws {
        self.config = config.validated(against: catalogue)
        self.catalogue = catalogue
        self.history = history
        self.exclusions = exclusions
        self.preconditions = preconditions
        self.scope = scope
        self.home = home
        self.protectedPaths = protectedPaths
        self.lockURL = try lockURL ?? RunLock.defaultURL()
        self.stateURL = try stateURL ?? FindingsStore.defaultDatabaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("autoclean-state.json")
        self.freeSpaceBytes = freeSpaceBytes ?? { [home] in
            (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
        }
        self.runningApplications = runningApplications ?? {
            NSWorkspace.shared.runningApplications.compactMap { app in
                app.bundleIdentifier.map { RunningAppInfo(bundleId: $0, name: app.localizedName ?? $0) }
            }
        }
    }

    public func run(reason: AutoCleanReason, now: Date = Date()) async throws -> AutoCleanOutcome {
        // The low-space agent fires hourly; only act when actually low.
        if reason == .lowSpace {
            guard let triggerGB = config.lowSpaceTriggerGB,
                  freeSpaceBytes() < Int64(triggerGB) * 1_000_000_000
            else { return .notNeeded }
        }

        // Preconditions, in order; any failure defers without touching files.
        if !preconditions.onACPowerOrCharged() { return try deferred(.onBattery, now: now) }
        if !preconditions.noFullScreenApp() { return try deferred(.fullScreenApp, now: now) }
        if !preconditions.noTimeMachineBackup() { return try deferred(.timeMachineBackup, now: now) }
        if !preconditions.volumeHealthy() { return try deferred(.volumeUnavailable, now: now) }
        guard let lock = RunLock.acquire(at: lockURL) else {
            return try deferred(.anotherRunActive, now: now)
        }
        defer { lock.release() }

        let ruleIds = config.effectiveRuleIds(catalogue: catalogue)
        let selection = try await scanFindings(ruleIds: ruleIds)
            .filter { ruleIds.contains($0.ruleId) && $0.isReclaimable }

        var plan = Planner(runningApplications: runningApplications)
            .plan(selection: selection, request: .autoClean)
        // Unattended: items of running apps are skipped, never force-quit.
        plan.skipBundleIds = Set(plan.runningAppConflicts.map(\.bundleId))
        // permanentApprovedForNoTrash stays false: an item whose volume has no
        // Trash is skipped, not deleted (S3).
        let result = try await Executor(
            history: history,
            protectedPaths: protectedPaths,
            exclusions: exclusions,
            volumeToMeasure: home
        ).execute(plan: plan)

        try saveState(State()) // a completed run resets the deferral clock
        return .completed(runId: result.runId, movedBytes: result.movedBytes,
                          itemCount: result.doneCount)
    }

    // MARK: - Restricted scan

    /// Reuses the full scan pipeline with the catalogue cut down to the ticked
    /// rules (S1 still holds: only catalogue rules claim files) and hashing
    /// disabled — duplicates are never eligible. Findings land in a throwaway
    /// store so the app's own last-scan results are untouched.
    private func scanFindings(ruleIds: Set<String>) async throws -> [Finding] {
        guard !ruleIds.isEmpty else { return [] }
        let rules = catalogue.rules.filter { ruleIds.contains($0.id) }.map(adjusted)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoclean-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try FindingsStore(databaseURL: tempDir.appendingPathComponent("scan.sqlite"))
        let runner = ScanRunner(
            scope: scope,
            catalogue: Catalogue(version: catalogue.version, rules: rules),
            store: store,
            exclusions: exclusions,
            protectedPaths: protectedPaths,
            home: home)
        runner.skipDuplicates()
        let result = try await runner.run()
        return try store.findings(in: result.scanId)
    }

    /// Applies the developer-junk age sub-option by raising (never lowering)
    /// the rule's mtime floor.
    private func adjusted(_ rule: Rule) -> Rule {
        guard rule.category == .developer, let minDays = config.developerMinAgeDays else { return rule }
        var predicates = rule.predicates
        var raised = false
        predicates = predicates.map { predicate in
            if case .mtimeOlderThanDays(let days) = predicate {
                raised = true
                return .mtimeOlderThanDays(max(days, minDays))
            }
            return predicate
        }
        if !raised { predicates.append(.mtimeOlderThanDays(minDays)) }
        return Rule(
            id: rule.id, category: rule.category, level: rule.level, match: rule.match,
            unit: rule.unit, predicates: predicates, owner: rule.owner, reason: rule.reason,
            consequence: rule.consequence, autoCleanEligible: rule.autoCleanEligible)
    }

    // MARK: - Deferral bookkeeping

    private func deferred(_ reason: AutoCleanDeferralReason, now: Date) throws -> AutoCleanOutcome {
        var state = loadState()
        if let first = state.firstDeferralAt, now.timeIntervalSince(first) >= 24 * 3600 {
            // 24 h of consecutive deferrals: note it in History and give up
            // until the next scheduled run.
            try history.createSkippedAutoRun(
                note: "Skipped: \(reason.displayText)", at: now)
            state.firstDeferralAt = nil
            try saveState(state)
            return .deferred(reason, gaveUp: true)
        }
        if state.firstDeferralAt == nil {
            state.firstDeferralAt = now
            try saveState(state)
        }
        return .deferred(reason, gaveUp: false)
    }

    private func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data)
        else { return State() }
        return state
    }

    private func saveState(_ state: State) throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
}
