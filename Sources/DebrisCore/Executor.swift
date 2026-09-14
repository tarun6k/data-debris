import Foundation

public struct ExecProgress: Sendable {
    public let itemsDone: Int
    public let itemsTotal: Int
    public let bytesMoved: Int64
    public let currentPath: String
}

public struct RunResult: Sendable {
    public let runId: Int64
    public let status: RunStatus
    /// Items moved to Trash plus items permanently removed.
    public let doneCount: Int
    public let skippedCount: Int
    /// Allocated bytes that left their original location (S10).
    public let movedBytes: Int64
    /// Measured free-space delta — near zero for Trash runs, which is honest:
    /// "moved to Trash" is not "freed" (S10).
    public let freedBytes: Int64
}

public struct RestoreFailure: Equatable, Sendable {
    public let itemId: Int64
    public let originalPath: String
    public let reason: SkipReason
}

public struct RestoreResult: Sendable {
    public let restoredCount: Int
    public let failures: [RestoreFailure]
}

public enum UndoAvailability: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case permanentDelete, trashEmptied, alreadyRestored, nothingMoved
    }
    case available
    case partiallyAvailable(Int, of: Int)
    case unavailable(Reason)
}

/// Executes a CleanPlan against the journal (product spec §8).
/// S4: the run and every item are durable rows before the first move.
/// S6: each item is re-verified (stat, open files, protection) at clean time.
public final class Executor: @unchecked Sendable {

    private let history: HistoryStore
    private let protectedPaths: ProtectedPaths
    private let exclusions: ExclusionStore?
    private let volumeToMeasure: URL

    /// Test hook: runs after the journal is durable, before any move. A throw
    /// aborts execute with the run still pending — the crash-window shape.
    var onJournaled: (() throws -> Void)?

    public init(
        history: HistoryStore,
        protectedPaths: ProtectedPaths = ProtectedPaths(),
        exclusions: ExclusionStore? = nil,
        volumeToMeasure: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.history = history
        self.protectedPaths = protectedPaths
        self.exclusions = exclusions
        self.volumeToMeasure = volumeToMeasure
    }

    // MARK: - Execute

    public func execute(
        plan: CleanPlan,
        progress: (@Sendable (ExecProgress) -> Void)? = nil
    ) async throws -> RunResult {
        let planItems = plan.items.filter {
            $0.ownerBundleId.map { !plan.skipBundleIds.contains($0) } ?? true
        }
        let freeBefore = freeSpace()
        let runId = try history.createRun(
            request: plan.request,
            estimatedBytes: plan.estimatedBytes,
            volumeFreeBefore: freeBefore,
            items: planItems)
        try onJournaled?()
        try history.setRunStatus(runId, .running)

        let journaled = try history.items(runId: runId)
        let requiresPermanent = Set(plan.itemsRequiringPermanent.map(\.originalPath))
        let total = journaled.count
        let state = ExecState()

        // Sequential within a volume, volumes in parallel.
        let byVolume = Dictionary(grouping: journaled, by: \.volumeUUID)
        await withTaskGroup(of: Void.self) { group in
            for volumeItems in byVolume.values {
                group.addTask { [self] in
                    for item in volumeItems {
                        if Task.isCancelled || state.failed { return }
                        let outcome = processItem(item, plan: plan, requiresPermanent: requiresPermanent)
                        do {
                            try history.markItem(
                                item.id, status: outcome.status, skipReason: outcome.skipReason,
                                trashURL: outcome.trashURL, movedAt: outcome.movedAt)
                        } catch {
                            // The file may already be in the Trash; stop before
                            // any further move outruns the journal (S4).
                            state.record(error)
                            return
                        }
                        let snapshot = state.advance(moved: outcome.movedAllocated)
                        progress?(ExecProgress(
                            itemsDone: snapshot.done, itemsTotal: total,
                            bytesMoved: snapshot.moved, currentPath: item.originalPath))
                    }
                }
            }
        }

        // Anything still pending was never reached: cancellation or a journal
        // write failure. Moved items stay done and restorable.
        let hadPending = try history.items(runId: runId).contains { $0.status == .pending }
        if hadPending {
            try history.skipRemainingPendingItems(runId: runId, reason: .cancelled)
        }

        let finalItems = try history.items(runId: runId)
        let doneCount = finalItems.filter { $0.status == .done || $0.status == .irreversible }.count
        let movedBytes = finalItems
            .filter { $0.status == .done || $0.status == .irreversible }
            .reduce(Int64(0)) { $0 + $1.allocatedSize }
        let freeAfter = freeSpace()
        let freedBytes = max(0, freeAfter - freeBefore)
        let status: RunStatus = hadPending ? .cancelled : .completed
        try history.finishRun(
            runId, status: status, movedBytes: movedBytes,
            freedBytes: freedBytes, volumeFreeAfter: freeAfter)

        if let error = state.firstError { throw error }
        return RunResult(
            runId: runId, status: status, doneCount: doneCount,
            skippedCount: finalItems.count - doneCount,
            movedBytes: movedBytes, freedBytes: freedBytes)
    }

    private struct Outcome {
        let status: ItemStatus
        var skipReason: SkipReason?
        var trashURL: String?
        var movedAt: Date?
        var movedAllocated: Int64 = 0

        static func skip(_ reason: SkipReason) -> Outcome {
            Outcome(status: .skipped, skipReason: reason)
        }
    }

    private func processItem(
        _ item: ItemRecord, plan: CleanPlan, requiresPermanent: Set<String>
    ) -> Outcome {
        let url = URL(fileURLWithPath: item.originalPath)

        // (a) Re-stat: gone or changed since the scan → hands off (S6).
        var st = stat()
        guard lstat(item.originalPath, &st) == 0 else { return .skip(.vanished) }
        let isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        if st.st_ino != item.inode || isDirectory != item.isDirectory { return .skip(.changed) }
        // Directory sizes are aggregates, only meaningful at scan time.
        if !item.isDirectory, Int64(st.st_size) != item.size { return .skip(.changed) }
        if abs(mtime - item.mtime) > 0.005 { return .skip(.changed) }

        // (b) Open-file check (S6).
        if let processName = processHoldingOpen(item.originalPath) {
            return .skip(.inUse(processName))
        }

        // (c) Protection and exclusion re-check (S1).
        if protectedPaths.isProtected(url) || (exclusions?.isExcluded(url) ?? false) {
            return .skip(.protected)
        }

        // (d) Move. Directories go as a unit — trashItem/removeItem both do.
        switch plan.request.disposal {
        case .trash:
            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                return Outcome(status: .done, trashURL: resulting?.path, movedAt: Date(),
                               movedAllocated: item.allocatedSize)
            } catch let error as CocoaError where error.code == .featureUnsupported {
                // No Trash on this volume. Fall through to permanent only if
                // the plan flagged the item AND the user approved it (S3).
                if requiresPermanent.contains(item.originalPath), plan.permanentApprovedForNoTrash {
                    return removePermanently(url, allocated: item.allocatedSize)
                }
                return .skip(.noTrash)
            } catch {
                return .skip(.moveFailed(error.localizedDescription))
            }
        case .permanent:
            return removePermanently(url, allocated: item.allocatedSize)
        }
    }

    private func removePermanently(_ url: URL, allocated: Int64) -> Outcome {
        do {
            try FileManager.default.removeItem(at: url)
            return Outcome(status: .irreversible, movedAt: Date(), movedAllocated: allocated)
        } catch {
            return .skip(.moveFailed(error.localizedDescription))
        }
    }

    /// Name of a process holding the path open, or nil if none.
    private func processHoldingOpen(_ path: String) -> String? {
        // ponytail: fixed 4096-pid buffer, one call per item (no recursion
        // into directories); enlarge or walk children if it ever misses.
        var pids = [pid_t](repeating: 0, count: 4096)
        // pathflags 2 = PROC_LISTPIDSPATH_EXCLUDE_EVTONLY: event-only fds
        // (FSEvents watchers) would flag half the disk as in use.
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, 2,
                              $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        guard let pid = pids[..<count].first(where: { $0 > 0 }) else { return nil }
        var name = [CChar](repeating: 0, count: 64)
        let length = proc_name(pid, &name, UInt32(name.count))
        return length > 0 ? String(cString: name) : "pid \(pid)"
    }

    private func freeSpace() -> Int64 {
        let values = try? volumeToMeasure.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: - Restore (S5)

    public func restore(runId: Int64) async throws -> RestoreResult {
        let itemIds = try history.items(runId: runId)
            .filter { $0.status == .done }
            .map(\.id)
        return try await restore(itemIds: itemIds)
    }

    public func restore(itemIds: [Int64]) async throws -> RestoreResult {
        var restoredCount = 0
        var failures: [RestoreFailure] = []
        var touchedRuns = Set<Int64>()

        for itemId in itemIds {
            guard let item = try history.item(itemId), item.status == .done else { continue }
            touchedRuns.insert(item.runId)
            switch restoreOne(item) {
            case .restored:
                try history.markItem(itemId, status: .restored)
                restoredCount += 1
            case .failed(let reason):
                // Still done in the journal; the reason marks why Undo
                // can't bring this one back.
                try history.markItem(itemId, status: .done, skipReason: reason)
                failures.append(RestoreFailure(
                    itemId: itemId, originalPath: item.originalPath, reason: reason))
            }
        }

        for runId in touchedRuns {
            let items = try history.items(runId: runId)
            guard items.contains(where: { $0.status == .restored }) else { continue }
            let anyDoneLeft = items.contains { $0.status == .done }
            try history.setRunStatus(runId, anyDoneLeft ? .partiallyRestored : .restored)
        }
        return RestoreResult(restoredCount: restoredCount, failures: failures)
    }

    private enum RestoreOutcome {
        case restored(String)
        case failed(SkipReason)
    }

    private func restoreOne(_ item: ItemRecord) -> RestoreOutcome {
        guard let trashPath = item.trashURL else { return .failed(.trashEmptied) }
        var st = stat()
        guard lstat(trashPath, &st) == 0, st.st_ino == item.inode else {
            return .failed(.trashEmptied)
        }
        if !item.isDirectory, Int64(st.st_size) != item.size { return .failed(.trashEmptied) }

        let destination = restoredDestination(for: item.originalPath)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: trashPath), to: destination)
            return .restored(destination.path)
        } catch {
            return .failed(.moveFailed(error.localizedDescription))
        }
    }

    /// Original path if free, otherwise "<name> (restored).<ext>" (S5),
    /// counting up if even that is taken.
    private func restoredDestination(for originalPath: String) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: originalPath) else {
            return URL(fileURLWithPath: originalPath)
        }
        let url = URL(fileURLWithPath: originalPath)
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var suffix = " (restored)"
        var counter = 1
        while true {
            let name = ext.isEmpty ? base + suffix : "\(base)\(suffix).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
            suffix = " (restored) \(counter)"
        }
    }
}

// MARK: - Undo availability (Done and History screens)

extension HistoryStore {
    public func undoAvailability(runId: Int64) throws -> UndoAvailability {
        let items = try items(runId: runId)
        let done = items.filter { $0.status == .done }
        if done.isEmpty {
            if items.contains(where: { $0.status == .restored }) { return .unavailable(.alreadyRestored) }
            if items.contains(where: { $0.status == .irreversible }) { return .unavailable(.permanentDelete) }
            return .unavailable(.nothingMoved)
        }
        let present = done.filter { item in
            item.trashURL.map { FileManager.default.fileExists(atPath: $0) } == true
        }.count
        if present == done.count { return .available }
        if present > 0 { return .partiallyAvailable(present, of: done.count) }
        return .unavailable(.trashEmptied)
    }
}

private final class ExecState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private var moved: Int64 = 0
    private var _firstError: Error?

    func advance(moved delta: Int64) -> (done: Int, moved: Int64) {
        lock.lock(); defer { lock.unlock() }
        done += 1
        moved += delta
        return (done, moved)
    }

    func record(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if _firstError == nil { _firstError = error }
    }

    var failed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _firstError != nil
    }

    var firstError: Error? {
        lock.lock(); defer { lock.unlock() }
        return _firstError
    }
}
