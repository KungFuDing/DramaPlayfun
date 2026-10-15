import SwiftUI

/// A vertical scroll view with an explicit pull threshold and a single load-more trigger near its end.
struct RefreshLoadScrollView<Content: View>: View {
    private static var refreshThreshold: CGFloat { 82 }

    private enum RefreshPhase {
        case idle, refreshing, finished
    }

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
    @State private var pullDistance: CGFloat = 0
    @State private var peakPullDistance: CGFloat = 0
    @State private var isTrackingPullGesture = false
    @State private var refreshPhase: RefreshPhase = .idle
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
        ScrollView {
            VStack(spacing: 0) {
                content
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.frame(in: .named(coordinateSpaceName)).minY
                    } action: { y in
                        if #unavailable(iOS 18.0) {
                            scrollOffset = max(0, -y)
                        }
                        guard refreshPhase == .idle else { return }
                        pullDistance = max(0, y)
                        peakPullDistance = max(peakPullDistance, pullDistance)
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
        .coordinateSpace(name: coordinateSpaceName)
        .modifier(RefreshLoadOffsetTracking(offset: $scrollOffset))
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { _ in
                    if !isTrackingPullGesture {
                        isTrackingPullGesture = true
                        peakPullDistance = pullDistance
                    }
                }
                .onEnded { _ in
                    if max(peakPullDistance, pullDistance) >= Self.refreshThreshold {
                        beginRefresh()
                    }
                    isTrackingPullGesture = false
                    peakPullDistance = 0
                }
        )
        .overlay(alignment: .top) {
            if pullDistance > 8 || refreshPhase != .idle {
                refreshStatus
                    .padding(.top, refreshIndicatorTop)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            viewportHeight = height
            loadMoreIfNeeded()
        }
        .onChange(of: hasMore) { _, _ in loadMoreIfNeeded() }
    }

    private var refreshStatus: some View {
        let progress = min(pullDistance / Self.refreshThreshold, 1)
        return HStack(spacing: 10) {
            if refreshPhase == .refreshing {
                ProgressView().tint(Theme.accent)
            } else if refreshPhase == .finished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            } else {
                ZStack {
                    Circle().stroke(.white.opacity(0.3), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: progress >= 1 ? "checkmark" : "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .frame(width: 22, height: 22)
            }
            Text(refreshPhase == .refreshing ? L10n.tr("正在刷新…") :
                 refreshPhase == .finished ? L10n.tr("刷新完成") :
                 progress >= 1 ? L10n.tr("松开立即刷新") : L10n.tr("继续下拉刷新 %d%%", Int(progress * 100)))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.86), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("refresh-status")
        .accessibilityLabel(refreshPhase == .refreshing ? L10n.tr("正在刷新") :
                            refreshPhase == .finished ? L10n.tr("刷新完成") :
                            progress >= 1 ? L10n.tr("松开立即刷新") : L10n.tr("继续下拉刷新"))
        .accessibilityValue(refreshPhase == .idle ? "\(Int(progress * 100))%" : "")
    }

    private func beginRefresh() {
        guard refreshPhase == .idle else { return }
        refreshPhase = .refreshing
        pullDistance = 0
        Task {
            let minimumDisplay = Task { try? await Task.sleep(for: .milliseconds(500)) }
            await onRefresh()
            await minimumDisplay.value
            refreshPhase = .finished
            try? await Task.sleep(for: .seconds(2))
            refreshPhase = .idle
        }
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
