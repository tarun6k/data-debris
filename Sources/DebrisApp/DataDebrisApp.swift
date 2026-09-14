import SwiftUI

@main
struct DataDebrisApp: App {
    @StateObject private var model = AppModel.live()

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
