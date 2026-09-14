import SwiftUI
import DebrisCore

struct CategoryDetailView: View {
    @EnvironmentObject var model: AppModel
    let category: Category

    var body: some View {
        Text(category.displayName)
    }
}
