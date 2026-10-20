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
    private var playbackErrors: [TheaterFeedItem.ID: Error] = [:]
    private(set) var currentID: TheaterFeedItem.ID?
    private(set) var isPaused = false
    private(set) var hasEnded = false
    private(set) var isBuffering = false
    private(set) var isScrubbing = false

    @ObservationIgnored private var sparePlayers: [AVPlayer] = []
    @ObservationIgnored private var prepareTasks: [TheaterFeedItem.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var prepareVersions: [TheaterFeedItem.ID: UUID] = [:]
    @ObservationIgnored private var loadingIDs: Set<TheaterFeedItem.ID> = []
    @ObservationIgnored private var prerollingIDs: Set<TheaterFeedItem.ID> = []
    @ObservationIgnored private var interruptedPreloadIDs: Set<TheaterFeedItem.ID> = []
    @ObservationIgnored private var startedPlaybackIDs: Set<TheaterFeedItem.ID> = []
    @ObservationIgnored private var itemObservers: [TheaterFeedItem.ID: [NSObjectProtocol]] = [:]
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    @ObservationIgnored private var scrubbingID: TheaterFeedItem.ID?
    @ObservationIgnored private var seekVersion = UUID()
    @ObservationIgnored private var timeObservers: [TheaterFeedItem.ID: NSKeyValueObservation] = [:]
    @ObservationIgnored private var bufferObservers: [TheaterFeedItem.ID: NSKeyValueObservation] = [:]
    @ObservationIgnored private var pendingBufferedStartID: TheaterFeedItem.ID?
    @ObservationIgnored private var preloadDirection = 1
    @ObservationIgnored private var audioSessionReady = false
    @ObservationIgnored private let cacheOwner = UUID()
    @ObservationIgnored private let logger = Logger(subsystem: "com.video.test.DramaPlayfun.playback", category: "player")
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var preparationActive = false
    @ObservationIgnored private var preloadingID: TheaterFeedItem.ID?
    @ObservationIgnored private var continuationPriority = false
    @ObservationIgnored private var items: [TheaterFeedItem] = []
    @ObservationIgnored private var renewalAttempts: Set<String> = []
    @ObservationIgnored private var renewingIDs: Set<String> = []
    @ObservationIgnored private var preparedURLs: [String: URL] = [:]
    @ObservationIgnored private var renewalHealthySince: [String: Date] = [:]
    @ObservationIgnored private var networkRecoveryAttempts: Set<String> = []
    @ObservationIgnored private var recoveryPositions: [String: Double] = [:]
    @ObservationIgnored private var recoveryBitrateLimitedIDs: Set<String> = []
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
    private var initialPosition: PlaybackPosition?
    private let preservesSessionProgress: Bool
    // Explicit list entry ignores old local history, but keeps new progress across player rebuilds.
    private var sessionPositions: [String: Double] = [:]
    private let library: LibraryStore
    private let cache: HLSOfflineCache
    private let progressReporter: TheaterProgressReporter?
    private let assetLoader: (TheaterFeedItem) async throws -> AVURLAsset
    private let refreshURLs: ((TheaterFeedItem) async throws -> [TheaterFeedItem])?
    private let recoveryClock: () -> Date

    init(library: LibraryStore, cache: HLSOfflineCache, progressReporter: TheaterProgressReporter? = nil,
         resumesProgress: Bool = false, initialPosition: PlaybackPosition? = nil,
         assetLoader: ((TheaterFeedItem) async throws -> AVURLAsset)? = nil,
         refreshURLs: ((TheaterFeedItem) async throws -> [TheaterFeedItem])? = nil,
         recoveryClock: @escaping () -> Date = Date.init) {
        self.resumesProgress = resumesProgress
        self.initialPosition = initialPosition
        self.preservesSessionProgress = initialPosition != nil
        self.library = library
        self.cache = cache
        self.progressReporter = progressReporter
        self.refreshURLs = refreshURLs
        self.recoveryClock = recoveryClock
        self.assetLoader = assetLoader ?? { item in
            guard let url = item.videoURL, let identity = item.keyIdentity else { throw HLSKeyError.invalidIdentity }
            return try await cache.asset(for: item.firstEpisode?.id ?? item.id, remoteURL: url, identity: identity)
        }
    }

    var playerCount: Int { players.count + sparePlayers.count }

    func player(for id: TheaterFeedItem.ID) -> AVPlayer? { players[id] }

    func errorMessage(for id: TheaterFeedItem.ID) -> String? {
        _ = LocalizationStore.shared.language
        return playbackErrors[id].map { L10n.errorMessage($0, fallback: "视频暂时无法播放，请重试。") }
    }

    private func setUnavailable(_ error: Error, for id: TheaterFeedItem.ID) {
        playbackErrors[id] = error
        states[id] = .unavailable(error.appLocalizedDescription)
    }

    var isApproachingEnd: Bool {
        guard visible, !hasEnded, let player = players[currentID ?? ""],
              let duration = player.currentItem?.duration.seconds else { return false }
        return Self.isContinuationWindow(seconds: player.currentTime().seconds, duration: duration)
    }

    static func isContinuationWindow(seconds: Double, duration: Double) -> Bool {
        seconds.isFinite && duration.isFinite && duration > 0 && seconds > 0 &&
            duration - seconds > 0 && duration - seconds <= 10
    }

    var canPreloadContinuation: Bool {
        guard isApproachingEnd, !isPaused, !isScrubbing, !isBuffering,
              let player = players[currentID ?? ""], player.timeControlStatus == .playing,
              let item = player.currentItem else { return false }
        let remaining = item.duration.seconds - player.currentTime().seconds
        let buffer = bufferedSeconds(player)
        let event = item.accessLog()?.events.last
        return buffer >= remaining || Self.hasPreloadCapacity(bufferedSeconds: buffer, remaining: remaining,
            rate: playbackRate, observedBitrate: event?.observedBitrate ?? 0,
            requiredBitrate: event?.indicatedBitrate ?? 0)
    }

    func prioritizeContinuation(_ active: Bool) {
        guard continuationPriority != active else { return }
        continuationPriority = active
        if active {
            // Keep completed neighbor buffers/decoders for a swipe during the ending.
            for id in Array(players.keys) where id != currentID && states[id] != .ready { release(id) }
        } else {
            update(items: items, selectedID: currentID, visible: visible, preparationActive: preparationActive)
        }
    }

    /// Silently prepares one selected episode for a later playback handoff.
    func preload(items: [TheaterFeedItem], selectedID: TheaterFeedItem.ID) {
        guard !visible, let item = items.first(where: { $0.id == selectedID }),
              item.videoURL != nil else { return }
        self.items = items
        currentID = selectedID
        preloadingID = selectedID
        cache.setPlaybackActive(true, owner: cacheOwner)
        if players[selectedID] == nil { prepare(item) }
        else if interruptedPreloadIDs.remove(selectedID) != nil,
                states[selectedID] == .ready, let player = players[selectedID],
                prepareTasks[selectedID] == nil {
            let version = UUID()
            prepareVersions[selectedID] = version
            prepareTasks[selectedID] = Task {
                defer {
                    if prepareVersions[selectedID] == version {
                        prerollingIDs.remove(selectedID)
                        prepareTasks[selectedID] = nil
                        prepareVersions[selectedID] = nil
                    }
                }
                await warmDecoder(player, id: selectedID, version: version)
            }
        }
    }

    /// Stops speculative work while retaining an already prepared item for entry.
    func stopPreloading() {
        guard !visible, let id = preloadingID else { return }
        preloadingID = nil
        if states[id] == .ready, let player = players[id] {
            if prepareTasks[id] != nil { interruptedPreloadIDs.insert(id) }
            prepareVersions[id] = nil
            prepareTasks.removeValue(forKey: id)?.cancel()
            loadingIDs.remove(id)
            prerollingIDs.remove(id)
            player.cancelPendingPrerolls()
            player.pause()
            player.isMuted = true
        } else {
            release(id)
        }
        cache.setPlaybackActive(preparationActive, owner: cacheOwner)
    }

    func update(items: [TheaterFeedItem], selectedID: TheaterFeedItem.ID?, visible: Bool,
                preparationActive: Bool = false) {
        let previousID = currentID
        let wasLocked = self.items.first(where: { $0.id == selectedID })?.firstEpisode?.canPlayWithoutValidation == false
        if previousID != selectedID || !visible { resetScrubbing() }
        if previousID != selectedID {
            if let previousID { renewalHealthySince[previousID] = nil }
            if let selectedID { renewalHealthySince[selectedID] = nil }
            saveProgress()
            if let previousIndex = self.items.firstIndex(where: { $0.id == previousID }),
               let selectedIndex = self.items.firstIndex(where: { $0.id == selectedID }) {
                preloadDirection = selectedIndex < previousIndex ? -1 : 1
            }
            // Keep an in-flight adjacent item so a quick reverse swipe can reuse it.
            // The bounded window below still cancels loads that are no longer nearby.
            pendingBufferedStartID = nil
            hasEnded = false
            isPaused = false
            isBuffering = false
            stallStartedAt = nil
        }
        self.items = items
        self.visible = visible
        if !visible, let selectedID { renewalHealthySince[selectedID] = nil }
        self.preparationActive = preparationActive || visible
        if self.preparationActive { preloadingID = nil }
        cache.setPlaybackActive(self.preparationActive || preloadingID != nil, owner: cacheOwner)
        currentID = selectedID

        guard let index = items.firstIndex(where: { $0.id == selectedID }) else {
            suspend()
            return
        }
        let wanted = Set(max(0, index - 1)...min(items.count - 1, index + 1))
        let wantedIDs = Set(wanted.map { items[$0].id })
        for id in Array(players.keys) where !wantedIDs.contains(id) { release(id) }
        // A refreshed authorization token must not discard a neighbor's buffer and decoder.
        // Pending loads still need the latest signed URL; content changes always invalidate it.
        for item in items where wantedIDs.contains(item.id) && item.id != selectedID {
            if let previous = preparedURLs[item.id], previous != item.videoURL,
               players[item.id]?.currentItem == nil || states[item.id] != .ready ||
                MediaResourceURL.contentKey(for: previous) != item.videoURL.map(MediaResourceURL.contentKey(for:)) {
                release(item.id)
            }
        }
        // Authorization alone keeps the warmed player/item. Rebuild only when the
        // source changes content, or an empty/failed player needs the latest URL.
        let selected = items[index]
        if wasLocked, canPlay(selected.id), selected.videoURL != nil,
           case .unavailable = states[selected.id] {
            release(selected.id)
        }
        if let player = players[selected.id], let url = selected.videoURL,
           preparedURLs[selected.id] != url,
           player.currentItem == nil || states[selected.id] != .ready ||
            preparedURLs[selected.id].map(MediaResourceURL.contentKey(for:)) != MediaResourceURL.contentKey(for: url) {
            release(selected.id)
        }
        for position in wanted.sorted(by: { abs($0 - index) < abs($1 - index) }) {
            let item = items[position]
            if players[item.id] == nil { prepare(item) }
        }
        for (id, player) in players { configureBuffer(player, isCurrent: id == selectedID) }
        if visible, let selectedID, canPlay(selectedID) { playCurrentIfReady() }
        else { pauseAll() }
    }

    func suspend() {
        visible = false
        preparationActive = false
        preloadingID = nil
        resetScrubbing()
        pauseAll()
        cache.setPlaybackActive(false, owner: cacheOwner)
        isBuffering = false
        stallStartedAt = nil
        if let currentID { renewalHealthySince[currentID] = nil }
        pendingBufferedStartID = nil
    }

    func reset() {
        suspend()
        preloadingID = nil
        continuationPriority = false
        for id in Array(players.keys) { release(id) }
        sparePlayers.removeAll()
        currentID = nil
        items = []
        hasEnded = false
        isPaused = false
        preloadDirection = 1
        renewalAttempts.removeAll()
        networkRecoveryAttempts.removeAll()
    }

    func toggle() {
        guard !isScrubbing, let currentID, canPlay(currentID),
              let player = players[currentID], states[currentID] == .ready else { return }
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
            renewalHealthySince[currentID] = nil
            isBuffering = false
            player.pause()
            saveProgress()
        }
    }

    @discardableResult
    func beginScrubbing(_ id: TheaterFeedItem.ID) -> Bool {
        guard visible, currentID == id, canPlay(id), states[id] == .ready, let player = players[id],
              let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return false }
        resetScrubbing()
        scrubbingID = id
        isScrubbing = true
        renewalHealthySince[id] = nil
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
            // An asynchronous seek can restore AVPlayer's previous rate.
            if self.isPaused || !self.visible || !self.canPlay(id) { player.pause() }
            else { self.playCurrentIfReady() }
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
        bufferObservers[id] = nil
        if pendingBufferedStartID == id { pendingBufferedStartID = nil }
        itemObservers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        player.automaticallyWaitsToMinimizeStalling = true
        player.isMuted = id != currentID || !visible || !canPlay(id)
        players[id] = player
        preparedURLs[id] = item.videoURL
        states[id] = .preparing
        playbackErrors[id] = nil
        guard item.videoURL != nil else {
            setUnavailable(TheaterPlayerError.missingResource, for: id)
            return
        }
        guard item.keyIdentity != nil else {
            setUnavailable(HLSKeyError.invalidIdentity, for: id)
            return
        }
        prepareTasks[id] = Task {
            defer {
                if prepareVersions[id] == version {
                    loadingIDs.remove(id)
                    prerollingIDs.remove(id)
                    prepareTasks[id] = nil
                    prepareVersions[id] = nil
                }
            }
            do {
                // Warm just the beginning of one neighbor at a time once the foreground is safe.
                // If this neighbor becomes selected, it immediately gains foreground priority.
                while !canPrepare(id) {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                if currentID != id && preloadingID != id {
                    // Once the foreground is safe, its likely next swipe takes the
                    // single preload slot from an unfinished reverse-swipe load.
                    for other in items where other.id != id && other.id != currentID && loadingIDs.contains(other.id) {
                        release(other.id)
                        prepare(other)
                    }
                }
                loadingIDs.insert(id)
                let started = Date()
                logger.info("preparing episode=\(id, privacy: .public) foreground=\(self.currentID == id)")
                let asset = try await assetLoader(item)
                // AVPlayerItem loads and validates HLS itself. A separate isPlayable
                // load can wait on CDN metadata before the player even sees the asset.
                try Task.checkCancellation()
                guard prepareVersions[id] == version, players[id] === player else { return }
                let playerItem = AVPlayerItem(asset: asset)
                player.replaceCurrentItem(with: playerItem)
                configureBuffer(player, isCurrent: id == currentID)
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
                if let position = initialPosition, item.firstEpisode?.number == position.episodeNumber {
                    // The tapped list item is authoritative, even near the end or after a startup retry.
                    try await restorePosition(position.seconds, player: player, id: id, version: version)
                    try Task.checkCancellation()
                    guard prepareVersions[id] == version, players[id] === player else { return }
                    initialPosition = nil
                    sessionPositions[id] = position.seconds
                } else if let resumeSeconds, resumeSeconds.isFinite, resumeSeconds >= 0 {
                    try await restorePosition(resumeSeconds, player: player, id: id, version: version)
                    try Task.checkCancellation()
                    guard prepareVersions[id] == version, players[id] === player else { return }
                } else if let seconds = sessionPositions[id] {
                    try await restorePosition(seconds, player: player, id: id, version: version)
                    try Task.checkCancellation()
                    guard prepareVersions[id] == version, players[id] === player else { return }
                } else if resumesProgress, let progress = library.progress[item.drama.id],
                   progress.episodeID == item.firstEpisode?.id, progress.fraction < 0.98 {
                    try await restorePosition(progress.seconds, player: player, id: id, version: version)
                    try Task.checkCancellation()
                    guard prepareVersions[id] == version, players[id] === player else { return }
                }
                states[id] = .ready
                recoveryPositions[id] = nil
                renewalHealthySince[id] = nil
                logger.info("prepared episode=\(id, privacy: .public) ms=\(Int(Date().timeIntervalSince(started) * 1000)) foreground=\(self.currentID == id)")
                observePlayback(of: playerItem, id: id)
                if currentID == id {
                    if visible { playCurrentIfReady() }
                }
                if preloadingID == id || currentID != id || !visible || !canPlay(id) {
                    await warmDecoder(player, id: id, version: version)
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
        }
    }

    private func warmDecoder(_ player: AVPlayer, id: String, version: UUID) async {
        guard player.rate == 0, player.status == .readyToPlay else { return }
        player.isMuted = true
        prerollingIDs.insert(id)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, prepareVersions[id] == version else { return }
            player.cancelPendingPrerolls()
        }
        defer { timeout.cancel() }
        let warmed = await player.preroll(atRate: playbackRate)
        guard !Task.isCancelled, prepareVersions[id] == version, players[id] === player else { return }
        prerollingIDs.remove(id)
        logger.info("prewarmed episode=\(id, privacy: .public) ready=\(warmed) buffer=\(self.bufferedSeconds(player))")
        if currentID == id && visible && canPlay(id) {
            configureBuffer(player, isCurrent: true)
            playCurrentIfReady()
        } else if player.rate != 0 { player.pause() }
    }

    private func restorePosition(_ seconds: Double, player: AVPlayer, id: String, version: UUID) async throws {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.prepareVersions[id] == version else { return }
            player.currentItem?.cancelPendingSeeks()
        }
        defer { timeout.cancel() }
        let finished = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                                         toleranceBefore: .zero, toleranceAfter: .zero)
        try Task.checkCancellation()
        guard finished else { throw TheaterPlayerError.timeout }
    }

    private func handleFailure(_ item: TheaterFeedItem, error: Error, forceRefresh: Bool = false) {
        let id = item.id
        guard !renewingIDs.contains(id), players[id] != nil else { return }
        preserveSessionPosition(id)
        let player = players[id]
        let transportError = player?.currentItem.flatMap { HLSLocalGateway.transientTransportFailure(for: $0.asset) }
        let logEvents = player?.currentItem?.errorLog()?.events ?? []
        let now = Date()
        let hasRecentNetworkError = logEvents.enumerated().contains { index, event in
            Self.isRecentTransientPlaybackLog(domain: event.errorDomain, code: event.errorStatusCode,
                date: event.date, isLatest: index == logEvents.count - 1, now: now)
        }
        logFailure(error, transportError: transportError, player: player, id: id)
        let expired = (error as? HLSKeyError) == .invalidMediaToken ||
            player?.currentItem.map { HLSLocalGateway.authorizationExpired(for: $0.asset) } == true ||
            player?.currentItem?.errorLog()?.events.contains(where: { [401, 403].contains($0.errorStatusCode) }) == true
        // AVFoundation can wrap a dropped HLS connection in a CoreMedia error.
        // The player's own segment timeout can precede URLSession's timeout.
        // Require network evidence from its error chain, recent log, or transport.
        if !forceRefresh, !expired, !Self.isCancellation(error),
           Self.isTransientNetworkFailure(error) || transportError != nil || hasRecentNetworkError,
           recoverPlayback(item) {
            return
        }
        guard (forceRefresh || expired), let refreshURLs, !renewalAttempts.contains(id) else {
            if pendingBufferedStartID == id { pendingBufferedStartID = nil }
            setUnavailable(error, for: id)
            player?.pause()
            if currentID == id { isBuffering = false }
            return
        }
        renewalAttempts.insert(id)
        renewingIDs.insert(id)
        renewalHealthySince[id] = nil
        let seconds = sessionPositions[id] ?? recoveryPositions[id] ?? player?.currentTime().seconds
        player?.pause()
        if scrubbingID == id { resetScrubbing() }
        timeObservers[id] = nil
        bufferObservers[id] = nil
        if pendingBufferedStartID == id { pendingBufferedStartID = nil }
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
                update(items: refreshed, selectedID: currentID, visible: visible, preparationActive: preparationActive)
            } catch {
                guard prepareVersions[id] == version else { return }
                renewingIDs.remove(id)
                prepareTasks[id] = nil
                prepareVersions[id] = nil
                setUnavailable(error, for: id)
                if currentID == id { isBuffering = false }
            }
        }
    }

    private static func errorChain(_ error: Error) -> [NSError] {
        var errors: [NSError] = []
        var current: NSError? = error as NSError
        while let value = current, errors.count < 8,
              !errors.contains(where: { $0 === value }) {
            errors.append(value)
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return errors
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || errorChain(error).contains {
            $0.domain == NSURLErrorDomain && $0.code == URLError.cancelled.rawValue
        }
    }

    private static func isTransientNetworkFailure(_ error: Error) -> Bool {
        errorChain(error).contains { isTransientPlaybackFailure($0) }
    }

    static func isTransientPlaybackFailure(_ error: NSError) -> Bool {
        // Observed AVPlayer segment deadline: "No response for media file in 2s".
        // Parser errors such as -16046 alone do not identify a network failure.
        HLSAuthorizationState.isTransient(error) ||
            (error.domain == "CoreMediaErrorDomain" && error.code == -12889)
    }

    static func isRecentTransientPlaybackLog(domain: String, code: Int, date: Date?,
                                             isLatest: Bool, now: Date) -> Bool {
        let isRecent = date.map { (0...30).contains(now.timeIntervalSince($0)) } ?? isLatest
        return isRecent && isTransientPlaybackFailure(NSError(domain: domain, code: code))
    }

    private func logFailure(_ error: Error, transportError: NSError?, player: AVPlayer?, id: String) {
        let chain = Self.errorChain(error).map { "\($0.domain):\($0.code)" }.joined(separator: " -> ")
        logger.error("playback failed episode=\(id, privacy: .public) errors=\(chain, privacy: .public)")
        if let transportError {
            let status = transportError.userInfo["HTTPStatusCode"] as? Int ?? 0
            logger.error("transport failure domain=\(transportError.domain, privacy: .public) code=\(transportError.code) status=\(status)")
        }
        for event in player?.currentItem?.errorLog()?.events.suffix(3) ?? [] {
            logger.error("item failure episode=\(id, privacy: .public) domain=\(event.errorDomain, privacy: .public) status=\(event.errorStatusCode)")
        }
    }

    private func canPlay(_ id: TheaterFeedItem.ID) -> Bool {
        items.first(where: { $0.id == id })?.firstEpisode?.canPlayWithoutValidation == true
    }

    private func canPrepare(_ id: TheaterFeedItem.ID) -> Bool {
        if preloadingID == id { return true }
        guard preparationActive else { return false }
        if currentID == id { return true }
        guard !continuationPriority, !isScrubbing,
              let index = items.firstIndex(where: { $0.id == currentID }),
              let candidate = items.firstIndex(where: { $0.id == id }), abs(candidate - index) == 1 else { return false }
        // Follow the user's last swipe direction without parallel neighbor downloads.
        let preferredIndex = index + preloadDirection
        let competing = loadingIDs.filter { $0 != currentID && $0 != id }
        guard competing.isEmpty || (candidate == preferredIndex && competing.allSatisfy { states[$0] == .preparing }) else {
            return false
        }
        if candidate != preferredIndex, items.indices.contains(preferredIndex),
           states[items[preferredIndex].id] == .preparing { return false }
        // A locked/currently covered page has no foreground playback to compete with.
        // Finish preparing it first, then use the wait for confirmation to warm neighbors.
        if !visible || !canPlay(items[index].id) || isPaused || hasEnded {
            guard let state = states[items[index].id] else { return false }
            return state != .preparing
        }
        guard !isBuffering,
              let player = players[items[index].id], player.timeControlStatus == .playing,
              let item = player.currentItem else { return false }
        let seconds = player.currentTime().seconds
        let duration = item.duration.seconds
        let remaining = duration.isFinite ? max(0, duration - seconds) : 8
        let event = item.accessLog()?.events.last
        return Self.hasNeighborPreloadCapacity(bufferedSeconds: bufferedSeconds(player), remaining: remaining,
            rate: playbackRate, observedBitrate: event?.observedBitrate ?? 0,
            requiredBitrate: event?.indicatedBitrate ?? 0, isNext: candidate == preferredIndex)
    }

    static func hasNeighborPreloadCapacity(bufferedSeconds: Double, remaining: Double, rate: Float,
                                          observedBitrate: Double, requiredBitrate: Double,
                                          isNext: Bool) -> Bool {
        guard bufferedSeconds.isFinite, bufferedSeconds > 0, remaining > 0 else { return false }
        if remaining.isFinite, bufferedSeconds >= remaining { return true }
        let speed = Double(max(1, rate))
        // A measured fast connection can warm the likely next swipe after one
        // second of playable reserve. Unknown/slow links retain the safer gate.
        if isNext, bufferedSeconds >= speed, requiredBitrate > 0,
           observedBitrate >= requiredBitrate * speed * 2 { return true }
        guard bufferedSeconds >= (isNext ? 3 : 6) * speed else { return false }
        // Access logs may not yet contain throughput on the first segment or a disk cache hit.
        return observedBitrate <= 0 || requiredBitrate <= 0 || observedBitrate >= requiredBitrate * speed * 1.25
    }

    static func hasPreloadCapacity(bufferedSeconds: Double, remaining: Double, rate: Float,
                                   observedBitrate: Double, requiredBitrate: Double) -> Bool {
        if remaining <= 4 && bufferedSeconds >= remaining { return true }
        return bufferedSeconds >= Double(max(12, rate * 8)) && requiredBitrate > 0 &&
            observedBitrate >= requiredBitrate * Double(rate) * 2
    }

    private func deferNeighborLoads() {
        // Preserve ready neighbors, including their first decoded frame, through transient waits.
        // Only unfinished loads compete with a starving foreground player.
        for item in items where item.id != currentID && loadingIDs.contains(item.id) && states[item.id] == .preparing {
            release(item.id)
            prepare(item)
        }
    }

    private func recoverStalledPlayback(_ item: TheaterFeedItem) {
        if !recoverPlayback(item) {
            handleFailure(item, error: TheaterPlayerError.timeout)
        }
    }

    /// Rebuild once with the same authorization. A healthy playback interval
    /// restores this allowance, while an immediate second failure is surfaced.
    @discardableResult
    private func recoverPlayback(_ item: TheaterFeedItem) -> Bool {
        guard !renewingIDs.contains(item.id), !networkRecoveryAttempts.contains(item.id),
              preparationActive || preloadingID == item.id,
              canPlay(item.id), let player = players[item.id] else { return false }
        networkRecoveryAttempts.insert(item.id)
        recoveryBitrateLimitedIDs.insert(item.id)
        preserveSessionPosition(item.id)
        renewalHealthySince[item.id] = nil
        let seconds = sessionPositions[item.id] ?? recoveryPositions[item.id] ?? player.currentTime().seconds
        if seconds.isFinite, seconds >= 0 { recoveryPositions[item.id] = seconds }
        timeObservers[item.id] = nil
        bufferObservers[item.id] = nil
        itemObservers.removeValue(forKey: item.id)?.forEach(NotificationCenter.default.removeObserver)
        player.pause()
        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
        prepareTasks.removeValue(forKey: item.id)?.cancel()
        if currentID == item.id {
            progressTask?.cancel()
            progressTask = nil
            stallStartedAt = nil
            isBuffering = false
        }
        logger.info("recovering playback episode=\(item.id, privacy: .public) seconds=\(seconds)")
        prepare(item, resumeSeconds: seconds)
        return true
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
        let foreground = isCurrent && visible && canPlay(currentID ?? "")
        player.isMuted = !foreground
        // Startup and silent preparation only need a short runway. Expand the
        // foreground reserve once it is playing, not before displaying the start.
        player.currentItem?.preferredForwardBufferDuration = foreground && player.timeControlStatus == .playing
            ? Double(max(12, playbackRate * 8)) : Double(max(1, playbackRate)) * 2
        let recovering = isCurrent && currentID.map { recoveryBitrateLimitedIDs.contains($0) } == true
        player.currentItem?.preferredPeakBitRate = foreground && !recovering ? 0 : 800_000
        player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        if #available(iOS 26.0, *) {
            player.networkResourcePriority = foreground ? .high : .low
        }
    }

    private func playCurrentIfReady() {
        pauseOtherPlayers()
        guard visible, !isPaused, !hasEnded, !isScrubbing, let currentID, canPlay(currentID),
              states[currentID] == .ready, let player = players[currentID] else { return }
        do {
            if !audioSessionReady {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                audioSessionReady = true
            }
            startedPlaybackIDs.insert(currentID)
            if prerollingIDs.contains(currentID) { player.cancelPendingPrerolls() }
            let buffer = bufferedSeconds(player)
            if player.timeControlStatus != .playing, buffer >= Double(playbackRate) * 0.5 {
                // The prefetched start is already playable; skip AVPlayer's startup heuristic.
                pendingBufferedStartID = nil
                player.playImmediately(atRate: playbackRate)
                logger.info("buffered start episode=\(currentID, privacy: .public) buffer=\(buffer)")
            } else {
                pendingBufferedStartID = player.timeControlStatus == .playing ? nil : currentID
                player.play()
            }
            if let item = items.first(where: { $0.id == currentID }),
               let episodeID = item.firstEpisode?.id,
               let asset = player.currentItem?.asset as? AVURLAsset {
                cache.downloadIfNeeded(episodeID: episodeID, asset: asset, title: item.drama.title)
            }
            startSavingProgress()
        } catch {
            setUnavailable(error, for: currentID)
        }
    }

    private func pauseOtherPlayers() {
        for (id, player) in players where id != currentID {
            if player.rate != 0 || (player.timeControlStatus == .waitingToPlayAtSpecifiedRate && !prerollingIDs.contains(id)) {
                player.pause()
            }
        }
    }

    private func pauseAll() {
        for (id, player) in players {
            if player.rate != 0 || (player.timeControlStatus == .waitingToPlayAtSpecifiedRate && !prerollingIDs.contains(id)) {
                player.pause()
            }
        }
        progressTask?.cancel()
        progressTask = nil
        saveProgress()
    }

    private func preserveSessionPosition(_ id: TheaterFeedItem.ID) {
        guard preservesSessionProgress, states[id] == .ready,
              let player = players[id], player.currentItem != nil else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds >= 0 else { return }
        sessionPositions[id] = seconds
    }

    private func release(_ id: TheaterFeedItem.ID) {
        preserveSessionPosition(id)
        renewingIDs.remove(id)
        renewalAttempts.remove(id)
        preparedURLs[id] = nil
        renewalHealthySince[id] = nil
        networkRecoveryAttempts.remove(id)
        recoveryPositions[id] = nil
        recoveryBitrateLimitedIDs.remove(id)
        if scrubbingID == id { resetScrubbing() }
        prepareTasks.removeValue(forKey: id)?.cancel()
        loadingIDs.remove(id)
        prerollingIDs.remove(id)
        interruptedPreloadIDs.remove(id)
        startedPlaybackIDs.remove(id)
        prepareVersions[id] = nil
        timeObservers[id] = nil
        bufferObservers[id] = nil
        if pendingBufferedStartID == id { pendingBufferedStartID = nil }
        itemObservers.removeValue(forKey: id)?.forEach(NotificationCenter.default.removeObserver)
        states[id] = nil
        playbackErrors[id] = nil
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
            bufferObservers[id] = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.pendingBufferedStartID == id, self.currentID == id,
                          self.players[id]?.currentItem === item, self.visible, self.canPlay(id),
                          self.states[id] == .ready, item.status == .readyToPlay,
                          !self.isPaused, !self.hasEnded, !self.isScrubbing,
                          self.bufferedSeconds(player) >= Double(self.playbackRate) * 0.5 else { return }
                    // readyToPlay may precede the first media bytes. Re-evaluate
                    // when they arrive instead of leaving HLS in its long startup wait.
                    self.pendingBufferedStartID = nil
                    player.playImmediately(atRate: self.playbackRate)
                }
            }
            timeObservers[id] = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.currentID == id, self.players[id]?.currentItem === item else { return }
                    if player.timeControlStatus == .playing {
                        self.pendingBufferedStartID = nil
                        self.configureBuffer(player, isCurrent: true)
                    } else { self.renewalHealthySince[id] = nil }
                    self.isBuffering = self.visible && self.canPlay(id) && !self.isPaused && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                    if self.isBuffering {
                        if self.stallStartedAt == nil { self.stallStartedAt = Date() }
                        // A cold startup wait is not evidence of depleted bandwidth.
                        if self.pendingBufferedStartID != id { self.deferNeighborLoads() }
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
                self.logger.debug("access episode=\(id, privacy: .public) stalls=\(event.numberOfStalls) bitrate=\(event.observedBitrate) required=\(event.indicatedBitrate) limit=\(item.preferredPeakBitRate) bytes=\(event.numberOfBytesTransferred)")
            }
        }
        let ended = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isScrubbing, self.currentID == id, self.canPlay(id),
                      self.startedPlaybackIDs.contains(id),
                      self.players[id]?.currentItem === item else { return }
                self.hasEnded = true
                self.progressTask?.cancel()
                self.progressTask = nil
                self.saveProgress()
            }
        }
        let failed = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            let reportedError = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            Task { @MainActor [weak self] in
                guard let self, self.players[id]?.currentItem === item else { return }
                if self.scrubbingID == id { self.resetScrubbing() }
                if let feedItem = self.items.first(where: { $0.id == id }) {
                    self.handleFailure(feedItem, error: reportedError ?? item.error ?? TheaterPlayerError.unplayable)
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
                if let currentID, let player = players[currentID] { updateRecoveryHealth(id: currentID, player: player) }
                if let currentID, !isPaused, !isScrubbing, !hasEnded,
                   let player = players[currentID], player.timeControlStatus == .playing,
                   bufferedSeconds(player) < Double(max(1, playbackRate)) { deferNeighborLoads() }
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

    private func updateRecoveryHealth(id: String, player: AVPlayer) {
        guard renewalAttempts.contains(id) || networkRecoveryAttempts.contains(id) ||
                recoveryBitrateLimitedIDs.contains(id) else { return }
        let buffer = bufferedSeconds(player)
        guard visible, currentID == id, canPlay(id), states[id] == .ready,
              !isPaused, !isScrubbing, !hasEnded, player.timeControlStatus == .playing, buffer >= 2 else {
            renewalHealthySince[id] = nil
            return
        }
        let now = recoveryClock()
        let since = renewalHealthySince[id] ?? now
        renewalHealthySince[id] = since
        let healthySeconds = now.timeIntervalSince(since)
        if healthySeconds >= 5 {
            renewalAttempts.remove(id)
            networkRecoveryAttempts.remove(id)
        }
        if healthySeconds >= 15, buffer >= 8, recoveryBitrateLimitedIDs.remove(id) != nil {
            configureBuffer(player, isCurrent: true)
            logger.info("recovery bitrate restored episode=\(id, privacy: .public) buffer=\(buffer)")
        }
        if !renewalAttempts.contains(id), !networkRecoveryAttempts.contains(id),
           !recoveryBitrateLimitedIDs.contains(id) { renewalHealthySince[id] = nil }
    }

    private func saveProgress(force: Bool = true) {
        guard preloadingID == nil, let currentID, canPlay(currentID), startedPlaybackIDs.contains(currentID),
              let item = items.first(where: { $0.id == currentID }),
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

private enum TheaterPlayerError: AppLocalizedError {
    case unplayable, timeout, missingResource

    var errorDescription: String? {
        switch self {
        case .missingResource: L10n.text("本集暂未提供播放资源或尚未解锁。")
        case .unplayable: L10n.text("视频暂时无法播放，请重试。")
        case .timeout: L10n.text("视频加载超时，请检查网络。")
        }
    }
}
