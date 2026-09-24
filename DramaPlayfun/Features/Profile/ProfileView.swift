import SwiftUI

struct ProfileView: View {
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router
    @State private var showFavorites = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("短剧爱好者").font(.title2.bold())
                        Text("收藏好故事，留住好时光").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { router.selectedTab = .membership } label: {
                    HStack {
                        Label(app.membership.isActive ? "我的会员" : "开通会员", systemImage: "crown.fill")
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.padding().foregroundStyle(Theme.accent).background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                }
                Picker("我的片单", selection: $showFavorites) {
                    Text("我的收藏").tag(true)
                    Text("观看历史").tag(false)
                }.pickerStyle(.segmented)
                if showFavorites {
                    let favorites = app.catalog.dramas.filter { app.library.favoriteIDs.contains($0.id) }
                    if favorites.isEmpty {
                        ContentUnavailableView("还没有收藏", systemImage: "heart", description: Text("在剧集详情中收藏喜欢的故事"))
                    } else { DramaGrid(dramas: favorites) }
                } else if app.library.recentProgress.isEmpty {
                    ContentUnavailableView("还没有观看记录", systemImage: "clock", description: Text("播放后会自动保存观看进度"))
                } else { ContinueWatchingSection() }
            }.padding()
        }.screenBackground().navigationTitle("我的")
    }
}
