import SwiftUI

struct TheaterView: View {
    @Environment(AppContainer.self) private var app
    @State private var category: DramaCategory = .all
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CategoryPicker(selection: $category)
                CatalogStatus(catalog: app.catalog)
                DramaGrid(dramas: app.catalog.filtered(category: category, query: query))
            }.padding()
        }
        .screenBackground().navigationTitle("剧场")
        .searchable(text: $query, prompt: "寻找喜欢的故事")
        .refreshable { await app.catalog.reload() }
    }
}
