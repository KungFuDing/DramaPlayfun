import Foundation

/// Coalesces expiry reports from the current episode and its preload into one request.
@MainActor
final class PlaybackURLRefresher {
    private let network: APIClient
    private var pending: [String: Task<[String: URL], Error>] = [:]

    init(network: APIClient) { self.network = network }

    func refresh(_ items: [TheaterFeedItem], requiredID: String?) async throws -> [String: URL] {
        let videos = items.compactMap { item -> APIModels.V1XMTokenVideo? in
            guard item.firstEpisode?.requiresCoinUnlock == false,
                  let id = (item.firstEpisode?.id).flatMap(Int64.init), let url = item.videoURL else { return nil }
            return .init(episodeId: id, videoUrl: url.absoluteString)
        }
        guard let requiredID, videos.contains(where: { String($0.episodeId ?? 0) == requiredID }) else {
            throw CatalogError.mediaNotConfigured
        }
        let key = videos.map { "\($0.episodeId ?? 0)|\($0.videoUrl ?? "")" }.joined(separator: "\n")
        if let task = pending[key] { return try await task.value }
        let task = Task { [network] in
            let response = try await network.request(AppAPI.v1ClientXMToken,
                body: .init(videoList: videos), unwrapEnvelope: true)
            let expected = Set(videos.compactMap(\.episodeId))
            var urls: [String: URL] = [:]
            for video in response.videoList ?? [] {
                guard let id = video.episodeId, expected.contains(id),
                      let raw = video.videoUrl, let url = URL(string: raw),
                      url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
                      url.user == nil, url.password == nil,
                      HLSLocalGateway.mediaToken(from: url)?.isEmpty == false else { continue }
                urls[String(id)] = url
            }
            guard urls.count == expected.count else { throw CatalogError.mediaNotConfigured }
            return urls
        }
        pending[key] = task
        defer { pending[key] = nil }
        return try await task.value
    }
}
