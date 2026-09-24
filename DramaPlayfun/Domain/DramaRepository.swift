import Foundation

/// Production implementations must obtain playback authorization from the server.
/// Client membership state is only used to present the paywall, never to protect media URLs.
@MainActor
protocol DramaRepository {
    func fetchDramas() async throws -> [Drama]
    func fetchEpisodes(dramaID: Drama.ID) async throws -> [Episode]
    func playbackURL(dramaID: Drama.ID, episodeID: Episode.ID) async throws -> URL
}

enum CatalogError: LocalizedError {
    case notFound
    case mediaNotConfigured

    var errorDescription: String? {
        switch self {
        case .notFound: "未找到该剧集，请刷新后重试。"
        case .mediaNotConfigured: "此剧暂未提供播放资源，请稍后再试。"
        }
    }
}
