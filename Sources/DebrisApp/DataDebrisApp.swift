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
        // Runs before every capture attempt, so a slow launch cannot miss it.
        func prepare() {
            NSApp.activate(ignoringOtherApps: true) // active-window chrome
            if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            // Match the design PNG canvas so shots compare 1:1; `--tall`
            // for screens that scroll (Settings).
            let window = NSApp.windows.first { $0.isVisible }
            window?.setContentSize(NSSize(width: 1200, height: args.contains("--tall") ? 1500 : 800))
            // `--scroll-end`: show the bottom of a scrolling screen (Settings > About).
            if args.contains("--scroll-end"), let content = window?.contentView {
                for scroll in scrollViews(in: content) {
                    guard let document = scroll.documentView else { continue }
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentSize.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
        // The window can lag launch when the app starts unfocused; retry until
        // one is up rather than racing it with a fixed delay.
        var attempts = 0
        func tryCapture() {
            attempts += 1
            prepare()
            if capture(to: path) {
                FileHandle.standardError.write(Data("SNAPSHOT: written after \(attempts) attempts\n".utf8))
                if args.contains("--quit") { quit() }
            } else if attempts < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tryCapture() }
            } else {
                FileHandle.standardError.write(Data("SNAPSHOT: gave up — no visible window\n".utf8))
                if args.contains("--quit") { quit() }
            }
        }
        // `--quit`: a routed run has nothing to save (scratch profile), and a
        // presented sheet can hold up NSApp.terminate, so exit outright.
        func quit() -> Never { exit(0) }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { tryCapture() }
    }
}
#endif

// @main lives on Main, which routes --auto-clean to the headless runner.
struct DataDebrisApp: App {
    @StateObject private var model = AppModel.live()
    @StateObject private var updates = UpdateManager.live()
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
                .environmentObject(updates)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear { NotificationHandler.shared.model = model }
                // datadebris://checkout-success — poll for the key right away.
                .onOpenURL { model.handleURL($0) }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for updates…") { updates.checkForUpdates() }
                    .disabled(!updates.canCheck)
            }
            CommandGroup(after: .help) {
                Button("Report a problem…") { model.problemReport = .problem }
                    .disabled(model.showWelcome)
                if model.betaFeedbackVisible {
                    Button("Beta feedback…") { model.problemReport = .betaFeedback }
                        .disabled(model.showWelcome)
                }
            }
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
