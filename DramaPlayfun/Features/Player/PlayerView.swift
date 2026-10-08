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
    @State private var showMembership = false
    @State private var feedbackEpisode: Episode?
    @State private var isSubmittingFeedback = false
    @State private var feedbackSubmitted = false
    @State private var controlVisible = false
    @State private var rate: Float = 1
    @State private var optionsKind: PlayerOptionsKind?
    @State private var subtitleGroup: AVMediaSelectionGroup?
    @State private var subtitleItemID: ObjectIdentifier?
    @State private var selectedSubtitleID: String?
    @State private var preferredSubtitleLanguage: String?
    @State private var isLoadingSubtitles = false
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
                if controlVisible && isVisible && !playback.isPaused && !playback.hasEnded {
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
            presentUnlockIfNeeded()
            updatePlayback()
        }
        .onChange(of: selectedID) { _, _ in
            presentUnlockIfNeeded()
            updatePlayback()
        }
        .onChange(of: isVisible) { _, _ in updatePlayback() }
        .onChange(of: playback.states[selectedID ?? ""]) { _, state in
            if state == .ready { applyMediaOptions() }
        }
        .task(id: mediaItemID) { await loadSubtitleOptions() }
        .onChange(of: playback.hasEnded) { _, ended in
            guard ended, isVisible, let index = store.items.firstIndex(where: { $0.id == selectedID }),
                  store.items.indices.contains(index + 1) else { return }
            selectedID = store.items[index + 1].id
        }
        .onDisappear { playback.reset() }
        .overlay {
            if let kind = optionsKind {
                PlayerOptionsSheet(kind: kind, options: options(for: kind), selectedID: selectedOptionID(for: kind),
                    isLoading: kind == .subtitles && isLoadingSubtitles,
                    onClose: { optionsKind = nil }, onSelect: { selectOption($0, kind: kind) })
            }
            if showEpisodes {
                PlayerEpisodesSheet(drama: currentItem?.drama ?? request.drama,
                    episodes: store.items.compactMap(\.firstEpisode), selectedID: currentItem?.firstEpisode?.id,
                    onClose: { showEpisodes = false }, onSelect: { episode in
                        if episode.requiresCoinUnlock { pendingUnlock = episode }
                        else { selectedID = episode.id; showEpisodes = false }
                    })
            }
        }
        .blur(radius: pendingUnlock == nil ? 0 : 8)
        .allowsHitTesting(pendingUnlock == nil)
        .accessibilityHidden(pendingUnlock != nil)
        .overlay {
            if let episode = pendingUnlock {
                PlayerUnlockDialog(episode: episode, isUnlocking: isUnlocking,
                    onClose: { pendingUnlock = nil },
                    onUnlock: { Task { await unlock(episode) } },
                    onMembership: { showMembership = true })
            }
        }
        .fullScreenCover(item: $shareItem) { DramaShareView(item: $0) }
        .sheet(isPresented: $showMembership, onDismiss: {
            Task { await refreshAfterMembership() }
        }) {
            NavigationStack {
                MembershipView().toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showMembership = false }
                    }
                }
            }
        }
        .alert("操作失败", isPresented: Binding(get: { unlockError != nil },
            set: { if !$0 { unlockError = nil } })) {
            Button("知道了", role: .cancel) { unlockError = nil }
        } message: { Text(unlockError ?? "") }
        .confirmationDialog("剧集反馈", isPresented: Binding(get: { feedbackEpisode != nil },
            set: { if !$0 { feedbackEpisode = nil } }), titleVisibility: .visible) {
            if let episode = feedbackEpisode {
                ForEach([("播放异常", "playback_abnormal"), ("内容低俗", "vulgar"),
                         ("侵权", "infringement"), ("其他", "other")], id: \.1) { title, code in
                    Button(title) { Task { await submitFeedback(episode, categoryCode: code) } }
                }
            }
            Button("取消", role: .cancel) { feedbackEpisode = nil }
        }
        .alert("反馈已提交", isPresented: $feedbackSubmitted) {
            Button("知道了", role: .cancel) { }
        } message: { Text("感谢你的反馈，我们会尽快处理。") }
    }

    private var isVisible: Bool { scenePhase == .active && !showEpisodes && optionsKind == nil && shareItem == nil && !isUnlocking && pendingUnlock == nil && !showMembership && feedbackEpisode == nil && !isSubmittingFeedback && !feedbackSubmitted }
    private var currentItem: TheaterFeedItem? { store.items.first(where: { $0.id == selectedID }) }
    private var mediaItem: AVPlayerItem? { playback.player(for: selectedID ?? "")?.currentItem }
    private var mediaItemID: ObjectIdentifier? { mediaItem.map(ObjectIdentifier.init) }
    private var subtitleTracks: [AVMediaSelectionOption] {
        (subtitleGroup?.options ?? []).filter { $0.mediaType == .subtitle }
    }

    private var header: some View {
        HStack {
            Button { playback.suspend(); dismiss() } label: {
                Image("PlayerBack").resizable().scaledToFit().frame(width: 24, height: 24)
                    .frame(width: 44, height: 44)
            }.accessibilityLabel("返回")
            Spacer()
            if !subtitleTracks.isEmpty {
                Button { optionsKind = .subtitles } label: {
                    Text("字幕").font(.system(size: 15)).padding(.horizontal, 7).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.6)))
                }
                .accessibilityIdentifier("player-subtitles")
                .accessibilityValue(options(for: .subtitles).first(where: { $0.id == selectedSubtitleID })?.title ?? "")
            }
            Menu {
                Button("反馈") { feedbackEpisode = currentItem?.firstEpisode }
                    .disabled(currentItem?.firstEpisode == nil || isSubmittingFeedback)
            } label: {
                Image("PlayerMore").resizable().scaledToFit().frame(width: 24, height: 24)
                    .frame(width: 44, height: 44)
            }.accessibilityLabel("更多").accessibilityIdentifier("player-more")
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
            Button { optionsKind = .quality } label: {
                HStack(spacing: 4) {
                    Image("PlayerQuality").resizable().scaledToFit().frame(width: 16, height: 16)
                    Text(quality == 0 ? "自动" : String(Int(quality)) + "P")
                }.padding(10).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }.accessibilityLabel("清晰度")
                .accessibilityIdentifier("player-quality")
                .accessibilityValue(quality == 0 ? "自动" : String(Int(quality)) + "P")
            Button { optionsKind = .speed } label: {
                Text("\(rate.formatted())x").padding(10)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }.accessibilityLabel("播放速度")
                .accessibilityIdentifier("player-speed")
                .accessibilityValue("\(rate.formatted())x")
        }.font(.system(size: 14)).padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.background)
    }

    private func updatePlayback() {
        playback.update(items: store.items, selectedID: selectedID, visible: isVisible)
        if playback.states[selectedID ?? ""] == .ready { applyMediaOptions() }
    }

    private func presentUnlockIfNeeded() {
        guard isReady else { return }
        pendingUnlock = currentItem?.firstEpisode.flatMap { $0.requiresCoinUnlock ? $0 : nil }
        if pendingUnlock != nil { optionsKind = nil }
    }

    private func refreshAfterMembership() async {
        await store.load()
        if let episode = pendingUnlock,
           let updated = store.items.first(where: { $0.firstEpisode?.id == episode.id })?.firstEpisode,
           !updated.requiresCoinUnlock {
            pendingUnlock = nil
            selectedID = updated.id
            showEpisodes = false
        }
        playback.reset()
        updatePlayback()
    }

    private func retry(_ item: TheaterFeedItem) {
        if item.firstEpisode?.requiresCoinUnlock == true { pendingUnlock = item.firstEpisode }
        else { playback.reset(); updatePlayback() }
    }

    private func submitFeedback(_ episode: Episode, categoryCode: String) async {
        guard !isSubmittingFeedback else { return }
        isSubmittingFeedback = true
        feedbackEpisode = nil
        defer { isSubmittingFeedback = false }
        do {
            try await store.reportFeedback(episode, categoryCode: categoryCode)
            feedbackSubmitted = true
        } catch { unlockError = error.localizedDescription }
    }

    private func unlock(_ episode: Episode) async {
        guard !isUnlocking else { return }
        isUnlocking = true
        defer { isUnlocking = false; updatePlayback() }
        do {
            try await store.unlock(episode)
            playback.reset()
            pendingUnlock = nil
            selectedID = episode.id
            showEpisodes = false
        } catch { unlockError = error.localizedDescription }
    }

    private func applyMediaOptions() {
        guard let item = mediaItem else { return }
        item.preferredMaximumResolution = quality == 0 ? .zero : CGSize(width: quality * 16 / 9, height: quality)
        guard subtitleItemID == ObjectIdentifier(item), let group = subtitleGroup,
              let id = selectedSubtitleID, let index = Int(id), subtitleTracks.indices.contains(index) else { return }
        item.select(subtitleTracks[index], in: group)
    }

    private func options(for kind: PlayerOptionsKind) -> [PlayerOption] {
        switch kind {
        case .quality:
            return [PlayerOption(id: "0", title: "自动"), PlayerOption(id: "480", title: "480P"),
                PlayerOption(id: "720", title: "720P"), PlayerOption(id: "1080", title: "1080P", isVIP: true)]
        case .speed:
            return ["0.75", "1", "1.5", "2", "3"].map { PlayerOption(id: $0, title: "\($0)x") }
        case .subtitles:
            return subtitleTracks.enumerated().map { index, track in
                PlayerOption(id: String(index), title: subtitleTitle(track))
            }
        }
    }

    private func selectedOptionID(for kind: PlayerOptionsKind) -> String? {
        switch kind {
        case .quality: String(Int(quality))
        case .speed: rate.formatted(.number.locale(Locale(identifier: "en_US_POSIX")))
        case .subtitles: selectedSubtitleID
        }
    }

    private func selectOption(_ option: PlayerOption, kind: PlayerOptionsKind) {
        switch kind {
        case .quality:
            guard let value = Double(option.id) else { return }
            quality = value
        case .speed:
            guard let value = Float(option.id) else { return }
            rate = value
            playback.playbackRate = value
        case .subtitles:
            guard let index = Int(option.id), subtitleTracks.indices.contains(index) else { return }
            selectedSubtitleID = option.id
            preferredSubtitleLanguage = subtitleLanguage(subtitleTracks[index])
        }
        applyMediaOptions()
        optionsKind = nil
    }

    private func loadSubtitleOptions() async {
        subtitleGroup = nil
        selectedSubtitleID = nil
        subtitleItemID = nil
        guard let item = mediaItem else { isLoadingSubtitles = false; return }
        isLoadingSubtitles = true
        let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        guard !Task.isCancelled, item === mediaItem else { return }
        subtitleGroup = group
        subtitleItemID = ObjectIdentifier(item)
        if let group {
            let preferred = subtitleTracks.firstIndex { subtitleLanguage($0) == preferredSubtitleLanguage }
            let defaultIndex = group.defaultOption.flatMap { subtitleTracks.firstIndex(of: $0) }
            selectedSubtitleID = (preferred ?? defaultIndex ?? subtitleTracks.indices.first).map(String.init)
        }
        if subtitleTracks.isEmpty && optionsKind == .subtitles { optionsKind = nil }
        isLoadingSubtitles = false
        applyMediaOptions()
    }

    private func subtitleLanguage(_ option: AVMediaSelectionOption) -> String {
        option.extendedLanguageTag ?? option.locale?.identifier ?? option.displayName
    }

    private func subtitleTitle(_ option: AVMediaSelectionOption) -> String {
        let language = subtitleLanguage(option).lowercased().replacingOccurrences(of: "_", with: "-")
        switch language.split(separator: "-").first {
        case "zh": return "中文"
        case "en": return "English"
        case "ja": return "にほんご"
        case "ko": return "한국어"
        default: return option.displayName
        }
    }
}
