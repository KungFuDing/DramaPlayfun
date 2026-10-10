import SwiftUI

struct HomeView: View {
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router
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
        @Bindable var categories = app.homeCategories
        let featured = categories.selectedID == DramaFeedTab.featured.id
        ZStack(alignment: .top) {
            RefreshLoadScrollView(
                hasMore: query.isEmpty && (featured ? app.homeFeed.hasMoreHot : categories.selectedPage.hasMore),
                isLoadingMore: featured ? app.homeFeed.isLoadingMore : categories.selectedPage.isLoadingMore,
                loadError: featured ? app.homeFeed.hotErrorMessage : categories.selectedPage.loadMoreErrorMessage,
                coordinateSpaceName: "homeScroll",
                refreshIndicatorTop: HomeTopControls.pinnedCategoryTop + 8,
                scrollOffset: $scrollOffset,
                onRefresh: {
                    await app.homeFeed.reload()
                    await app.watchHistory.reload()
                    await categories.reloadTabs()
                    await categories.refreshSelected()
                },
                onLoadMore: {
                    if featured { await app.homeFeed.loadMore() }
                    else { await categories.loadMore() }
                }
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    HomeBannerCarousel(banners: app.homeFeed.banners)

                    VStack(alignment: .leading, spacing: 28) {
                        if let message = app.homeFeed.homeErrorMessage {
                            VStack(spacing: 8) {
                                Text(message).foregroundStyle(.secondary)
                                Button("重新加载") { Task { await app.homeFeed.reload() } }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        HomeContinueWatchingSection()
                        CategoryPicker(tabs: categories.tabs, selection: $categories.selectedID)
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.frame(in: .named("homeContent")).minY
                            } action: { newY in
                                categoryContentY = newY
                            }
                            .opacity(isCategoryPinned ? 0 : 1)
                        FeedTabsStatus(feed: categories)
                        HomeCategoryPager(tabs: categories.tabs, selection: $categories.selectedID, query: query,
                                          minimumHeight: max(1, viewportHeight - HomeTopControls.pinnedCategoryTop))
                    }
                    .padding(.top, 22)
                    .padding(.horizontal, Theme.spacing)
                    .padding(.bottom, 28)
                }
                .coordinateSpace(name: "homeContent")
            }

            HomeTopControls(
                query: $query,
                isSearchFocused: $isSearchFocused,
                tabs: categories.tabs,
                category: $categories.selectedID,
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
        .task { await app.homeFeed.loadIfNeeded() }
        .task { await app.watchHistory.reload() }
        .onChange(of: router.playback?.id) { old, new in
            if old != nil && new == nil { Task { await app.watchHistory.reload() } }
        }
        .task { await categories.loadTabsIfNeeded() }
        .task(id: categories.selectedID) { await categories.loadSelectedIfNeeded() }
    }

}

/// Each category owns its content height; short pages still fill the space below the pinned tabs.
private struct HomeCategoryPager: View {
    let tabs: [DramaFeedTab]
    @Binding var selection: String
    let query: String
    let minimumHeight: CGFloat
    @State private var pageHeights: [String: CGFloat] = [:]

    private var pageHeight: CGFloat {
        max(minimumHeight, pageHeights[selection] ?? minimumHeight)
    }

    private var pagePosition: Binding<String?> {
        Binding(get: { selection }, set: { if let category = $0 { selection = category } })
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(tabs) { category in
                        HomeCategoryContent(category: category, query: query)
                            .frame(width: geometry.size.width, alignment: .topLeading)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                pageHeights[category.id] = height
                            }
                            // Equal target bounds keep short categories detectable when Featured is scrolled down.
                            .frame(height: pageHeight, alignment: .top)
                            .contentShape(Rectangle())
                            .id(category.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: pagePosition, anchor: .leading)
            .accessibilityIdentifier("home-category-pages")
            .accessibilityValue(tabs.first(where: { $0.id == selection })?.title ?? "")
        }
        .frame(height: pageHeight)
    }
}

private struct HomeCategoryContent: View {
    let category: DramaFeedTab
    let query: String
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if category.id == DramaFeedTab.featured.id && query.isEmpty {
                if app.homeFeed.hasLoaded {
                    HomeMomentsSection(feed: app.homeFeed)
                    ForEach(app.homeFeed.shelves) { shelf in
                        HomeDramaShelf(title: shelf.title, dramas: shelf.dramas)
                    }
                    HomeSectionTitle(title: "热播剧集") { router.selectedTab = .rankings }
                    if !app.homeFeed.hotDramas.isEmpty {
                        HomeWaterfallGrid(dramas: app.homeFeed.hotDramas)
                    }
                    if app.homeFeed.hotDramas.isEmpty && !app.homeFeed.isLoadingMore && app.homeFeed.hotErrorMessage == nil {
                        ContentUnavailableView("暂无剧集", systemImage: "film")
                    }
                } else if app.homeFeed.isLoading {
                    ProgressView("加载首页…").frame(maxWidth: .infinity).padding(.vertical, 36)
                }
            } else if category.id == DramaFeedTab.featured.id {
                let dramas = app.homeFeed.hotDramas.filter { $0.title.localizedStandardContains(query) || $0.displayTags.localizedStandardContains(query) }
                HomeWaterfallGrid(dramas: dramas)
            } else {
                let state = app.homeCategories.page(for: category.id)
                FeedPageStatus(state: state) { await app.homeCategories.refreshSelected() }
                let dramas = state.dramas.filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.displayTags.localizedStandardContains(query) }
                if !dramas.isEmpty { HomeWaterfallGrid(dramas: dramas) }
            }
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
    let tabs: [DramaFeedTab]
    @Binding var category: String
    let isCategoryPinned: Bool
    let navbarOpacity: Double
    let onGiftTap: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HomeSearchBar(query: $query, isSearchFocused: isSearchFocused, onGiftTap: onGiftTap)
            if isCategoryPinned {
                CategoryPicker(tabs: tabs, selection: $category)
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
    let banners: [HomeBanner]
    @State private var selectedIndex = 0

    var body: some View {
        ZStack {
            if banners.isEmpty {
                HomeBannerArtwork()
            } else {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(banners.enumerated()), id: \.element.id) { index, banner in
                        HomeBannerPage(banner: banner)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            if let drama = currentBanner?.drama {
                VStack(alignment: .leading, spacing: 10) {
                    HomeBannerIndicator(selectedIndex: selectedIndex, pageCount: banners.count)
                    HStack(spacing: 8) {
                        Text(drama.title).font(.title3.bold()).lineLimit(1)
                        if let badge = drama.displayBadge {
                            Text(badge).font(.caption.bold()).foregroundStyle(.black)
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 5))
                        }
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
        .onChange(of: banners.map(\.id), initial: true) { _, _ in
            selectedIndex = 0
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("推荐剧集轮播")
    }

    private var currentBanner: HomeBanner? {
        banners.indices.contains(selectedIndex) ? banners[selectedIndex] : nil
    }
}

private struct HomeBannerPage: View {
    @Environment(AppRouter.self) private var router
    let banner: HomeBanner

    var body: some View {
        Button { router.openPlayback(banner.drama) } label: {
            ZStack(alignment: .bottomLeading) {
                if let imageURL = banner.imageURL {
                    CachedRemoteImage(url: imageURL) { HomeBannerArtwork() }
                } else {
                    HomeBannerArtwork()
                }
                LinearGradient(colors: [.clear, .black.opacity(0.12), Theme.background], startPoint: .top, endPoint: .bottom)
            }
            .frame(height: 370)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("推荐剧集，\(banner.drama.title)")
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

struct HomeSectionTitle: View {
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
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 8, height: 14)
                }
                .font(.subheadline)
                .foregroundStyle(Color(red: 185.0 / 255, green: 185.0 / 255, blue: 185.0 / 255))
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
                        DramaCard(drama: drama, onSelect: { router.openPlayback(drama) }).frame(width: 142)
                            .accessibilityIdentifier("home-shelf-item-\(drama.id)")
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
                HomeWaterfallColumn(dramas: leftColumn)
                HomeWaterfallColumn(dramas: rightColumn)
            }
        }
    }
}

private struct HomeWaterfallColumn: View {
    let dramas: [Drama]

    var body: some View {
        LazyVStack(spacing: 16) {
            ForEach(dramas) { drama in
                HomeWaterfallCard(drama: drama)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct HomeWaterfallCard: View {
    @Environment(AppRouter.self) private var router
    let drama: Drama

    var body: some View {
        Button { router.openPlayback(drama) } label: {
            VStack(alignment: .leading, spacing: 0) {
                DramaPoster(drama: drama, aspectRatio: 0.77)
                VStack(alignment: .leading, spacing: 7) {
                    Text(drama.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    if !drama.displayTags.isEmpty {
                        Text(drama.displayTags).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-drama-item-\(drama.id)")
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
                                Button { router.openPlayback(drama) } label: {
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
