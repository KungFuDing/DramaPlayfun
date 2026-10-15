import Foundation

/// Production implementations must obtain playback authorization from the server.
/// Client membership state is only used to present the paywall, never to protect media URLs.
@MainActor
protocol DramaRepository {
    func fetchDramas() async throws -> [Drama]
    func fetchEpisodes(dramaID: Drama.ID) async throws -> [Episode]
    func playbackURL(dramaID: Drama.ID, episodeID: Episode.ID) async throws -> URL
    func playbackSource(dramaID: Drama.ID, episodeID: Episode.ID) async throws -> PlaybackSource
}

struct PlaybackSource {
    let url: URL
    let rootDramaID: Int64?
}

extension DramaRepository {
    func playbackSource(dramaID: Drama.ID, episodeID: Episode.ID) async throws -> PlaybackSource {
        PlaybackSource(url: try await playbackURL(dramaID: dramaID, episodeID: episodeID),
                       rootDramaID: nil)
    }
}

enum CatalogError: AppLocalizedError {
    case notFound
    case mediaNotConfigured
    case episodeLocked

    var errorDescription: String? {
        switch self {
        case .notFound: L10n.text("未找到该剧集，请刷新后重试。")
        case .mediaNotConfigured: L10n.text("此剧暂未提供播放资源，请稍后再试。")
        case .episodeLocked: L10n.text("本集尚未解锁，请先在选集页解锁。")
        }
    }
}
