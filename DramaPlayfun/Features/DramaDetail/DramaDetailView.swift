import SwiftUI

struct DramaDetailView: View {
    let drama: Drama
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router
    @State private var episodes: [Episode] = []
    @State private var errorMessage: String?
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 20) {
                    DramaPoster(drama: drama).frame(width: 130)
                    VStack(alignment: .leading, spacing: 14) {
                        Text(drama.title).font(.title2.bold())
                        if !drama.displayTags.isEmpty || drama.episodeCount > 0 {
                            Text([drama.displayTags, drama.episodeCount > 0 ? L10n.tr("全%d集", drama.episodeCount) : ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        }
                        Button { app.library.toggleFavorite(drama.id) } label: {
                            Label(app.library.favoriteIDs.contains(drama.id) ? L10n.tr("已收藏") : L10n.tr("action.favorite"), systemImage: app.library.favoriteIDs.contains(drama.id) ? "heart.fill" : "heart")
                        }.buttonStyle(.bordered)
                    }
                }
                Text(drama.summary).foregroundStyle(.secondary)
                if isLoading { ProgressView(L10n.tr("加载选集…")) }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button(L10n.tr("重试")) { Task { await load() } }
                }
                if let first = episodes.first {
                    Button { play(resumeEpisode ?? first) } label: {
                        Label(resumeEpisode == nil ? L10n.tr("立即播放") : L10n.tr("继续观看"), systemImage: "play.fill").frame(maxWidth: .infinity).padding(8)
                    }.buttonStyle(.borderedProminent).foregroundStyle(.black)
                }
                Text(L10n.tr("选集")).font(.title3.bold())
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 12) {
                    ForEach(episodes) { episode in
                        Button { play(episode) } label: {
                            HStack(spacing: 4) {
                                Text("\(episode.number)")
                                if episode.requiresMembership { Image(systemName: "lock.fill").font(.caption2) }
                            }.frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                        }.accessibilityLabel(episode.requiresMembership ? L10n.tr("第%d集，会员专享", episode.number) : L10n.tr("第%d集", episode.number))
                    }
                }
            }.padding()
        }.screenBackground().navigationTitle(L10n.tr("剧集详情")).navigationBarTitleDisplayMode(.inline)
            .task { await load() }
    }

    private var resumeEpisode: Episode? {
        episodes.first { $0.id == app.library.progress[drama.id]?.episodeID }
    }

    private func play(_ episode: Episode) {
        if episode.requiresMembership && !app.membership.isActive {
            router.membershipPresented = true
        } else {
            router.playback = PlaybackRequest(drama: drama, episode: episode)
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do { episodes = try await app.repository.fetchEpisodes(dramaID: drama.id) }
        catch is CancellationError {} catch { errorMessage = error.appLocalizedDescription }
    }
}
