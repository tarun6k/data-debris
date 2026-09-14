import SwiftUI
import DebrisCore

/// Screen 11: glance and shortcut, never a second UI. Smart Clean still opens
/// the Review sheet in the app — no deletion is one click from the menu bar.
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(Format.bytes(DiskUsage.freeAndTotal().free)) free · \(DiskUsage.volumeName)")
        Divider()
        if model.isScanning {
            if let fraction = model.scanProgressFraction {
                Text("Scanning · \(Int(fraction * 100)) %")
            } else {
                Text("Scanning…")
            }
            Button("Cancel scan") { model.stopScan() }
        } else {
            Button("Scan now") {
                openApp()
                model.startScan()
            }
            if model.hasResults && model.safeBytes > 0 {
                Button("Smart Clean · \(Format.bytes(model.safeBytes))") {
                    openApp()
                    model.smartClean() // opens Review — still the gate (S2)
                }
            }
        }
        Divider()
        if let next = model.nextAutoCleanRun {
            Text("Auto Clean: next \(Format.runMoment(next))")
        } else {
            Text("Auto Clean off")
        }
        if let run = model.undoableAutoRun {
            Button("Auto Clean ran · \(Format.bytes(run.movedBytes)) · Undo") {
                Task {
                    await NotificationHandler.shared.handle(
                        actionId: AutoCleanNotifier.undoActionId, runId: run.id)
                }
            }
        }
        Divider()
        Button("Open Data Debris") { openApp() }
    }

    private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}

/// Settings, for now just General. Protected paths and licensing arrive in
/// later phases.
struct SettingsView: View {
    @AppStorage("showInMenuBar") private var showInMenuBar = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show in menu bar", isOn: $showInMenuBar)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
