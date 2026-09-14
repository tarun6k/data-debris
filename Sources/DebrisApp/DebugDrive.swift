import AppKit
import Foundation

#if DEBUG
/// `--drive-clean <marker> [--drive-shots <dir>] [--drive-undo]`
///
/// Test scaffolding for the manual pass: scans, selects only findings whose
/// path contains <marker>, then walks the real UI entry points — openReview,
/// startClean, undoRun — printing DRIVE: lines and capturing PNGs at each
/// stage. It calls exactly the methods the buttons call; nothing bypasses
/// the Review gate (S2).
extension AppModel {
    func applyDriveIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--drive-clean"),
              args.indices.contains(index + 1) else { return }
        let marker = args[index + 1]
        let shotsDir = args.firstIndex(of: "--drive-shots")
            .flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let doUndo = args.contains("--drive-undo")
        showWelcome = false

        func shot(_ name: String, settle: UInt64 = 600_000_000) async {
            guard let shotsDir else { return }
            try? await Task.sleep(nanoseconds: settle)
            Snapshot.capture(to: shotsDir + "/" + name)
        }

        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            print("DRIVE: scanning")
            startScan()
            while isScanning { try? await Task.sleep(nanoseconds: 500_000_000) }

            deselectAll()
            let mine = findings.filter { $0.url.path.contains(marker) && $0.isReclaimable }
            setSelected(mine.map(\.id), true)
            print("DRIVE: selected \(mine.count) findings · \(selectedBytes) bytes · marker \(marker)")

            openReview()
            guard let flow = cleanFlow else {
                print("DRIVE: FAILED — review did not open")
                NSApp.terminate(nil)
                return
            }
            print("DRIVE: review — \(flow.plan.items.count) items · \(flow.plan.estimatedBytes) bytes · \(flow.plan.notices.count) notices · \(flow.plan.runningAppConflicts.count) conflicts")
            await shot("drive-review.png", settle: 1_000_000_000)

            flow.startClean()
            var midRunShot = false
            while flow.stage == .cleaning {
                if !midRunShot, let progress = flow.progress,
                   progress.itemsDone >= max(1, flow.runTotalItems / 3) {
                    midRunShot = true
                    await shot("cleaning.png", settle: 0)
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if !midRunShot { print("DRIVE: run finished before a mid-run frame") }
            if let result = flow.result {
                print("DRIVE: done — status \(result.status) · moved \(result.movedBytes) · freed \(result.freedBytes) · done \(result.doneCount) · skipped \(result.skippedCount) · run \(result.runId)")
            } else {
                print("DRIVE: FAILED — no result (\(flow.runError ?? "unknown"))")
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000) // trash gauge task
            await shot("done.png")

            // --drive-pause <seconds>: window for the shell to inspect ~/.Trash.
            if let pauseIndex = args.firstIndex(of: "--drive-pause"),
               args.indices.contains(pauseIndex + 1),
               let seconds = UInt64(args[pauseIndex + 1]) {
                print("DRIVE: pausing \(seconds)s for inspection")
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }

            if doUndo {
                print("DRIVE: undo")
                flow.undoRun()
                while flow.restoredCount == nil {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                print("DRIVE: restored \(flow.restoredCount ?? 0) items")
                await shot("done-undo.png")
            }

            cleanFlow = nil
            sidebar = .history
            await shot("history.png", settle: 1_200_000_000)
            print("DRIVE: complete")
            try? await Task.sleep(nanoseconds: 300_000_000)
            NSApp.terminate(nil)
        }
    }
}
#endif
