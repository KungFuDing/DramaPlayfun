import SwiftUI

struct HomeView: View {
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router
    @State private var category: DramaCategory = .all
    @State private var query = ""
    @State private var scrollOffset: CGFloat = 0
    @State private var viewportHeight: CGFloat = 700
    @State private var categoryContentY: CGFloat = .greatestFiniteMagnitude
    @FocusState private var isSearchFocused: Bool

    private var navbarOpacity: Double {
        let fadeDistance = HomeBannerCarousel.height - HomeTopControls.navbarHeight
        return Double(min(max(scrollOffset / fadeDistance, 0), 1))
    }

    private var isCategoryPinned: Bool {
        scrollOffset >= categoryContentY - HomeTopControls.pinnedCategoryTop
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HomeBannerCarousel(dramas: Array(app.catalog.dramas.prefix(5)))

                    VStack(alignment: .leading, spacing: 28) {
                        CatalogStatus(catalog: app.catalog)
                        ContinueWatchingSection()
                        CategoryPicker(selection: $category)
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.frame(in: .named("homeContent")).minY
                            } action: { newY in
                                categoryContentY = newY
                            }
                            .opacity(isCategoryPinned ? 0 : 1)
                        HomeCategoryPager(selection: $category, query: query,
                                          minimumHeight: max(1, viewportHeight - HomeTopControls.pinnedCategoryTop))
                    }
                    .padding(.top, 22)
                    .padding(.horizontal, Theme.spacing)
                    .padding(.bottom, 28)
                }
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.frame(in: .named("homeScroll")).minY
                } action: { newY in
                    if #unavailable(iOS 18.0) {
                        scrollOffset = max(0, -newY)
                    }
                }
                .coordinateSpace(name: "homeContent")
            }
            .coordinateSpace(name: "homeScroll")
            .modifier(HomeScrollTracking(offset: $scrollOffset))

            HomeTopControls(
                query: $query,
                isSearchFocused: $isSearchFocused,
                category: $category,
                isCategoryPinned: isCategoryPinned,
                navbarOpacity: navbarOpacity
            ) {
                router.membershipPresented = true
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .screenBackground()
        .scrollDismissesKeyboard(.interactively)
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(edges: .top)
        .refreshable { await app.catalog.reload() }
    }

}

/// Each category owns its content height; short pages still fill the space below the pinned tabs.
private struct HomeCategoryPager: View {
    @Binding var selection: DramaCategory
    let query: String
    let minimumHeight: CGFloat
    @State private var pageHeights: [DramaCategory: CGFloat] = [:]

    private var pageHeight: CGFloat {
        max(minimumHeight, pageHeights[selection] ?? minimumHeight)
    }

    private var pagePosition: Binding<DramaCategory?> {
        Binding(get: { selection }, set: { if let category = $0 { selection = category } })
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(DramaCategory.allCases) { category in
                        HomeCategoryContent(category: category, query: query)
                            .frame(width: geometry.size.width, alignment: .topLeading)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                pageHeights[category] = height
                            }
                            // Equal target bounds keep short categories detectable when Featured is scrolled down.
                            .frame(height: pageHeight, alignment: .top)
                            .contentShape(Rectangle())
                            .id(category)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: pagePosition, anchor: .leading)
            .accessibilityIdentifier("home-category-pages")
            .accessibilityValue(selection.rawValue)
        }
        .frame(height: pageHeight)
    }
}

private struct HomeCategoryContent: View {
    let category: DramaCategory
    let query: String
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            let dramas = app.catalog.filtered(category: category, query: query)
            if category == .all && query.isEmpty {
                HomeDramaShelf(title: "最新发布", dramas: app.catalog.dramas)
                HomeDramaShelf(title: "独家播出", dramas: app.catalog.dramas.filter { $0.category == .costume || $0.category == .drama })
                HomeSectionTitle(title: "热播剧集") { router.selectedTab = .rankings }
                HomeWaterfallGrid(dramas: dramas)
            } else {
                HomeWaterfallGrid(dramas: dramas)
            }
        }
    }
}

private struct HomeScrollTracking: ViewModifier {
    @Binding var offset: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, newOffset in
                offset = newOffset
            }
        } else {
            content
        }
    }
}

private struct HomeTopControls: View {
    static let searchTop: CGFloat = 54
    static let searchHeight: CGFloat = 44
    static let navbarHeight = searchTop + searchHeight
    static let pinnedCategoryTop = searchTop + searchHeight + 10

    @Binding var query: String
    var isSearchFocused: FocusState<Bool>.Binding
    @Binding var category: DramaCategory
    let isCategoryPinned: Bool
    let navbarOpacity: Double
    let onGiftTap: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HomeSearchBar(query: $query, isSearchFocused: isSearchFocused, onGiftTap: onGiftTap)
            if isCategoryPinned {
                CategoryPicker(selection: $category)
                    .padding(.vertical, 2)
                    .transition(.opacity)
            }
        }
        .padding(.top, Self.searchTop)
        .padding(.horizontal, Theme.spacing)
        .padding(.bottom, isCategoryPinned ? 8 : 0)
        .background {
            Color.black.opacity(navbarOpacity)
                .ignoresSafeArea(edges: .top)
        }
        .animation(.easeInOut(duration: 0.16), value: isCategoryPinned)
        .modifier(HomeHeaderTestAccessibility(opacity: navbarOpacity))
    }
}

private struct HomeHeaderTestAccessibility: ViewModifier {
    let opacity: Double

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-top-controls")
            .accessibilityValue("\(Int((opacity * 100).rounded()))%")
        #else
        content
        #endif
    }
}

private struct HomeBannerCarousel: View {
    static let height: CGFloat = 370
    let dramas: [Drama]
    @State private var selectedIndex = 0

    var body: some View {
        ZStack {
            if dramas.isEmpty {
                HomeBannerArtwork()
            } else {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(dramas.enumerated()), id: \.element.id) { index, drama in
                        HomeBannerPage(drama: drama)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            if let drama = currentDrama {
                VStack(alignment: .leading, spacing: 10) {
                    HomeBannerIndicator(selectedIndex: selectedIndex, pageCount: dramas.count)
                    HStack(spacing: 8) {
                        Text(drama.title).font(.title3.bold()).lineLimit(1)
                        Text(drama.badge ?? "最新").font(.caption.bold()).foregroundStyle(.black)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.spacing)
                .padding(.bottom, 20)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            }
        }
        .frame(height: Self.height)
        .onChange(of: dramas.map(\.id), initial: true) { _, _ in
            selectedIndex = 0
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("推荐剧集轮播")
    }

    private var currentDrama: Drama? {
        dramas.indices.contains(selectedIndex) ? dramas[selectedIndex] : nil
    }
}

private struct HomeBannerPage: View {
    let drama: Drama

    var body: some View {
        NavigationLink(value: AppRoute.drama(drama)) {
            ZStack(alignment: .bottomLeading) {
                HomeBannerArtwork()
                LinearGradient(colors: [.clear, .black.opacity(0.12), Theme.background], startPoint: .top, endPoint: .bottom)
            }
            .frame(height: 370)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("推荐剧集，\(drama.title)")
    }
}

private struct HomeBannerIndicator: View {
    let selectedIndex: Int
    let pageCount: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<pageCount, id: \.self) { index in
                if index == selectedIndex {
                    Capsule().fill(Theme.accent).frame(width: 20, height: 5)
                } else {
                    Circle().fill(.white.opacity(0.42)).frame(width: 5, height: 5)
                }
            }
        }
    }
}

private struct HomeBannerArtwork: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .purple, .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.18)).blur(radius: 16).frame(width: 210).offset(x: -110, y: -90)
            Circle().fill(.pink.opacity(0.26)).blur(radius: 28).frame(width: 260).offset(x: 110, y: -30)
            Image(systemName: "sparkles").font(.system(size: 150, weight: .thin))
                .foregroundStyle(.white.opacity(0.22)).rotationEffect(.degrees(-18)).offset(x: 65, y: -48)
        }
        .overlay {
            VStack(spacing: 0) {
                Spacer()
                Text("重启人生，命运由我书写").font(.title2.weight(.medium)).foregroundStyle(.white.opacity(0.18)).padding(.bottom, 110)
            }
        }
        .clipped()
    }
}

private struct HomeSearchBar: View {
    @Binding var query: String
    var isSearchFocused: FocusState<Bool>.Binding
    let onGiftTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Image("HomeSearch")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                TextField("请输入剧名、类型", text: $query).focused(isSearchFocused).foregroundStyle(.white).submitLabel(.search)
            }
            .padding(.horizontal, 13).frame(height: 44)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.26)))

            Button(action: onGiftTap) {
                Image("HomeGift")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.32)))
            }
            .accessibilityLabel("会员礼遇")
        }
    }
}

private struct HomeSectionTitle: View {
    let title: String
    let onMore: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            ZStack(alignment: .trailing) {
                Image("HomeHeadingGlow")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .offset(x: 11, y: -1)
                Text(title).font(.title3.bold())
            }
            Spacer()
            Button(action: onMore) {
                HStack(spacing: 6) {
                    Text("更多")
                    Image("HomeChevron")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 8, height: 14)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct HomeDramaShelf: View {
    let title: String
    let dramas: [Drama]
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HomeSectionTitle(title: title) { router.selectedTab = .theater }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(dramas) { drama in
                        DramaCard(drama: drama).frame(width: 142)
                    }
                }
            }
        }
    }
}

private struct HomeWaterfallGrid: View {
    let dramas: [Drama]
    private var leftColumn: [Drama] { dramas.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil } }
    private var rightColumn: [Drama] { dramas.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? nil : $0.element } }

    var body: some View {
        if dramas.isEmpty {
            ContentUnavailableView("暂无剧集", systemImage: "film", description: Text("试试其他分类或关键词"))
                .frame(maxWidth: .infinity).padding(.vertical, 36)
        } else {
            HStack(alignment: .top, spacing: 14) {
                HomeWaterfallColumn(dramas: leftColumn, startsTall: true)
                HomeWaterfallColumn(dramas: rightColumn, startsTall: false)
            }
        }
    }
}

private struct HomeWaterfallColumn: View {
    let dramas: [Drama]
    let startsTall: Bool

    var body: some View {
        LazyVStack(spacing: 16) {
            ForEach(Array(dramas.enumerated()), id: \.element.id) { index, drama in
                HomeWaterfallCard(drama: drama, posterRatio: (index.isMultiple(of: 2) == startsTall) ? 0.64 : 0.79)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct HomeWaterfallCard: View {
    let drama: Drama
    let posterRatio: CGFloat

    var body: some View {
        NavigationLink(value: AppRoute.drama(drama)) {
            VStack(alignment: .leading, spacing: 0) {
                DramaPoster(drama: drama).aspectRatio(posterRatio, contentMode: .fit)
                VStack(alignment: .leading, spacing: 7) {
                    Text(drama.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text("\(drama.category.rawValue) · 都市 · 甜宠").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(10)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
    }
}

struct ContinueWatchingSection: View {
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router

    var body: some View {
        let history = app.library.recentProgress
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HomeSectionTitle(title: "继续观看") { router.selectedTab = .profile }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(history, id: \.dramaID) { progress in
                            if let drama = app.catalog.dramas.first(where: { $0.id == progress.dramaID }) {
                                NavigationLink(value: AppRoute.drama(drama)) {
                                    HStack(spacing: 12) {
                                        DramaPoster(drama: drama).frame(width: 74)
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(drama.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                            Text("第\(progress.episodeNumber)集 · 剩余\(remainingMinutes(progress))分钟").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            ProgressView(value: progress.fraction).tint(Theme.accent)
                                        }
                                    }
                                    .padding(10).frame(width: 300, height: 110)
                                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func remainingMinutes(_ progress: WatchProgress) -> Int {
        max(1, Int((progress.duration - progress.seconds).rounded(.up) / 60))
    }
}

#Preview {
    HomeView().environment(AppContainer()).environment(AppRouter())
}
