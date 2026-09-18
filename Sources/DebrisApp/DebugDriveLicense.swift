import AppKit
import DebrisCore
import Foundation
import Security

#if DEBUG
/// Phase 7B live pass. Both routes go through the exact methods the buttons
/// call — openReview, acknowledgePrivacy, choosePlan, deactivateThisMac,
/// enterLicenseKey, setAutoCleanEnabled, Executor.restore — and print
/// timestamped `DRIVE hh:mm:ss:` lines. Nothing bypasses the entitlement
/// gate or the worker, and the license key never reaches stdout or argv.
///
/// `--drive-purchase <marker> [--drive-shots <dir>]`
///   Free → scan → select the <marker> findings → Review (the Free gate opens
///   the privacy sheet) → Continue → Get 1 Year with auto-renew off → browser
///   checkout. Stays alive until the flow finishes, reports the resumed
///   Review and runs the clean so History has a run to undo later.
///
/// `--drive-license <command> [--drive-shots <dir>] [--age-license]`
///   status                  entitlement, gate, Auto Clean, History
///   autoclean-on            Settings > Auto Clean toggle on
///   deactivate-reenter      Settings > Deactivate this Mac, then Enter the
///                           key again (read from the store in-process)
///   lapse-check:<marker>    History + Undo of the last run, then Review on
///                           the restored files (must hit the gate)
///   With --age-license the route first waits for the launch validate
///   round-trip so the printed state is the worker's, not the cache's.
extension AppModel {
    private static let driveClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func drive(_ line: String) {
        print("DRIVE \(Self.driveClock.string(from: Date())): \(line)")
        fflush(stdout) // the log is a file, not a tty
    }

    private func driveShotsDir(_ args: [String]) -> String? {
        args.firstIndex(of: "--drive-shots")
            .flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    private func driveShot(_ dir: String?, _ name: String, settle: UInt64 = 600_000_000) async {
        guard let dir else { return }
        try? await Task.sleep(nanoseconds: settle)
        let ok = Snapshot.capture(to: dir + "/" + name)
        drive("shot \(name) \(ok ? "written" : "FAILED")")
    }

    /// NSApp.terminate does not return while a sheet is up; the scratch
    /// profile has nothing pending to save.
    private func driveQuit() -> Never { exit(0) }

    /// Never prints a whole key.
    private func describe(_ step: PurchaseFlow.Step) -> String {
        switch step {
        case .privacy: return "privacy"
        case .plan: return "plan"
        case .waiting(let short): return "waiting(\(short))"
        case .activationLimit(let key, let machines):
            return "activationLimit(key …\(key.suffix(4)), machines \(machines.map(\.name)))"
        case .failed(let message, let retryKey):
            return "failed(\(message), retryKey: \(retryKey.map { "…" + $0.suffix(4) } ?? "none"))"
        }
    }

    private func describeState() -> String {
        "entitlement \(entitlementState) · require(.clean) \(entitlements.require(.clean))"
    }

    /// Reads the license item the way LicenseStore does, one stage at a time,
    /// so a failure names its stage: Keychain status, decode, or signature.
    private func driveKeychainDiagnostics() {
        let service = KeychainSecretStore.service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "license",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            drive("keychain \(service): SecItemCopyMatching status \(status)")
            return
        }
        guard let stored = try? JSONDecoder().decode(LicenseStore.Stored.self, from: data) else {
            drive("keychain \(service): \(data.count) bytes, Stored decode FAILED")
            return
        }
        let payload = SignedEntitlement.verify(stored.entitlement)
        drive("keychain \(service): \(data.count) bytes · key …\(stored.licenseKey.suffix(4))"
            + " · lastValidatedAt \(Self.driveClock.string(from: stored.lastValidatedAt))"
            + " · signature \(payload == nil ? "INVALID" : "valid")"
            + " · machines \(payload?.machines.map(\.name) ?? [])")
    }

    private func driveScanAndSelect(marker: String) async {
        drive("scanning")
        startScan()
        while isScanning { try? await Task.sleep(nanoseconds: 500_000_000) }
        deselectAll()
        let mine = findings.filter { $0.url.path.contains(marker) && $0.isReclaimable }
        setSelected(mine.map(\.id), true)
        drive("selected \(mine.count) findings · \(selectedBytes) bytes · marker \(marker)")
        sidebar = .results
    }

    /// With --age-license the launch housekeeping is already talking to the
    /// worker; wait for the stamp it writes so the state we print is fresh.
    private func driveAwaitValidate() async {
        guard CommandLine.arguments.contains("--age-license") else { return }
        let launched = Date()
        for _ in 0..<40 {
            if let stored = licenseStore.load()?.stored,
               stored.lastValidatedAt > launched.addingTimeInterval(-60) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        refreshEntitlement()
        let stamp = licenseStore.load()?.stored.lastValidatedAt
        drive("validate round-trip stamped \(stamp.map { Self.driveClock.string(from: $0) } ?? "never")")
    }

    // MARK: - --drive-purchase

    func applyPurchaseDriveIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--drive-purchase"),
              args.indices.contains(index + 1) else { return }
        let marker = args[index + 1]
        let shots = driveShotsDir(args)
        showWelcome = false

        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            drive("launch — \(describeState()) · privacyAcknowledged \(privacyAcknowledged)")
            await driveScanAndSelect(marker: marker)
            await driveShot(shots, "results.png", settle: 1_000_000_000)

            drive("click Review")
            openReview()
            if cleanFlow != nil {
                drive("FAILED — Review opened without the gate")
                driveQuit()
            }
            guard let flow = purchase else {
                drive("FAILED — no purchase flow (toast: \(licenseToast ?? "none"))")
                driveQuit()
            }
            drive("purchase step \(describe(flow.step)) · resume \(flow.resume)")
            await driveShot(shots, "privacy-sheet.png", settle: 1_500_000_000)

            drive("Continue — acknowledgePrivacy (the sheet enables it only after scroll-to-end and the tick)")
            flow.acknowledgePrivacy()
            drive("purchase step \(describe(flow.step)) · privacyAcknowledged \(privacyAcknowledged)")
            await driveShot(shots, "choose-plan.png", settle: 1_000_000_000)

            flow.autoRenew = false
            drive("Get 1 Year · autoRenew \(flow.autoRenew)")
            flow.choosePlan(.oneYear)
            drive("purchase step \(describe(flow.step)) · reference \(flow.reference ?? "-") · checkout page handed to the default browser")
            await driveShot(shots, "waiting.png", settle: 1_500_000_000)

            var last = describe(flow.step)
            while purchase === flow {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let now = describe(flow.step)
                if now != last {
                    drive("purchase step \(now)")
                    last = now
                }
            }
            drive("purchase finished — \(describeState())")
            drive("toast: \(licenseToast ?? "none")")
            await driveShot(shots, "activated.png", settle: 1_000_000_000)

            guard let review = cleanFlow else {
                drive("FAILED — Review did not reopen")
                driveQuit()
            }
            drive("Review reopened — \(review.plan.items.count) items · \(review.plan.estimatedBytes) bytes · stage \(review.stage)")
            await driveShot(shots, "review-resumed.png", settle: 1_000_000_000)

            drive("Clean — startClean, so History has a run")
            review.startClean()
            while review.stage == .cleaning { try? await Task.sleep(nanoseconds: 50_000_000) }
            if let result = review.result {
                drive("clean done — status \(result.status) · moved \(result.movedBytes) · run \(result.runId)")
            } else {
                drive("FAILED — clean produced no result (\(review.runError ?? "unknown"))")
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await driveShot(shots, "done.png")
            cleanFlow = nil
            drive("complete")
            try? await Task.sleep(nanoseconds: 300_000_000)
            driveQuit()
        }
    }

    // MARK: - --drive-license

    func applyLicenseDriveIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--drive-license"),
              args.indices.contains(index + 1) else { return }
        let command = args[index + 1]
        let shots = driveShotsDir(args)
        showWelcome = false

        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await driveAwaitValidate()
            driveKeychainDiagnostics()
            drive("launch — \(describeState()) · autoClean enabled \(autoCleanConfig.enabled)")
            sidebar = .home
            await driveShot(shots, "home.png", settle: 1_000_000_000)

            if command == "autoclean-on" {
                drive("Settings > Auto Clean toggle on — setAutoCleanEnabled(true)")
                setAutoCleanEnabled(true)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                drive("autoClean enabled \(autoCleanConfig.enabled) · purchase sheet \(purchase.map { describe($0.step) } ?? "none")")
            } else if command == "deactivate-reenter" {
                guard let (_, stored) = licenseStore.load() else {
                    drive("FAILED — no stored license")
                    driveQuit()
                }
                let key = stored.licenseKey // stays in-process
                drive("Settings > License > Deactivate this Mac — deactivateThisMac (key …\(key.suffix(4)))")
                await deactivateThisMac()
                drive("toast: \(licenseToast ?? "none")")
                drive("\(describeState()) · stored license \(licenseStore.load() == nil ? "cleared" : "STILL PRESENT")")
                await driveShot(shots, "deactivated.png", settle: 1_000_000_000)

                drive("Settings > License > Enter a different key — enterLicenseKey")
                await enterLicenseKey(key)
                drive("toast: \(licenseToast ?? "none")")
                drive(describeState())
                await driveShot(shots, "reactivated.png", settle: 1_000_000_000)
                driveKeychainDiagnostics()
            } else if command.hasPrefix("lapse-check:") {
                let marker = String(command.dropFirst("lapse-check:".count))
                let runs = (try? history.runs()) ?? []
                drive("History: \(runs.count) runs")
                sidebar = .history
                await driveShot(shots, "history.png", settle: 1_200_000_000)
                guard let lastRun = runs.max(by: { $0.startedAt < $1.startedAt }) else {
                    drive("FAILED — no run to undo")
                    driveQuit()
                }
                drive("last run \(lastRun.id) · status \(lastRun.status) · moved \(lastRun.movedBytes)")
                drive("History > Undo — Executor.restore(runId:)")
                let restored = try? await Executor(history: history).restore(runId: lastRun.id)
                cleanDidFinish()
                let after = try? history.run(lastRun.id)
                drive("restored \(restored?.restoredCount ?? -1) items · failures \(restored?.failures.count ?? -1) · run status now \(after.map { "\($0.status)" } ?? "unknown")")
                await driveShot(shots, "history-undone.png", settle: 1_200_000_000)

                await driveScanAndSelect(marker: marker)
                drive("click Review")
                openReview()
                let locked = cleanFlow == nil && purchase != nil
                drive("Review opened \(cleanFlow != nil) · purchase sheet \(purchase.map { describe($0.step) } ?? "none") — Clean is \(locked ? "LOCKED" : "NOT LOCKED")")
                await driveShot(shots, "review-attempt.png", settle: 1_200_000_000)
                purchase?.cancel()
            } else if command == "keychain-probe" {
                let probe = KeychainSecretStore(account: "probe")
                do {
                    try probe.write(Data("probe \(Date())".utf8))
                    drive("probe write ok")
                } catch {
                    drive("probe write FAILED \(error)")
                }
                drive("probe read \(probe.read().map { "\($0.count) bytes" } ?? "nil")")
                probe.delete()
                drive("probe read after delete \(probe.read().map { "\($0.count) bytes" } ?? "nil")")
            } else if command != "status" {
                drive("FAILED — unknown command \(command)")
            }
            drive("complete")
            try? await Task.sleep(nanoseconds: 300_000_000)
            driveQuit()
        }
    }
}
#endif
