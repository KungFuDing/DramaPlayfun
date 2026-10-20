import Foundation
import Observation

@MainActor @Observable
final class DramaPlaybackStore {
    private(set) var items: [TheaterFeedItem] = []
    private(set) var isLoading = false
    private var loadError: Error?
    var errorMessage: String? {
        _ = LocalizationStore.shared.language
        return loadError?.appLocalizedDescription
    }
    private(set) var likingIDs: Set<String> = []
    private(set) var isFavoriting = false
    private let network: APIClient
    private let urlRefresher: PlaybackURLRefresher
    private let repository: any DramaRepository
    private let library: LibraryStore
    private let detailCache: PlaybackDetailCache?
    // These grants come from the server, and exist only for this playback session.
    private var authorizedEpisodeIDs: Set<String> = []
    let drama: Drama

    init(drama: Drama, network: APIClient, repository: any DramaRepository, library: LibraryStore,
         detailCache: PlaybackDetailCache? = nil) {
        self.drama = drama
        self.network = network
        urlRefresher = PlaybackURLRefresher(network: network)
        self.repository = repository
        self.library = library
        self.detailCache = detailCache
    }

    func refreshPlaybackURLs(for item: TheaterFeedItem) async throws -> [TheaterFeedItem] {
        let snapshot = items
        let urls = try await urlRefresher.refresh(snapshot, requiredID: item.firstEpisode?.id)
        try Task.checkCancellation()
        for index in items.indices {
            let episodeID = items[index].firstEpisode?.id ?? ""
            guard let url = urls[episodeID],
                  snapshot.contains(where: { $0.id == items[index].id && $0.videoURL == items[index].videoURL }) else { continue }
            items[index].videoURL = url
        }
        let previousURLs = snapshot.reduce(into: [String: URL]()) { values, item in
            if let episodeID = item.firstEpisode?.id, let url = item.videoURL { values[episodeID] = url }
        }
        await detailCache?.updatePlaybackURLs(dramaID: drama.id, replacing: previousURLs, with: urls)
        return items
    }

    func load(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let loaded: [TheaterFeedItem]
            if let id = Int64(drama.id) {
                let response: APIModels.V1GetDramaEpisodeListRes
                if let detailCache {
                    response = try await detailCache.load(dramaID: drama.id, forceRefresh: forceRefresh)
                } else {
                    response = try await network.request(AppAPI.v1ClientDramaEpisodeList,
                        body: .init(dramaId: id), unwrapEnvelope: true)
                }
                loaded = Self.makeItems(response, fallback: drama, authorizedEpisodeIDs: authorizedEpisodeIDs)
            } else {
                let episodes = try await repository.fetchEpisodes(dramaID: drama.id)
                var mapped: [TheaterFeedItem] = []
                for episode in episodes.sorted(by: { $0.number < $1.number }) {
                    let source = try await repository.playbackSource(dramaID: drama.id, episodeID: episode.id)
                    mapped.append(TheaterFeedItem(drama: drama, firstEpisode: episode,
                        videoURL: source.url, firstEpisodeLikeCount: 0, isFirstEpisodeLiked: false,
                        isFavorited: library.favoriteIDs.contains(drama.id), playbackID: episode.id))
                }
                loaded = mapped
            }
            try Task.checkCancellation()
            items = loaded
            if loaded.isEmpty { loadError = DramaPlaybackError.noPlayableEpisodes }
        } catch is CancellationError {
        } catch { loadError = error }
    }

    static func makeItems(_ response: APIModels.V1GetDramaEpisodeListRes, fallback: Drama,
                          authorizedEpisodeIDs: Set<String> = []) -> [TheaterFeedItem] {
        let drama = Drama(id: fallback.id, title: response.dramaTitle ?? fallback.title,
            summary: response.dramaDesc ?? fallback.summary, category: fallback.category,
            episodeCount: response.episodePassed ?? max(response.episodes?.count ?? 0, fallback.episodeCount),
            heat: response.favoriteCount ?? fallback.heat, badge: fallback.badge,
            coverURL: response.coverUrl.flatMap(URL.init(string:)) ?? fallback.coverURL,
            tagNames: response.tagNames ?? fallback.tagNames,
            rootDramaID: response.rootDramaId ?? fallback.rootDramaID)
        var seen: Set<String> = []
        return (response.episodes ?? []).compactMap { raw -> TheaterFeedItem? in
            guard let id = raw.episodeId, let number = raw.episodeNo, number > 0,
                  seen.insert(String(id)).inserted else { return nil }
            let episode = Episode(id: String(id), number: number, title: "",
                requiresMembership: false, unlockCoin: raw.unlockCoin ?? 0,
                isUnlocked: raw.isUnlocked == true || authorizedEpisodeIDs.contains(String(id)), looked: raw.looked)
            let url = raw.videoUrl.flatMap(URL.init(string:)).flatMap { url -> URL? in
                url.scheme?.lowercased() == "https" && url.host?.isEmpty == false &&
                    url.user == nil && url.password == nil ? url : nil
            }
            return TheaterFeedItem(drama: drama, firstEpisode: episode, videoURL: url,
                firstEpisodeLikeCount: raw.likeCount ?? 0, isFirstEpisodeLiked: raw.isLiked ?? false,
                isFavorited: response.isFavorited ?? false, playbackID: episode.id,
                favoriteCount: response.favoriteCount)
        }.sorted { ($0.firstEpisode?.number ?? 0) < ($1.firstEpisode?.number ?? 0) }
    }

    func initialID(request: PlaybackRequest) -> String? {
        if let position = request.startPosition {
            return items.first(where: { $0.firstEpisode?.number == position.episodeNumber })?.id ?? items.first?.id
        }
        if let item = items.first(where: { $0.firstEpisode?.id == request.episode.id }) { return item.id }
        if request.episode.id.isEmpty, request.startsFromBeginning {
            return items.first(where: { $0.firstEpisode?.number == request.episode.number })?.id ?? items.first?.id
        }
        if request.episode.id.isEmpty, let progress = library.progress[drama.id],
           let item = items.first(where: { $0.firstEpisode?.id == progress.episodeID ||
               $0.firstEpisode?.number == progress.episodeNumber }) { return item.id }
        return items.first?.id
    }

    func toggleLike(_ id: String) async throws {
        guard !likingIDs.contains(id), let item = items.first(where: { $0.id == id }),
              let episodeID = (item.firstEpisode?.id).flatMap(Int64.init) else { return }
        likingIDs.insert(id)
        defer { likingIDs.remove(id) }
        let liked = !item.isFirstEpisodeLiked
        let response = try await network.request(AppAPI.v1ClientDramaLike,
            body: .init(episodeId: episodeID, like: liked), unwrapEnvelope: true)
        detailCache?.invalidate(dramaID: drama.id)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isFirstEpisodeLiked = response.isLiked ?? liked
        items[index].firstEpisodeLikeCount = response.likeCount ?? max(0, item.firstEpisodeLikeCount + (liked ? 1 : -1))
    }

    func toggleFavorite() async throws {
        guard !isFavoriting, let id = Int64(drama.id), let first = items.first else { return }
        isFavoriting = true
        defer { isFavoriting = false }
        let favorite = !first.isFavorited
        let response = try await network.request(AppAPI.v1ClientDramaFavorite,
            body: .init(dramaId: id, favorite: favorite), unwrapEnvelope: true)
        detailCache?.invalidate(dramaID: drama.id)
        let value = response.isFavorited ?? favorite
        for index in items.indices {
            items[index].isFavorited = value
            if let count = items[index].favoriteCount, value != first.isFavorited {
                items[index].favoriteCount = max(0, count + (value ? 1 : -1))
            }
        }
        library.setFavorite(drama.id, isFavorite: value)
    }

    func applyFavorite(_ id: Drama.ID, isFavorite: Bool, count: Int?) {
        detailCache?.invalidate(dramaID: id)
        for index in items.indices where items[index].drama.id == id {
            items[index].isFavorited = isFavorite
            if let count { items[index].favoriteCount = count }
        }
    }

    func unlockStatus(_ episode: Episode) async throws -> APIModels.V1GetEpisodeUnlockStatusRes {
        guard let episodeID = Int64(episode.id) else { throw CatalogError.notFound }
        return try await network.request(AppAPI.v1DramaEpisodeUnlockStatus,
            body: .init(episodeId: episodeID), unwrapEnvelope: true)
    }

    /// Only the coordinator calls this mutation, after serializing and checking the wallet.
    func unlock(_ episode: Episode) async throws -> APIModels.V1UnlockDramaEpisodeRes {
        guard let dramaID = Int64(drama.id), let episodeID = Int64(episode.id) else { throw CatalogError.notFound }
        let response = try await network.request(AppAPI.v1DramaEpisodeUnlock,
            body: .init(dramaId: dramaID, episodeId: episodeID), unwrapEnvelope: true)
        guard response.canWatch == true || response.unlocked == true else { throw CatalogError.episodeLocked }
        authorizePlayback(episode)
        return response
    }

    func hasAuthorizedPlayback(_ episode: Episode) -> Bool {
        authorizedEpisodeIDs.contains(episode.id)
    }

    /// Preserve the confirmed grant even if fetching the signed URL subsequently fails.
    /// A retry then fetches the URL without submitting another coin transaction.
    func authorizePlayback(_ episode: Episode) {
        authorizedEpisodeIDs.insert(episode.id)
        detailCache?.invalidate(dramaID: drama.id)
        guard let index = items.firstIndex(where: { $0.firstEpisode?.id == episode.id }),
              let currentEpisode = items[index].firstEpisode, !currentEpisode.isUnlocked else { return }
        let current = items[index]
        let authorizedEpisode = Episode(id: currentEpisode.id, number: currentEpisode.number,
            title: currentEpisode.title, requiresMembership: currentEpisode.requiresMembership,
            unlockCoin: currentEpisode.unlockCoin, isUnlocked: true, looked: currentEpisode.looked)
        // The pool can promote its already prepared AVPlayerItem as soon as access is
        // confirmed. Keep the exact signed URL so authorization never invalidates it.
        items[index] = TheaterFeedItem(drama: current.drama, firstEpisode: authorizedEpisode,
            videoURL: current.videoURL, firstEpisodeLikeCount: current.firstEpisodeLikeCount,
            isFirstEpisodeLiked: current.isFirstEpisodeLiked, isFavorited: current.isFavorited,
            playbackID: current.playbackID, favoriteCount: current.favoriteCount)
    }

    func refreshPlayableEpisode(_ episode: Episode) async throws {
        if let current = items.first(where: { $0.firstEpisode?.id == episode.id }),
           current.firstEpisode?.requiresCoinUnlock == false, current.videoURL != nil {
            return
        }
        guard let dramaID = Int64(drama.id) else { throw CatalogError.notFound }
        let response: APIModels.V1GetDramaEpisodeListRes
        if let detailCache {
            response = try await detailCache.load(dramaID: drama.id, forceRefresh: true)
        } else {
            response = try await network.request(AppAPI.v1ClientDramaEpisodeList,
                body: .init(dramaId: dramaID), unwrapEnvelope: true)
        }
        try Task.checkCancellation()
        let refreshed = Self.makeItems(response, fallback: drama, authorizedEpisodeIDs: authorizedEpisodeIDs)
        guard let item = refreshed.first(where: { $0.firstEpisode?.id == episode.id }),
              item.videoURL != nil, item.firstEpisode?.requiresCoinUnlock == false else {
            throw EpisodeUnlockError.playbackUnavailable
        }
        // Keep neighboring signed URLs, players and interaction state intact.
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let previous = items[index]
            items[index] = TheaterFeedItem(drama: item.drama, firstEpisode: item.firstEpisode,
                videoURL: item.videoURL, firstEpisodeLikeCount: previous.firstEpisodeLikeCount,
                isFirstEpisodeLiked: previous.isFirstEpisodeLiked, isFavorited: previous.isFavorited,
                playbackID: item.playbackID, favoriteCount: previous.favoriteCount)
        }
    }

    func reportFeedback(_ episode: Episode, categoryCode: String) async throws {
        guard let episodeID = Int64(episode.id) else { throw CatalogError.notFound }
        _ = try await network.request(AppAPI.v1ClientDramaEpisodeFeedback,
            body: .init(episodeId: episodeID, categoryCode: categoryCode), unwrapEnvelope: true)
    }
}

private enum DramaPlaybackError: AppLocalizedError {
    case noPlayableEpisodes
    var errorDescription: String? { L10n.text("暂无可播放剧集。") }
}
