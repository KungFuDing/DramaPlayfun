import SwiftUI

struct RankingsView: View {
    @Environment(AppContainer.self) private var app
    @State private var viewportHeight: CGFloat = 700
    @State private var viewportWidth: CGFloat = 375
    @State private var isRetrying = false

    private var scale: CGFloat { viewportWidth / 375 }

    private var showsNetworkFailure: Bool {
        let feed = app.rankings
        return isRetrying
            || (feed.tabs.isEmpty && feed.tabsErrorMessage != nil)
            || (feed.selectedPage.dramas.isEmpty && feed.selectedPage.errorMessage != nil)
    }

    var body: some View {
        @Bindable var feed = app.rankings
        let state = feed.selectedPage
        let selectedID = feed.selectedID
        ZStack {
            if showsNetworkFailure {
                NetworkFailureView { await retryFailedRequest() }
            } else {
                RefreshLoadScrollView(
                    hasMore: state.hasMore,
                    isLoadingMore: state.isLoadingMore,
                    loadError: state.loadMoreErrorMessage,
                    onRefresh: {
                        await feed.reloadTabs()
                        await feed.refreshSelected()
                    },
                    onLoadMore: { await feed.loadMore() }
                ) {
                    VStack(alignment: .leading, spacing: 0) {
                        RankingHeader(scale: scale)
                        VStack(alignment: .leading, spacing: 12 * scale) {
                            RankingTabPicker(tabs: feed.tabs, selection: $feed.selectedID, scale: scale)
                            FeedTabsStatus(feed: feed)
                            RankingCategoryPager(feed: feed, selection: $feed.selectedID,
                                                 minimumHeight: max(1, viewportHeight - 203 * scale))
                        }
                        .padding(.horizontal, 12 * scale)
                        .padding(.bottom, 24)
                    }
                }
                .background(alignment: .top) {
                    ZStack {
                        Theme.background
                        Image("RankingBackground")
                            .resizable().scaledToFit()
                            .frame(maxHeight: .infinity, alignment: .top)
                    }.ignoresSafeArea()
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RankingBottomNavigation()
        }
        .task { await feed.loadTabsIfNeeded() }
        .task(id: selectedID) {
            guard !isRetrying, feed.selectedID == selectedID else { return }
            await feed.loadSelectedIfNeeded()
        }
    }

    private func retryFailedRequest() async {
        guard !isRetrying else { return }
        let feed = app.rankings
        let needsTabs = feed.tabs.isEmpty && feed.tabsErrorMessage != nil
        isRetrying = true
        defer { isRetrying = false }
        if needsTabs {
            await feed.reloadTabs()
            await feed.loadSelectedIfNeeded()
        } else {
            await feed.refreshSelected()
        }
    }
}

private struct RankingBottomNavigation: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                let selected = router.selectedTab == tab
                Button { router.selectedTab = tab } label: {
                    VStack(spacing: 4) {
                        Image(tab.iconAsset(isSelected: selected))
                            .resizable().scaledToFit().frame(width: 22, height: 22)
                        Text(tab.title).font(.system(size: 10))
                    }
                    .foregroundStyle(selected ? Theme.accent : .white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Theme.surface.opacity(0.7))
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

private struct RankingHeader: View {
    let scale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image("RankingTrophy")
                .resizable().scaledToFit()
                .frame(width: 163 * scale, height: 126 * scale)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(y: 12 * scale)
            VStack(spacing: 7 * scale) {
                Text(L10n.tr("短剧排行榜"))
                    .font(.system(size: 30 * scale, weight: .heavy))
                    .foregroundStyle(Color(red: 1, green: 0.90, blue: 0.70))
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .frame(width: 230 * scale, height: 36 * scale)
                Text(L10n.tr("真实榜单   精品热播   神作推荐"))
                    .font(.system(size: 12 * scale))
                    .lineLimit(1).minimumScaleFactor(0.65)
                    .frame(width: 230 * scale)
                    .foregroundStyle(Color(red: 0.85, green: 0.83, blue: 0.81))
            }
            .padding(.leading, 20 * scale)
            .padding(.top, 38 * scale)
        }
        .frame(height: 140 * scale, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("短剧排行榜，真实榜单、精品热播、神作推荐"))
    }
}

private struct RankingTabPicker: View {
    let tabs: [DramaFeedTab]
    @Binding var selection: String
    let scale: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20 * scale) {
                    ForEach(tabs) { tab in
                        let selected = selection == tab.id
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { selection = tab.id }
                        } label: {
                            Text(tab.displayTitle)
                                .font(.system(size: 16 * scale, weight: .bold))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(.white.opacity(selected ? 1 : 0.7))
                                .frame(width: 82 * scale, height: 40 * scale)
                                .frame(height: 47 * scale, alignment: .top)
                                .background(alignment: .top) {
                                    Image(selected ? "RankingTabSelected" : "RankingTabNormal")
                                        .resizable()
                                        .frame(width: 82 * scale, height: (selected ? 47 : 40) * scale)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .id(tab.id)
                    }
                }
            }
            .onChange(of: selection, initial: true) { _, id in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct RankingCategoryPager: View {
    let feed: DramaTabFeedStore
    @Binding var selection: String
    let minimumHeight: CGFloat
    @State private var heights: [String: CGFloat] = [:]

    private var height: CGFloat { max(minimumHeight, heights[selection] ?? minimumHeight) }
    private var position: Binding<String?> {
        Binding(get: { selection }, set: { if let id = $0 { selection = id } })
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(feed.tabs) { tab in
                        RankingCategoryContent(state: feed.page(for: tab.id), width: geometry.size.width) {
                            await feed.refreshSelected()
                        }
                        .frame(width: geometry.size.width, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[tab.id] = $0 }
                        .frame(height: height, alignment: .top)
                        .clipped()
                        .contentShape(Rectangle())
                        .accessibilityHidden(tab.id != selection)
                        .id(tab.id)
                    }
                }.scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: position, anchor: .leading)
            .accessibilityIdentifier("ranking-category-pages")
            .accessibilityValue(feed.tabs.first(where: { $0.id == selection })?.displayTitle ?? "")
        }.frame(height: height)
    }
}

private struct RankingCategoryContent: View {
    let state: DramaTabPage
    let width: CGFloat
    let onRetry: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FeedPageStatus(state: state, onRetry: onRetry)
            LazyVStack(spacing: 12 * width / 351) {
                ForEach(Array(state.dramas.enumerated()), id: \.element.id) { index, drama in
                    RankingDramaRow(drama: drama, rank: index + 1, posterWidth: 95 * width / 351)
                }
            }
            .padding(.top, 4 * width / 351)
        }
    }
}
