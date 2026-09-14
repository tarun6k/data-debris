import AppKit
import DebrisCore

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
            case .deferred(_, gaveUp: false):
                try? agents.installRetry(at: Date().addingTimeInterval(3600))
            case .deferred(_, gaveUp: true):
                agents.removeRetry()
            case .completed(let runId, let movedBytes, let itemCount):
                agents.removeRetry()
                await AutoCleanNotifier.post(runId: runId, movedBytes: movedBytes,
                                             itemCount: itemCount, notify: config.notify)
                DistributedNotificationCenter.default().postNotificationName(
                    .debrisAutoCleanDidRun, object: nil, userInfo: nil, deliverImmediately: true)
            case .notNeeded:
                break
            }
        } catch {
            // launchd captures stderr in the log; the run stays deferred until
            // the next schedule.
            FileHandle.standardError.write(Data("auto-clean: \(error)\n".utf8))
        }
    }
}
