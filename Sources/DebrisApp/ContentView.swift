import SwiftUI
import DebrisCore

enum SidebarItem: String, CaseIterable, Identifiable {
    case home
    case results
    case duplicates
    case autoClean
    case history
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .home: return "Home"
        case .results: return "Results"
        case .duplicates: return "Duplicates"
        case .autoClean: return "Auto Clean"
        case .history: return "History"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .results: return "list.bullet"
        case .duplicates: return "square.on.square"
        case .autoClean: return "clock"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.showWelcome {
            WelcomeView()
        } else {
            NavigationSplitView {
                List(selection: $model.sidebar) {
                    Section("Data Debris") {
                        ForEach(SidebarItem.allCases) { item in
                            // Results and Duplicates need a scan first; an
                            // untagged row cannot be selected (macOS 13 has
                            // no .selectionDisabled).
                            if (item == .results || item == .duplicates)
                                && model.lastScan == nil && !model.isScanning {
                                Label(item.title, systemImage: item.systemImage)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Label(item.title, systemImage: item.systemImage)
                                    .tag(item)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(200)
            } detail: {
                detail
            }
            // Review/Cleaning/Done live in one sheet over whatever is behind
            // it — the only gate to deletion (S2).
            .sheet(item: $model.cleanFlow) { flow in
                CleanSheet(flow: flow)
                    .environmentObject(model)
            }
            // Privacy → plan → checkout, one sheet; Esc anywhere = cancel.
            .sheet(item: purchaseBinding) { flow in
                PurchaseSheet(flow: flow)
                    .environmentObject(model)
            }
            .overlay(alignment: .bottom) { licenseToast }
        }
    }

    /// Dismissing the sheet by any route (Esc, close) cancels the flow, so
    /// polling always stops and nothing changes.
    private var purchaseBinding: Binding<PurchaseFlow?> {
        Binding(
            get: { model.purchase },
            set: { if $0 == nil { model.purchase?.cancel() } })
    }

    @ViewBuilder
    private var licenseToast: some View {
        if let text = model.licenseToast {
            Text(text)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 3)
                .padding(.bottom, 18)
                .task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    model.licenseToast = nil
                }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.sidebar ?? .home {
        case .home:
            HomeView()
        case .results:
            if model.isScanning {
                ScanningView()
            } else if let category = model.openCategory {
                CategoryDetailView(category: category)
                    .id(category) // reset scroll/filter state per category
            } else {
                ResultsView()
            }
        case .duplicates:
            DuplicatesView()
        case .autoClean:
            AutoCleanView()
        case .history:
            HistoryView()
        case .settings:
            SettingsView()
        }
    }
}
