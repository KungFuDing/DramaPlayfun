import Foundation
import Observation

struct TheaterFeedItem: Identifiable {
    let drama: Drama
    let firstEpisode: Episode?
    let videoURL: URL?
    let firstEpisodeLikeCount: Int
    let isFirstEpisodeLiked: Bool
    let isFavorited: Bool

    var id: Drama.ID { drama.id }
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
    private(set) var errorMessage: String?
    private(set) var loadMoreErrorMessage: String?

    private let network: APIClient
    private let pageSize = 20
    private var page = 0
    private var generation = 0

    init(network: APIClient) { self.network = network }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        generation += 1
        let requestGeneration = generation
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        loadMoreErrorMessage = nil
        defer { isLoading = false }
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
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasLoaded, hasMore, !isLoading, !isLoadingMore else { return }
        let requestGeneration = generation
        isLoadingMore = true
        loadMoreErrorMessage = nil
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
            if requestGeneration == generation { loadMoreErrorMessage = error.localizedDescription }
        }
    }

    private static func makeItem(_ raw: APIModels.V2HomeListItem) -> TheaterFeedItem? {
        guard let dramaID = raw.dramaId ?? raw.rootDramaId ?? raw.id.map(Int64.init),
              let title = raw.dramaTitle, !title.isEmpty else { return nil }
        let first = raw.episodes?.first(where: { $0.episodeNo == 1 })
        let episodeID = first?.episodeId ?? raw.episodeId
        let episode = episodeID.map {
            Episode(id: String($0), number: 1, title: "第1集", requiresMembership: false)
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
