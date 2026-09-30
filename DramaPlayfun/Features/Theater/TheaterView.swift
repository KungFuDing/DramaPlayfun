import SwiftUI
import AVFoundation

struct TheaterView: View {
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedID: Drama.ID?
    @State private var episodeDrama: Drama?
    @State private var pendingRequest: PlaybackRequest?
    @State private var retryingPlayback = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if app.theaterFeed.items.isEmpty {
                    VStack(spacing: 20) {
                        if app.theaterFeed.isLoading || !app.theaterFeed.hasLoaded {
                            ProgressView("正在加载剧场…")
                        } else {
                            ContentUnavailableView("暂无剧集", systemImage: "play.rectangle",
                                description: Text(app.theaterFeed.errorMessage ?? "精彩故事即将上线"))
                            Button("重新加载") { Task { await app.theaterFeed.reload() } }
                        }
                    }
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(app.theaterFeed.items) { item in
                                TheaterVideoPage(
                                    item: item,
                                    playback: app.theaterPlayback,
                                    isActive: selectedID == item.id && isTheaterVisible,
                                    topInset: geometry.safeAreaInsets.top,
                                    onRetry: { Task { await retryPlayback() } },
                                    onEpisodes: { episodeDrama = item.drama }
                                )
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .id(item.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                    .scrollPosition(id: $selectedID, anchor: .top)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .accessibilityIdentifier("theater-feed")
                    .overlay(alignment: .bottom) {
                        if let error = app.theaterFeed.loadMoreErrorMessage {
                            Button("加载更多失败，点击重试：\(error)") {
                                Task { await app.theaterFeed.loadMore() }
                            }
                            .font(.caption)
                            .padding(10)
                            .background(.black.opacity(0.85), in: Capsule())
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(.black)
        .toolbar(.hidden, for: .navigationBar)
        .task { await app.theaterFeed.loadIfNeeded() }
        .task(id: playbackKey) {
            app.theaterPlayback.update(items: app.theaterFeed.items,
                                       selectedID: selectedID, visible: isTheaterVisible)
        }
        .onChange(of: app.theaterFeed.items.map(\.id), initial: true) { _, ids in
            if !ids.contains(where: { $0 == selectedID }) { selectedID = ids.first }
        }
        .onChange(of: selectedID) { _, id in
            guard let index = app.theaterFeed.items.firstIndex(where: { $0.id == id }),
                  index >= app.theaterFeed.items.count - 3 else { return }
            Task { await app.theaterFeed.loadMore() }
        }
        .onDisappear { app.theaterPlayback.suspend() }
        .sheet(item: $episodeDrama, onDismiss: presentSelectedEpisode) { drama in
            TheaterEpisodesSheet(drama: drama) { episode in
                pendingRequest = PlaybackRequest(drama: drama, episode: episode)
                episodeDrama = nil
            }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var isTheaterVisible: Bool {
        router.selectedTab == .theater && scenePhase == .active && episodeDrama == nil
            && router.playback == nil && !router.membershipPresented
    }

    private var playbackKey: String {
        "\(selectedID ?? "none")|\(isTheaterVisible)|\(app.theaterFeed.items.map(\.id).joined(separator: ","))"
    }

    private func presentSelectedEpisode() {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        if request.episode.requiresMembership && !app.membership.isActive {
            router.membershipPresented = true
        } else {
            router.playback = request
        }
    }

    private func retryPlayback() async {
        guard !retryingPlayback else { return }
        retryingPlayback = true
        defer { retryingPlayback = false }
        await app.theaterFeed.reload()
        app.theaterPlayback.reset()
        if !app.theaterFeed.items.contains(where: { $0.id == selectedID }) {
            selectedID = app.theaterFeed.items.first?.id
        }
        app.theaterPlayback.update(items: app.theaterFeed.items,
                                   selectedID: selectedID, visible: isTheaterVisible)
    }
}

private struct TheaterVideoPage: View {
    let item: TheaterFeedItem
    let playback: TheaterPlayerPool
    let isActive: Bool
    let topInset: CGFloat
    let onRetry: () -> Void
    let onEpisodes: () -> Void
    @Environment(AppContainer.self) private var app
    @State private var isExpanded = false
    @State private var summaryHeight: CGFloat = 20
    @State private var showCheckIn = false
    @AppStorage private var isLiked: Bool

    private var drama: Drama { item.drama }

    init(item: TheaterFeedItem, playback: TheaterPlayerPool, isActive: Bool,
         topInset: CGFloat, onRetry: @escaping () -> Void, onEpisodes: @escaping () -> Void) {
        self.item = item
        self.playback = playback
        self.isActive = isActive
        self.topInset = topInset
        self.onRetry = onRetry
        self.onEpisodes = onEpisodes
        _isLiked = AppStorage(wrappedValue: item.isFirstEpisodeLiked, "theater.liked.\(item.id)")
    }

    var body: some View {
        ZStack {
            TheaterVideoBackdrop(drama: drama)
            if let player = playback.player(for: item.id) {
                TheaterPlayerSurface(player: player)
                    .opacity(player.currentItem == nil ? 0 : 1)
            }
            Color.clear.contentShape(Rectangle()).onTapGesture { togglePlayback() }
            LinearGradient(colors: [.black.opacity(0.2), .clear, .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            playbackStatus

            VStack {
                checkInBanner.padding(.top, max(topInset, 54) + 16)
                Spacer(minLength: 24)
                HStack(alignment: .bottom, spacing: 16) {
                    metadata.frame(maxWidth: .infinity, alignment: .leading)
                    actions.padding(.bottom, 64)
                }
                progressBar
            }
            .padding(.horizontal, 14)
        }
        .clipped()
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theater-video-\(drama.id)")
        .alert("每日签到", isPresented: $showCheckIn) {
            Button("知道了", role: .cancel) { }
        } message: { Text("签到服务暂未接入，接入后可领取每日奖励。") }
    }

    private var checkInBanner: some View {
        HStack(spacing: 10) {
            Image("HomeGift").resizable().scaledToFit().frame(width: 28, height: 28)
            Text("今日签到").font(.subheadline)
            Text("+20金币").font(.subheadline.bold()).foregroundStyle(Theme.accent)
            Button("领取") { showCheckIn = true }
                .font(.subheadline).foregroundStyle(.black)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(6)
        .background(LinearGradient(colors: [.yellow.opacity(0.6), .brown.opacity(0.65)],
                                   startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var playbackStatus: some View {
        if case .unavailable(let error) = playback.states[item.id] {
            VStack(spacing: 12) {
                Image(systemName: "play.slash").font(.largeTitle)
                Text(error).font(.subheadline).multilineTextAlignment(.center)
                Button("重试", action: onRetry).buttonStyle(.bordered)
            }
            .padding(24).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 48)
        } else if isActive && playback.states[item.id] != .ready {
            ProgressView().tint(.white)
        } else if isActive && (playback.isPaused || playback.hasEnded) {
            Button { togglePlayback() } label: {
                Image(systemName: "play.fill").font(.system(size: 56)).foregroundStyle(.white.opacity(0.85))
            }.accessibilityLabel("播放视频")
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(drama.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
            HStack(spacing: 6) {
                tag("共\(drama.episodeCount)集")
                tag("热度\(drama.heat.formatted())")
                tag(drama.category.rawValue)
            }
            Button(action: onEpisodes) {
                HStack(spacing: 6) {
                    Image(systemName: "play.rectangle")
                    Text("更多剧集(第1集/共\(drama.episodeCount)集)").lineLimit(1).minimumScaleFactor(0.75)
                    Image(systemName: "chevron.right")
                }.font(.subheadline).padding(10)
                    .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }.accessibilityLabel("更多剧集，\(drama.title)")
            HStack(alignment: .bottom, spacing: 8) {
                if isExpanded {
                    ScrollView {
                        Text("第一集 | \(drama.summary)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                summaryHeight = height
                            }
                            .accessibilityIdentifier("theater-summary-text")
                    }
                    .frame(height: min(max(summaryHeight, 20), 140))
                    .accessibilityIdentifier("theater-summary-scroll")
                } else {
                    Text("第一集 | \(drama.summary)").lineLimit(1)
                        .accessibilityIdentifier("theater-summary-text")
                }
                Button(isExpanded ? "收起" : "展开") { isExpanded.toggle() }
                    .fixedSize().foregroundStyle(.white)
            }.font(.subheadline).foregroundStyle(.white.opacity(0.7))
        }
    }

    private func tag(_ title: String) -> some View {
        Text(title).font(.caption).lineLimit(1)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }

    private var actions: some View {
        VStack(spacing: 24) {
            Button { isLiked.toggle() } label: {
                actionLabel("heart.fill", title: isLiked ? "已赞" : "点赞", color: isLiked ? .red : .white)
            }.accessibilityLabel(isLiked ? "取消点赞" : "点赞")
            Button { app.library.toggleFavorite(drama.id) } label: {
                actionLabel("star.fill", title: app.library.favoriteIDs.contains(drama.id) ? "已收藏" : "收藏",
                            color: app.library.favoriteIDs.contains(drama.id) ? Theme.accent : .white)
            }.accessibilityLabel(app.library.favoriteIDs.contains(drama.id) ? "取消收藏" : "收藏")
            ShareLink(item: "\(drama.title)\n\(drama.summary)") {
                actionLabel("square.and.arrow.up", title: "分享", color: .white)
            }
        }
        .frame(width: 48)
        .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
    }

    private func actionLabel(_ symbol: String, title: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.85))
        }.frame(minWidth: 44, minHeight: 54)
    }

    private var progressBar: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !isActive || playback.isPaused)) { _ in
            let player = playback.player(for: item.id)
            let duration = player?.currentItem?.duration.seconds ?? 0
            let seconds = player?.currentTime().seconds ?? 0
            let fraction = duration.isFinite && duration > 0 && seconds.isFinite ? min(max(seconds / duration, 0), 1) : 0
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(Theme.accent).frame(width: proxy.size.width * fraction)
                }
            }.frame(height: 2)
        }
        .padding(.top, 4).padding(.bottom, 4)
        .accessibilityLabel("播放进度")
    }

    private func togglePlayback() {
        playback.toggle()
    }
}

private struct TheaterVideoBackdrop: View {
    let drama: Drama

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.22, green: 0.18, blue: 0.2), .black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let url = drama.coverURL {
                CachedRemoteImage(url: url) { Color.clear }
            }
        }.clipped()
    }
}

private struct TheaterPlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        view.layerPlayer.videoGravity = .resizeAspectFill
        view.layerPlayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerSurface, context: Context) { view.layerPlayer.player = player }
    static func dismantleUIView(_ view: PlayerSurface, coordinator: ()) { view.layerPlayer.player = nil }

    final class PlayerSurface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var layerPlayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

private struct TheaterEpisodesSheet: View {
    let drama: Drama
    let onSelect: (Episode) -> Void
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [Episode] = []
    @State private var error: String?
    @State private var isLoading = true
    @State private var isUnlocking = false
    @State private var pendingUnlock: Episode?
    @State private var unlockError: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(drama.title).font(.title3.bold())
                    Text("共\(drama.episodeCount)集").font(.subheadline).foregroundStyle(.secondary)
                    if isLoading { ProgressView("加载选集…") }
                    if isUnlocking { ProgressView("正在解锁…") }
                    if let error {
                        Text(error).foregroundStyle(.secondary)
                        Button("重试") { attempt += 1 }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 12) {
                        ForEach(episodes) { episode in
                            Button {
                                if episode.requiresCoinUnlock { pendingUnlock = episode }
                                else { onSelect(episode) }
                            } label: {
                                HStack(spacing: 3) {
                                    Text("\(episode.number)")
                                    if episode.requiresCoinUnlock {
                                        Text("\(episode.unlockCoin)币").font(.caption2)
                                    } else if episode.requiresMembership {
                                        Image(systemName: "lock.fill").font(.caption2)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .disabled(isUnlocking)
                            .accessibilityLabel("第\(episode.number)集\(episode.requiresCoinUnlock ? "，需\(episode.unlockCoin)金币解锁" : "")")
                        }
                    }
                }.padding()
            }
            .screenBackground()
            .navigationTitle("选集").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("解锁本集", isPresented: Binding(
                get: { pendingUnlock != nil },
                set: { if !$0 { pendingUnlock = nil } }
            )) {
                Button("花\(pendingUnlock?.unlockCoin ?? 0)金币解锁") {
                    let episode = pendingUnlock
                    pendingUnlock = nil
                    Task { await unlockEpisode(episode) }
                }
                Button("取消", role: .cancel) { pendingUnlock = nil }
            } message: {
                Text("确认后将从钱包扣除金币。")
            }
            .alert("解锁失败", isPresented: Binding(
                get: { unlockError != nil },
                set: { if !$0 { unlockError = nil } }
            )) {
                Button("知道了", role: .cancel) { unlockError = nil }
            } message: {
                Text(unlockError ?? "请稍后重试。")
            }
            .task(id: attempt) {
                isLoading = true
                error = nil
                defer { isLoading = false }
                do { episodes = try await app.repository.fetchEpisodes(dramaID: drama.id) }
                catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private func unlockEpisode(_ episode: Episode?) async {
        guard let episode,
              let dramaID = Int64(drama.id), let episodeID = Int64(episode.id) else {
            unlockError = "剧集信息无效。"
            return
        }
        isUnlocking = true
        defer { isUnlocking = false }
        do {
            let result = try await app.network.request(AppAPI.v1DramaEpisodeUnlock,
                body: .init(dramaId: dramaID, episodeId: episodeID), unwrapEnvelope: true)
            guard result.canWatch == true || result.unlocked == true else {
                throw CatalogError.episodeLocked
            }
            episodes = try await app.repository.fetchEpisodes(dramaID: drama.id)
            guard let unlocked = episodes.first(where: { $0.id == episode.id }),
                  !unlocked.requiresCoinUnlock else { throw CatalogError.episodeLocked }
            onSelect(unlocked)
        } catch {
            unlockError = error.localizedDescription
        }
    }
}
