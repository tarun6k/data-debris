import DebrisCore
import Foundation

/// The worker calls the purchase flow needs — a seam so tests run against a
/// fake instead of the network.
protocol LicenseService {
    func byReference(_ reference: String) async throws -> String?
    func activate(key: String, machineId: String, machineName: String) async throws -> String
    func validate(key: String, machineId: String) async throws -> String
    func deactivate(key: String, machineId: String) async throws
    func recover(email: String) async throws
}

extension LicenseClient: LicenseService {}

/// One purchase attempt, from a locked action to its resumption. The order is
/// fixed: privacy sheet (unless already acknowledged for the current text
/// hash) → plan sheet → browser checkout → poll for the key → activate →
/// resume the original action. Cancel or Esc at any step changes nothing.
@MainActor
final class PurchaseFlow: ObservableObject, Identifiable {

    /// What to pick up again after activation, exactly where it was left.
    enum ResumeAction: Equatable {
        case openReview(CleanFlow.Entry)
        /// Re-runs the whole Smart Clean (selection is recomputed, then Review).
        case smartClean
        case enableAutoClean
        case runAutoCleanNow
        case none
    }

    enum Step: Equatable {
        case privacy
        case plan
        case waiting(shortReference: String)
        /// 409 from activate: the key is on 2 Macs already; offer Manage Macs.
        case activationLimit(key: String, machineIds: [String])
        case failed(message: String, retryKey: String?)
    }

    enum Outcome {
        case cancelled
        case activated(EntitlementPayload)
    }

    let id = UUID()
    let resume: ResumeAction

    @Published private(set) var step: Step
    /// OFF by default (spec); picks the recurring vs one-time price id.
    @Published var autoRenew = false

    private let service: LicenseService
    private let store: LicenseStore
    private var publicKey: Data { store.publicKey }
    private let machineId: String
    private let machineName: String
    private let pollInterval: TimeInterval
    private let launchCheckout: (LicensePlan, Bool, String) -> Void
    private let recordAcknowledgement: () -> Void
    private let onDone: (PurchaseFlow, Outcome) -> Void

    private var pollTask: Task<Void, Never>?
    private(set) var reference: String?
    private var finished = false

    init(resume: ResumeAction,
         acknowledged: Bool,
         service: LicenseService,
         store: LicenseStore,
         machineId: String = MachineIdentity.machineId(),
         machineName: String = MachineIdentity.machineName(),
         pollInterval: TimeInterval = 3,
         launchCheckout: @escaping (LicensePlan, Bool, String) -> Void,
         recordAcknowledgement: @escaping () -> Void,
         onDone: @escaping (PurchaseFlow, Outcome) -> Void) {
        self.resume = resume
        self.service = service
        self.store = store
        self.machineId = machineId
        self.machineName = machineName
        self.pollInterval = pollInterval
        self.launchCheckout = launchCheckout
        self.recordAcknowledgement = recordAcknowledgement
        self.onDone = onDone
        step = acknowledged ? .plan : .privacy
    }

    // MARK: - Steps

    /// Continue on the privacy sheet — only reachable once the view has
    /// verified scrolled-to-end AND the box is ticked.
    func acknowledgePrivacy() {
        guard step == .privacy else { return }
        recordAcknowledgement()
        step = .plan
    }

    /// "Get 1 Year" / "Get 3 Years": open the browser checkout and start
    /// polling the worker for the key the webhook will mint.
    func choosePlan(_ plan: LicensePlan) {
        guard step == .plan else { return }
        let ref = UUID().uuidString
        reference = ref
        launchCheckout(plan, autoRenew, ref)
        step = .waiting(shortReference: String(ref.prefix(8)))
        startPolling(reference: ref, immediateFirstCheck: false)
    }

    /// datadebris://checkout-success landed: check right now, not in 3 s.
    func checkoutCallbackReceived() {
        guard let ref = reference, case .waiting = step else { return }
        startPolling(reference: ref, immediateFirstCheck: true)
    }

    /// "Not now", Esc, or the waiting sheet's Cancel.
    func cancel() {
        finish(.cancelled)
    }

    /// LicenseEntrySheet ("Already have a license?") and the retry button.
    func enterKey(_ key: String) async {
        await activate(key: key)
    }

    func recoverKey(email: String) async {
        try? await service.recover(email: email)
    }

    /// Manage Macs: free the chosen slot, then retry the blocked activation.
    func deactivateMachine(key: String, machineId otherId: String) async {
        try? await service.deactivate(key: key, machineId: otherId)
        await activate(key: key)
    }

    // MARK: - Polling and activation

    private func startPolling(reference: String, immediateFirstCheck: Bool) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(15 * 60)
            var skipSleep = immediateFirstCheck
            while let self, !Task.isCancelled, Date() < deadline {
                if !skipSleep {
                    try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
                }
                skipSleep = false
                guard !Task.isCancelled else { return }
                // Network errors and 404 both mean "keep waiting".
                if let key = try? await self.service.byReference(reference) {
                    await self.activate(key: key)
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.step = .failed(
                message: "No completed checkout arrived. If you paid, use "
                    + "\u{201C}Already have a license?\u{201D} with the key from your email.",
                retryKey: nil)
        }
    }

    func activate(key: String) async {
        do {
            let entitlement = try await service.activate(
                key: key, machineId: machineId, machineName: machineName)
            try store.save(licenseKey: key, entitlement: entitlement, lastValidatedAt: Date())
            guard let (payload, _) = store.load() else { throw LicenseStoreError.badEntitlement }
            finish(.activated(payload))
        } catch LicenseClientError.activationLimit {
            // The entitlement from validate carries the two machine ids.
            let ids = (try? await service.validate(key: key, machineId: machineId))
                .flatMap { SignedEntitlement.verify($0, publicKey: publicKey)?.machines } ?? []
            step = .activationLimit(key: key, machineIds: ids)
        } catch LicenseClientError.unknownKey {
            step = .failed(message: "That key was not found. Check it against the email from your purchase.",
                           retryKey: nil)
        } catch LicenseClientError.inactive {
            step = .failed(message: "This key is no longer active (refunded or expired).",
                           retryKey: nil)
        } catch {
            step = .failed(message: "Could not reach the license service. Check your connection and retry.",
                           retryKey: key)
        }
    }

    func backToPlans() {
        pollTask?.cancel()
        step = .plan
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        pollTask?.cancel()
        onDone(self, outcome)
    }
}
