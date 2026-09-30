import Foundation

/// Keeps the existing demo catalog while resolving server-backed theater dramas by numeric ID.
@MainActor
struct APIDramaRepository: DramaRepository {
    let network: APIClient
    let fallback: any DramaRepository

    func fetchDramas() async throws -> [Drama] {
        try await fallback.fetchDramas()
    }

    func fetchEpisodes(dramaID: Drama.ID) async throws -> [Episode] {
        guard let id = Int64(dramaID) else { return try await fallback.fetchEpisodes(dramaID: dramaID) }
        let result = try await network.request(AppAPI.v1ClientDramaEpisodeList,
            body: .init(dramaId: id), unwrapEnvelope: true)
        return (result.episodes ?? []).compactMap { item -> Episode? in
            guard let episodeID = item.episodeId, let number = item.episodeNo else { return nil }
            return Episode(id: String(episodeID), number: number, title: "第\(number)集",
                           requiresMembership: false, unlockCoin: item.unlockCoin ?? 0,
                           isUnlocked: item.isUnlocked ?? false)
        }.sorted { $0.number < $1.number }
    }

    func playbackURL(dramaID: Drama.ID, episodeID: Episode.ID) async throws -> URL {
        try await playbackSource(dramaID: dramaID, episodeID: episodeID).url
    }

    func playbackSource(dramaID: Drama.ID, episodeID: Episode.ID) async throws -> PlaybackSource {
        guard let id = Int64(dramaID), let numericEpisodeID = Int(episodeID) else {
            return try await fallback.playbackSource(dramaID: dramaID, episodeID: episodeID)
        }
        let result = try await network.request(AppAPI.v1ClientDramaEpisodeList,
            body: .init(dramaId: id), unwrapEnvelope: true)
        guard let item = result.episodes?.first(where: { $0.episodeId == numericEpisodeID }) else {
            throw CatalogError.notFound
        }
        guard (item.unlockCoin ?? 0) == 0 || item.isUnlocked == true else {
            throw CatalogError.episodeLocked
        }
        guard let raw = item.videoUrl, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.host != nil else {
            throw CatalogError.mediaNotConfigured
        }
        return PlaybackSource(url: url, rootDramaID: result.rootDramaId)
    }
}
