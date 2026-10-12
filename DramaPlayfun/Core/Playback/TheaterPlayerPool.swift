import AVFoundation
import Observation
import OSLog

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
    private(set) var isBuffering = false
    private(set) var isScrubbing = false

    @ObservationIgnored private var sparePlayers: [AVPlayer] = []
    @ObservationIgnored private var prepareTasks: [TheaterFeedItem.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var prepareVersions: [TheaterFeedItem.ID: UUID] = [:]
    @ObservationIgnored private var itemObservers: [TheaterFeedItem.ID: [NSObjectProtocol]] = [:]
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var scrubbingID: TheaterFeedItem.ID?
    @ObservationIgnored private var seekVersion = UUID()
    @ObservationIgnored private var timeObservers: [TheaterFeedItem.ID: NSKeyValueObservation] = [:]
    @ObservationIgnored private var audioSessionReady = false
    @ObservationIgnored private let cacheOwner = UUID()
    @ObservationIgnored private let logger = Logger(subsystem: "com.video.test.DramaPlayfun.playback", category: "player")
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var items: [TheaterFeedItem] = []
    @ObservationIgnored private var renewalAttempts: Set<String> = []
    @ObservationIgnored private var renewingIDs: Set<String> = []
    @ObservationIgnored private var preparedURLs: [String: URL] = [:]
    @ObservationIgnored private var renewalHealthySince: [String: Date] = [:]
    @ObservationIgnored private var networkRecoveryAttempts: Set<String> = []
    @ObservationIgnored private var stallStartedAt: Date?
    var playbackRate: Float = 1 {
        didSet {
            guard oldValue != playbackRate else { return }
            if let player = players[currentID ?? ""] {
                configureBuffer(player, isCurrent: true)
                if visible && !isPaused && !hasEnded { playCurrentIfReady() }
            }
        }
    }
    private let resumesProgress: Bool
    private let library: LibraryStore
    private let cache: HLSOfflineCache
    private let progressReporter: TheaterProgressReporter?
    private let assetLoader: (TheaterFeedItem) async throws -> AVURLAsset
    private let refreshURLs: ((TheaterFeedItem) async throws -> [TheaterFeedItem])?

    init(library: LibraryStore, cache: HLSOfflineCache, progressReporter: TheaterProgressReporter? = nil,
         resumesProgress: Bool = false, assetLoader: ((TheaterFeedItem) async throws -> AVURLAsset)? = nil,
         refreshURLs: ((TheaterFeedItem) async throws -> [TheaterFeedItem])? = nil) {
        self.resumesProgress = resumesProgress
        self.library = library
        self.cache = cache
        self.progressReporter = progressReporter
        self.refreshURLs = refreshURLs
        self.assetLoader = assetLoader ?? { item in
            guard let url = item.videoURL, let identity = item.keyIdentity else { throw HLSKeyError.invalidIdentity }
            return try await cache.asset(for: item.firstEpisode?.id ?? item.id, remoteURL: url, identity: identity)
        }
    }

    var playerCount: Int { players.count + sparePlayers.count }

    func player(for id: TheaterFeedItem.ID) -> AVPlayer? { players[id] }

    func update(items: [TheaterFeedItem], selectedID: TheaterFeedItem.ID?, visible: Bool) {
        let previousID = currentID
        if previousID != selectedID || !visible { resetScrubbing() }
        if previousID != selectedID {
            saveProgress()
            // A rapid swipe should cancel the old foreground load before starting the new one.
            if let previousID, states[previousID] == .preparing { release(previousID) }
            hasEnded = false
            isPaused = false
            isBuffering = false
            stallStartedAt = nil
        }
        self.items = items
        self.visible = visible
        cache.setPlaybackActive(visible, owner: cacheOwner)
        currentID = selectedID

        guard let index = items.firstIndex(where: { $0.id == selectedID }) else {
            suspend()
            return
        }
        let wanted = Set(max(0, index - 1)...min(items.count - 1, index + 1))
        let wantedIDs = Set(wanted.map { items[$0].id })
        for id in Array(players.keys) where !wantedIDs.contains(id) { release(id) }
        // A batch renewal invalidates prepared neighbors, without rebuilding a healthy current player.
        for item in items where wantedIDs.contains(item.id) && item.id != selectedID {
            if let previous = self.preparedURLs[item.id], previous != item.videoURL { release(item.id) }
        }
        for position in wanted.sorted(by: { abs($0 - index) < abs($1 - index) }) {
            let item = items[position]
            if players[item.id] == nil { prepare(item) }
        }
        for (id, player) in players { configureBuffer(player, isCurrent: id == selectedID) }
        if visible { playCurrentIfReady() }
        else { pauseAll() }
    }

    func suspend() {
        visible = false
        resetScrubbing()
        pauseAll()
        cache.setPlaybackActive(false, owner: cacheOwner)
        isBuffering = false
        stallStartedAt = nil
    }

    func reset() {
        suspend()
        for id in Array(players.keys) { release(id) }
        sparePlayers.removeAll()
        currentID = nil
        items = []
        hasEnded = false
        isPaused = false
        renewalAttempts.removeAll()
        networkRecoveryAttempts.removeAll()
    }

    func toggle() {
        guard !isScrubbing, let currentID, let player = players[currentID], states[currentID] == .ready else { return }
        if hasEnded {
            player.seek(to: .zero)
            hasEnded = false
            isPaused = false
            playCurrentIfReady()
        } else if isPaused {
            isPaused = false
            playCurrentIfReady()
        } else {
            isPaused = true
            isBuffering = false
            player.pause()
            saveProgress()
        }
    }

    @discardableResult
    func beginScrubbing(_ id: TheaterFeedItem.ID) -> Bool {
        guard visible, currentID == id, states[id] == .ready, let player = players[id],
              let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return false }
        resetScrubbing()
        scrubbingID = id
        isScrubbing = true
        isBuffering = false
        player.pause()
        progressTask?.cancel()
        progressTask = nil
        return true
    }

    func endScrubbing(_ id: TheaterFeedItem.ID, fraction: Double) {
        guard scrubbingID == id, currentID == id, let player = players[id],
              let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0,
              fraction.isFinite else { cancelScrubbing(id); return }
        let seconds = min(max(fraction, 0) * duration, max(0, duration - 0.05))
        let version = UUID()
        seekVersion = version
        seekTask?.cancel()
        player.currentItem?.cancelPendingSeeks()
        seekTask = Task { [weak self] in
            await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            guard let self, !Task.isCancelled, self.seekVersion == version,
                  self.currentID == id, self.players[id] === player else { return }
            self.seekTask = nil
            self.scrubbingID = nil
            self.isScrubbing = false
            self.hasEnded = false
            self.saveProgress()
            self.playCurrentIfReady()
        }
    }

    func cancelScrubbing(_ id: TheaterFeedItem.ID) {
        guard scrubbingID == id else { return }
        resetScrubbing()
        playCurrentIfReady()
    }

    private func resetScrubbing() {
        seekVersion = UUID()
        seekTask?.cancel()
        seekTask = nil
        if let scrubbingID { players[scrubbingID]?.currentItem?.cancelPendingSeeks() }
        scrubbingID = nil
        isScrubbing = false
    }

    func retry(_ id: TheaterFeedItem.ID) {
        guard !renewingIDs.contains(id), let item = items.first(where: { $0.id == id }) else { return }
        renewalAttempts.remove(id)
        networkRecoveryAttempts.remove(id)
        handleFailure(item, error: TheaterPlayerError.unplayable, forceRefresh: true)
    }

    private func prepare(_ item: TheaterFeedItem, resumeSeconds: Double? = nil) {
        let id = item.id
        let version = UUID()
        prepareVersions[id] = version
        let player = players[id] ?? sparePlayers.popLast() ?? AVPlayer()
        timeObservers[id] = nil
        itemObservers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        player.automaticallyWaitsToMinimizeStalling = true
        players[id] = player
        preparedURLs[id] = item.videoURL
        states[id] = .preparing
        guard item.videoURL != nil else {
            states[id] = .unavailable("本集暂未提供播放资源或尚未解锁。")
            return
        }
        guard item.keyIdentity != nil else {
            states[id] = .unavailable(HLSKeyError.invalidIdentity.localizedDescription)
            return
        }
        prepareTasks[id] = Task {
            do {
                // Only preload the next episode after the visible one has a healthy buffer.
                // If this neighbor becomes selected, it immediately gains foreground priority.
                while !canPrepare(id) {
                    try await Task.sleep(for: .milliseconds(250))
                }
                try Task.checkCancellation()
                let started = Date()
                logger.info("preparing episode=\(id, privacy: .public) foreground=\(self.currentID == id)")
                let asset = try await assetLoader(item)
                // AVPlayerItem loads and validates HLS itself. A separate isPlayable
                // load can wait on CDN metadata before the player even sees the asset.
                try Task.checkCancellation()
                guard prepareVersions[id] == version, players[id] === player else { return }
                let playerItem = AVPlayerItem(asset: asset)
                playerItem.preferredForwardBufferDuration = id == currentID ? Double(max(12, playbackRate * 8)) : 2
                playerItem.preferredPeakBitRate = id == currentID ? 0 : 800_000
                player.replaceCurrentItem(with: playerItem)
                let deadline = Date().addingTimeInterval(20)
                while playerItem.status == .unknown {
                    if HLSLocalGateway.authorizationExpired(for: asset) { throw HLSKeyError.invalidMediaToken }
                    guard Date() < deadline else { throw TheaterPlayerError.timeout }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard playerItem.status == .readyToPlay else {
                    throw playerItem.error ?? TheaterPlayerError.unplayable
                }
                try Task.checkCancellation()
                guard prepareVersions[id] == version, players[id] === player else { return }
                if let resumeSeconds, resumeSeconds.isFinite, resumeSeconds >= 0 {
                    try await restorePosition(resumeSeconds, player: player, id: id, version: version)
                    try Task.checkCancellation()
                    guard prepareVersions[id] == version, players[id] === player else { return }
                } else if resumesProgress, let progress = library.progress[item.drama.id],
                   progress.episodeID == item.firstEpisode?.id, progress.fraction < 0.98 {
                    try await restorePosition(progress.seconds, player: player, id: id, version: version)
                    try Task.checkCancellation()
                    guard prepareVersions[id] == version, players[id] === player else { return }
                }
                states[id] = .ready
                if renewalAttempts.contains(id) || networkRecoveryAttempts.contains(id) { renewalHealthySince[id] = Date() }
                logger.info("prepared episode=\(id, privacy: .public) ms=\(Int(Date().timeIntervalSince(started) * 1000)) foreground=\(self.currentID == id)")
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
                if prepareVersions[id] == version, players[id] === player {
                    handleFailure(item, error: error)
                    logger.info("prepare failed episode=\(id, privacy: .public) code=\((error as NSError).code)")
                    if let event = player.currentItem?.errorLog()?.events.last {
                        logger.info("item error status=\(event.errorStatusCode) domain=\(event.errorDomain, privacy: .public)")
                    }
                }
            }
            if prepareVersions[id] == version {
                prepareTasks[id] = nil
                prepareVersions[id] = nil
            }
        }
    }

    private func restorePosition(_ seconds: Double, player: AVPlayer, id: String, version: UUID) async throws {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.prepareVersions[id] == version else { return }
            player.currentItem?.cancelPendingSeeks()
        }
        defer { timeout.cancel() }
        let finished = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        try Task.checkCancellation()
        guard finished else { throw TheaterPlayerError.timeout }
    }

    private func handleFailure(_ item: TheaterFeedItem, error: Error, forceRefresh: Bool = false) {
        let id = item.id
        guard !renewingIDs.contains(id), players[id] != nil else { return }
        let player = players[id]
        let expired = (error as? HLSKeyError) == .invalidMediaToken ||
            player?.currentItem.map { HLSLocalGateway.authorizationExpired(for: $0.asset) } == true ||
            player?.currentItem?.errorLog()?.events.contains(where: { [401, 403].contains($0.errorStatusCode) }) == true
        guard (forceRefresh || expired), let refreshURLs, !renewalAttempts.contains(id) else {
            states[id] = .unavailable(error.localizedDescription)
            player?.pause()
            if currentID == id { isBuffering = false }
            return
        }
        renewalAttempts.insert(id)
        renewingIDs.insert(id)
        renewalHealthySince[id] = nil
        let seconds = player?.currentTime().seconds
        player?.pause()
        if scrubbingID == id { resetScrubbing() }
        timeObservers[id] = nil
        itemObservers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        player?.cancelPendingPrerolls()
        player?.replaceCurrentItem(with: nil)
        states[id] = .preparing
        let version = UUID()
        prepareVersions[id] = version
        prepareTasks.removeValue(forKey: id)?.cancel()
        logger.info("renewing episode=\(id, privacy: .public)")
        prepareTasks[id] = Task {
            do {
                let refreshed = try await refreshURLs(item)
                try Task.checkCancellation()
                guard prepareVersions[id] == version, players[id] === player,
                      let updated = refreshed.first(where: { $0.id == id }), updated.videoURL != nil else {
                    throw CancellationError()
                }
                items = refreshed
                renewingIDs.remove(id)
                prepare(updated, resumeSeconds: seconds)
                update(items: refreshed, selectedID: currentID, visible: visible)
            } catch {
                guard prepareVersions[id] == version else { return }
                renewingIDs.remove(id)
                prepareTasks[id] = nil
                prepareVersions[id] = nil
                states[id] = .unavailable(error.localizedDescription)
                if currentID == id { isBuffering = false }
            }
        }
    }

    private func canPrepare(_ id: TheaterFeedItem.ID) -> Bool {
        guard visible else { return false }
        if currentID == id { return true }
        guard !isPaused, !hasEnded, !isScrubbing,
              let index = items.firstIndex(where: { $0.id == currentID }),
              items.indices.contains(index + 1), items[index + 1].id == id,
              let player = players[currentID ?? ""], player.timeControlStatus == .playing,
              let item = player.currentItem else { return false }
        let seconds = player.currentTime().seconds
        let duration = item.duration.seconds
        let remaining = duration.isFinite ? max(0, duration - seconds) : 8
        let event = item.accessLog()?.events.last
        return Self.hasPreloadCapacity(bufferedSeconds: bufferedSeconds(player), remaining: remaining,
            rate: playbackRate, observedBitrate: event?.observedBitrate ?? 0,
            requiredBitrate: event?.indicatedBitrate ?? 0)
    }

    static func hasPreloadCapacity(bufferedSeconds: Double, remaining: Double, rate: Float,
                                   observedBitrate: Double, requiredBitrate: Double) -> Bool {
        if remaining <= 4 && bufferedSeconds >= remaining { return true }
        return bufferedSeconds >= Double(max(12, rate * 8)) && requiredBitrate > 0 &&
            observedBitrate >= requiredBitrate * Double(rate) * 2
    }

    private func deferNeighborLoads() {
        for item in items where item.id != currentID && players[item.id]?.currentItem != nil {
            release(item.id)
            prepare(item)
        }
    }

    private func recoverStalledPlayback(_ item: TheaterFeedItem) {
        guard !renewingIDs.contains(item.id), let player = players[item.id] else { return }
        guard !networkRecoveryAttempts.contains(item.id) else {
            handleFailure(item, error: TheaterPlayerError.timeout)
            return
        }
        networkRecoveryAttempts.insert(item.id)
        let seconds = player.currentTime().seconds
        player.pause()
        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
        prepareTasks.removeValue(forKey: item.id)?.cancel()
        stallStartedAt = nil
        isBuffering = false
        logger.info("reloading stalled episode=\(item.id, privacy: .public)")
        prepare(item, resumeSeconds: seconds)
    }

    private func bufferedSeconds(_ player: AVPlayer) -> Double {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return 0 }
        return player.currentItem?.loadedTimeRanges.reduce(0) { result, value in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            return start <= seconds + 0.1 && end >= seconds ? max(result, end - seconds) : result
        } ?? 0
    }

    private func configureBuffer(_ player: AVPlayer, isCurrent: Bool) {
        player.defaultRate = playbackRate
        player.currentItem?.preferredForwardBufferDuration = isCurrent ? Double(max(12, playbackRate * 8)) : 2
        player.currentItem?.preferredPeakBitRate = isCurrent ? 0 : 800_000
    }

    private func playCurrentIfReady() {
        pauseOtherPlayers()
        guard visible, !isPaused, !hasEnded, !isScrubbing, let currentID,
              states[currentID] == .ready, let player = players[currentID] else { return }
        do {
            if !audioSessionReady {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                audioSessionReady = true
            }
            player.play()
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
        renewingIDs.remove(id)
        renewalAttempts.remove(id)
        preparedURLs[id] = nil
        renewalHealthySince[id] = nil
        networkRecoveryAttempts.remove(id)
        if scrubbingID == id { resetScrubbing() }
        prepareTasks.removeValue(forKey: id)?.cancel()
        prepareVersions[id] = nil
        timeObservers[id] = nil
        itemObservers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        states[id] = nil
        guard let player = players.removeValue(forKey: id) else { return }
        player.pause()
        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()
        player.currentItem?.asset.cancelLoading()
        player.replaceCurrentItem(with: nil)
        sparePlayers.append(player)
    }

    private func observePlayback(of item: AVPlayerItem, id: TheaterFeedItem.ID) {
        itemObservers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        if let player = players[id] {
            timeObservers[id] = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.currentID == id, self.players[id]?.currentItem === item else { return }
                    self.isBuffering = self.visible && !self.isPaused && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    if self.isBuffering {
                        if self.stallStartedAt == nil { self.stallStartedAt = Date() }
                        self.deferNeighborLoads()
                    } else { self.stallStartedAt = nil }
                }
            }
        }
        let stalled = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentID == id else { return }
                self.logger.info("stalled episode=\(id, privacy: .public) buffer=\(self.players[id].map(self.bufferedSeconds) ?? 0)")
            }
        }
        let access = NotificationCenter.default.addObserver(forName: .AVPlayerItemNewAccessLogEntry, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let event = item.accessLog()?.events.last else { return }
                self.logger.debug("access episode=\(id, privacy: .public) stalls=\(event.numberOfStalls) bitrate=\(event.observedBitrate) required=\(event.indicatedBitrate) bytes=\(event.numberOfBytesTransferred)")
            }
        }
        let ended = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isScrubbing, self.currentID == id,
                      self.players[id]?.currentItem === item else { return }
                self.hasEnded = true
                self.progressTask?.cancel()
                self.progressTask = nil
                self.saveProgress()
            }
        }
        let failed = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.players[id]?.currentItem === item else { return }
                if self.scrubbingID == id { self.resetScrubbing() }
                if let feedItem = self.items.first(where: { $0.id == id }) {
                    self.handleFailure(feedItem, error: item.error ?? TheaterPlayerError.unplayable)
                }
            }
        }
        let authorization = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.players[id]?.currentItem === item,
                      HLSLocalGateway.authorizationExpired(for: item.asset) ||
                        item.errorLog()?.events.contains(where: { [401, 403].contains($0.errorStatusCode) }) == true,
                      let feedItem = self.items.first(where: { $0.id == id }) else { return }
                self.handleFailure(feedItem, error: HLSKeyError.invalidMediaToken)
            }
        }
        itemObservers[id] = [ended, failed, stalled, access, authorization]
    }

    private func startSavingProgress() {
        progressTask?.cancel()
        progressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                if let currentID, let item = players[currentID]?.currentItem,
                   item.status == .failed || HLSLocalGateway.authorizationExpired(for: item.asset),
                   let feedItem = items.first(where: { $0.id == currentID }) {
                    handleFailure(feedItem, error: item.error ?? HLSKeyError.invalidMediaToken)
                    return
                }
                if let currentID, let since = renewalHealthySince[currentID],
                   Date().timeIntervalSince(since) >= 5,
                   let player = players[currentID], player.timeControlStatus == .playing,
                   bufferedSeconds(player) >= 2 {
                    renewalAttempts.remove(currentID)
                    renewalHealthySince[currentID] = nil
                    networkRecoveryAttempts.remove(currentID)
                }
                if let currentID, !isPaused, !isScrubbing, !hasEnded,
                   let player = players[currentID], player.timeControlStatus == .playing,
                   bufferedSeconds(player) < Double(max(4, playbackRate * 4)) { deferNeighborLoads() }
                if let currentID, let since = stallStartedAt, Date().timeIntervalSince(since) >= 8,
                   visible, !isPaused, !isScrubbing, !hasEnded,
                   let item = items.first(where: { $0.id == currentID }) {
                    recoverStalledPlayback(item)
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
