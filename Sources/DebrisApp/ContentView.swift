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
        case .results: return "line.3.horizontal.decrease"
        case .duplicates: return "square.on.square"
        case .autoClean: return "clock"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .home

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Data Debris") {
                    ForEach(SidebarItem.allCases) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(200)
        } detail: {
            PlaceholderDetailView(item: selection ?? .home)
        }
    }
}

struct PlaceholderDetailView: View {
    let item: SidebarItem

    var body: some View {
        Text(item.title)
            .font(.largeTitle.weight(.semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(item.title)
    }
}
