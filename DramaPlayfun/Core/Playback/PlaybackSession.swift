import AVFoundation
import Observation

/// Owned by the presented player screen, so closing it releases the playback session.
@MainActor @Observable
final class PlaybackSession {
    let player = AVPlayer()
    private(set) var isLoading = true
    private var loadError: Error?
    var errorMessage: String? {
        _ = LocalizationStore.shared.language
        return loadError.map { L10n.errorMessage($0, fallback: "视频加载失败，请重试。") }
    }
    private(set) var hasEnded = false
    private let request: PlaybackRequest
    private let repository: any DramaRepository
    private let library: LibraryStore
    private let cache: HLSOfflineCache?

    init(request: PlaybackRequest, repository: any DramaRepository, library: LibraryStore,
         cache: HLSOfflineCache? = nil) {
        self.request = request
        self.repository = repository
        self.library = library
        self.cache = cache
    }

    func run() async {
        isLoading = true
        loadError = nil
        hasEnded = false
        defer { isLoading = false }
        do {
            let source = try await repository.playbackSource(dramaID: request.drama.id,
                                                             episodeID: request.episode.id)
            guard let episodeID = Int64(request.episode.id) else { throw HLSKeyError.invalidIdentity }
            let identity = HLSKeyIdentity(rootDramaID: source.rootDramaID
                ?? request.drama.rootDramaID ?? 0, episodeID: episodeID)
            guard identity.isValid else { throw HLSKeyError.invalidIdentity }
            let asset: AVURLAsset
            if let cache {
                asset = try await cache.asset(for: request.episode.id, remoteURL: source.url,
                                              identity: identity)
            } else {
                asset = try await HLSLocalGateway.shared.asset(remoteURL: source.url,
                    identity: identity, secret: HLSPlaybackKey.configuredSecret())
            }
            try Task.checkCancellation()
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            let item = AVPlayerItem(asset: asset)
            CaptureProtectedVideoOutput.configure(player)
            CaptureProtectedVideoOutput.prepare(item)
            player.replaceCurrentItem(with: item)
            let deadline = Date().addingTimeInterval(30)
            while item.status == .unknown {
                guard Date() < deadline else { throw PlaybackError.timeout }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard item.status == .readyToPlay else { throw item.error ?? PlaybackError.failed }
            if let progress = library.progress[request.drama.id], progress.episodeID == request.episode.id,
               progress.fraction < 0.98 {
                await player.seek(to: CMTime(seconds: progress.seconds, preferredTimescale: 600))
            }
            try Task.checkCancellation()
            isLoading = false
            player.play()
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(2))
                if item.status == .failed { throw item.error ?? PlaybackError.failed }
                saveProgress()
                let duration = item.duration.seconds
                hasEnded = duration.isFinite && duration > 0 && player.currentTime().seconds >= duration - 0.25
            }
        } catch is CancellationError {
            player.pause()
        } catch {
            loadError = error
            player.pause()
        }
    }

    func replay() {
        player.seek(to: .zero)
        hasEnded = false
        player.play()
    }

    func pause() { player.pause(); saveProgress() }

    func stop() {
        pause()
        player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func saveProgress() {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        let seconds = player.currentTime().seconds
        let duration = item.duration.seconds
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return }
        library.save(WatchProgress(dramaID: request.drama.id, episodeID: request.episode.id,
                                   episodeNumber: request.episode.number, seconds: seconds,
                                   duration: duration, updatedAt: Date()))
    }
}

private enum PlaybackError: AppLocalizedError {
    case failed, timeout
    var errorDescription: String? {
        switch self {
        case .failed: L10n.text("视频加载失败，请重试。")
        case .timeout: L10n.text("视频加载超时，请检查网络后重试。")
        }
    }
}
