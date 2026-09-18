import DebrisCore
import AppKit
import Foundation

enum FullDiskAccess {
    enum Status: Equatable { case granted, denied }

    /// TCC has no query API. The only way to know is to try reading a folder
    /// it protects; Safari's is present on every Mac.
    static let probeRelativePath = "Library/Safari"

    /// Pure probe: `canList` is the file-system call, replaceable in tests.
    static func probe(home: String = NSHomeDirectory(),
                      canList: (String) -> Bool = defaultCanList) -> Status {
        canList(home + "/" + probeRelativePath) ? .granted : .denied
    }

    static var granted: Bool { probe() == .granted }

    static func defaultCanList(_ path: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}

/// TCC ties Full Disk Access to the app's location; running from Downloads
/// and moving later resets the grant. So we offer the move before asking,
/// on every launch until the app lives in an Applications folder.
enum MoveToApplications {
    enum Decision: Equatable {
        case notABundle            // tests, CLI
        case alreadyInApplications // /Applications or ~/Applications
        case developmentBuild      // Xcode/xcodebuild output, Debug builds only
        case offer(destination: URL)
    }

    static let pendingRemovalKey = "pendingOldCopyRemoval"

    static func decision(bundleURL: URL, home: URL, isDebugBuild: Bool) -> Decision {
        let path = bundleURL.standardizedFileURL.path
        guard path.hasSuffix(".app") else { return .notABundle }
        let userApplications = home.standardizedFileURL
            .appendingPathComponent("Applications").path
        if path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/") {
            return .alreadyInApplications
        }
        if isDebugBuild, path.contains("/DerivedData/") || path.contains("/build/") {
            return .developmentBuild
        }
        return .offer(destination: URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(bundleURL.lastPathComponent))
    }

    static var current: Decision {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return decision(bundleURL: Bundle.main.bundleURL,
                        home: FileManager.default.homeDirectoryForCurrentUser,
                        isDebugBuild: debug)
    }

    struct MoveFailed: LocalizedError {
        let underlying: Error
        var errorDescription: String? {
            "Could not copy the app to Applications: \(underlying.localizedDescription)"
        }
    }

    /// Copy to /Applications (or ~/Applications when /Applications is not
    /// writable), launch the copy as a new process, quit. The copy trashes
    /// the old one via `removeOldCopyIfPending` on its first launch, so the
    /// running binary is never deleted from under itself.
    static func moveAndRelaunch(to preferred: URL) throws {
        let source = Bundle.main.bundleURL
        let fm = FileManager.default
        let fallback = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
            .appendingPathComponent(source.lastPathComponent)
        var destination = preferred
        do {
            try copyReplacing(source: source, destination: preferred)
        } catch {
            do {
                try fm.createDirectory(at: fallback.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try copyReplacing(source: source, destination: fallback)
                destination = fallback
            } catch {
                throw MoveFailed(underlying: error)
            }
        }
        AppPaths.userDefaults.set(source.path, forKey: pendingRemovalKey)
        let configuration = NSWorkspace.OpenConfiguration()
        // Same bundle id as this process: without this LaunchServices would
        // just activate us instead of starting the copy.
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                if app != nil {
                    NSApp.terminate(nil)
                } else {
                    NSLog("Relaunch from \(destination.path) failed: \(error?.localizedDescription ?? "?")")
                    AppPaths.userDefaults.removeObject(forKey: pendingRemovalKey)
                }
            }
        }
    }

    private static func copyReplacing(source: URL, destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            // An older copy of this app; Trash, never delete.
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: destination)
    }

    /// Called once at launch. Returns true when this process is the copy that
    /// `moveAndRelaunch` started, so the caller can re-check Full Disk Access.
    @discardableResult
    static func removeOldCopyIfPending() -> Bool {
        let defaults = AppPaths.userDefaults
        guard let old = defaults.string(forKey: pendingRemovalKey) else { return false }
        defaults.removeObject(forKey: pendingRemovalKey)
        guard old != Bundle.main.bundleURL.path, old.hasSuffix(".app") else { return false }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: old), resultingItemURL: nil)
        } catch {
            NSLog("Could not move the old copy at \(old) to Trash: \(error.localizedDescription)")
        }
        return true
    }
}
