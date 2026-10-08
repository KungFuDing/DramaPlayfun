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
            if let badge = drama.displayBadge {
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
    var onSelect: (() -> Void)? = nil

    var body: some View {
        Group {
            if let onSelect {
                Button(action: onSelect) { content }
            } else {
                NavigationLink(value: AppRoute.drama(drama)) { content }
            }
        }.buttonStyle(.plain)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            DramaPoster(drama: drama)
            Text(drama.title).font(.subheadline).lineLimit(2)
            if !drama.displayTags.isEmpty || drama.episodeCount > 0 {
                Text([drama.displayTags, drama.episodeCount > 0 ? "全\(drama.episodeCount)集" : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
    let tabs: [DramaFeedTab]
    @Binding var selection: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(tabs) { category in
                        Button { withAnimation(.easeInOut(duration: 0.25)) { selection = category.id } } label: {
                            HStack(spacing: 5) {
                                if category.id == DramaFeedTab.featured.id {
                                    Image("HomeFeatured")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 18, height: 18)
                                }
                                Text(category.title)
                            }
                                .font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 10)
                                .background(selection == category.id ? Theme.accent : Theme.surface)
                                .foregroundStyle(selection == category.id ? Color.black : Color.secondary)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }.accessibilityAddTraits(selection == category.id ? .isSelected : [])
                        .id(category.id)
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
