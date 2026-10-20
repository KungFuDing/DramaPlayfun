import Foundation

/// Keeps metadata and the muted, prepared second episode alive across presentation.
@MainActor
final class PlaybackPreparation {
    let store: DramaPlaybackStore
    let playback: TheaterPlayerPool
    private var loadTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var transferred = false
    private var cancelled = false

    init(store: DramaPlaybackStore, playback: TheaterPlayerPool) {
        self.store = store
        self.playback = playback
    }

    convenience init(drama: Drama, app: AppContainer) {
        let store = DramaPlaybackStore(drama: drama, network: app.network,
            repository: app.repository, library: app.library, detailCache: app.playbackDetails)
        let playback = TheaterPlayerPool(library: app.library, cache: app.hlsCache,
            progressReporter: TheaterProgressReporter(network: app.network), resumesProgress: false,
            refreshURLs: { item in try await store.refreshPlaybackURLs(for: item) })
        self.init(store: store, playback: playback)
    }

    func beginLoading() {
        guard !cancelled, loadTask == nil else { return }
        loadTask = Task { [store] in
            guard !Task.isCancelled else { return }
            await store.load()
        }
    }

    func load() async {
        beginLoading()
        await loadTask?.value
    }

    func preloadVideo() {
        guard !cancelled, !transferred, preloadTask == nil else { return }
        preloadTask = Task { [weak self] in
            guard !Task.isCancelled, let self, !cancelled else { return }
            await load()
            guard !Task.isCancelled, !transferred,
                  let second = store.items.first(where: { $0.firstEpisode?.number == 2 }),
                  second.videoURL != nil else { return }
            playback.preload(items: store.items, selectedID: second.id)
        }
    }

    func stopPreloadingVideo() {
        guard !transferred, preloadTask != nil else { return }
        preloadTask?.cancel()
        preloadTask = nil
        playback.reset()
    }

    func handoff() {
        transferred = true
        preloadTask?.cancel()
        preloadTask = nil
    }

    func cancel() {
        guard !transferred else { return }
        cancelled = true
        loadTask?.cancel()
        loadTask = nil
        stopPreloadingVideo()
        playback.reset()
    }
}
