import SwiftUI

struct RankingsView: View {
    @Environment(AppContainer.self) private var app
    @State private var viewportHeight: CGFloat = 700

    var body: some View {
        @Bindable var feed = app.rankings
        let state = feed.selectedPage
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
            VStack(alignment: .leading, spacing: 10) {
                Image("RankingsHeader")
                    .resizable().scaledToFit()
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                .init(color: .white, location: 0.04),
                                                .init(color: .white, location: 0.90),
                                                .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .accessibilityLabel("短剧排行榜，真实榜单、精品热播、神作推荐")
                VStack(alignment: .leading, spacing: 18) {
                    RankingTabPicker(tabs: feed.tabs, selection: $feed.selectedID)
                    FeedTabsStatus(feed: feed)
                    RankingCategoryPager(feed: feed, selection: $feed.selectedID,
                                         minimumHeight: max(1, viewportHeight - 240))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
        }
        .background(alignment: .top) {
            ZStack {
                Theme.background
                LinearGradient(colors: [Color(red: 0.71, green: 0.57, blue: 0.35),
                                        Color(red: 0.37, green: 0.13, blue: 0.11)],
                               startPoint: .topLeading, endPoint: .topTrailing)
                    .frame(height: 280)
                    .frame(maxHeight: .infinity, alignment: .top)
                LinearGradient(colors: [.clear, Theme.background], startPoint: .top, endPoint: .bottom)
                    .frame(height: 280)
                    .frame(maxHeight: .infinity, alignment: .top)
            }.ignoresSafeArea()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .toolbar(.hidden, for: .navigationBar)
        .task { await feed.loadTabsIfNeeded() }
        .task(id: feed.selectedID) { await feed.loadSelectedIfNeeded() }
    }
}

private struct RankingTabPicker: View {
    let tabs: [DramaFeedTab]
    @Binding var selection: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(tabs) { tab in
                        let selected = selection == tab.id
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { selection = tab.id }
                        } label: {
                            Text(tab.title)
                                .font(.system(size: 20, weight: .bold))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(.white.opacity(selected ? 1 : 0.65))
                                .frame(width: 86, height: 50)
                                .padding(.bottom, 7)
                                .background {
                                    RankingTabShape(hasTail: selected)
                                        .fill(LinearGradient(colors: [Color(red: 0.65, green: 0.47, blue: 0.17),
                                                                      Color(red: 0.30, green: 0.15, blue: 0.10),
                                                                      Color(red: 0.48, green: 0.14, blue: 0.21)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .opacity(selected ? 1 : 0.5)
                                }
                                .overlay {
                                    if selected {
                                        RankingTabShape(hasTail: true)
                                            .stroke(LinearGradient(colors: [Color(red: 1, green: 0.95, blue: 0.69),
                                                                            .white.opacity(0.8),
                                                                            Color(red: 0.78, green: 0.63, blue: 0.39)],
                                                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .id(tab.id)
                    }
                }.padding(.horizontal, 1).padding(.vertical, 1)
            }
            .onChange(of: selection, initial: true) { _, id in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct RankingTabShape: Shape {
    let hasTail: Bool

    func path(in rect: CGRect) -> Path {
        let bottom = rect.maxY - 7
        let radius: CGFloat = 7
        var path = Path()
        path.move(to: CGPoint(x: radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: bottom), control: CGPoint(x: rect.maxX, y: bottom))
        path.addLine(to: CGPoint(x: hasTail ? 14 : radius, y: bottom))
        if hasTail {
            path.addLine(to: CGPoint(x: 0, y: rect.maxY))
        } else {
            path.addQuadCurve(to: CGPoint(x: 0, y: bottom - radius), control: CGPoint(x: 0, y: bottom))
        }
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        path.closeSubpath()
        return path
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
                        RankingCategoryContent(state: feed.page(for: tab.id), width: geometry.size.width - 12) {
                            await feed.refreshSelected()
                        }
                        .padding(.horizontal, 6)
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
            .accessibilityValue(feed.tabs.first(where: { $0.id == selection })?.title ?? "")
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
            LazyVStack(spacing: 16) {
                ForEach(Array(state.dramas.enumerated()), id: \.element.id) { index, drama in
                    RankingDramaRow(drama: drama, rank: index + 1, posterWidth: min(112, width * 0.27))
                }
            }
        }
    }
}
