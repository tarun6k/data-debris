import AppKit
import Foundation

enum FullDiskAccess {
    /// FDA is detectable only by trying: ~/Library/Safari is unreadable
    /// without it.
    static var granted: Bool {
        (try? FileManager.default.contentsOfDirectory(
            atPath: NSHomeDirectory() + "/Library/Safari")) != nil
    }

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}

/// TCC ties Full Disk Access to the app's location; running from Downloads
/// and moving later resets the grant. So we offer the move before asking.
enum MoveToApplications {
    static let pendingRemovalKey = "pendingOldCopyRemoval"

    /// False for /Applications installs and for Xcode/debug builds.
    static var shouldOffer: Bool {
        let path = Bundle.main.bundleURL.path
        guard path.hasSuffix(".app") else { return false } // not a bundle (tests, CLI)
        if path.hasPrefix("/Applications/") { return false }
        if path.contains("/DerivedData/") || path.contains("/build/") { return false }
        return true
    }

    /// Copy to /Applications, relaunch the copy, quit. The new instance
    /// removes the old copy via `removeOldCopyIfPending`.
    static func moveAndRelaunch() {
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(source.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            NSLog("Move to Applications failed: \(error.localizedDescription)")
            return
        }
        UserDefaults.standard.set(source.path, forKey: pendingRemovalKey)
        NSWorkspace.shared.openApplication(
            at: destination, configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Called at launch by the /Applications copy.
    static func removeOldCopyIfPending() {
        guard let old = UserDefaults.standard.string(forKey: pendingRemovalKey) else { return }
        UserDefaults.standard.removeObject(forKey: pendingRemovalKey)
        guard old != Bundle.main.bundleURL.path, old.hasSuffix(".app") else { return }
        try? FileManager.default.removeItem(atPath: old)
    }
}
