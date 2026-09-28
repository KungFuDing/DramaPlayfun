import SwiftUI

struct DramaPoster: View {
    let drama: Drama

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(LinearGradient(colors: [.indigo.opacity(0.75), Theme.surface, .black], startPoint: .topLeading, endPoint: .bottomTrailing))
            CachedRemoteImage(url: drama.coverURL) {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(Theme.accent)
                    Text(drama.title).font(.headline).multilineTextAlignment(.center)
                }.padding()
            }
            if let badge = drama.badge {
                DramaBadge(title: badge)
            }
        }
        .aspectRatio(0.72, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .accessibilityHidden(true)
    }
}

private struct DramaBadge: View {
    let title: String

    var body: some View {
        switch title {
        case "新品":
            HomeBadge(background: "HomeBadgeNewBackground", label: "HomeBadgeNew")
        case "爆款":
            HomeBadge(background: "HomeBadgeHotBackground", label: "HomeBadgeHot")
        default:
            Text(title).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.indigo)
        }
    }
}

private struct HomeBadge: View {
    let background: String
    let label: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(background).resizable().frame(width: 42, height: 22)
            Image(label).resizable().scaledToFit().frame(width: 25, height: 12).padding(.top, 4).padding(.leading, 4)
        }
        .frame(width: 42, height: 22, alignment: .topLeading)
    }
}

struct DramaCard: View {
    let drama: Drama
    var body: some View {
        NavigationLink(value: AppRoute.drama(drama)) {
            VStack(alignment: .leading, spacing: 8) {
                DramaPoster(drama: drama)
                Text(drama.title).font(.subheadline).lineLimit(2)
                Text("\(drama.category.rawValue) · 全\(drama.episodeCount)集")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain)
    }
}

struct DramaGrid: View {
    let dramas: [Drama]
    var body: some View {
        if dramas.isEmpty {
            ContentUnavailableView("暂无剧集", systemImage: "film", description: Text("试试其他分类或关键词"))
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], alignment: .leading, spacing: 24) {
                ForEach(dramas) { DramaCard(drama: $0) }
            }
        }
    }
}

struct CategoryPicker: View {
    @Binding var selection: DramaCategory
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(DramaCategory.allCases) { category in
                        Button { withAnimation(.easeInOut(duration: 0.25)) { selection = category } } label: {
                            HStack(spacing: 5) {
                                if category == .all {
                                    Image("HomeFeatured")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 18, height: 18)
                                }
                                Text(category.rawValue)
                            }
                                .font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 10)
                                .background(selection == category ? Theme.accent : Theme.surface)
                                .foregroundStyle(selection == category ? Color.black : Color.secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }.accessibilityAddTraits(selection == category ? .isSelected : [])
                        .id(category)
                    }
                }
            }
            .onChange(of: selection, initial: true) { _, category in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(category, anchor: .center) }
            }
        }
    }
}

struct CatalogStatus: View {
    let catalog: CatalogStore
    var body: some View {
        if catalog.isLoading && catalog.dramas.isEmpty {
            ProgressView("加载剧集…").frame(maxWidth: .infinity).padding(40)
        } else if let message = catalog.errorMessage {
            VStack(spacing: 12) {
                Text(message).foregroundStyle(.secondary)
                Button("重新加载") { Task { await catalog.reload() } }
            }.frame(maxWidth: .infinity).padding()
        }
    }
}
