import SwiftUI

/// A vertical scroll view with an explicit pull threshold and a single load-more trigger near its end.
struct RefreshLoadScrollView<Content: View>: View {
    let hasMore: Bool
    let isLoadingMore: Bool
    let loadError: String?
    let coordinateSpaceName: String
    let refreshIndicatorTop: CGFloat
    let onRefresh: () async -> Void
    let onLoadMore: () async -> Void
    @Binding var scrollOffset: CGFloat
    @ViewBuilder let content: Content

    @State private var viewportHeight: CGFloat = 0
    @State private var footerY: CGFloat = .infinity
    @State private var isRequestingLoad = false

    init(
        hasMore: Bool,
        isLoadingMore: Bool,
        loadError: String? = nil,
        coordinateSpaceName: String = "refreshLoadScroll",
        refreshIndicatorTop: CGFloat = 16,
        scrollOffset: Binding<CGFloat> = .constant(0),
        onRefresh: @escaping () async -> Void,
        onLoadMore: @escaping () async -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.hasMore = hasMore
        self.isLoadingMore = isLoadingMore
        self.loadError = loadError
        self.coordinateSpaceName = coordinateSpaceName
        self.refreshIndicatorTop = refreshIndicatorTop
        self._scrollOffset = scrollOffset
        self.onRefresh = onRefresh
        self.onLoadMore = onLoadMore
        self.content = content()
    }

    var body: some View {
        PullToRefreshScrollView(coordinateSpaceName: coordinateSpaceName,
                                refreshIndicatorTop: refreshIndicatorTop, onRefresh: onRefresh) {
            VStack(spacing: 0) {
                content
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.frame(in: .named(coordinateSpaceName)).minY
                    } action: { y in
                        if #unavailable(iOS 18.0) {
                            scrollOffset = max(0, -y)
                        }
                    }

                footer
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.frame(in: .named(coordinateSpaceName)).minY
                    } action: { y in
                        footerY = y
                        loadMoreIfNeeded()
                    }
            }
        }
        .modifier(RefreshLoadOffsetTracking(offset: $scrollOffset))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            viewportHeight = height
            loadMoreIfNeeded()
        }
        .onChange(of: hasMore) { _, _ in loadMoreIfNeeded() }
    }

    @ViewBuilder private var footer: some View {
        if isLoadingMore || isRequestingLoad {
            ProgressView(L10n.tr("加载更多…"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        } else if let loadError {
            Button {
                requestLoadMore(allowRetry: true)
            } label: {
                VStack(spacing: 4) {
                    Text(L10n.tr("加载失败，点击重试"))
                    Text(loadError).font(.caption).lineLimit(2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private func loadMoreIfNeeded() {
        guard footerY <= viewportHeight + 160, viewportHeight > 0 else { return }
        requestLoadMore()
    }

    private func requestLoadMore(allowRetry: Bool = false) {
        guard hasMore, !isLoadingMore, !isRequestingLoad, allowRetry || loadError == nil else { return }
        isRequestingLoad = true
        Task {
            await onLoadMore()
            isRequestingLoad = false
        }
    }
}

private struct RefreshLoadOffsetTracking: ViewModifier {
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
