import SwiftUI

struct RankingsView: View {
    @Environment(AppContainer.self) private var app
    @State private var category: DramaCategory = .all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("热门好剧，一榜看尽").foregroundStyle(.secondary)
                CategoryPicker(selection: $category)
                CatalogStatus(catalog: app.catalog)
                let ranked = app.catalog.filtered(category: category).sorted { $0.heat > $1.heat }
                if ranked.isEmpty && !app.catalog.isLoading {
                    ContentUnavailableView("暂无榜单", systemImage: "trophy")
                }
                LazyVStack(spacing: 18) {
                    ForEach(Array(ranked.enumerated()), id: \.element.id) { index, drama in
                        NavigationLink(value: AppRoute.drama(drama)) {
                            HStack(spacing: 16) {
                                Text(String(format: "%02d", index + 1)).font(.title2.bold().monospacedDigit())
                                    .foregroundStyle(index < 3 ? Theme.accent : .secondary).frame(width: 36)
                                DramaPoster(drama: drama).frame(width: 80)
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(drama.title).font(.headline)
                                    Text(drama.category.rawValue).font(.caption).foregroundStyle(.secondary)
                                    Label("\(drama.heat / 10000)万热度", systemImage: "flame.fill")
                                        .font(.caption).foregroundStyle(Theme.accent)
                                }
                                Spacer(minLength: 0)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }.padding()
        }.screenBackground().navigationTitle("排行榜")
    }
}
