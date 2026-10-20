import Foundation
import Observation

struct WatchHistoryItem: Identifiable {
    let drama: Drama
    let episodeID: String?
    let episodeNumber: Int?
    let seconds: Double
    let episodeText: String?
    let isOnline: Bool

    var id: String { drama.id }
    var subtitle: String {
        let episode = episodeNumber.map { L10n.tr("第%d集", $0) } ?? episodeText ?? L10n.tr("观看记录")
        guard seconds > 0 else { return episode }
        let time = Int(seconds)
        return L10n.tr("%@ · 已观看 %@", episode, String(format: "%d:%02d", time / 60, time % 60))
    }

    func fraction(using library: LibraryStore) -> Double? {
        guard let episodeID else { return nil }
        let local = library.progress[id]
        let duration: Double?
        if let local, local.episodeID == episodeID, local.duration > 0 {
            duration = local.duration
        } else {
            // Localized drama IDs can differ while the watched episode ID stays the same.
            duration = library.progress.values
                .filter { $0.episodeID == episodeID && $0.duration > 0 }
                .max(by: { $0.updatedAt < $1.updatedAt })?.duration
        }
        guard let duration else { return nil }
        return min(max(seconds / duration, 0), 1)
    }

    var playbackPosition: PlaybackPosition {
        PlaybackPosition(episodeNumber: episodeNumber, seconds: seconds)
    }
}

@MainActor @Observable
final class WatchHistoryStore {
    private(set) var items: [WatchHistoryItem] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private var loadError: Error?
    var errorMessage: String? {
        _ = LocalizationStore.shared.language
        return loadError?.appLocalizedDescription
    }
    private var loadMoreError: Error?
    var loadMoreErrorMessage: String? {
        _ = LocalizationStore.shared.language
        return loadMoreError?.appLocalizedDescription
    }
    private var page = 0
    private var generation = 0
    private let network: APIClient
    private let pageSize = 20

    init(network: APIClient) { self.network = network }

    func clearAccountData() {
        generation += 1
        items = []
        page = 0
        hasMore = false
        loadError = nil
        loadMoreError = nil
    }

    func reload() async {
        guard !isLoading else { return }
        generation += 1
        let current = generation
        isLoading = true
        isLoadingMore = false
        loadError = nil
        loadMoreError = nil
        defer { isLoading = false }
        do {
            let result = try await network.request(AppAPI.v1ClientMeHistoryList,
                body: .init(page: 1, pageSize: pageSize), unwrapEnvelope: true)
            try Task.checkCancellation()
            guard current == generation else { return }
            var ids = Set<String>()
            items = (result.list ?? []).compactMap(Self.item).filter { ids.insert($0.id).inserted }
            page = result.page ?? 1
            hasMore = result.hasMore ?? false
        } catch is CancellationError {
        } catch {
            loadError = error
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        let current = generation
        let nextPage = page + 1
        isLoadingMore = true
        loadMoreError = nil
        defer { if current == generation { isLoadingMore = false } }
        do {
            let result = try await network.request(AppAPI.v1ClientMeHistoryList,
                body: .init(page: nextPage, pageSize: pageSize), unwrapEnvelope: true)
            try Task.checkCancellation()
            guard current == generation else { return }
            var ids = Set(items.map(\.id))
            items += (result.list ?? []).compactMap(Self.item).filter { ids.insert($0.id).inserted }
            page = result.page ?? nextPage
            hasMore = result.hasMore ?? false
        } catch is CancellationError {
        } catch {
            if current == generation { loadMoreError = error }
        }
    }

    private static func item(_ raw: APIModels.V1MyHistoryItem) -> WatchHistoryItem? {
        guard let id = raw.dramaId ?? raw.id ?? raw.rootDramaId,
              let title = raw.dramaTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let cover = raw.coverUrl.flatMap(URL.init(string:)).flatMap { url in
            ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil ? url : nil
        }
        let drama = Drama(id: String(id), title: title, summary: raw.dramaDesc ?? "", category: .all,
            episodeCount: 0, heat: 0, badge: raw.badge, coverURL: cover, rootDramaID: raw.rootDramaId)
        let episodeText = raw.episodeText?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WatchHistoryItem(drama: drama, episodeID: raw.episodeId.map(String.init),
            episodeNumber: raw.episodeNo.flatMap { $0 > 0 ? $0 : nil },
            seconds: Double(max(raw.progressSeconds ?? 0, 0)),
            episodeText: episodeText?.isEmpty == false ? episodeText : nil,
            isOnline: raw.isOnline?.lowercased() != "offline")
    }
}
