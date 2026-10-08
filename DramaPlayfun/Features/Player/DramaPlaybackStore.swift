import Foundation
import Observation

@MainActor @Observable
final class DramaPlaybackStore {
    private(set) var items: [TheaterFeedItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var likingIDs: Set<String> = []
    private(set) var isFavoriting = false
    private let network: APIClient
    private let repository: any DramaRepository
    private let library: LibraryStore
    let drama: Drama

    init(drama: Drama, network: APIClient, repository: any DramaRepository, library: LibraryStore) {
        self.drama = drama
        self.network = network
        self.repository = repository
        self.library = library
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded: [TheaterFeedItem]
            if let id = Int64(drama.id) {
                let response = try await network.request(AppAPI.v1ClientDramaEpisodeList,
                    body: .init(dramaId: id), unwrapEnvelope: true)
                loaded = Self.makeItems(response, fallback: drama)
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
            if loaded.isEmpty { errorMessage = "暂无可播放剧集。" }
        } catch is CancellationError {
        } catch { errorMessage = error.localizedDescription }
    }

    static func makeItems(_ response: APIModels.V1GetDramaEpisodeListRes, fallback: Drama) -> [TheaterFeedItem] {
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
            let episode = Episode(id: String(id), number: number, title: "第\(number)集",
                requiresMembership: false, unlockCoin: raw.unlockCoin ?? 0,
                isUnlocked: raw.isUnlocked ?? false, looked: raw.looked)
            let url = raw.videoUrl.flatMap(URL.init(string:)).flatMap { url -> URL? in
                url.scheme?.lowercased() == "https" && url.host != nil && !episode.requiresCoinUnlock ? url : nil
            }
            return TheaterFeedItem(drama: drama, firstEpisode: episode, videoURL: url,
                firstEpisodeLikeCount: raw.likeCount ?? 0, isFirstEpisodeLiked: raw.isLiked ?? false,
                isFavorited: response.isFavorited ?? false, playbackID: episode.id,
                favoriteCount: response.favoriteCount)
        }.sorted { ($0.firstEpisode?.number ?? 0) < ($1.firstEpisode?.number ?? 0) }
    }

    func initialID(request: PlaybackRequest) -> String? {
        if let item = items.first(where: { $0.firstEpisode?.id == request.episode.id }) { return item.id }
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
        for index in items.indices where items[index].drama.id == id {
            items[index].isFavorited = isFavorite
            if let count { items[index].favoriteCount = count }
        }
    }

    func unlock(_ episode: Episode) async throws {
        guard let dramaID = Int64(drama.id), let episodeID = Int64(episode.id) else { throw CatalogError.notFound }
        let response = try await network.request(AppAPI.v1DramaEpisodeUnlock,
            body: .init(dramaId: dramaID, episodeId: episodeID), unwrapEnvelope: true)
        guard response.canWatch == true || response.unlocked == true else { throw CatalogError.episodeLocked }
        await load()
        guard let item = items.first(where: { $0.firstEpisode?.id == episode.id }),
              item.videoURL != nil, item.firstEpisode?.requiresCoinUnlock == false else { throw CatalogError.episodeLocked }
    }

    func reportFeedback(_ episode: Episode, categoryCode: String) async throws {
        guard let episodeID = Int64(episode.id) else { throw CatalogError.notFound }
        _ = try await network.request(AppAPI.v1ClientDramaEpisodeFeedback,
            body: .init(episodeId: episodeID, categoryCode: categoryCode), unwrapEnvelope: true)
    }
}
