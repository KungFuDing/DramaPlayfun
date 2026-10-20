import Foundation
import Observation

struct DramaFeedTab: Identifiable, Hashable {
    let id: String
    let title: String
    let serverID: Int64?

    var displayTitle: String { id == "featured" && serverID == nil ? L10n.tr("精选") : title }

    static let featured = DramaFeedTab(id: "featured", title: "精选", serverID: nil)
}

struct DramaTabPage {
    var dramas: [Drama] = []
    var page = 0
    var hasMore = false
    var isLoading = false
    var isLoadingMore = false
    var hasLoaded = false
    var loadError: Error?
    var errorMessage: String? {
        _ = LocalizationStore.shared.language
        return loadError?.appLocalizedDescription
    }
    var loadMoreError: Error?
    var loadMoreErrorMessage: String? {
        _ = LocalizationStore.shared.language
        return loadMoreError?.appLocalizedDescription
    }
    var requestID = UUID()
}

@MainActor @Observable
final class DramaTabFeedStore {
    enum Source { case homeTags, rankings }

    private(set) var tabs: [DramaFeedTab]
    var selectedID: String
    private(set) var isLoadingTabs = false
    private var tabsError: Error?
    var tabsErrorMessage: String? {
        _ = LocalizationStore.shared.language
        return tabsError?.appLocalizedDescription
    }
    private(set) var hasLoadedTabs = false
    private(set) var pages: [String: DramaTabPage] = [:]
    private let network: APIClient
    private let source: Source
    private let pageSize: Int

    init(network: APIClient, source: Source, pageSize: Int = 20) {
        self.network = network
        self.source = source
        self.pageSize = pageSize
        tabs = source == .homeTags ? [.featured] : []
        selectedID = source == .homeTags ? DramaFeedTab.featured.id : ""
    }

    var selectedPage: DramaTabPage { page(for: selectedID) }
    func page(for id: String) -> DramaTabPage { pages[id] ?? DramaTabPage() }

    func loadTabsIfNeeded() async {
        guard !hasLoadedTabs else { return }
        await reloadTabs()
    }

    func reloadTabs() async {
        guard !isLoadingTabs else { return }
        isLoadingTabs = true
        tabsError = nil
        defer { isLoadingTabs = false }
        do {
            var loaded: [DramaFeedTab]
            switch source {
            case .homeTags:
                let result = try await network.request(AppAPI.v1DramaTagList, body: .init(), unwrapEnvelope: true)
                loaded = (result.list ?? []).compactMap { item in
                    Self.tab(id: item.tagId, title: item.tagName, prefix: "tag")
                }
                loaded.insert(.featured, at: 0)
            case .rankings:
                let result = try await network.request(AppAPI.v1DramaCategoryList,
                    body: .init(type: "ranking"), unwrapEnvelope: true)
                loaded = (result.list ?? []).compactMap { item in
                    Self.tab(id: item.categoryId, title: item.categoryName, prefix: "ranking")
                }
            }
            try Task.checkCancellation()
            var ids = Set<String>()
            tabs = loaded.filter { ids.insert($0.id).inserted }
            // Keep cached pages only for categories still returned by the server.
            pages = pages.filter { ids.contains($0.key) }
            if !ids.contains(selectedID) { selectedID = tabs.first?.id ?? "" }
            hasLoadedTabs = true
        } catch is CancellationError {
        } catch {
            tabsError = error
        }
    }

    func loadSelectedIfNeeded() async {
        let id = selectedID
        guard !page(for: id).hasLoaded else { return }
        await fetch(id: id, refresh: true)
    }

    func refreshSelected() async {
        await fetch(id: selectedID, refresh: true)
    }

    func loadMore() async {
        let id = selectedID
        let state = page(for: id)
        guard state.hasLoaded, state.hasMore, !state.isLoading, !state.isLoadingMore else { return }
        await fetch(id: id, refresh: false)
    }

    private func fetch(id: String, refresh: Bool) async {
        guard let tab = tabs.first(where: { $0.id == id }), let serverID = tab.serverID else { return }
        var state = page(for: id)
        guard refresh || (!state.isLoading && !state.isLoadingMore) else { return }
        let requestID = UUID()
        let nextPage = refresh ? 1 : state.page + 1
        state.requestID = requestID
        state.isLoading = refresh
        state.isLoadingMore = !refresh
        if refresh { state.loadError = nil }
        state.loadMoreError = nil
        pages[id] = state
        defer {
            if pages[id]?.requestID == requestID {
                pages[id]?.isLoading = false
                pages[id]?.isLoadingMore = false
            }
        }
        do {
            let dramas: [Drama]
            let hasMore: Bool
            switch source {
            case .homeTags:
                let result = try await network.request(AppAPI.v1DramaTagSeriesList,
                    body: .init(tagId: serverID, page: nextPage, pageSize: pageSize), unwrapEnvelope: true)
                dramas = (result.list ?? []).compactMap { item in
                    Self.drama(id: item.dramaId ?? item.id ?? item.rootDramaId, title: item.dramaTitle,
                        summary: nil, tags: item.tagNames, badge: item.badge, cover: item.coverUrl,
                        rootID: item.rootDramaId,
                        playbackPosition: PlaybackPosition(episodeNumber: item.episodeNo,
                                                           seconds: item.progressSeconds.map(Double.init)))
                }
                hasMore = result.hasMore ?? false
            case .rankings:
                let result = try await network.request(AppAPI.v2TheaterRankList,
                    body: .init(categoryId: serverID, page: nextPage, pageSize: pageSize), unwrapEnvelope: true)
                dramas = (result.list ?? []).compactMap { item in
                    Self.drama(id: item.dramaId ?? item.id ?? item.rootDramaId, title: item.dramaTitle,
                        summary: item.dramaDesc, tags: item.tagNames, badge: nil, cover: item.coverUrl,
                        rootID: item.rootDramaId)
                }
                // This endpoint has no hasMore field: a short raw page marks its end.
                hasMore = (result.list ?? []).count >= pageSize
            }
            try Task.checkCancellation()
            guard pages[id]?.requestID == requestID else { return }
            var updated = pages[id]!
            if refresh { updated.dramas = [] }
            var ids = Set(updated.dramas.map(\.id))
            let appended = dramas.filter { ids.insert($0.id).inserted }
            updated.dramas += appended
            updated.page = nextPage
            updated.hasMore = hasMore && (source != .rankings || refresh || !appended.isEmpty)
            updated.hasLoaded = true
            updated.loadError = nil
            updated.loadMoreError = nil
            pages[id] = updated
        } catch is CancellationError {
        } catch {
            if pages[id]?.requestID == requestID {
                if refresh { pages[id]?.loadError = error }
                else { pages[id]?.loadMoreError = error }
            }
        }
    }

    private static func tab(id: Int64?, title: String?, prefix: String) -> DramaFeedTab? {
        guard let id, let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return DramaFeedTab(id: "\(prefix)-\(id)", title: title, serverID: id)
    }

    private static func drama(id: Int64?, title: String?, summary: String?, tags: [String]?,
                              badge: String?, cover: String?, rootID: Int64?,
                              playbackPosition: PlaybackPosition? = nil) -> Drama? {
        guard let id, let title, !title.isEmpty else { return nil }
        let category = DramaCategory.allCases.first { category in
            category != .all && (tags ?? []).contains(where: { $0.localizedStandardContains(category.rawValue) })
        } ?? .all
        let url = cover.flatMap(URL.init(string:)).flatMap { url in
            ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil ? url : nil
        }
        return Drama(id: String(id), title: title, summary: summary ?? "", category: category,
            episodeCount: 0, heat: 0, badge: badge, coverURL: url, tagNames: tags ?? [], rootDramaID: rootID,
            playbackPosition: playbackPosition)
    }
}
