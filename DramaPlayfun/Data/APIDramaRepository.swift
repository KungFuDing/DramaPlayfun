import Foundation

/// Keeps the existing demo catalog while resolving server-backed theater dramas by numeric ID.
@MainActor
struct APIDramaRepository: DramaRepository {
    let network: APIClient
    let fallback: any DramaRepository
    var detailCache: PlaybackDetailCache? = nil

    func fetchDramas() async throws -> [Drama] {
        try await fallback.fetchDramas()
    }

    func fetchEpisodes(dramaID: Drama.ID) async throws -> [Episode] {
        guard let id = Int64(dramaID) else { return try await fallback.fetchEpisodes(dramaID: dramaID) }
        let snapshot = try await episodeList(dramaID: id)
        return (snapshot.response.episodes ?? []).compactMap { item -> Episode? in
            guard let episodeID = item.episodeId, let number = item.episodeNo else { return nil }
            return Episode(id: String(episodeID), number: number, title: "",
                           requiresMembership: false, unlockCoin: item.unlockCoin ?? 0,
                           isUnlocked: item.isUnlocked ?? false,
                           requiresAccessValidation: snapshot.requiresAccessValidation)
        }.sorted { $0.number < $1.number }
    }

    func playbackURL(dramaID: Drama.ID, episodeID: Episode.ID) async throws -> URL {
        try await playbackSource(dramaID: dramaID, episodeID: episodeID).url
    }

    func playbackSource(dramaID: Drama.ID, episodeID: Episode.ID) async throws -> PlaybackSource {
        guard let id = Int64(dramaID), let numericEpisodeID = Int(episodeID) else {
            return try await fallback.playbackSource(dramaID: dramaID, episodeID: episodeID)
        }
        let scope = network.playbackCacheScope
        let snapshot = try await episodeList(dramaID: id)
        let result = snapshot.response
        guard let item = result.episodes?.first(where: { $0.episodeId == numericEpisodeID }) else {
            throw CatalogError.notFound
        }
        if snapshot.requiresAccessValidation {
            let status = try await network.request(AppAPI.v1DramaEpisodeUnlockStatus,
                body: .init(episodeId: Int64(numericEpisodeID)), unwrapEnvelope: true)
            try Task.checkCancellation()
            guard network.playbackCacheScope == scope else { throw CancellationError() }
            guard status.episodeId == nil || status.episodeId == Int64(numericEpisodeID) else {
                throw EpisodeUnlockError.accessUnavailable
            }
            _ = try PlaybackAccessPolicy.validUntil(for: status, now: Date())
        } else if (item.unlockCoin ?? 0) > 0 && item.isUnlocked != true {
            throw CatalogError.episodeLocked
        }
        guard let raw = item.videoUrl, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.host != nil else {
            throw CatalogError.mediaNotConfigured
        }
        return PlaybackSource(url: url, rootDramaID: result.rootDramaId)
    }

    private func episodeList(dramaID: Int64) async throws -> PlaybackDetailSnapshot {
        if let detailCache { return try await detailCache.loadSnapshot(dramaID: String(dramaID)) }
        let response = try await network.request(AppAPI.v1ClientDramaEpisodeList,
            body: .init(dramaId: dramaID), unwrapEnvelope: true)
        return PlaybackDetailSnapshot(response: response, storedAt: Date(), requiresAccessValidation: false)
    }
}
