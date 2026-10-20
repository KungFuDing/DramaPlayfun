import Foundation

/// Publishes the home feed before fetching theater metadata and warming its first episode.
@MainActor
final class StartupContentLoader {
    private let home: HomeFeedStore
    private let theater: TheaterFeedStore
    private let playback: TheaterPlayerPool
    private var preloadingEnabled = false
    private var handedOff = false
    private var cancelled = false

    init(home: HomeFeedStore, theater: TheaterFeedStore, playback: TheaterPlayerPool) {
        self.home = home
        self.theater = theater
        self.playback = playback
    }

    func load() async {
        guard !cancelled, !Task.isCancelled else { return }
        // Home publishes its sections as they arrive, including the first hot page.
        await home.loadIfNeeded()
        guard !cancelled, !Task.isCancelled else { return }
        await Task.yield()
        guard !cancelled, !Task.isCancelled else { return }
        // Entry into the theater joins this request if the user switches tabs early.
        await theater.loadIfNeeded()
        guard !cancelled, !Task.isCancelled else { return }
        updatePreloading()
    }

    func setPreloadingEnabled(_ enabled: Bool) {
        preloadingEnabled = enabled
        updatePreloading()
    }

    func handoff() {
        // Briefly visiting an empty theater has not taken ownership of a player.
        guard !theater.items.isEmpty else { return }
        // Returning home must never reset the user's theater selection or progress.
        handedOff = true
    }

    func cancel() {
        cancelled = true
        theater.cancelLoading()
        if !handedOff { playback.stopPreloading() }
    }

    private func updatePreloading() {
        guard !cancelled, !handedOff else { return }
        guard preloadingEnabled else {
            playback.stopPreloading()
            return
        }
        guard home.hasLoaded, !home.isLoading, theater.hasLoaded,
              let first = theater.items.first,
              playback.currentID == nil || playback.currentID == first.id else { return }
        playback.preload(items: theater.items, selectedID: first.id)
    }
}
