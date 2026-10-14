import SwiftUI

struct ProfileHistoryView: View {
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { dismiss() } label: {
                    Image("SettingsBack").renderingMode(.original).resizable().scaledToFit()
                        .frame(width: 22, height: 22).frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }.accessibilityLabel("返回").accessibilityIdentifier("profile-history-back")
                Text("历史记录").font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            ScrollView {
                VStack(spacing: 18) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(app.watchHistory.items) { item in
                            Button {
                                item.prepareResume(in: app.library)
                                router.openPlayback(item.drama)
                            } label: {
                                ProfileHistoryCard(item: item)
                            }.disabled(!item.isOnline)
                                .accessibilityIdentifier("profile-history-\(item.id)")
                        }
                    }
                    loadingState
                }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 24)
            }.scrollIndicators(.hidden)
                .refreshable { await app.watchHistory.reload() }
                .accessibilityIdentifier("profile-history-grid")
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar).toolbar(.hidden, for: .tabBar)
        .task { await app.watchHistory.reload() }
    }

    @ViewBuilder private var loadingState: some View {
        let history = app.watchHistory
        if history.isLoading || history.isLoadingMore { ProgressView().padding() }
        if let error = history.errorMessage {
            Text(error).font(.footnote).foregroundStyle(.secondary)
            Button("重试") { Task { await history.reload() } }.foregroundStyle(Theme.accent)
        } else if !history.isLoading, history.items.isEmpty {
            ContentUnavailableView("还没有观看记录", systemImage: "clock")
        }
        if let error = history.loadMoreErrorMessage {
            Text(error).font(.footnote).foregroundStyle(.secondary)
        }
        if history.hasMore {
            Button(history.loadMoreErrorMessage == nil ? "加载更多" : "重新加载") {
                Task { await history.loadMore() }
            }.font(.system(size: 13)).foregroundStyle(Theme.accent)
                .disabled(history.isLoading || history.isLoadingMore)
        }
    }
}

private struct ProfileHistoryCard: View {
    let item: WatchHistoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedRemoteImage(url: item.drama.coverURL) {
                Rectangle().fill(Theme.surface)
                    .overlay { Image(systemName: "film").foregroundStyle(Color(white: 0.5)) }
            }
            .aspectRatio(222.0 / 288, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("profile-history-cover-\(item.id)")
            Text(item.drama.title).font(.system(size: 14)).lineSpacing(4).lineLimit(2)
                .foregroundStyle(Color(white: 0.88))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(progressText).font(.system(size: 11)).lineLimit(1)
                .foregroundStyle(Color(white: 0.58))
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
    }

    private var progressText: String {
        guard item.isOnline else { return "已下架" }
        return item.episodeText ?? item.episodeNumber.map { "已看第\($0)集" } ?? "观看记录"
    }
}
