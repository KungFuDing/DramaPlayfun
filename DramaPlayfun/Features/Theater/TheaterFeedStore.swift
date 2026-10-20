import Foundation
import Observation

struct TheaterFeedItem: Identifiable {
    let drama: Drama
    let firstEpisode: Episode?
    var videoURL: URL?
    var firstEpisodeLikeCount: Int
    var isFirstEpisodeLiked: Bool
    var isFavorited: Bool

    var playbackID: String? = nil
    var favoriteCount: Int? = nil

    var id: String { playbackID ?? drama.id }
    var keyIdentity: HLSKeyIdentity? {
        guard let firstEpisode else { return nil }
        return HLSKeyIdentity(drama: drama, episode: firstEpisode)
    }
}

@MainActor @Observable
final class TheaterFeedStore {
    private(set) var items: [TheaterFeedItem] = []
    private(set) var hasMore = false
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private var loadError: Error?
    private var loadMoreError: Error?
    var errorMessage: String? {
        _ = LocalizationStore.shared.language
        return loadError?.appLocalizedDescription
    }
    var loadMoreErrorMessage: String? {
        _ = LocalizationStore.shared.language
        return loadMoreError?.appLocalizedDescription
    }

    private(set) var likingIDs: Set<Drama.ID> = []
    private(set) var favoritingIDs: Set<Drama.ID> = []

    private let network: APIClient
    private let detailCache: PlaybackDetailCache?
    private let urlRefresher: PlaybackURLRefresher
    private let pageSize = 20
    private var page = 0
    private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(network: APIClient, detailCache: PlaybackDetailCache? = nil) {
        self.network = network
        self.detailCache = detailCache
        urlRefresher = PlaybackURLRefresher(network: network)
    }

    func refreshPlaybackURLs(for item: TheaterFeedItem) async throws -> [TheaterFeedItem] {
        guard let current = items.first(where: { $0.id == item.id }),
              current.firstEpisode?.number == 1 else { throw CatalogError.notFound }
        let requestGeneration = generation
        let urls = try await urlRefresher.refresh([current], requiredID: current.firstEpisode?.id)
        try Task.checkCancellation()
        guard requestGeneration == generation else { throw CancellationError() }
        for index in items.indices where items[index].id == current.id && items[index].videoURL == current.videoURL {
            items[index].videoURL = urls[items[index].firstEpisode?.id ?? ""]
        }
        return items
    }

    func loadIfNeeded() async {
        if let loadTask {
            await loadTask.value
            return
        }
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        if let loadTask {
            await loadTask.value
            return
        }
        guard !Task.isCancelled else { return }
        generation += 1
        let requestGeneration = generation
        isLoading = true
        isLoadingMore = false
        loadError = nil
        loadMoreError = nil
        // The store owns this request so leaving one screen cannot cancel another
        // caller's load. Every caller waits until the same result is published.
        let task = Task { await loadFirstPage(generation: requestGeneration) }
        loadTask = task
        await task.value
    }

    /// Retires pending reads when this store is replaced, such as a language change.
    func cancelLoading() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        isLoadingMore = false
    }

    private func loadFirstPage(generation requestGeneration: Int) async {
        defer {
            if requestGeneration == generation {
                isLoading = false
                loadTask = nil
            }
        }
        do {
            let result = try await network.request(AppAPI.v2ClientList,
                body: .init(page: 1, pageSize: pageSize), unwrapEnvelope: true)
            try Task.checkCancellation()
            guard requestGeneration == generation else { return }
            items = (result.list ?? []).compactMap(Self.makeItem)
            page = result.page ?? 1
            hasMore = result.hasMore ?? false
            hasLoaded = true
        } catch is CancellationError {
        } catch {
            if requestGeneration == generation { loadError = error }
        }
    }

    func loadMore() async {
        guard hasLoaded, hasMore, !isLoading, !isLoadingMore else { return }
        let requestGeneration = generation
        isLoadingMore = true
        loadMoreError = nil
        defer {
            if requestGeneration == generation { isLoadingMore = false }
        }
        do {
            let nextPage = page + 1
            let result = try await network.request(AppAPI.v2ClientList,
                body: .init(page: nextPage, pageSize: pageSize), unwrapEnvelope: true)
            try Task.checkCancellation()
            guard requestGeneration == generation else { return }
            var existingIDs = Set(items.map(\.id))
            items += (result.list ?? []).compactMap(Self.makeItem)
                .filter { existingIDs.insert($0.id).inserted }
            page = result.page ?? nextPage
            hasMore = result.hasMore ?? false
        } catch is CancellationError {
        } catch {
            if requestGeneration == generation { loadMoreError = error }
        }
    }

    func toggleLike(_ id: Drama.ID) async throws {
        guard !likingIDs.contains(id), let item = items.first(where: { $0.id == id }),
              let episodeID = (item.firstEpisode?.id).flatMap(Int64.init) else {
            if likingIDs.contains(id) { return }
            throw TheaterInteractionError.invalidEpisode
        }
        likingIDs.insert(id)
        defer { likingIDs.remove(id) }
        let liked = !item.isFirstEpisodeLiked
        let response = try await network.request(AppAPI.v1ClientDramaLike,
            body: .init(episodeId: episodeID, like: liked), unwrapEnvelope: true)
        detailCache?.invalidate(dramaID: item.drama.id)
        guard let index = items.firstIndex(where: { $0.id == id && $0.firstEpisode?.id == item.firstEpisode?.id }) else { return }
        items[index].isFirstEpisodeLiked = response.isLiked ?? liked
        items[index].firstEpisodeLikeCount = response.likeCount ?? max(0, item.firstEpisodeLikeCount + (liked ? 1 : -1))
    }

    func toggleFavorite(_ id: Drama.ID, library: LibraryStore) async throws {
        guard !favoritingIDs.contains(id), let item = items.first(where: { $0.id == id }),
              let dramaID = Int64(id) else {
            if favoritingIDs.contains(id) { return }
            throw TheaterInteractionError.invalidEpisode
        }
        favoritingIDs.insert(id)
        defer { favoritingIDs.remove(id) }
        let favorite = !item.isFavorited
        let response = try await network.request(AppAPI.v1ClientDramaFavorite,
            body: .init(dramaId: dramaID, favorite: favorite), unwrapEnvelope: true)
        detailCache?.invalidate(dramaID: id)
        let value = response.isFavorited ?? favorite
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].isFavorited = value }
        library.setFavorite(id, isFavorite: value)
    }

    func applyFavorite(_ id: Drama.ID, isFavorite: Bool, count: Int?) {
        detailCache?.invalidate(dramaID: id)
        for index in items.indices where items[index].drama.id == id {
            items[index].isFavorited = isFavorite
            if let count { items[index].favoriteCount = count }
        }
    }

    private static func makeItem(_ raw: APIModels.V2HomeListItem) -> TheaterFeedItem? {
        guard let dramaID = raw.dramaId ?? raw.rootDramaId ?? raw.id.map(Int64.init),
              let title = raw.dramaTitle, !title.isEmpty else { return nil }
        let first = raw.episodes?.first(where: { $0.episodeNo == 1 })
        let episodeID = first?.episodeId ?? raw.episodeId
        let episode = episodeID.map {
            Episode(id: String($0), number: 1, title: "", requiresMembership: false)
        }
        let tags = raw.tagNames ?? []
        let category = DramaCategory.allCases.first { category in
            category != .all && tags.contains(where: { $0.localizedStandardContains(category.rawValue) })
        } ?? .all
        let drama = Drama(id: String(dramaID), title: title, summary: raw.dramaDesc ?? "",
                          category: category, episodeCount: raw.episodePassed ?? 0,
                          heat: raw.favoriteCount ?? 0, badge: nil,
                          coverURL: validURL(raw.coverUrl), tagNames: tags,
                          rootDramaID: raw.rootDramaId)
        return TheaterFeedItem(drama: drama, firstEpisode: episode,
                               videoURL: validURL(first?.videoUrl),
                               firstEpisodeLikeCount: first?.likeCount ?? 0,
                               isFirstEpisodeLiked: first?.isLiked ?? false,
                               isFavorited: raw.isFavorited ?? false)
    }

    private static func validURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
}


nonisolated enum TheaterInteractionError: AppLocalizedError {
    case invalidEpisode, missingShareText, missingCover, imageRendering, photoPermission, progressRejected
    var errorDescription: String? {
        switch self {
        case .invalidEpisode: L10n.text("剧集信息无效，请重新加载。")
        case .missingShareText: L10n.text("暂无有效分享内容，请重试。")
        case .missingCover: L10n.text("暂无短剧封面，无法生成分享图片。")
        case .imageRendering: L10n.text("分享图片生成失败，请重试。")
        case .photoPermission: L10n.text("请在系统设置中允许添加照片后重试。")
        case .progressRejected: L10n.text("观看进度保存失败。")
        }
    }
}
