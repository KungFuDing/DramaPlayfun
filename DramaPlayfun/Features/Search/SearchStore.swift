import Foundation
import Observation

@MainActor @Observable
final class SearchStore {
    private(set) var history: [String] = []
    private(set) var suggestions: [Drama] = []
    private(set) var results: [Drama] = []
    private(set) var isLoadingHistory = false
    private(set) var isClearingHistory = false
    private(set) var isLoadingSuggestions = false
    private(set) var isSearching = false
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private var historyFailure: Error?
    var historyError: String? {
        _ = LocalizationStore.shared.language
        return historyFailure?.appLocalizedDescription
    }
    private var searchFailure: Error?
    var searchError: String? {
        _ = LocalizationStore.shared.language
        return searchFailure?.appLocalizedDescription
    }
    private var loadMoreFailure: Error?
    var loadMoreError: String? {
        _ = LocalizationStore.shared.language
        return loadMoreFailure?.appLocalizedDescription
    }
    private var keyword = ""
    private var page = 0
    private var generation = 0
    private var historyGeneration = 0
    private let network: APIClient
    private let pageSize = 20

    init(network: APIClient) { self.network = network }

    func loadHistory() async {
        guard !isClearingHistory else { return }
        historyGeneration += 1
        let current = historyGeneration
        isLoadingHistory = true
        historyFailure = nil
        defer { if current == historyGeneration { isLoadingHistory = false } }
        do {
            let response = try await network.request(AppAPI.v1TheaterSearchHistory,
                body: .init(page: 1, pageSize: pageSize), unwrapEnvelope: true)
            try Task.checkCancellation()
            guard current == historyGeneration else { return }
            var seen = Set<String>()
            history = (response.list ?? []).map(Self.trim).filter { !$0.isEmpty && seen.insert($0).inserted }
        } catch is CancellationError {
        } catch {
            if current == historyGeneration { historyFailure = error }
        }
    }

    func clearHistory() async {
        guard !isClearingHistory else { return }
        historyGeneration += 1
        isLoadingHistory = false
        isClearingHistory = true
        historyFailure = nil
        defer { isClearingHistory = false }
        do {
            _ = try await network.request(AppAPI.v1TheaterSearchHistoryClear, body: .init(), unwrapEnvelope: true)
            try Task.checkCancellation()
            history = []
        } catch is CancellationError {
        } catch { historyFailure = error }
    }

    func suggest(_ input: String, debounce: Duration = .milliseconds(250)) async {
        generation += 1
        let current = generation
        keyword = ""
        results = []
        suggestions = []
        hasMore = false
        isSearching = false
        isLoadingMore = false
        searchFailure = nil
        loadMoreFailure = nil
        let input = Self.trim(input)
        isLoadingSuggestions = !input.isEmpty
        guard !input.isEmpty else { return }
        defer { if current == generation { isLoadingSuggestions = false } }
        do {
            try await Task.sleep(for: debounce)
            try Task.checkCancellation()
            let response = try await network.request(AppAPI.v1TheaterSearchGuess,
                body: .init(keyword: input), unwrapEnvelope: true)
            try Task.checkCancellation()
            guard current == generation else { return }
            suggestions = Self.unique((response.list ?? []).compactMap {
                Self.drama(id: $0.dramaId ?? $0.id ?? $0.rootDramaId, root: $0.rootDramaId,
                    title: $0.dramaTitle, summary: $0.dramaDesc, tags: $0.tagNames,
                    badge: $0.badge, cover: $0.coverUrl,
                    playbackPosition: PlaybackPosition(episodeNumber: $0.episodeNo,
                        seconds: $0.progressSeconds.map(Double.init)))
            })
        } catch is CancellationError {
        } catch {
            if current == generation { searchFailure = error }
        }
    }

    func search(_ input: String) async {
        let input = Self.trim(input)
        guard !input.isEmpty else { await suggest(""); return }
        generation += 1
        let current = generation
        keyword = input
        page = 0
        results = []
        suggestions = []
        hasMore = false
        isLoadingSuggestions = false
        isLoadingMore = false
        isSearching = true
        searchFailure = nil
        loadMoreFailure = nil
        await fetchResults(page: 1, generation: current)
    }

    func loadMore() async {
        guard hasMore, !isSearching, !isLoadingMore, !keyword.isEmpty else { return }
        isLoadingMore = true
        loadMoreFailure = nil
        await fetchResults(page: page + 1, generation: generation)
    }

    private func fetchResults(page nextPage: Int, generation current: Int) async {
        let requestedKeyword = keyword
        defer {
            if current == generation { isSearching = false; isLoadingMore = false }
        }
        do {
            let response = try await network.request(AppAPI.v1TheaterSearch,
                body: .init(keyword: requestedKeyword, page: nextPage, pageSize: pageSize), unwrapEnvelope: true)
            try Task.checkCancellation()
            guard current == generation else { return }
            let incoming = (response.list ?? []).compactMap {
                Self.drama(id: $0.dramaId ?? $0.id ?? $0.rootDramaId, root: $0.rootDramaId,
                    title: $0.dramaTitle, summary: $0.dramaDesc, tags: $0.tagNames,
                    badge: $0.badge, cover: $0.coverUrl,
                    playbackPosition: PlaybackPosition(episodeNumber: $0.episodeNo,
                        seconds: $0.progressSeconds.map(Double.init)))
            }
            results = Self.unique(results + incoming)
            page = max(nextPage, response.page ?? nextPage)
            hasMore = response.hasMore ?? response.total.map { results.count < $0 }
                ?? ((response.list ?? []).count >= pageSize)
            if nextPage == 1 {
                historyGeneration += 1
                isLoadingHistory = false
                history = [requestedKeyword] + history.filter { $0 != requestedKeyword }
                history = Array(history.prefix(pageSize))
            }
        } catch is CancellationError {
        } catch {
            guard current == generation else { return }
            if nextPage == 1 { searchFailure = error }
            else { loadMoreFailure = error }
        }
    }

    private static func trim(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unique(_ dramas: [Drama]) -> [Drama] {
        var seen = Set<String>()
        return dramas.filter { seen.insert($0.id).inserted }
    }

    private static func drama(id: Int64?, root: Int64?, title: String?, summary: String?,
                              tags: [String]?, badge: String?, cover: String?,
                              playbackPosition: PlaybackPosition) -> Drama? {
        guard let id, let title, !trim(title).isEmpty else { return nil }
        let url = cover.flatMap(URL.init(string:)).flatMap {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil ? $0 : nil
        }
        let category = DramaCategory.allCases.first { category in
            category != .all && (tags ?? []).contains { $0.localizedStandardContains(category.rawValue) }
        } ?? .all
        return Drama(id: String(id), title: title, summary: summary ?? "", category: category,
            episodeCount: 0, heat: 0, badge: badge, coverURL: url, tagNames: tags ?? [],
            rootDramaID: root, playbackPosition: playbackPosition)
    }
}
