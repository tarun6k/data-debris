import AppKit
import DebrisCore
import UserNotifications

extension Notification.Name {
    /// Posted (distributed) by a headless auto-clean process so an already
    /// running GUI instance refreshes Home and History.
    static let debrisAutoCleanDidRun = Notification.Name("com.tarunkumar.datadebris.autoCleanDidRun")
}

/// The post-run notification: "Auto Clean · 1.9 GB moved to Trash · 402
/// items" with Undo (valid 24 h) and Open History. Deferred runs never
/// notify — there is nothing to report and nothing to undo.
enum AutoCleanNotifier {
    static let categoryId = "AUTO_CLEAN_RUN"
    static let undoActionId = "AUTO_CLEAN_UNDO"
    static let openHistoryActionId = "AUTO_CLEAN_OPEN_HISTORY"

    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryId,
            actions: [
                // No .foreground: Undo restores without dragging the user
                // into the app.
                UNNotificationAction(identifier: undoActionId, title: "Undo", options: []),
                UNNotificationAction(identifier: openHistoryActionId, title: "Open History",
                                     options: [.foreground]),
            ],
            intentIdentifiers: [], options: [])
    }

    /// nil when the notify setting suppresses it.
    static func content(
        runId: Int64, movedBytes: Int64, itemCount: Int, notify: AutoCleanNotify
    ) -> UNMutableNotificationContent? {
        switch notify {
        case .never: return nil
        case .overOneGB: guard movedBytes > 1_000_000_000 else { return nil }
        case .always: break
        }
        let content = UNMutableNotificationContent()
        content.title = "Auto Clean"
        content.body = "\(Format.bytes(movedBytes)) moved to Trash · "
            + "\(Format.count(itemCount)) \(itemCount == 1 ? "item" : "items")"
        content.categoryIdentifier = categoryId
        content.userInfo = ["runId": runId]
        return content
    }

    static func post(runId: Int64, movedBytes: Int64, itemCount: Int, notify: AutoCleanNotify) async {
        guard let content = content(runId: runId, movedBytes: movedBytes,
                                    itemCount: itemCount, notify: notify) else { return }
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        try? await center.add(UNNotificationRequest(
            identifier: "autoclean-run-\(runId)", content: content, trigger: nil))
    }

    /// Asked once, when the user first enables Auto Clean (the confirmation
    /// sheet explains why).
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }
}

/// Receives notification taps and action buttons — in the GUI instance,
/// including when the click itself launched the app.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    /// Attached once the window exists; nil until then (Undo still works via
    /// its own HistoryStore, navigation is a no-op).
    @MainActor weak var model: AppModel?

    /// Idempotent and model-free, so it is safe from App.init, which can run
    /// more than once. The delegate must be set at launch: a notification
    /// click can be the reason the app is running at all.
    func installEarly() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([AutoCleanNotifier.category])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier
        let runId = (response.notification.request.content.userInfo["runId"] as? NSNumber)?.int64Value
        Task { @MainActor in
            await self.handle(actionId: actionId, runId: runId)
            completionHandler()
        }
    }

    /// Auto Clean runs while the app may be frontmost ("Run now"): still show
    /// the banner.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    @MainActor
    func handle(actionId: String, runId: Int64?) async {
        if actionId == AutoCleanNotifier.undoActionId, let runId,
           let history = try? historyStore(),
           let run = try? history.run(runId), let finished = run.finishedAt,
           Date().timeIntervalSince(finished) <= 24 * 3600 {
            _ = try? await Executor(history: history).restore(runId: runId)
            model?.cleanDidFinish()
            return
        }
        // Open History: the explicit button, a plain tap, and an expired Undo
        // all land the user where the run (and Restore) lives.
        NSApp.activate(ignoringOtherApps: true)
        model?.sidebar = .history
    }

    @MainActor
    private func historyStore() throws -> HistoryStore {
        if let model { return model.history }
        return try HistoryStore()
    }
}
