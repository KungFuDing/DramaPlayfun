import SwiftUI

struct HomeContinueWatchingSection: View {
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router

    var body: some View {
        let history = app.watchHistory
        if !history.items.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HomeSectionTitle(title: "继续观看") { router.selectedTab = .profile }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(history.items) { item in
                            Button {
                                item.prepareResume(in: app.library)
                                router.paths[.home, default: []].append(.drama(item.drama))
                            } label: {
                                HStack(spacing: 12) {
                                    DramaPoster(drama: item.drama).frame(width: 74)
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(item.drama.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                        Text(item.isOnline ? item.subtitle : "已下架")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        if let fraction = item.fraction(using: app.library) {
                                            ProgressView(value: fraction).tint(Theme.accent)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(10).frame(width: 300, height: 110)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("history-\(item.id)")
                            .disabled(!item.isOnline)
                            .onAppear {
                                if item.id == history.items.last?.id && history.loadMoreErrorMessage == nil {
                                    Task { await history.loadMore() }
                                }
                            }
                        }
                        if history.isLoadingMore {
                            ProgressView().frame(width: 60)
                        } else if history.loadMoreErrorMessage != nil {
                            Button("加载失败，重试") { Task { await history.loadMore() } }
                                .frame(width: 140)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-continue-watching")
        }
    }
}
