import AppKit
import DebrisCore
import os

/// Entry point. `--auto-clean <reason>` (spawned by a LaunchAgent) runs
/// headless: no window, no Dock icon — run, notify, quit. An already running
/// GUI instance refreshes itself via the distributed notification instead of
/// this process handing over to it.
@main
enum Main {
    static func main() {
        if let reason = autoCleanReason() {
            headlessRun(reason: reason)
        }
        DataDebrisApp.main()
    }

    static func autoCleanReason(_ arguments: [String] = CommandLine.arguments) -> AutoCleanReason? {
        guard let index = arguments.firstIndex(of: "--auto-clean"),
              arguments.indices.contains(index + 1) else { return nil }
        return AutoCleanReason(rawValue: arguments[index + 1])
    }

    private static func headlessRun(reason: AutoCleanReason) -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task.detached {
            await runOnce(reason: reason)
            exit(0)
        }
        dispatchMain()
    }

    static func runOnce(reason: AutoCleanReason) async {
        // Unified log for production; stderr so a plist with StandardErrorPath
        // (or a terminal run) can capture the outcome too.
        let logger = Logger(subsystem: "com.tarunkumar.datadebris", category: "autoclean")
        func log(_ line: String, error: Bool = false) {
            if error { logger.error("\(line, privacy: .public)") }
            else { logger.notice("\(line, privacy: .public)") }
            FileHandle.standardError.write(Data("auto-clean: \(line)\n".utf8))
        }
        let agents = LaunchAgentManager()
        do {
            let config = AutoCleanConfig.load(from: try AutoCleanConfig.defaultFileURL())
            guard config.enabled else {
                // A stale agent (settings reset by hand): clean up and stop.
                agents.uninstall()
                return
            }
            let runner = try AutoCleanRunner(
                config: config,
                catalogue: try Catalogue.bundled(),
                history: try HistoryStore(),
                exclusions: try? ExclusionStore())
            switch try await runner.run(reason: reason) {
            case .deferred(let why, gaveUp: false):
                log("deferred: \(why.rawValue), retrying in 1 h")
                do { try agents.installRetry(at: Date().addingTimeInterval(3600)) }
                catch { log("retry agent install failed: \(error)", error: true) }
            case .deferred(let why, gaveUp: true):
                log("deferred: \(why.rawValue), gave up after 24 h")
                agents.removeRetry()
            case .completed(let runId, let movedBytes, let itemCount):
                log("completed: run \(runId), \(movedBytes) bytes, \(itemCount) items")
                agents.removeRetry()
                await AutoCleanNotifier.post(runId: runId, movedBytes: movedBytes,
                                             itemCount: itemCount, notify: config.notify)
                DistributedNotificationCenter.default().postNotificationName(
                    .debrisAutoCleanDidRun, object: nil, userInfo: nil, deliverImmediately: true)
            case .notNeeded:
                break
            }
        } catch {
            // The run stays deferred until the next schedule.
            log("failed: \(error)", error: true)
        }
    }
}
