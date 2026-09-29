import Foundation
import Observation

struct HomeBanner: Identifiable {
    let id: String
    let drama: Drama
    let imageURL: URL?
}

struct HomeShelf: Identifiable {
    let id: String
    let title: String
    let dramas: [Drama]
}

@MainActor @Observable
final class HomeFeedStore {
    private(set) var banners: [HomeBanner] = []
    private(set) var shelves: [HomeShelf] = []
    private(set) var hotDramas: [Drama] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasMoreHot = false
    private(set) var homeErrorMessage: String?
    private(set) var hotErrorMessage: String?
    private(set) var hasLoaded = false
    private var hotPage = 0
    private let network: APIClient
    private let pageSize = 20

    init(network: APIClient) { self.network = network }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        guard !isLoading, !isLoadingMore else { return }
        isLoading = true
        homeErrorMessage = nil
        hotErrorMessage = nil
        defer { isLoading = false }
        do {
            let home = try await network.request(AppAPI.v1TheaterHome, body: .init(), unwrapEnvelope: true)
            try Task.checkCancellation()
            banners = (home.banners ?? []).compactMap(Self.banner)
            shelves = (home.list ?? []).enumerated().compactMap { index, group in
                guard let title = group.categoryName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else { return nil }
                return HomeShelf(id: "\(index)-\(title)", title: title,
                                 dramas: (group.list ?? []).compactMap(Self.drama))
            }
        } catch APIError.missingBaseURL {
            // Preview/offline mode until a server address is supplied in the build settings.
            let dramas = DemoDramaRepository.dramas
            banners = dramas.prefix(5).map { HomeBanner(id: $0.id, drama: $0, imageURL: nil) }
            shelves = [
                HomeShelf(id: "demo-latest", title: "最新发布", dramas: dramas),
                HomeShelf(id: "demo-exclusive", title: "独家播出",
                          dramas: dramas.filter { $0.category == .costume || $0.category == .drama })
            ]
            hotDramas = dramas
            hotPage = 1
            hasMoreHot = false
            hasLoaded = true
            return
        } catch is CancellationError {
            return
        } catch {
            homeErrorMessage = error.localizedDescription
        }
        hasLoaded = true
        hotDramas = []
        hotPage = 0
        hasMoreHot = true
        await loadMore()
    }

    func loadMore() async {
        guard hasMoreHot, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let nextPage = hotPage + 1
            let result = try await network.request(AppAPI.v1TheaterHomeHotPage,
                body: .init(page: nextPage, pageSize: pageSize), unwrapEnvelope: true)
            try Task.checkCancellation()
            let existingIDs = Set(hotDramas.map(\.id))
            hotDramas += (result.list ?? []).compactMap(Self.drama).filter { !existingIDs.contains($0.id) }
            hotPage = result.page ?? nextPage
            hasMoreHot = result.hasMore ?? false
            hotErrorMessage = nil
        } catch is CancellationError {
        } catch {
            hotErrorMessage = error.localizedDescription
        }
    }

    private static func banner(_ item: APIModels.V1TheaterHomeBannerItem) -> HomeBanner? {
        guard let id = item.id, let title = item.dramaTitle, !title.isEmpty else { return nil }
        let drama = Drama(id: String(id), title: title, summary: "", category: .all,
                          episodeCount: 0, heat: 0, badge: item.badge,
                          coverURL: imageURL(item.coverUrl))
        return HomeBanner(id: String(id), drama: drama, imageURL: imageURL(item.bannerImage))
    }

    private static func drama(_ item: APIModels.V1GetTheaterHomeCategoryDramaItem) -> Drama? {
        makeDrama(id: item.dramaId ?? item.id ?? item.rootDramaId, title: item.dramaTitle,
                  summary: nil, tags: item.tagNames, badge: item.badge, cover: item.coverUrl)
    }

    private static func drama(_ item: APIModels.V1GetTheaterHomeHotPageItem) -> Drama? {
        makeDrama(id: item.dramaId ?? item.id ?? item.rootDramaId, title: item.dramaTitle,
                  summary: item.dramaDesc, tags: item.tagNames, badge: item.badge, cover: item.coverUrl)
    }

    private static func makeDrama(id: Int64?, title: String?, summary: String?, tags: [String]?,
                                  badge: String?, cover: String?) -> Drama? {
        guard let id, let title, !title.isEmpty else { return nil }
        let category = DramaCategory.allCases.first { category in
            category != .all && (tags ?? []).contains(where: { $0.localizedStandardContains(category.rawValue) })
        } ?? .all
        return Drama(id: String(id), title: title, summary: summary ?? "", category: category,
                     episodeCount: 0, heat: 0, badge: badge, coverURL: imageURL(cover),
                     tagNames: tags ?? [])
    }

    private static func imageURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }
}
