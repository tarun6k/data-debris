import Combine
import Foundation

public struct ScanProgress: Sendable {
    public let currentPath: String
    public let recordCount: Int
    public let findingCount: Int
    public let bytesFound: Int64
    public let deniedCount: Int
}

public struct ScanResult: Sendable {
    public let scanId: Int64
    public let status: ScanStatus
    public let recordCount: Int
    public let findingCount: Int
    /// Allocated bytes of reclaimable findings (S10).
    public let bytesFound: Int64
    public let deniedCount: Int
    public let trashBytes: Int64
    public let trashCount: Int
    public let duration: TimeInterval
    /// nil when hashing was skipped (user, cancellation) — not when the scan
    /// simply found no duplicates.
    public let duplicates: DuplicateScanSummary?
}

/// Drives one scan: Scanner → analyzers → FindingsStore, in a single
/// consumer loop. Cancellation is not an error; the partial scan is
/// finished with status `.cancelled` and its findings stay valid.
public final class ScanRunner: @unchecked Sendable {

    private let scope: ScanScope
    private let catalogue: Catalogue
    private let store: FindingsStore
    private let exclusions: ExclusionStore?
    private let protectedPaths: ProtectedPaths
    private let home: URL

    private let skipLock = NSLock()
    private var skipDup = false
    private var shouldSkipDuplicates: Bool {
        skipLock.lock(); defer { skipLock.unlock() }
        return skipDup
    }

    /// "Skip duplicates" on the Scanning screen: hashing stops (or never
    /// starts), the rest of the scan is unaffected.
    public func skipDuplicates() {
        skipLock.lock(); skipDup = true; skipLock.unlock()
    }

    public init(
        scope: ScanScope,
        catalogue: Catalogue,
        store: FindingsStore,
        exclusions: ExclusionStore? = nil,
        protectedPaths: ProtectedPaths = ProtectedPaths(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.scope = scope
        self.catalogue = catalogue
        self.store = store
        self.exclusions = exclusions
        self.protectedPaths = protectedPaths
        self.home = home.standardizedFileURL
    }

    public func run(
        now: Date = Date(),
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil,
        onDuplicateProgress: (@Sendable (DuplicateProgress) -> Void)? = nil
    ) async throws -> ScanResult {
        let started = Date()
        let scanId = try store.beginScan(startedAt: started)

        let matcher = RuleMatcher(catalogue: catalogue, protectedPaths: protectedPaths, home: home)
        let ruleAnalyzer = RuleAnalyzer(catalogue: catalogue, matcher: matcher, home: home)
        let largeOld = LargeOldAnalyzer(thresholds: scope.thresholds, catalogue: catalogue)
        let trash = TrashAnalyzer(home: home)
        let finder = DuplicateFinder(thresholds: scope.thresholds, home: home, cache: store)
        let scanner = Scanner(
            scope: scope,
            protectedPaths: protectedPaths,
            home: home,
            isExcluded: { [exclusions] in exclusions?.isExcluded($0) ?? false })

        var batch: [Finding] = []
        var recordCount = 0
        var findingCount = 0
        var bytesFound: Int64 = 0
        var currentPath = ""
        var cancelled = false

        func take(_ findings: [Finding]) {
            for finding in findings where !(exclusions?.excludesOwner(finding.ownerBundleId) ?? false) {
                batch.append(finding)
                findingCount += 1
                if finding.isReclaimable { bytesFound += finding.allocatedSize }
            }
        }
        func flush() throws {
            try store.upsert(batch, scanId: scanId)
            batch.removeAll(keepingCapacity: true)
        }

        do {
            for try await record in scanner.records() {
                try Task.checkCancellation()
                recordCount += 1
                currentPath = record.url.path
                trash.observe(record)
                finder.observe(record)
                let (findings, claimed) = ruleAnalyzer.process(record, now: now)
                take(findings)
                if !claimed, let large = largeOld.process(record, now: now) {
                    take([large])
                }
                // Periodic flush so the UI's live category totals fill in.
                if batch.count >= 500 || (!batch.isEmpty && recordCount % 2000 == 0) { try flush() }
                if !findings.isEmpty || recordCount % 100 == 0 {
                    onProgress?(ScanProgress(
                        currentPath: currentPath, recordCount: recordCount,
                        findingCount: findingCount, bytesFound: bytesFound,
                        deniedCount: scanner.deniedCount))
                }
            }
            // A cancelled iterating task can also end the stream with nil
            // instead of throwing.
            if Task.isCancelled {
                cancelled = true
            } else {
                take(ruleAnalyzer.finish())
            }
        } catch is CancellationError {
            // Open directory aggregation is dropped: its size would be
            // incomplete, and under-reporting is the safe direction.
            cancelled = true
        }

        // Hashing runs last (§Screen 2): the walk is done, so throttled I/O
        // only delays the duplicates category.
        var duplicates: DuplicateScanSummary?
        if !cancelled, !shouldSkipDuplicates {
            do {
                let summary = try await finder.findGroups(
                    shouldAbort: { [weak self] in Task.isCancelled || self?.shouldSkipDuplicates == true },
                    onProgress: onDuplicateProgress)
                for group in summary.groups { take(group.findings(home: home)) }
                try store.saveDuplicates(summary.groups, clonePairs: summary.clonePairsIgnored,
                                         status: "done", scanId: scanId)
                duplicates = summary
            } catch is CancellationError {
                // Skipped mid-hash: partial groups would under- or over-count,
                // so none are reported.
            }
        }
        if duplicates == nil {
            try store.saveDuplicates([], clonePairs: 0, status: "skipped", scanId: scanId)
        }

        try flush()
        let denied = scanner.deniedCount
        let status: ScanStatus = cancelled ? .cancelled : (denied > 0 ? .partial : .complete)
        try store.finishScan(scanId, status: status, deniedCount: denied)

        return ScanResult(
            scanId: scanId,
            status: status,
            recordCount: recordCount,
            findingCount: findingCount,
            bytesFound: bytesFound,
            deniedCount: denied,
            trashBytes: trash.totalAllocated,
            trashCount: trash.count,
            duration: Date().timeIntervalSince(started),
            duplicates: duplicates)
    }
}

/// Observable wrapper for the later UI. ObservableObject, not @Observable:
/// the deployment target is macOS 13 and Observation needs 14.
@MainActor
public final class ScanSession: ObservableObject {

    public enum CategoryProgress: Equatable, Sendable {
        case queued, running, done
    }

    public enum DuplicatePhase: Equatable, Sendable {
        case queued, hashing, done, skipped
    }

    @Published public private(set) var categoryProgress: [Category: CategoryProgress]
    @Published public private(set) var bytesFound: Int64 = 0
    @Published public private(set) var recordCount = 0
    @Published public private(set) var currentPath = ""
    @Published public private(set) var deniedCount = 0
    @Published public private(set) var isScanning = false
    @Published public private(set) var lastResult: ScanResult?
    @Published public private(set) var dupPhase: DuplicatePhase = .queued
    @Published public private(set) var dupProgress: DuplicateProgress?

    private var task: Task<Void, Never>?
    private var runner: ScanRunner?

    public init() {
        categoryProgress = Dictionary(uniqueKeysWithValues: Category.allCases.map { ($0, .queued) })
    }

    public func start(_ runner: ScanRunner) {
        guard !isScanning else { return }
        isScanning = true
        self.runner = runner
        dupPhase = .queued
        dupProgress = nil
        // ponytail: one pass feeds every analyzer, so all categories run and
        // finish together; per-category phases if scanning ever gets stages.
        setAll(.running)
        task = Task {
            let result = try? await runner.run(
                onProgress: { progress in
                    guard progress.recordCount % 100 == 0 || progress.findingCount % 25 == 0 else { return }
                    Task { @MainActor in self.apply(progress) }
                },
                onDuplicateProgress: { progress in
                    guard progress.filesHashed % 5 == 0 || progress.filesHashed < 5 else { return }
                    Task { @MainActor in
                        self.dupPhase = .hashing
                        self.dupProgress = progress
                    }
                })
            lastResult = result
            deniedCount = result?.deniedCount ?? deniedCount
            bytesFound = result?.bytesFound ?? bytesFound
            dupPhase = result?.duplicates == nil ? .skipped : .done
            setAll(.done)
            isScanning = false
        }
    }

    public func cancel() {
        task?.cancel()
    }

    /// Stops hashing (or keeps it from starting); the walk continues.
    public func skipDuplicates() {
        runner?.skipDuplicates()
        dupPhase = .skipped
    }

    private func apply(_ progress: ScanProgress) {
        currentPath = progress.currentPath
        recordCount = progress.recordCount
        bytesFound = progress.bytesFound
        deniedCount = progress.deniedCount
    }

    private func setAll(_ state: CategoryProgress) {
        for category in Category.allCases { categoryProgress[category] = state }
    }
}
