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
    private let now: () -> Date
    private var snapshotDate: Date?
    private var accessDeadlines: [String: Date] = [:]
    private struct AccessValidation {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Void, Error>]
    }
    private var validations: [String: AccessValidation] = [:]
    private var activeAccessEpisodeID: String?
    private let accessPriceRefresh = EpisodeAccessPriceRefresh()
    private var generation = UUID()
    private(set) var contentRevision = 0
    // These grants come from the server, and exist only for this playback session.
    private var authorizedEpisodeIDs: Set<String> = []
    private var explicitConfirmationIDs: Set<String> = []
    let drama: Drama

    init(drama: Drama, network: APIClient, repository: any DramaRepository, library: LibraryStore,
         detailCache: PlaybackDetailCache? = nil, now: @escaping () -> Date = Date.init) {
        self.drama = drama
        self.network = network
        urlRefresher = PlaybackURLRefresher(network: network)
        self.repository = repository
        self.library = library
        self.detailCache = detailCache
        self.now = now
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
        contentRevision += 1
        return items
    }

    func load(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        generation = UUID()
        cancelAccessValidations()
        accessPriceRefresh.cancel()
        expireAccessIfNeeded()
        loadError = nil
        defer { isLoading = false }
        do {
            let loaded: [TheaterFeedItem]
            if let id = Int64(drama.id) {
                let response: APIModels.V1GetDramaEpisodeListRes
                let storedAt: Date
                let requiresValidation: Bool
                if let detailCache {
                    let snapshot = try await detailCache.loadSnapshot(dramaID: drama.id, forceRefresh: forceRefresh)
                    response = snapshot.response
                    storedAt = snapshot.storedAt
                    requiresValidation = snapshot.requiresAccessValidation
                } else {
                    response = try await network.request(AppAPI.v1ClientDramaEpisodeList,
                        body: .init(dramaId: id), unwrapEnvelope: true)
                    storedAt = now()
                    requiresValidation = false
                }
                snapshotDate = storedAt
                loaded = Self.makeItems(response, fallback: drama, authorizedEpisodeIDs: authorizedEpisodeIDs,
                    requiresAccessValidation: requiresValidation)
                for item in loaded {
                    guard let episode = item.firstEpisode, !authorizedEpisodeIDs.contains(episode.id) else { continue }
                    accessDeadlines[episode.id] = storedAt.addingTimeInterval(PlaybackAccessPolicy.maxAge)
                }
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
            contentRevision += 1
            if loaded.isEmpty { loadError = DramaPlaybackError.noPlayableEpisodes }
        } catch is CancellationError {
        } catch { loadError = error }
    }

    static func makeItems(_ response: APIModels.V1GetDramaEpisodeListRes, fallback: Drama,
                          authorizedEpisodeIDs: Set<String> = [],
                          requiresAccessValidation: Bool = false) -> [TheaterFeedItem] {
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
                isUnlocked: raw.isUnlocked == true || authorizedEpisodeIDs.contains(String(id)), looked: raw.looked,
                requiresAccessValidation: requiresAccessValidation && !authorizedEpisodeIDs.contains(String(id)))
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

    /// Publish newer metadata only if no interaction or authorization changed during
    /// the fetch. The shared cache is updated regardless, for the next visit.
    func revalidateDetails() async {
        guard let detailCache, Int64(drama.id) != nil, !items.isEmpty, validations.isEmpty else { return }
        let revision = contentRevision
        let loadGeneration = generation
        do {
            let snapshot = try await detailCache.revalidate(dramaID: drama.id)
            try Task.checkCancellation()
            guard generation == loadGeneration, contentRevision == revision, validations.isEmpty,
                  snapshotDate.map({ snapshot.storedAt > $0 }) ?? true else { return }
            let refreshed = Self.makeItems(snapshot.response, fallback: drama,
                authorizedEpisodeIDs: authorizedEpisodeIDs,
                requiresAccessValidation: snapshot.requiresAccessValidation)
            // Preserve prepared players when the resource only received a new token.
            items = refreshed.map { item in
                var item = item
                if let previous = items.first(where: { $0.id == item.id }) {
                    if previous.firstEpisode?.requiresAccessValidation == true,
                       item.firstEpisode?.requiresCoinUnlock == true, let episodeID = item.firstEpisode?.id {
                        explicitConfirmationIDs.insert(episodeID)
                    }
                    if let oldURL = previous.videoURL, let newURL = item.videoURL,
                       MediaResourceURL.contentKey(for: oldURL) == MediaResourceURL.contentKey(for: newURL) {
                        item.videoURL = oldURL
                    }
                }
                return item
            }
            snapshotDate = snapshot.storedAt
            for item in items {
                guard let episode = item.firstEpisode, !authorizedEpisodeIDs.contains(episode.id) else { continue }
                accessDeadlines[episode.id] = snapshot.storedAt.addingTimeInterval(PlaybackAccessPolicy.maxAge)
            }
            contentRevision += 1
            expireAccessIfNeeded()
        } catch { /* Retained metadata remains usable; access is validated separately. */ }
    }

    func accessDeadline(for episodeID: String?) -> Date? {
        guard let episodeID, let item = items.first(where: { $0.firstEpisode?.id == episodeID }),
              item.firstEpisode?.requiresAccessValidation == false else { return nil }
        return accessDeadlines[episodeID]
    }

    /// Unlike the UI's current-grant deadline, this remains stable while a grant
    /// becomes stale so the prefetch task does not cancel its own request.
    func accessPrefetchDeadline(for episodeID: String?) -> Date? {
        episodeID.flatMap { accessDeadlines[$0] }
    }

    /// Transfer speculative work to the selected page before SwiftUI cancels the
    /// previous page's task. A new foreground waiter may attach on the next turn.
    func setActiveAccessEpisode(_ episodeID: String?) {
        activeAccessEpisodeID = episodeID
        for (id, flight) in validations where id != episodeID && flight.waiters.isEmpty {
            validations[id] = nil
            flight.task.cancel()
        }
    }

    @discardableResult
    func expireAccessIfNeeded() -> Bool {
        var expired = false
        for index in items.indices {
            guard var episode = items[index].firstEpisode,
                  let deadline = accessDeadlines[episode.id], deadline <= now() else { continue }
            authorizedEpisodeIDs.remove(episode.id)
            guard !episode.requiresAccessValidation else { continue }
            episode.requiresAccessValidation = true
            replaceEpisode(at: index, with: episode)
            contentRevision += 1
            expired = true
        }
        return expired
    }

    /// This read-only path can never submit a coin transaction.
    func validateCachedAccess(_ requested: Episode) async throws {
        try Task.checkCancellation()
        expireAccessIfNeeded()
        guard let episode = items.first(where: { $0.firstEpisode?.id == requested.id })?.firstEpisode,
              episode.requiresAccessValidation else { return }
        let waiterID = UUID()
        let episodeID = episode.id
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                joinAccessValidation(episode, waiterID: waiterID, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelAccessWaiter(episodeID: episodeID, waiterID: waiterID)
            }
        }
        try Task.checkCancellation()
    }

    /// Only the immediate next episode is checked, without entering the purchase
    /// coordinator. Fresh grants are reused until their existing expiry.
    func prevalidateNextEpisode(after selectedID: String) async {
        guard let index = items.firstIndex(where: { $0.id == selectedID }),
              items.indices.contains(index + 1), let episode = items[index + 1].firstEpisode else { return }
        do {
            if let deadline = accessDeadline(for: episode.id) {
                try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSince(now()))))
            }
            try Task.checkCancellation()
            try await validateCachedAccess(episode)
        } catch {
            // Speculative failures stay local; selecting the page can retry and
            // show the foreground error without authorizing playback or a purchase.
        }
    }

    private func joinAccessValidation(_ episode: Episode, waiterID: UUID,
                                      continuation: CheckedContinuation<Void, Error>) {
        if var existing = validations[episode.id] {
            existing.waiters[waiterID] = continuation
            validations[episode.id] = existing
            return
        }
        // A metadata response started earlier must not overrule this access check.
        contentRevision += 1
        let loadGeneration = generation
        let scope = network.playbackCacheScope
        let validationID = UUID()
        let task = Task {
            let result: Result<Void, Error>
            do {
                try await performAccessValidation(episode, validationID: validationID,
                                                  loadGeneration: loadGeneration, scope: scope)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            finishAccessValidation(episodeID: episode.id, validationID: validationID, result: result)
        }
        validations[episode.id] = AccessValidation(id: validationID, task: task, waiters: [waiterID: continuation])
    }

    private func performAccessValidation(_ episode: Episode, validationID: UUID,
                                         loadGeneration: UUID, scope: String) async throws {
        let status = try await unlockStatus(episode)
        try Task.checkCancellation()
        guard generation == loadGeneration, scope == network.playbackCacheScope,
              validations[episode.id]?.id == validationID else { throw CancellationError() }
        // A payment or membership refresh may have granted this episode while
        // the read was pending. Do not replace its newer authorization.
        guard items.first(where: { $0.id == episode.id })?.firstEpisode?.requiresAccessValidation == true else { return }
        if let responseID = status.episodeId, String(responseID) != episode.id {
            throw EpisodeUnlockError.accessUnavailable
        }
        if status.canWatch == true {
            let deadline = try PlaybackAccessPolicy.validUntil(for: status, now: now())
            authorizePlayback(episode, validUntil: deadline)
            try await refreshPlayableEpisode(episode)
        } else {
            guard status.canWatch == false else { throw EpisodeUnlockError.accessUnavailable }
            // An old grant can report a zero price. Fetch the current price before
            // exposing confirmation, including when this is a speculative check.
            let response = try await freshEpisodeList()
            try Task.checkCancellation()
            guard generation == loadGeneration, scope == network.playbackCacheScope,
                  validations[episode.id]?.id == validationID else { throw CancellationError() }
            guard items.first(where: { $0.id == episode.id })?.firstEpisode?.requiresAccessValidation == true else { return }
            guard let fresh = Self.makeItems(response, fallback: drama).first(where: { $0.id == episode.id }),
                  let current = fresh.firstEpisode, current.requiresCoinUnlock,
                  let index = items.firstIndex(where: { $0.id == episode.id }) else {
                throw EpisodeUnlockError.accessUnavailable
            }
            authorizedEpisodeIDs.remove(episode.id)
            explicitConfirmationIDs.insert(episode.id)
            replaceEpisode(at: index, with: current)
            items[index].videoURL = fresh.videoURL
            accessDeadlines[episode.id] = now().addingTimeInterval(PlaybackAccessPolicy.maxAge)
            contentRevision += 1
        }
    }

    private func finishAccessValidation(episodeID: String, validationID: UUID, result: Result<Void, Error>) {
        guard let flight = validations[episodeID], flight.id == validationID else { return }
        validations[episodeID] = nil
        for waiter in flight.waiters.values { waiter.resume(with: result) }
    }

    private func cancelAccessWaiter(episodeID: String, waiterID: UUID) {
        guard var flight = validations[episodeID], let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        if flight.waiters.isEmpty && activeAccessEpisodeID != episodeID {
            validations[episodeID] = nil
            flight.task.cancel()
        } else {
            validations[episodeID] = flight
        }
        waiter.resume(throwing: CancellationError())
    }

    private func cancelAccessValidations() {
        let flights = validations.values
        validations.removeAll()
        for flight in flights {
            flight.task.cancel()
            for waiter in flight.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
    }

    private func freshEpisodeList() async throws -> APIModels.V1GetDramaEpisodeListRes {
        guard let id = Int64(drama.id) else { throw CatalogError.notFound }
        // Concurrent permission denials need one fresh price list. Separate
        // forceRefresh calls would otherwise supersede and cancel each other.
        return try await accessPriceRefresh.load { [self] in
            if let detailCache { return try await detailCache.load(dramaID: drama.id, forceRefresh: true) }
            return try await network.request(AppAPI.v1ClientDramaEpisodeList, body: .init(dramaId: id), unwrapEnvelope: true)
        }
    }

    private func replaceEpisode(at index: Int, with episode: Episode) {
        let current = items[index]
        items[index] = TheaterFeedItem(drama: current.drama, firstEpisode: episode,
            videoURL: current.videoURL, firstEpisodeLikeCount: current.firstEpisodeLikeCount,
            isFirstEpisodeLiked: current.isFirstEpisodeLiked, isFavorited: current.isFavorited,
            playbackID: current.playbackID, favoriteCount: current.favoriteCount)
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
        contentRevision += 1
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
        contentRevision += 1
    }

    func applyFavorite(_ id: Drama.ID, isFavorite: Bool, count: Int?) {
        contentRevision += 1
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
        detailCache?.invalidate(dramaID: drama.id)
        authorizePlayback(episode)
        return response
    }

    func hasAuthorizedPlayback(_ episode: Episode) -> Bool {
        expireAccessIfNeeded()
        return authorizedEpisodeIDs.contains(episode.id)
    }

    func requiresExplicitConfirmation(_ episode: Episode) -> Bool {
        explicitConfirmationIDs.contains(episode.id)
    }

    /// Preserve the confirmed grant even if fetching the signed URL subsequently fails.
    /// A retry then fetches the URL without submitting another coin transaction.
    func authorizePlayback(_ episode: Episode, validUntil: Date? = nil) {
        authorizedEpisodeIDs.insert(episode.id)
        explicitConfirmationIDs.remove(episode.id)
        accessDeadlines[episode.id] = validUntil ?? now().addingTimeInterval(PlaybackAccessPolicy.maxAge)
        guard let index = items.firstIndex(where: { $0.firstEpisode?.id == episode.id }),
              let currentEpisode = items[index].firstEpisode else { return }
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
        contentRevision += 1
    }

    func refreshPlayableEpisode(_ episode: Episode) async throws {
        expireAccessIfNeeded()
        if let current = items.first(where: { $0.firstEpisode?.id == episode.id }),
           current.firstEpisode?.canPlayWithoutValidation == true, current.videoURL != nil {
            return
        }
        if items.first(where: { $0.firstEpisode?.id == episode.id })?.firstEpisode?.requiresAccessValidation == true {
            throw EpisodeUnlockError.accessUnavailable
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
              item.videoURL != nil, item.firstEpisode?.canPlayWithoutValidation == true else {
            throw EpisodeUnlockError.playbackUnavailable
        }
        // Keep neighboring signed URLs, players and interaction state intact.
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let previous = items[index]
            items[index] = TheaterFeedItem(drama: item.drama, firstEpisode: item.firstEpisode,
                videoURL: item.videoURL, firstEpisodeLikeCount: previous.firstEpisodeLikeCount,
                isFirstEpisodeLiked: previous.isFirstEpisodeLiked, isFavorited: previous.isFavorited,
                playbackID: item.playbackID, favoriteCount: previous.favoriteCount)
            if !authorizedEpisodeIDs.contains(episode.id) {
                accessDeadlines[episode.id] = now().addingTimeInterval(PlaybackAccessPolicy.maxAge)
            }
            contentRevision += 1
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
