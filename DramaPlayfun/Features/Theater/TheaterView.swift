import SwiftUI
import AVFoundation

struct TheaterView: View {
    @Environment(AppContainer.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedID: Drama.ID?
    @State private var shareItem: TheaterFeedItem?
    @State private var replayAfterPlaybackID: Drama.ID?
    @State private var continuation: PlaybackPreparation?
    @State private var checkInError: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if app.theaterFeed.items.isEmpty, app.theaterFeed.errorMessage != nil {
                    NetworkFailureView { await app.theaterFeed.reload() }
                } else if app.theaterFeed.items.isEmpty {
                    VStack(spacing: 20) {
                        if app.theaterFeed.isLoading || !app.theaterFeed.hasLoaded {
                            ProgressView("正在加载剧场…")
                        } else {
                            ContentUnavailableView("暂无剧集", systemImage: "play.rectangle",
                                description: Text("精彩故事即将上线"))
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
                                    onRetry: { app.theaterPlayback.retry(item.id) },
                                    onEpisodes: {
                                        replayAfterPlaybackID = item.id
                                        router.openPlayback(item.drama, episode: item.firstEpisode)
                                    },
                                    onShare: { shareItem = item },
                                    onDetail: { router.paths[.theater, default: []].append(.shortDrama(item.drama)) }
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
            .overlay(alignment: .top) {
                if !app.theaterFeed.items.isEmpty && app.welfare.shouldShowSignPopup {
                    checkInBanner
                        .padding(.horizontal, 14)
                        .padding(.top, max(geometry.safeAreaInsets.top + 16, 76))
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .background(.black)
        .toolbar(.hidden, for: .navigationBar)
        .task { await app.theaterFeed.loadIfNeeded() }
        .task(id: isTheaterVisible) {
            if isTheaterVisible { await app.welfare.reloadSignPopupStatus() }
        }
        .task(id: playbackKey) {
            if !isTheaterVisible || continuation?.store.drama.id != selectedID {
                cancelContinuation()
            }
            if isTheaterVisible, replayAfterPlaybackID == selectedID, replayAfterPlaybackID != nil {
                app.theaterPlayback.reset()
                replayAfterPlaybackID = nil
            }
            app.theaterPlayback.update(items: app.theaterFeed.items,
                                       selectedID: selectedID, visible: isTheaterVisible)
            guard isTheaterVisible else { return }
            while !Task.isCancelled {
                prepareContinuationIfNeeded()
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
            }
        }
        .onChange(of: app.theaterPlayback.hasEnded) { _, ended in
            guard ended, isTheaterVisible,
                  let item = app.theaterFeed.items.first(where: { $0.id == selectedID }),
                  item.firstEpisode?.number == 1, item.drama.episodeCount > 1 else { return }
            replayAfterPlaybackID = item.id
            let prepared = continuation
            prepared?.handoff()
            continuation = nil
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                router.openPlayback(item.drama, episodeNumber: 2, preparation: prepared)
            }
        }
        .onChange(of: app.theaterFeed.items.map(\.id), initial: true) { _, ids in
            if !ids.contains(where: { $0 == selectedID }) { selectedID = ids.first }
        }
        .onChange(of: selectedID) { _, id in
            guard let index = app.theaterFeed.items.firstIndex(where: { $0.id == id }),
                  index >= app.theaterFeed.items.count - 3 else { return }
            Task { await app.theaterFeed.loadMore() }
        }
        .onDisappear {
            cancelContinuation()
            app.theaterPlayback.suspend()
        }
        .fullScreenCover(item: $shareItem) { item in
            DramaShareView(item: item)
        }
        .alert("签到失败", isPresented: Binding(get: { checkInError != nil },
            set: { if !$0 { checkInError = nil } })) {
            Button("知道了", role: .cancel) { checkInError = nil }
        } message: { Text(checkInError ?? "") }
    }

    private var checkInBanner: some View {
        HStack(spacing: 0) {
            Image("TheaterCheckInGift")
                .renderingMode(.original).resizable().scaledToFit()
                .frame(width: 24, height: 24)
                .frame(width: 34)
            HStack(spacing: 6) {
                Text("今日签到").foregroundStyle(.white)
                if let coins = app.welfare.signPopupRewardCoin {
                    Text("+\(coins)金币").foregroundStyle(Color(red: 1, green: 194 / 255, blue: 56 / 255))
                }
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.leading, 8)
            Spacer(minLength: 0)
            Button {
                Task {
                    await app.welfare.signIn(popupScene: "home_enter")
                    checkInError = app.welfare.error
                }
            } label: {
                Text("领取")
                    .font(.system(size: 12)).foregroundStyle(Color(red: 0.2, green: 0.16, blue: 0.08))
                    .fixedSize()
                    .frame(width: 48, height: 29)
                    .background(Color(red: 1, green: 194 / 255, blue: 56 / 255), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(app.welfare.isSigning || app.welfare.isLoading || app.welfare.isLoadingSignPopupStatus)
            .accessibilityIdentifier("theater-check-in-receive")
            .padding(.trailing, 4)
        }
        .frame(width: 210, height: 37)
        .background {
            LinearGradient(colors: [Color(red: 146 / 255, green: 106 / 255, blue: 39 / 255),
                                    Color(red: 84 / 255, green: 46 / 255, blue: 33 / 255)],
                           startPoint: .leading, endPoint: .trailing)
                .overlay(alignment: .leading) {
                    TheaterCheckInGiftBackground()
                        .fill(Color(red: 201 / 255, green: 153 / 255, blue: 49 / 255))
                        .frame(width: 46)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theater-check-in")
    }

    private var isTheaterVisible: Bool {
        router.selectedTab == .theater && scenePhase == .active && shareItem == nil
            && app.appUpdate.notice == nil
            && router.playback == nil && !router.membershipPresented && (router.paths[.theater] ?? []).isEmpty
    }

    private var playbackKey: String {
        "\(selectedID ?? "none")|\(isTheaterVisible)|\(app.theaterFeed.items.map(\.id).joined(separator: ","))"
    }

    private func prepareContinuationIfNeeded() {
        guard isTheaterVisible, app.theaterPlayback.isApproachingEnd,
              let item = app.theaterFeed.items.first(where: { $0.id == selectedID }),
              item.firstEpisode?.number == 1, item.drama.episodeCount > 1 else {
            // Keep a completed handoff intact while the presentation begins.
            if !app.theaterPlayback.hasEnded { cancelContinuation() }
            return
        }
        if continuation == nil {
            let prepared = PlaybackPreparation(drama: item.drama, app: app)
            continuation = prepared
            prepared.beginLoading()
        }
        let canPreload = app.theaterPlayback.canPreloadContinuation
        app.theaterPlayback.prioritizeContinuation(canPreload)
        if canPreload { continuation?.preloadVideo() }
        else { continuation?.stopPreloadingVideo() }
    }

    private func cancelContinuation() {
        continuation?.cancel()
        continuation = nil
        app.theaterPlayback.prioritizeContinuation(false)
    }

}

private struct TheaterCheckInGiftBackground: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: rect.origin)
        path.addLine(to: CGPoint(x: rect.maxX * 0.5, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                      control1: CGPoint(x: rect.maxX * 0.83, y: rect.minY),
                      control2: CGPoint(x: rect.maxX * 0.62, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct TheaterVideoPage: View {
    let item: TheaterFeedItem
    let playback: TheaterPlayerPool
    let isActive: Bool
    let onRetry: () -> Void
    let onEpisodes: () -> Void
    let onShare: () -> Void
    let onDetail: () -> Void
    var isDetail = false
    var onLike: (() async throws -> Void)?
    var onFavorite: (() async throws -> Void)?
    @Environment(AppContainer.self) private var app
    @State private var isExpanded = false
    @State private var summaryHeight: CGFloat = 20
    @State private var interactionError: String?
    private var isLiked: Bool { item.isFirstEpisodeLiked }

    private var drama: Drama { item.drama }

    init(item: TheaterFeedItem, playback: TheaterPlayerPool, isActive: Bool,
         onRetry: @escaping () -> Void, onEpisodes: @escaping () -> Void,
         onShare: @escaping () -> Void, onDetail: @escaping () -> Void, isDetail: Bool = false,
         onLike: (() async throws -> Void)? = nil, onFavorite: (() async throws -> Void)? = nil) {
        self.item = item
        self.playback = playback
        self.isActive = isActive
        self.onRetry = onRetry
        self.onEpisodes = onEpisodes
        self.onShare = onShare
        self.onDetail = onDetail
        self.isDetail = isDetail
        self.onLike = onLike
        self.onFavorite = onFavorite
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
                Spacer(minLength: 24)
                HStack(alignment: .bottom, spacing: 16) {
                    metadata.frame(maxWidth: .infinity, alignment: .leading)
                    actions.padding(.bottom, 64)
                }
                .zIndex(1) // Keep introduction buttons above the expanded progress touch area.
                progressBar
            }
            .padding(.horizontal, 14)
        }
        .clipped()
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(isDetail ? "player-episode-\(item.firstEpisode?.number ?? 1)" : "theater-video-\(drama.id)")
        .alert("操作失败", isPresented: Binding(get: { interactionError != nil },
            set: { if !$0 { interactionError = nil } })) {
            Button("知道了", role: .cancel) { interactionError = nil }
        } message: { Text(interactionError ?? "") }
    }

    @ViewBuilder private var playbackStatus: some View {
        if isDetail && item.firstEpisode?.requiresCoinUnlock == true {
            EmptyView()
        } else if case .unavailable(let error) = playback.states[item.id] {
            VStack(spacing: 12) {
                Image(systemName: "play.slash").font(.largeTitle)
                Text(error).font(.subheadline).multilineTextAlignment(.center)
                Button("重试", action: onRetry).buttonStyle(.bordered)
            }
            .padding(24).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 48)
        } else if isActive && (playback.states[item.id] != .ready || playback.isBuffering) {
            ProgressView().tint(.white)
        } else if isActive && (playback.isPaused || playback.hasEnded) {
            Button { togglePlayback() } label: {
                if isDetail {
                    ZStack {
                        Image("PlayerPlayBackground").resizable().scaledToFit()
                        Image("PlayerPlay").resizable().scaledToFit().frame(width: 28, height: 28)
                    }.frame(width: 68, height: 68)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 56)).foregroundStyle(.white.opacity(0.85))
                }
            }.accessibilityLabel("播放视频")
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onDetail) {
                Text(drama.title).font(.system(size: 18, weight: .semibold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("drama-detail-title-\(drama.id)")
            HStack(spacing: 6) {
                tag("共\(drama.episodeCount)集")
                tag("热度\(drama.heat.formatted())")
                tag(drama.tagNames.first ?? drama.category.rawValue)
            }
            if !isDetail {
                Button(action: onEpisodes) {
                    HStack(spacing: 6) {
                        Image("TheaterEpisodes").renderingMode(.original)
                            .resizable().scaledToFit().frame(width: 20, height: 20)
                        Text("更多剧集(第1集/共\(drama.episodeCount)集)").lineLimit(1).minimumScaleFactor(0.75)
                        Image("TheaterChevron").renderingMode(.original)
                            .resizable().scaledToFit().frame(width: 16, height: 16)
                    }.font(.subheadline).padding(10)
                        .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                }.accessibilityLabel("更多剧集，\(drama.title)")
            }
            HStack(alignment: .bottom, spacing: 8) {
                if isExpanded {
                    ScrollView {
                        Text("第\(item.firstEpisode?.number ?? 1)集 | \(drama.summary)")
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
                    Text("第\(item.firstEpisode?.number ?? 1)集 | \(drama.summary)").lineLimit(1)
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
            Button {
                Task {
                    do {
                        if let onLike { try await onLike() }
                        else { try await app.theaterFeed.toggleLike(item.id) }
                    }
                    catch { interactionError = error.localizedDescription }
                }
            } label: {
                actionLabel(isLiked ? "TheaterLikeSelected" : "TheaterLike",
                            title: isDetail ? item.firstEpisodeLikeCount.formatted() : (isLiked ? "已赞" : "点赞"))
            }.disabled(app.theaterFeed.likingIDs.contains(item.id))
                .accessibilityLabel(isLiked ? "取消点赞" : "点赞")
                .accessibilityIdentifier("theater-like-\(item.id)")
            Button {
                Task {
                    do {
                        if let onFavorite { try await onFavorite() }
                        else { try await app.theaterFeed.toggleFavorite(item.id, library: app.library) }
                    }
                    catch { interactionError = error.localizedDescription }
                }
            } label: {
                actionLabel(item.isFavorited ? "TheaterFavoriteSelected" : "TheaterFavorite",
                            title: isDetail ? (item.favoriteCount ?? drama.heat).formatted() : (item.isFavorited ? "已收藏" : "收藏"))
            }.disabled(app.theaterFeed.favoritingIDs.contains(item.id))
                .accessibilityLabel(item.isFavorited ? "取消收藏" : "收藏")
                .accessibilityIdentifier("theater-favorite-\(item.id)")
            Button(action: onShare) {
                actionLabel("TheaterShare", title: "分享")
            }.accessibilityIdentifier("theater-share-\(item.id)")
        }
        .frame(width: 48)
        .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
    }

    private func actionLabel(_ asset: String, title: String) -> some View {
        VStack(spacing: 6) {
            Image(asset).renderingMode(.original)
                .resizable().scaledToFit().frame(width: 32, height: 32)
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.85))
        }.frame(minWidth: 44, minHeight: 54)
    }

    private var progressBar: some View {
        PlaybackProgressBar(playback: playback, itemID: item.id, isActive: isActive,
            identifier: isDetail ? "player-progress-\(item.firstEpisode?.number ?? 1)" : "theater-progress-\(item.id)")
    }

    private func togglePlayback() {
        playback.toggle()
    }
}

struct TheaterVideoBackdrop: View {
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

struct TheaterPlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        view.layerPlayer.videoGravity = .resizeAspectFill
        view.layerPlayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerSurface, context: Context) {
        if view.layerPlayer.player !== player { view.layerPlayer.player = player }
    }
    static func dismantleUIView(_ view: PlayerSurface, coordinator: ()) { view.layerPlayer.player = nil }

    final class PlayerSurface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var layerPlayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
