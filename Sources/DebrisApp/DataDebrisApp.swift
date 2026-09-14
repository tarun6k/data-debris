import SwiftUI

#if DEBUG
/// `--snapshot <path> <delaySeconds>`: writes a PNG of the window via
/// cacheDisplay (no Screen Recording permission needed). Screenshots only.
enum Snapshot {
    /// Captures the sheet when one is up, otherwise the main window.
    /// Returns false when no visible window exists yet.
    @discardableResult
    static func capture(to path: String) -> Bool {
        let window = NSApp.windows.first { $0.isVisible && $0.sheetParent != nil }
            ?? NSApp.windows.first { $0.isVisible }
        guard let frame = window?.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return false }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        return true
    }

    static func armIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), args.indices.contains(index + 1) else { return }
        let path = args[index + 1]
        let delay = args.indices.contains(index + 2) ? Double(args[index + 2]) ?? 3 : 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay - 0.5) {
            NSApp.activate(ignoringOtherApps: true) // active-window chrome
            if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            // Match the design PNG canvas so shots compare 1:1.
            NSApp.windows.first { $0.isVisible }?
                .setContentSize(NSSize(width: 1200, height: 800))
        }
        // The window can lag launch when the app starts unfocused; retry until
        // one is up rather than racing it with a fixed delay.
        var attempts = 0
        func tryCapture() {
            attempts += 1
            if capture(to: path) {
                FileHandle.standardError.write(Data("SNAPSHOT: written after \(attempts) attempts\n".utf8))
            } else if attempts < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tryCapture() }
            } else {
                FileHandle.standardError.write(Data("SNAPSHOT: gave up — no visible window\n".utf8))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { tryCapture() }
    }
}
#endif

// @main lives on Main, which routes --auto-clean to the headless runner.
struct DataDebrisApp: App {
    @StateObject private var model = AppModel.live()
    @AppStorage("showInMenuBar") private var showInMenuBar = false

    init() {
        // App.init can run more than once; never create state here (the
        // @StateObject autoclosure guards AppModel). A duplicate AppModel
        // re-ran the debug drive and rewrote the LaunchAgent mid-schedule.
        NotificationHandler.shared.installEarly()
        #if DEBUG
        Snapshot.armIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup("Data Debris", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { NotificationHandler.shared.model = model }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Now") { model.startScan() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning || model.showWelcome)
                Button("Review Selection…") { model.openReview() }
                    .disabled(!model.canReview || model.showWelcome || model.cleanFlow != nil)
            }
            // The app has no document undo; ⌘Z is "put my files back" (S5).
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Last Clean") { model.undoLastClean() }
                    .keyboardShortcut("z")
                    .disabled(model.showWelcome || model.lastUndoableRunId == nil)
            }
        }

        // Screen 11 — off unless Settings > General turns it on.
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuBarLowSpace ? "gauge.low" : "gauge.medium")
                .foregroundStyle(model.menuBarLowSpace ? Color.orange : Color.primary)
        }
    }
}
