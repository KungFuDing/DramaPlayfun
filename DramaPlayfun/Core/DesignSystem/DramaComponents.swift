import SwiftUI

struct DramaPoster: View {
    let drama: Drama
    var aspectRatio: CGFloat = 0.72
    var cornerRadius: CGFloat = Theme.cornerRadius

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(LinearGradient(colors: [.indigo.opacity(0.75), Theme.surface, .black], startPoint: .topLeading, endPoint: .bottomTrailing))
            CachedRemoteImage(url: drama.coverURL, source: .dramaCover(drama.id)) {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(Theme.accent)
                    Text(drama.title).font(.headline).multilineTextAlignment(.center)
                }.padding()
            }
            if let badge = drama.badge?.trimmingCharacters(in: .whitespacesAndNewlines), !badge.isEmpty {
                DramaBadge(title: badge)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}

private struct DramaBadge: View {
    let title: String

    var body: some View {
        switch title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "new", "新品":
            HomeBadge(background: "HomeBadgeNewBackground", label: L10n.tr("新品"))
        case "hot", "爆款":
            HomeBadge(background: "HomeBadgeHotBackground", label: L10n.tr("爆款"))
        case "最新":
            HomeBadge(background: "HomeBadgeNewBackground", label: L10n.tr("最新"))
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
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(width: 34, height: 14).padding(.top, 3).padding(.leading, 2)
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
                Text([drama.displayTags, drama.episodeCount > 0 ? L10n.tr("全%d集", drama.episodeCount) : ""]
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
            ContentUnavailableView(L10n.tr("暂无剧集"), systemImage: "film", description: Text(L10n.tr("试试其他分类或关键词")))
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
                                Text(category.displayTitle)
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
            ProgressView(L10n.tr("加载剧集…")).frame(maxWidth: .infinity).padding(40)
        } else if let message = catalog.errorMessage {
            VStack(spacing: 12) {
                Text(message).foregroundStyle(.secondary)
                Button(L10n.tr("重新加载")) { Task { await catalog.reload() } }
            }.frame(maxWidth: .infinity).padding()
        }
    }
}
