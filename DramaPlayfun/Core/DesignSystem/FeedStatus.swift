import SwiftUI

struct FeedTabsStatus: View {
    let feed: DramaTabFeedStore

    var body: some View {
        if feed.isLoadingTabs && !feed.hasLoadedTabs {
            ProgressView(L10n.tr("加载分类…")).frame(maxWidth: .infinity)
        } else if let message = feed.tabsErrorMessage {
            VStack(spacing: 8) {
                Text(message).foregroundStyle(.secondary)
                Button(L10n.tr("重新加载分类")) { Task { await feed.reloadTabs() } }
            }.frame(maxWidth: .infinity)
        } else if feed.hasLoadedTabs && feed.tabs.isEmpty {
            EmptyStateView(title: L10n.tr("暂无分类"))
                .padding(.vertical, 24)
        }
    }
}

struct FeedPageStatus: View {
    let state: DramaTabPage
    let onRetry: () async -> Void
    @State private var isRetrying = false

    var body: some View {
        if state.dramas.isEmpty && (state.errorMessage != nil || isRetrying) {
            NetworkFailureContent {
                guard !isRetrying else { return }
                isRetrying = true
                defer { isRetrying = false }
                await onRetry()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        } else if state.isLoading && state.dramas.isEmpty {
            ProgressView(L10n.tr("加载剧集…")).frame(maxWidth: .infinity).padding(.vertical, 36)
        } else if let message = state.errorMessage {
            VStack(spacing: 8) {
                Text(message).foregroundStyle(.secondary)
                Button(L10n.tr("重新加载")) { Task { await onRetry() } }
            }.frame(maxWidth: .infinity)
        } else if state.hasLoaded && state.dramas.isEmpty && state.errorMessage == nil {
            EmptyStateView(title: L10n.tr("暂无剧集"))
                .padding(.vertical, 36)
        }
    }
}
