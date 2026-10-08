import AVFoundation
import Observation

enum TheaterPlaybackState: Equatable {
    case preparing
    case ready
    case unavailable(String)
}

/// Owns at most three players: the selected video and its immediate neighbors.
@MainActor @Observable
final class TheaterPlayerPool {
    private(set) var players: [TheaterFeedItem.ID: AVPlayer] = [:]
    private(set) var states: [TheaterFeedItem.ID: TheaterPlaybackState] = [:]
    private(set) var currentID: TheaterFeedItem.ID?
    private(set) var isPaused = false
    private(set) var hasEnded = false

    @ObservationIgnored private var sparePlayers: [AVPlayer] = []
    @ObservationIgnored private var prepareTasks: [TheaterFeedItem.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var prepareVersions: [TheaterFeedItem.ID: UUID] = [:]
    @ObservationIgnored private var itemObservers: [TheaterFeedItem.ID: [NSObjectProtocol]] = [:]
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var secondNextTask: Task<Void, Never>?
    @ObservationIgnored private var secondNextID: TheaterFeedItem.ID?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var items: [TheaterFeedItem] = []
    var playbackRate: Float = 1 {
        didSet { if visible && !isPaused && !hasEnded { players[currentID ?? ""]?.rate = playbackRate } }
    }
    private let resumesProgress: Bool
    private let library: LibraryStore
    private let cache: HLSOfflineCache
    private let progressReporter: TheaterProgressReporter?

    init(library: LibraryStore, cache: HLSOfflineCache, progressReporter: TheaterProgressReporter? = nil, resumesProgress: Bool = false) {
        self.resumesProgress = resumesProgress
        self.library = library
        self.cache = cache
        self.progressReporter = progressReporter
    }

    var playerCount: Int { players.count + sparePlayers.count }

    func player(for id: TheaterFeedItem.ID) -> AVPlayer? { players[id] }

    func update(items: [TheaterFeedItem], selectedID: TheaterFeedItem.ID?, visible: Bool) {
        let previousID = currentID
        if previousID != selectedID {
            saveProgress()
            hasEnded = false
            isPaused = false
        }
        self.items = items
        self.visible = visible
        currentID = selectedID

        guard let index = items.firstIndex(where: { $0.id == selectedID }) else {
            suspend()
            return
        }
        let wanted = Set(max(0, index - 1)...min(items.count - 1, index + 1))
        let wantedIDs = Set(wanted.map { items[$0].id })
        for id in Array(players.keys) where !wantedIDs.contains(id) { release(id) }
        for position in wanted.sorted(by: { abs($0 - index) < abs($1 - index) }) {
            let item = items[position]
            if players[item.id] == nil { prepare(item) }
        }
        warmSecondNext(visible && index + 2 < items.count ? items[index + 2] : nil)
        if visible { playCurrentIfReady() }
        else { pauseAll() }
    }

    func suspend() {
        visible = false
        pauseAll()
        warmSecondNext(nil)
    }

    func reset() {
        suspend()
        for id in Array(players.keys) { release(id) }
        sparePlayers.removeAll()
        currentID = nil
        items = []
        hasEnded = false
        isPaused = false
    }

    func toggle() {
        guard let currentID, let player = players[currentID], states[currentID] == .ready else { return }
        if hasEnded {
            player.seek(to: .zero)
            hasEnded = false
            isPaused = false
            player.playImmediately(atRate: playbackRate)
        } else if isPaused {
            isPaused = false
            player.playImmediately(atRate: playbackRate)
        } else {
            isPaused = true
            player.pause()
            saveProgress()
        }
    }

    private func prepare(_ item: TheaterFeedItem) {
        let id = item.id
        let version = UUID()
        prepareVersions[id] = version
        let player = sparePlayers.popLast() ?? AVPlayer()
        players[id] = player
        states[id] = .preparing
        guard let url = item.videoURL else {
            states[id] = .unavailable("本集暂未提供播放资源或尚未解锁。")
            return
        }
        guard let identity = item.keyIdentity else {
            states[id] = .unavailable(HLSKeyError.invalidIdentity.localizedDescription)
            return
        }
        prepareTasks[id] = Task {
            do {
                let asset = try await cache.asset(for: item.firstEpisode?.id ?? id,
                                                  remoteURL: url, identity: identity)
                guard try await asset.load(.isPlayable) else { throw TheaterPlayerError.unplayable }
                try Task.checkCancellation()
                guard players[id] === player else { return }
                let playerItem = AVPlayerItem(asset: asset)
                playerItem.preferredForwardBufferDuration = 2
                player.replaceCurrentItem(with: playerItem)
                let deadline = Date().addingTimeInterval(20)
                while playerItem.status == .unknown {
                    guard Date() < deadline else { throw TheaterPlayerError.timeout }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard playerItem.status == .readyToPlay else {
                    throw playerItem.error ?? TheaterPlayerError.unplayable
                }
                try Task.checkCancellation()
                guard players[id] === player else { return }
                if resumesProgress, let progress = library.progress[item.drama.id],
                   progress.episodeID == item.firstEpisode?.id, progress.fraction < 0.98 {
                    await player.seek(to: CMTime(seconds: progress.seconds, preferredTimescale: 600))
                    try Task.checkCancellation()
                    guard players[id] === player else { return }
                }
                states[id] = .ready
                observePlayback(of: playerItem, id: id)
                if currentID == id {
                    if visible { playCurrentIfReady() }
                } else {
                    _ = await player.preroll(atRate: 1)
                    guard !Task.isCancelled, prepareVersions[id] == version, players[id] === player else { return }
                    if currentID == id && visible { playCurrentIfReady() }
                    else { player.pause() }
                }
            } catch is CancellationError {
            } catch {
                if players[id] === player { states[id] = .unavailable(error.localizedDescription) }
            }
            if prepareVersions[id] == version {
                prepareTasks[id] = nil
                prepareVersions[id] = nil
            }
        }
    }

    private func warmSecondNext(_ item: TheaterFeedItem?) {
        guard secondNextID != item?.id else { return }
        secondNextTask?.cancel()
        secondNextTask = nil
        secondNextID = item?.id
        guard let item, let url = item.videoURL, let identity = item.keyIdentity else { return }
        secondNextTask = Task {
            guard let asset = try? await cache.asset(for: item.firstEpisode?.id ?? item.id,
                                                     remoteURL: url, identity: identity) else { return }
            _ = try? await asset.load(.isPlayable)
        }
    }

    private func playCurrentIfReady() {
        pauseOtherPlayers()
        guard visible, !isPaused, !hasEnded, let currentID,
              states[currentID] == .ready, let player = players[currentID] else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            player.playImmediately(atRate: playbackRate)
            if let item = items.first(where: { $0.id == currentID }),
               let episodeID = item.firstEpisode?.id,
               let asset = player.currentItem?.asset as? AVURLAsset {
                cache.downloadIfNeeded(episodeID: episodeID, asset: asset, title: item.drama.title)
            }
            startSavingProgress()
        } catch {
            states[currentID] = .unavailable(error.localizedDescription)
        }
    }

    private func pauseOtherPlayers() {
        for (id, player) in players where id != currentID { player.pause() }
    }

    private func pauseAll() {
        for player in players.values { player.pause() }
        progressTask?.cancel()
        progressTask = nil
        saveProgress()
    }

    private func release(_ id: TheaterFeedItem.ID) {
        prepareTasks.removeValue(forKey: id)?.cancel()
        prepareVersions[id] = nil
        itemObservers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        states[id] = nil
        guard let player = players.removeValue(forKey: id) else { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        sparePlayers.append(player)
    }

    private func observePlayback(of item: AVPlayerItem, id: TheaterFeedItem.ID) {
        itemObservers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        let ended = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentID == id else { return }
                self.hasEnded = true
                self.progressTask?.cancel()
                self.progressTask = nil
                self.saveProgress()
            }
        }
        let failed = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "视频播放失败，请重试。"
            Task { @MainActor [weak self] in
                guard let self, self.players[id]?.currentItem === item else { return }
                self.states[id] = .unavailable(message)
                self.players[id]?.pause()
            }
        }
        itemObservers[id] = [ended, failed]
    }

    private func startSavingProgress() {
        progressTask?.cancel()
        progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                if let currentID, let item = players[currentID]?.currentItem, item.status == .failed {
                    states[currentID] = .unavailable(item.error?.localizedDescription ?? "视频播放失败，请重试。")
                    players[currentID]?.pause()
                    return
                }
                saveProgress(force: false)
            }
        }
    }

    private func saveProgress(force: Bool = true) {
        guard let currentID, let item = items.first(where: { $0.id == currentID }),
              let episode = item.firstEpisode, let player = players[currentID],
              let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        let progress = WatchProgress(dramaID: item.drama.id, episodeID: episode.id,
                                     episodeNumber: episode.number, seconds: seconds,
                                     duration: duration, updatedAt: Date())
        library.save(progress)
        progressReporter?.report(progress, force: force)
    }
}

private enum TheaterPlayerError: LocalizedError {
    case unplayable, timeout

    var errorDescription: String? {
        switch self {
        case .unplayable: "视频暂时无法播放，请重试。"
        case .timeout: "视频加载超时，请检查网络。"
        }
    }
}
