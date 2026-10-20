import SwiftUI
import AVFoundation

struct PlayerView: View {
    let request: PlaybackRequest
    @State private var store: DramaPlaybackStore
    @State private var playback: TheaterPlayerPool
    @State private var unlockCoordinator: EpisodeUnlockCoordinator
    @State private var isReady = false
    @State private var selectedID: String?
    @State private var attempt = 0
    @State private var completedAttempt: Int?
    @State private var showEpisodes = false
    @State private var shareItem: TheaterFeedItem?
    @State private var pendingUnlock: Episode?
    @State private var unlockError: String?
    @State private var changingAutoUnlock = false
    @State private var unlockToast: String?
    @State private var membershipDestination: MembershipCategory?
    @State private var accessRevision = 0
    @State private var accessFailureID: String?
    @State private var isMounted = false
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
    @State private var selectedDetail: Drama?
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(request: PlaybackRequest, app: AppContainer) {
        self.request = request
        if let preparation = request.preparation {
            _store = State(initialValue: preparation.store)
            _unlockCoordinator = State(initialValue: EpisodeUnlockCoordinator(playback: preparation.store,
                wallet: app.wallet, profile: app.profile, membership: app.membership))
            _playback = State(initialValue: preparation.playback)
            let loaded = !preparation.store.items.isEmpty
            _isReady = State(initialValue: loaded)
            _selectedID = State(initialValue: preparation.store.initialID(request: request))
            _completedAttempt = State(initialValue: loaded ? 0 : nil)
            return
        }
        let store = DramaPlaybackStore(drama: request.drama, network: app.network,
            repository: app.repository, library: app.library, detailCache: app.playbackDetails)
        _store = State(initialValue: store)
        _unlockCoordinator = State(initialValue: EpisodeUnlockCoordinator(playback: store,
            wallet: app.wallet, profile: app.profile, membership: app.membership))
        _playback = State(initialValue: TheaterPlayerPool(library: app.library, cache: app.hlsCache,
            progressReporter: TheaterProgressReporter(network: app.network),
            resumesProgress: !request.startsFromBeginning && request.startPosition == nil,
            initialPosition: request.startPosition,
            refreshURLs: { item in try await store.refreshPlaybackURLs(for: item) }))
    }

    var body: some View {
        playerContent
            .toolbar(.hidden, for: .navigationBar, .tabBar)
            .navigationBackGesture(isEnabled: !showEpisodes && optionsKind == nil && pendingUnlock == nil)
            .navigationDestination(item: $selectedDetail) { drama in
                ShortDramaDetailView(drama: drama, app: app) { id, favorite, count in
                    store.applyFavorite(id, isFavorite: favorite, count: count)
                    app.theaterFeed.applyFavorite(id, isFavorite: favorite, count: count)
                }
            }
    }

    private var playerContent: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if store.items.isEmpty || !isReady {
                    VStack(spacing: 16) {
                        if store.isLoading || !isReady { ProgressView(L10n.tr("正在加载剧集…")) }
                        else {
                            Text(store.errorMessage ?? L10n.tr("player.no_episodes"))
                            Button(L10n.tr("重试")) { attempt += 1 }
                        }
                    }.padding(32)
                } else {
                    ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(store.items) { item in
                                episodePage(item)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .contentShape(Rectangle())
                                    .id(item.id)
                            }
                        }.scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                    .scrollPosition(id: $selectedID, anchor: .top)
                    .accessibilityIdentifier("player-episode-feed")
                    .accessibilityValue(L10n.tr("第%d集", currentItem?.firstEpisode?.number ?? 1))
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
                    }.accessibilityLabel(L10n.tr("暂停"))
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
            if isReady && completedAttempt == attempt {
                updatePlayback()
                return
            }
            isReady = false
            if attempt == 0, let preparation = request.preparation {
                await preparation.load()
                // A speculative request can fail; entry gets one normal loading attempt.
                if store.items.isEmpty && !Task.isCancelled { await store.load() }
            } else {
                playback.reset()
                await store.load(forceRefresh: attempt > 0)
            }
            guard !Task.isCancelled else { return }
            selectedID = store.initialID(request: request)
            isReady = true
            completedAttempt = attempt
            updatePlayback()
        }
        .onChange(of: selectedID) { _, _ in
            pendingUnlock = nil
            unlockToast = nil
            accessFailureID = nil
            updatePlayback()
        }
        .task(id: accessTaskID) {
            guard canResolveAccess, let episode = currentItem?.firstEpisode,
                  !episode.canPlayWithoutValidation else { return }
            do { try await Task.sleep(for: .milliseconds(220)) }
            catch { return }
            await resolveAccess(episode, automatically: true)
        }
        .task(id: isReady) {
            guard isReady else { return }
            await store.revalidateDetails()
        }
        .task(id: accessExpirationID) {
            guard canResolveAccess, let deadline = store.accessDeadline(for: currentItem?.firstEpisode?.id) else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            updatePlayback()
        }
        .onChange(of: store.contentRevision) { _, _ in updatePlayback() }
        .onChange(of: isVisible) { _, _ in updatePlayback() }
        .onChange(of: isPreparationActive) { _, _ in updatePlayback() }
        .onChange(of: playback.states[selectedID ?? ""]) { _, state in
            if state == .ready { applyMediaOptions() }
        }
        .task(id: mediaItemID) { await loadSubtitleOptions() }
        .onChange(of: playback.hasEnded) { _, ended in
            guard ended, isVisible, app.profile.autoPlaysNext,
                  let index = store.items.firstIndex(where: { $0.id == selectedID }),
                  store.items.indices.contains(index + 1) else { return }
            selectedID = store.items[index + 1].id
        }
        .onAppear { isMounted = true }
        .onDisappear {
            isMounted = false
            if selectedDetail == nil { playback.reset() } else { playback.suspend() }
        }
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
                        selectedID = episode.id
                        showEpisodes = false
                    })
            }
        }
        .overlay(alignment: .bottom) {
            if let unlockToast {
                Text(unlockToast).font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.bottom, 72)
                    .accessibilityIdentifier("player-unlock-toast")
                    .allowsHitTesting(false)
            }
        }
        .task(id: unlockToast) {
            guard unlockToast != nil else { return }
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            unlockToast = nil
        }
        .overlay {
            if let episode = pendingUnlock {
                PlayerUnlockConfirmationSheet(drama: currentItem?.drama ?? request.drama,
                    episode: episode, balanceText: app.wallet.balanceText,
                    autoUnlocksNext: app.profile.autoPlaysNext,
                    isUpdatingAutoUnlock: changingAutoUnlock,
                    isUnlocking: unlockCoordinator.isUnlocking,
                    onClose: { pendingUnlock = nil },
                    onAutoUnlockChange: { enabled in Task { await setAutoUnlock(enabled) } },
                    onConfirm: { Task { await resolveAccess(episode, automatically: false) } },
                    onMembership: { openMembership(.weekly) })
            }
        }
        .fullScreenCover(item: $shareItem) { DramaShareView(item: $0) }
        .sheet(item: $membershipDestination, onDismiss: {
            Task { await refreshAfterMembership() }
        }) { category in
            NavigationStack {
                MembershipView(initialCategory: category, showsNavigationBar: true).toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.tr("完成")) { membershipDestination = nil }
                    }
                }
            }
        }
        .alert(L10n.tr("操作失败"), isPresented: Binding(get: { unlockError != nil },
            set: { if !$0 { unlockError = nil } })) {
            Button(L10n.tr("知道了"), role: .cancel) { unlockError = nil }
        } message: { Text(unlockError ?? "") }
        .confirmationDialog(L10n.tr("剧集反馈"), isPresented: Binding(get: { feedbackEpisode != nil },
            set: { if !$0 { feedbackEpisode = nil } }), titleVisibility: .visible) {
            if let episode = feedbackEpisode {
                ForEach([(L10n.tr("播放异常"), "playback_abnormal"), (L10n.tr("内容低俗"), "vulgar"),
                         (L10n.tr("侵权"), "infringement"), (L10n.tr("其他"), "other")], id: \.1) { title, code in
                    Button(title) { Task { await submitFeedback(episode, categoryCode: code) } }
                }
            }
            Button(L10n.tr("取消"), role: .cancel) { feedbackEpisode = nil }
        }
        .alert(L10n.tr("反馈已提交"), isPresented: $feedbackSubmitted) {
            Button(L10n.tr("知道了"), role: .cancel) { }
        } message: { Text(L10n.tr("感谢你的反馈，我们会尽快处理。")) }
    }

    private func episodePage(_ item: TheaterFeedItem) -> some View {
        let validating = item.firstEpisode?.requiresAccessValidation == true
        let locked = item.firstEpisode?.canPlayWithoutValidation == false
        let showsUnlockLayer = locked && pendingUnlock?.id != item.firstEpisode?.id
        return ZStack {
            TheaterVideoPage(item: item, playback: playback,
                isActive: selectedID == item.id && isVisible,
                onRetry: { retry(item) }, onEpisodes: { showEpisodes = true },
                onShare: { shareItem = item }, onDetail: { selectedDetail = item.drama }, isDetail: true,
                onLike: { try await store.toggleLike(item.id) },
                onFavorite: { try await store.toggleFavorite() })
                .blur(radius: showsUnlockLayer ? 8 : 0)
                .allowsHitTesting(!locked)
                .accessibilityHidden(locked || selectedID != item.id)
            if showsUnlockLayer {
                Color.black.opacity(0.35).allowsHitTesting(false)
                if selectedID == item.id, let episode = item.firstEpisode {
                    if validating {
                        VStack(spacing: 16) {
                            if accessFailureID == episode.id {
                                Text(L10n.text("暂时无法确认本集播放权限，请稍后重试。"))
                                    .multilineTextAlignment(.center)
                                Button(L10n.tr("重试")) { retry(item) }
                            } else {
                                ProgressView(L10n.tr("正在加载剧集…"))
                            }
                        }.padding(28)
                    } else {
                        PlayerUnlockDialog(episode: episode,
                            isUnlocking: unlockCoordinator.unlockingEpisodeIDs.contains(episode.id),
                            onUnlock: { pendingUnlock = episode })
                    }
                }
            }
        }
        .clipped()
    }

    private var isVisible: Bool { isMounted && selectedDetail == nil && scenePhase == .active && app.appUpdate.notice == nil && !showEpisodes && optionsKind == nil && shareItem == nil && currentItem?.firstEpisode?.canPlayWithoutValidation == true && pendingUnlock == nil && membershipDestination == nil && feedbackEpisode == nil && !isSubmittingFeedback && !feedbackSubmitted }
    private var isPreparationActive: Bool {
        isMounted && isReady && selectedDetail == nil && scenePhase == .active &&
            app.appUpdate.notice == nil && membershipDestination == nil && shareItem == nil
    }
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
            }.accessibilityLabel(L10n.tr("返回")).accessibilityIdentifier("player-back")
            Spacer()
            if !subtitleTracks.isEmpty {
                Button { optionsKind = .subtitles } label: {
                    Text(L10n.tr("字幕")).font(.system(size: 15)).padding(.horizontal, 7).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.6)))
                }
                .accessibilityIdentifier("player-subtitles")
                .accessibilityValue(options(for: .subtitles).first(where: { $0.id == selectedSubtitleID })?.title ?? "")
            }
            Menu {
                Button(L10n.tr("反馈")) { feedbackEpisode = currentItem?.firstEpisode }
                    .disabled(currentItem?.firstEpisode == nil || isSubmittingFeedback)
            } label: {
                Image("PlayerMore").resizable().scaledToFit().frame(width: 24, height: 24)
                    .frame(width: 44, height: 44)
            }.accessibilityLabel(L10n.tr("更多")).accessibilityIdentifier("player-more")
        }.padding(.horizontal, 8)
    }

    private var bottomControls: some View {
        HStack(spacing: 10) {
            Button { showEpisodes = true } label: {
                HStack {
                    Text(L10n.tr("选集·全%d集", store.items.count)).lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 4)
                    Image("PlayerEpisodesChevron").resizable().scaledToFit().frame(width: 16, height: 16)
                }.padding(10).frame(maxWidth: .infinity)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }.accessibilityIdentifier("player-episodes")
            Button { optionsKind = .quality } label: {
                HStack(spacing: 4) {
                    Image("PlayerQuality").resizable().scaledToFit().frame(width: 16, height: 16)
                    Text(quality == 0 ? L10n.tr("自动") : String(Int(quality)) + "P")
                }.padding(10).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }.accessibilityLabel(L10n.tr("清晰度"))
                .accessibilityIdentifier("player-quality")
                .accessibilityValue(quality == 0 ? L10n.tr("自动") : String(Int(quality)) + "P")
            Button { optionsKind = .speed } label: {
                Text("\(rate.formatted())x").padding(10)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }.accessibilityLabel(L10n.tr("播放速度"))
                .accessibilityIdentifier("player-speed")
                .accessibilityValue("\(rate.formatted())x")
        }.font(.system(size: 14)).padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.background)
    }

    private func updatePlayback() {
        guard isMounted else { playback.suspend(); return }
        if store.expireAccessIfNeeded() { accessRevision += 1 }
        playback.update(items: store.items, selectedID: selectedID, visible: isVisible,
            preparationActive: isPreparationActive)
        if playback.states[selectedID ?? ""] == .ready { applyMediaOptions() }
    }

    private var accessTaskID: String {
        "\(canResolveAccess)-\(selectedID ?? "")-\(accessRevision)"
    }

    private var accessExpirationID: String {
        "\(canResolveAccess)-\(selectedID ?? "")-\(store.accessDeadline(for: currentItem?.firstEpisode?.id)?.timeIntervalSince1970 ?? 0)"
    }

    private var canResolveAccess: Bool {
        isMounted && isReady && selectedDetail == nil && scenePhase == .active && app.appUpdate.notice == nil && membershipDestination == nil
    }

    private func refreshAfterMembership() async {
        guard isMounted else { return }
        await app.profile.reloadProfile()
        await app.wallet.reloadBalance()
        await app.membership.refresh()
        await store.load(forceRefresh: true)
        guard !Task.isCancelled, isMounted else { return }
        accessRevision += 1
        updatePlayback()
    }

    private func retry(_ item: TheaterFeedItem) {
        store.expireAccessIfNeeded()
        if let episode = store.items.first(where: { $0.id == item.id })?.firstEpisode,
           episode.requiresAccessValidation {
            Task { await resolveAccess(episode, automatically: true) }
        } else if let episode = item.firstEpisode, episode.requiresCoinUnlock {
            pendingUnlock = episode
        } else if let episode = item.firstEpisode, item.videoURL == nil {
            Task {
                do {
                    try await store.refreshPlayableEpisode(episode)
                    guard !Task.isCancelled, isMounted, selectedID == item.id else { return }
                    updatePlayback()
                } catch {
                    guard !Task.isCancelled, isMounted, selectedID == item.id else { return }
                    unlockError = error.appLocalizedDescription
                }
            }
        } else { playback.retry(item.id) }
    }

    private func openMembership(_ category: MembershipCategory) {
        pendingUnlock = nil
        membershipDestination = category
    }

    private func setAutoUnlock(_ enabled: Bool) async {
        guard !changingAutoUnlock else { return }
        changingAutoUnlock = true
        defer { changingAutoUnlock = false }
        do { try await app.profile.setAutoPlayNext(enabled) }
        catch { unlockError = error.appLocalizedDescription }
    }

    private func submitFeedback(_ episode: Episode, categoryCode: String) async {
        guard !isSubmittingFeedback else { return }
        isSubmittingFeedback = true
        feedbackEpisode = nil
        defer { isSubmittingFeedback = false }
        do {
            try await store.reportFeedback(episode, categoryCode: categoryCode)
            feedbackSubmitted = true
        } catch { unlockError = error.appLocalizedDescription }
    }

    private func resolveAccess(_ episode: Episode, automatically: Bool) async {
        guard canResolveAccess, selectedID == episode.id else { return }
        if automatically && pendingUnlock != nil { return }
        accessFailureID = nil
        do {
            let outcome = try await unlockCoordinator.resolve(episode, automatically: automatically)
            guard !Task.isCancelled, isMounted, selectedID == episode.id else { return }
            switch outcome {
            case .unlocked(let coins):
                pendingUnlock = nil
                if coins > 0 { unlockToast = L10n.tr("成功扣除%lld金币，已解锁第%d集", coins, episode.number) }
            case .needsConfirmation:
                break // The page-local unlock layer remains swipeable.
            case .needsRecharge:
                openMembership(.coins)
            }
            updatePlayback()
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, isMounted, selectedID == episode.id else { return }
            if currentItem?.firstEpisode?.requiresAccessValidation == true { accessFailureID = episode.id }
            unlockError = error.appLocalizedDescription
            updatePlayback()
        }
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
            return [PlayerOption(id: "0", title: L10n.tr("自动")), PlayerOption(id: "480", title: "480P"),
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
        let language = subtitleLanguage(option).replacingOccurrences(of: "_", with: "-")
        let locale = LocalizationStore.shared.language.locale
        return locale.localizedString(forIdentifier: language) ?? option.displayName
    }
}
