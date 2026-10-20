import Moya
import XCTest
@testable import DramaPlayfun

@MainActor
final class PlaybackCacheIntegrationTests: XCTestCase {
    private let drama = Drama(id: "101", title: "列表标题", summary: "", category: .drama,
        episodeCount: 2, heat: 0, badge: nil, coverURL: nil, rootDramaID: 100)

    func testRepeatedLoadsAndNewPlayerStoreReuseDetailResponse() async throws {
        var requests = 0
        let network = try client { _ in
            requests += 1
            return Self.response()
        }
        let cache = PlaybackDetailCache(network: network, directory: try temporaryDirectory())
        let first = makeStore(network: network, cache: cache)

        await first.load()
        await first.load()
        let reopened = makeStore(network: network, cache: cache)
        await reopened.load()

        XCTAssertEqual(requests, 1, "Reopening playback should reuse the downloaded episode details")
        XCTAssertEqual(first.items.map(\.id), ["1001", "1002"])
        XCTAssertEqual(reopened.items.map(\.id), first.items.map(\.id))
        XCTAssertEqual(reopened.items.first?.drama.title, "详情版本1")
        XCTAssertEqual(reopened.items.first?.videoURL, first.items.first?.videoURL)
        XCTAssertTrue(try XCTUnwrap(reopened.items.last?.firstEpisode).requiresCoinUnlock,
                      "Cache reuse must preserve the paid episode's access requirement")
        XCTAssertNil(reopened.errorMessage)
    }

    func testEnteringPlayerDuringPrefetchSharesThePendingRequest() async throws {
        var requests = 0
        let started = expectation(description: "Detail prefetch started")
        let network = try client(delay: 0.2) { _ in
            requests += 1
            if requests == 1 { started.fulfill() }
            return Self.response()
        }
        let cache = PlaybackDetailCache(network: network, directory: try temporaryDirectory())
        let prefetch = _Concurrency.Task { await cache.prefetch(dramaID: drama.id) }
        await fulfillment(of: [started], timeout: 2)
        let store = makeStore(network: network, cache: cache)

        await store.load()
        await prefetch.value

        XCTAssertEqual(requests, 1, "A tap while prefetching must join the existing detail request")
        XCTAssertEqual(store.items.first?.firstEpisode?.id, "1001")
        XCTAssertNotNil(store.items.first?.videoURL)
        XCTAssertNil(store.errorMessage)
    }

    func testRepositoryEpisodeSelectionAndPlaybackSourceShareDetailCache() async throws {
        var requests = 0
        let network = try client { _ in
            requests += 1
            return Self.response()
        }
        let cache = PlaybackDetailCache(network: network, directory: try temporaryDirectory())
        let repository = APIDramaRepository(network: network, fallback: DemoDramaRepository(), detailCache: cache)

        let episodes = try await repository.fetchEpisodes(dramaID: drama.id)
        let first = try XCTUnwrap(episodes.first)
        let source = try await repository.playbackSource(dramaID: drama.id, episodeID: first.id)
        let store = makeStore(network: network, cache: cache)
        await store.load()

        XCTAssertEqual(requests, 1, "Episode selection and player entry should consume the same response")
        XCTAssertEqual(episodes.map(\.id), ["1001", "1002"])
        XCTAssertEqual(source.rootDramaID, 100)
        XCTAssertEqual(source.url.absoluteString, "https://example.invalid/1.m3u8?X-Media-Token=version-1")
        XCTAssertEqual(store.items.first?.videoURL, source.url)
        do {
            _ = try await repository.playbackSource(dramaID: drama.id, episodeID: "1002")
            XCTFail("A cached URL must not authorize a locked episode")
        } catch CatalogError.episodeLocked { }
        XCTAssertEqual(requests, 1)
    }

    func testForcedPlayerRefreshUpdatesCacheForLaterConsumers() async throws {
        var requests = 0
        let network = try client { _ in
            requests += 1
            return Self.response(version: requests)
        }
        let cache = PlaybackDetailCache(network: network, directory: try temporaryDirectory())
        let store = makeStore(network: network, cache: cache)
        await store.load()
        XCTAssertEqual(store.items.first?.drama.title, "详情版本1")

        await store.load(forceRefresh: true)
        let reopened = makeStore(network: network, cache: cache)
        await reopened.load()
        let repository = APIDramaRepository(network: network, fallback: DemoDramaRepository(), detailCache: cache)
        let source = try await repository.playbackSource(dramaID: drama.id, episodeID: "1001")

        XCTAssertEqual(requests, 2, "Explicit retry refreshes once and publishes the new response to all consumers")
        XCTAssertEqual(store.items.first?.drama.title, "详情版本2")
        XCTAssertEqual(reopened.items.first?.drama.title, "详情版本2")
        XCTAssertEqual(source.url.absoluteString, "https://example.invalid/1.m3u8?X-Media-Token=version-2")
        XCTAssertEqual(reopened.items.first?.videoURL, source.url)
    }

    func testStableAccountReusesPersistedDetailsAfterAccessTokenRotation() async throws {
        var requests = 0
        let network = try client { _ in
            requests += 1
            return Self.response()
        }
        network.setAccessToken("first-session-token", accountID: "account-1")
        let directory = try temporaryDirectory()
        let initialCache = PlaybackDetailCache(network: network, directory: directory)
        let first = makeStore(network: network, cache: initialCache)
        await first.load()
        XCTAssertEqual(requests, 1)

        network.setAccessToken("renewed-session-token", accountID: "account-1")
        let reopenedCache = PlaybackDetailCache(network: network, directory: directory)
        let reopened = makeStore(network: network, cache: reopenedCache)
        await reopened.load()

        XCTAssertEqual(requests, 1, "A new token for the same account must retain the persisted detail cache")
        XCTAssertEqual(reopened.items.map(\.id), ["1001", "1002"])
        XCTAssertEqual(reopened.items.first?.videoURL, first.items.first?.videoURL)
    }

    func testDifferentAccountsCannotReuseMemoryOrPersistedEpisodeDetails() async throws {
        var requests = 0
        let network = try client { _ in
            requests += 1
            return Self.response(version: requests)
        }
        network.setAccessToken("first-token", accountID: "account-1")
        let directory = try temporaryDirectory()
        let cache = PlaybackDetailCache(network: network, directory: directory)
        let first = makeStore(network: network, cache: cache)
        await first.load()
        XCTAssertEqual(first.items.first?.drama.title, "详情版本1")

        network.setAccessToken("second-token", accountID: "account-2")
        let second = makeStore(network: network, cache: cache)
        await second.load()
        XCTAssertEqual(requests, 2, "Changing accounts must bypass details cached for the previous account")
        XCTAssertEqual(second.items.first?.drama.title, "详情版本2")

        network.setAccessToken("third-token", accountID: "account-3")
        let reopenedCache = PlaybackDetailCache(network: network, directory: directory)
        let third = makeStore(network: network, cache: reopenedCache)
        await third.load()
        XCTAssertEqual(requests, 3, "Disk persistence must preserve the account boundary too")
        XCTAssertEqual(third.items.first?.drama.title, "详情版本3")
    }

    private func makeStore(network: APIClient, cache: PlaybackDetailCache) -> DramaPlaybackStore {
        DramaPlaybackStore(drama: drama, network: network, repository: DemoDramaRepository(),
            library: LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            detailCache: cache)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackCacheIntegrationTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func client(delay: TimeInterval = 0,
                        response: @escaping (APITarget) -> String) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            XCTAssertEqual(target.path, AppAPI.v1ClientDramaEpisodeList.path)
            let body = try! JSONDecoder().decode(APIModels.V1GetDramaEpisodeListReq.self, from: target.body)
            XCTAssertEqual(body.dramaId, 101)
            let payload = response(target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(payload.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in delay > 0 ? .delayed(seconds: delay) : .immediate })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                         provider: provider)
    }

    private static func response(version: Int = 1) -> String {
        """
        {"code":200,"data":{"dramaId":101,"rootDramaId":100,"dramaTitle":"详情版本\(version)","episodePassed":2,"episodes":[
        {"episodeId":1002,"episodeNo":2,"videoUrl":"https://example.invalid/2.m3u8?X-Media-Token=version-\(version)","unlockCoin":10,"isUnlocked":false},
        {"episodeId":1001,"episodeNo":1,"videoUrl":"https://example.invalid/1.m3u8?X-Media-Token=version-\(version)","unlockCoin":0,"isUnlocked":true}
        ]}}
        """
    }
}
