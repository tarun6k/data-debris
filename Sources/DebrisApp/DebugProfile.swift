import DebrisCore
import Foundation

#if DEBUG
/// Gives every `--screen` / `--drive…` launch a scratch profile before any
/// store is created (see AppPaths). An operator who already exported
/// APP_SUPPORT_OVERRIDE keeps it — that is how state carries across several
/// `--drive-autoclean` launches.
enum DebugProfile {

    static func installIfRouted(arguments: [String] = CommandLine.arguments) {
        guard AppPaths.isDebugRoute(arguments) else { return }
        if let existing = AppPaths.overrideDirectory {
            log("DEBUG PROFILE: \(existing.path) (from the environment)")
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DataDebris-debug-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            fatalError("DEBUG PROFILE: cannot create \(dir.path): \(error)")
        }
        setenv(AppPaths.overrideKey, dir.path, 1)
        log("DEBUG PROFILE: \(dir.path)")
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
#endif
