import SwiftUI

#if DEBUG
/// `--snapshot <path> <delaySeconds>`: writes a PNG of the window via
/// cacheDisplay (no Screen Recording permission needed). Screenshots only.
enum Snapshot {
    static func armIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), args.indices.contains(index + 1) else { return }
        let path = args[index + 1]
        let delay = args.indices.contains(index + 2) ? Double(args[index + 2]) ?? 3 : 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay - 0.5) {
            NSApp.activate(ignoringOtherApps: true) // active-window chrome
            if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let frame = window.contentView?.superview,
                  let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif

@main
struct DataDebrisApp: App {
    @StateObject private var model = AppModel.live()

    init() {
        #if DEBUG
        Snapshot.armIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup("Data Debris") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Now") { model.startScan() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning || model.showWelcome)
            }
        }
    }
}
