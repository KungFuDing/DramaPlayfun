import SwiftUI
import AVFoundation

struct PlayerView: View {
    let request: PlaybackRequest
    @State private var store: DramaPlaybackStore
    @State private var playback: TheaterPlayerPool
    @State private var isReady = false
    @State private var selectedID: String?
    @State private var attempt = 0
    @State private var showEpisodes = false
    @State private var shareItem: TheaterFeedItem?
    @State private var pendingUnlock: Episode?
    @State private var unlockError: String?
    @State private var isUnlocking = false
    @State private var controlVisible = false
    @State private var rate: Float = 1
    @State private var subtitlesEnabled = false
    @State private var quality: Double = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(request: PlaybackRequest, app: AppContainer) {
        self.request = request
        _store = State(initialValue: DramaPlaybackStore(drama: request.drama, network: app.network,
            repository: app.repository, library: app.library))
        _playback = State(initialValue: TheaterPlayerPool(library: app.library, cache: app.hlsCache,
            progressReporter: TheaterProgressReporter(network: app.network), resumesProgress: true))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if store.items.isEmpty || !isReady {
                    VStack(spacing: 16) {
                        if store.isLoading || !isReady { ProgressView("正在加载剧集…") }
                        else {
                            Text(store.errorMessage ?? "暂无剧集")
                            Button("重试") { attempt += 1 }
                        }
                    }.padding(32)
                } else {
                    ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(store.items) { item in
                                TheaterVideoPage(item: item, playback: playback,
                                    isActive: selectedID == item.id && isVisible,
                                    topInset: geometry.safeAreaInsets.top,
                                    onRetry: { retry(item) }, onEpisodes: { showEpisodes = true },
                                    onShare: { shareItem = item }, isDetail: true,
                                    onLike: { try await store.toggleLike(item.id) },
                                    onFavorite: { try await store.toggleFavorite() })
                                    .overlay {
                                        if item.firstEpisode?.requiresCoinUnlock == true {
                                            Button("解锁第\(item.firstEpisode?.number ?? 1)集") {
                                                pendingUnlock = item.firstEpisode
                                            }.buttonStyle(.borderedProminent).tint(Theme.accent)
                                        }
                                    }
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .id(item.id)
                            }
                        }.scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                    .scrollPosition(id: $selectedID, anchor: .top)
                    .accessibilityIdentifier("player-episode-feed")
                    .accessibilityValue("第\(currentItem?.firstEpisode?.number ?? 1)集")
                    .task {
                        await Task.yield()
                        if let selectedID { proxy.scrollTo(selectedID, anchor: .top) }
                    }
                    }
                }
                if controlVisible && !playback.isPaused && !playback.hasEnded {
                    Button { playback.toggle() } label: {
                        ZStack {
                            Image("PlayerPauseBackground").resizable().scaledToFit()
                            Image("PlayerPause").resizable().scaledToFit().frame(width: 28, height: 28)
                        }.frame(width: 68, height: 68)
                    }.accessibilityLabel("暂停")
                }
            }
            .overlay(alignment: .top) { header.padding(.top, max(geometry.safeAreaInsets.top, 54) + 8) }
            .simultaneousGesture(TapGesture().onEnded { controlVisible = true })
            .task(id: controlVisible) {
                guard controlVisible else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { controlVisible = false }
            }
        }
        .ignoresSafeArea(edges: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
        .background(.black)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task(id: attempt) {
            isReady = false
            playback.reset()
            await store.load()
            selectedID = store.initialID(request: request)
            isReady = true
            updatePlayback()
        }
        .onChange(of: selectedID) { _, _ in updatePlayback() }
        .onChange(of: isVisible) { _, _ in updatePlayback() }
        .onChange(of: playback.states[selectedID ?? ""]) { _, state in
            if state == .ready { applyMediaOptions() }
        }
        .onChange(of: playback.hasEnded) { _, ended in
            guard ended, isVisible, let index = store.items.firstIndex(where: { $0.id == selectedID }),
                  store.items.indices.contains(index + 1) else { return }
            selectedID = store.items[index + 1].id
        }
        .onDisappear { playback.reset() }
        .sheet(isPresented: $showEpisodes) { episodesSheet }
        .fullScreenCover(item: $shareItem) { DramaShareView(item: $0) }
        .alert("解锁本集", isPresented: Binding(get: { pendingUnlock != nil },
            set: { if !$0 { pendingUnlock = nil } })) {
            Button("花\(pendingUnlock?.unlockCoin ?? 0)金币解锁") {
                guard let episode = pendingUnlock else { return }
                pendingUnlock = nil
                Task { await unlock(episode) }
            }
            Button("取消", role: .cancel) { pendingUnlock = nil }
        } message: { Text("确认后将从钱包扣除金币。") }
        .alert("操作失败", isPresented: Binding(get: { unlockError != nil },
            set: { if !$0 { unlockError = nil } })) {
            Button("知道了", role: .cancel) { unlockError = nil }
        } message: { Text(unlockError ?? "") }
    }

    private var isVisible: Bool { scenePhase == .active && !showEpisodes && shareItem == nil && !isUnlocking && pendingUnlock == nil }
    private var currentItem: TheaterFeedItem? { store.items.first(where: { $0.id == selectedID }) }

    private var header: some View {
        HStack {
            Button { playback.suspend(); dismiss() } label: {
                Image("PlayerBack").resizable().scaledToFit().frame(width: 24, height: 24)
                    .frame(width: 44, height: 44)
            }.accessibilityLabel("返回")
            Spacer()
            Button {
                subtitlesEnabled.toggle()
                applyMediaOptions()
            } label: {
                Text("字幕").font(.system(size: 15)).padding(.horizontal, 7).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(subtitlesEnabled ? Theme.accent : .white.opacity(0.6)))
            }.accessibilityValue(subtitlesEnabled ? "已开启" : "已关闭")
            Menu {
                Button("选集") { showEpisodes = true }
                Button("分享") { shareItem = currentItem }
                Button("重新加载") { attempt += 1 }
            } label: {
                Image("PlayerMore").resizable().scaledToFit().frame(width: 24, height: 24)
                    .frame(width: 44, height: 44)
            }.accessibilityLabel("更多")
        }.padding(.horizontal, 8)
    }

    private var bottomControls: some View {
        HStack(spacing: 10) {
            Button { showEpisodes = true } label: {
                HStack {
                    Text("选集·全\(store.items.count)集").lineLimit(1)
                    Spacer(minLength: 4)
                    Image("PlayerEpisodesChevron").resizable().scaledToFit().frame(width: 16, height: 16)
                }.padding(10).frame(maxWidth: .infinity)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }.accessibilityIdentifier("player-episodes")
            Menu {
                Button("自动") { quality = 0; applyMediaOptions() }
                Button("720P（最高）") { quality = 720; applyMediaOptions() }
                Button("1080P（最高）") { quality = 1080; applyMediaOptions() }
            } label: {
                HStack(spacing: 4) {
                    Image("PlayerQuality").resizable().scaledToFit().frame(width: 16, height: 16)
                    Text(quality == 0 ? "自动" : "\(Int(quality))P")
                }.padding(10).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }.accessibilityLabel("清晰度")
            Menu {
                ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { value in
                    Button("\(value.formatted())x") { rate = value; playback.playbackRate = value }
                }
            } label: {
                Text("\(rate.formatted())x").padding(10)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }.accessibilityLabel("播放速度")
        }.font(.system(size: 14)).padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.background)
    }

    private var episodesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(currentItem?.drama.title ?? request.drama.title).font(.title3.bold())
                    if isUnlocking { ProgressView("正在解锁…") }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 56))], spacing: 12) {
                        ForEach(store.items) { item in
                            if let episode = item.firstEpisode {
                                Button {
                                    if episode.requiresCoinUnlock { showEpisodes = false; pendingUnlock = episode }
                                    else { selectedID = item.id; showEpisodes = false }
                                } label: {
                                    VStack(spacing: 4) {
                                        Text("\(episode.number)")
                                        if episode.requiresCoinUnlock { Text("\(episode.unlockCoin)币").font(.caption2) }
                                    }.frame(maxWidth: .infinity, minHeight: 48)
                                        .background(selectedID == item.id ? Theme.accent.opacity(0.3) : Theme.surface,
                                            in: RoundedRectangle(cornerRadius: 8))
                                }.disabled(isUnlocking)
                                    .accessibilityLabel("第\(episode.number)集")
                            }
                        }
                    }
                }.padding()
            }.screenBackground().navigationTitle("选集").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showEpisodes = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func updatePlayback() {
        playback.update(items: store.items, selectedID: selectedID, visible: isVisible)
        if playback.states[selectedID ?? ""] == .ready { applyMediaOptions() }
    }

    private func retry(_ item: TheaterFeedItem) {
        if item.firstEpisode?.requiresCoinUnlock == true { pendingUnlock = item.firstEpisode }
        else { playback.reset(); updatePlayback() }
    }

    private func unlock(_ episode: Episode) async {
        isUnlocking = true
        defer { isUnlocking = false; updatePlayback() }
        do {
            try await store.unlock(episode)
            playback.reset()
            selectedID = episode.id
            showEpisodes = false
        } catch { unlockError = error.localizedDescription }
    }

    private func applyMediaOptions() {
        guard let item = playback.player(for: selectedID ?? "")?.currentItem else { return }
        item.preferredMaximumResolution = quality == 0 ? .zero : CGSize(width: quality * 16 / 9, height: quality)
        Task { @MainActor in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            item.select(subtitlesEnabled ? group.options.first : nil, in: group)
        }
    }
}
