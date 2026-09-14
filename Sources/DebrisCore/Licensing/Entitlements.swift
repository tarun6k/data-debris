import Foundation

/// The single authority the app asks before any locked action: Review's Clean
/// button, Smart Clean (window and menu bar), the Auto Clean toggle and
/// Duplicates review all call require(_:). Free is the default; only a
/// signature-verified, recently validated entitlement unlocks anything.
public final class Entitlements {

    private let store: LicenseStore
    private let now: () -> Date

    public init(store: LicenseStore = LicenseStore(), now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    public var state: EntitlementState {
        guard let (payload, stored) = store.load() else { return .free }
        return EntitlementState.derive(payload: payload,
                                       lastValidatedAt: stored.lastValidatedAt, now: now())
    }

    public func require(_ feature: LockedFeature) -> GateResult {
        state.isEntitled ? .allowed : .needsPurchase
    }

    /// At most one service round-trip per 24 h (launch and wake both call
    /// this). Network failure changes nothing — the cached entitlement keeps
    /// working until the 30-day offline grace runs out. A definitive "no"
    /// from the service (refunded or key gone) clears the cache to Free.
    public func validateIfNeeded(
        machineId: String,
        using validate: (_ key: String, _ machineId: String) async throws -> String
    ) async {
        guard let (_, stored) = store.load(),
              now().timeIntervalSince(stored.lastValidatedAt) > EntitlementState.validateInterval
        else { return }
        do {
            let entitlement = try await validate(stored.licenseKey, machineId)
            try store.save(licenseKey: stored.licenseKey, entitlement: entitlement,
                           lastValidatedAt: now())
        } catch LicenseClientError.inactive, LicenseClientError.unknownKey {
            store.clear()
        } catch {
            // Offline or a server hiccup: EntitlementState.derive handles it.
        }
    }

    /// Lapsed, refunded or past due must also stop the LaunchAgents (S2 — no
    /// unpaid background cleaning). The config keeps enabled=true so a renewal
    /// puts the agents back without the user re-ticking anything.
    public func reconcileAutoCleanAgent(config: AutoCleanConfig, agents: LaunchAgentManager) {
        guard config.enabled else { return }
        let installed = FileManager.default.fileExists(
            atPath: agents.plistURL(LaunchAgentManager.label).path)
        if state.isEntitled {
            if !installed {
                try? agents.install(schedule: config.schedule,
                                    lowSpaceTrigger: config.lowSpaceTriggerGB != nil)
            }
        } else if installed {
            agents.uninstall()
        }
    }
}
