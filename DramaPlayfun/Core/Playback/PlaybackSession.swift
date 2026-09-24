import AVFoundation
import Observation

/// Owned by the presented player screen, so closing it releases the playback session.
@MainActor @Observable
final class PlaybackSession {
    let player = AVPlayer()
    private(set) var isLoading = true
    private(set) var errorMessage: String?
    private(set) var hasEnded = false
    private let request: PlaybackRequest
    private let repository: any DramaRepository
    private let library: LibraryStore

    init(request: PlaybackRequest, repository: any DramaRepository, library: LibraryStore) {
        self.request = request
        self.repository = repository
        self.library = library
    }

    func run() async {
        isLoading = true
        errorMessage = nil
        hasEnded = false
        defer { isLoading = false }
        do {
            let url = try await repository.playbackURL(dramaID: request.drama.id, episodeID: request.episode.id)
            try Task.checkCancellation()
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            let item = AVPlayerItem(url: url)
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
            errorMessage = error.localizedDescription
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

private enum PlaybackError: LocalizedError {
    case failed, timeout
    var errorDescription: String? {
        switch self {
        case .failed: "视频加载失败，请重试。"
        case .timeout: "视频加载超时，请检查网络后重试。"
        }
    }
}
