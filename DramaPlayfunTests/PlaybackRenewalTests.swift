import XCTest
import Moya
import AVFoundation
@testable import DramaPlayfun

@MainActor
final class PlaybackRenewalTests: XCTestCase {
    private let oldURL = "https://example.invalid/1.m3u8?X-Media-Token=old"
    private let newURL = "https://example.invalid/1.m3u8?X-Media-Token=new"

    private func client(_ response: @escaping (APITarget) -> String,
                        delay: TimeInterval = 0) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let json = response(target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in delay > 0 ? .delayed(seconds: delay) : .immediate })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!), provider: provider)
    }

    private func item(_ id: String = "1") -> TheaterFeedItem {
        let drama = Drama(id: "101", title: "测试", summary: "", category: .drama,
            episodeCount: 3, heat: 0, badge: nil, coverURL: nil, rootDramaID: 100)
        return TheaterFeedItem(drama: drama, firstEpisode: Episode(id: id, number: 1, title: "", requiresMembership: false),
            videoURL: URL(string: oldURL), firstEpisodeLikeCount: 12, isFirstEpisodeLiked: true,
            isFavorited: true, playbackID: id)
    }

    func testTheaterRenewsOnlyCurrentFirstEpisodeAndPreservesFeed() async throws {
        var submitted: [APIModels.V1XMTokenVideo] = []
        let network = try client { target in
            if target.path == AppAPI.v2ClientList.path {
                return #"{"code":200,"data":{"page":1,"hasMore":true,"list":[{"dramaId":101,"rootDramaId":100,"dramaTitle":"甲","episodes":[{"episodeId":1,"episodeNo":1,"videoUrl":"https://example.invalid/1.m3u8?X-Media-Token=old","isLiked":true,"likeCount":12}]},{"dramaId":102,"rootDramaId":100,"dramaTitle":"乙","episodes":[{"episodeId":2,"episodeNo":1,"videoUrl":"https://example.invalid/2.m3u8?X-Media-Token=old"}]}]}}"#
            }
            XCTAssertEqual(target.path, AppAPI.v1ClientXMToken.path)
            submitted = try! JSONDecoder().decode(APIModels.V1GetXMTokenReq.self, from: target.body).videoList ?? []
            return #"{"code":200,"data":{"videoList":[{"episodeId":1,"videoUrl":"https://example.invalid/1.m3u8?X-Media-Token=new"}]}}"#
        }
        let store = TheaterFeedStore(network: network)
        await store.loadIfNeeded()
        _ = try await store.refreshPlaybackURLs(for: XCTUnwrap(store.items.first))
        XCTAssertEqual(submitted.compactMap(\.episodeId), [1])
        XCTAssertEqual(store.items.map(\.id), ["101", "102"])
        XCTAssertEqual(store.items[0].videoURL?.absoluteString, newURL)
        XCTAssertEqual(HLSLocalGateway.mediaToken(from: store.items[1].videoURL!), "old")
        XCTAssertTrue(store.items[0].isFirstEpisodeLiked)
        XCTAssertEqual(store.items[0].firstEpisodeLikeCount, 12)
        XCTAssertTrue(store.hasMore)
    }

    func testDetailRenewsPrewarmSourcesWithoutUnlockingPaidEpisode() async throws {
        var submitted: [APIModels.V1XMTokenVideo] = []
        let network = try client { target in
            if target.path == AppAPI.v1ClientDramaEpisodeList.path {
                return #"{"code":200,"data":{"rootDramaId":100,"isFavorited":true,"episodes":[{"episodeId":1,"episodeNo":1,"videoUrl":"https://example.invalid/1.m3u8?X-Media-Token=old","likeCount":12,"isLiked":true},{"episodeId":2,"episodeNo":2,"videoUrl":"https://example.invalid/2.m3u8?X-Media-Token=old","unlockCoin":10,"isUnlocked":true},{"episodeId":3,"episodeNo":3,"videoUrl":"https://example.invalid/3.m3u8?X-Media-Token=old","unlockCoin":10,"isUnlocked":false}]}}"#
            }
            XCTAssertEqual(target.path, AppAPI.v1ClientXMToken.path)
            submitted = try! JSONDecoder().decode(APIModels.V1GetXMTokenReq.self, from: target.body).videoList ?? []
            return #"{"code":200,"data":{"videoList":[{"episodeId":2,"videoUrl":"https://example.invalid/2.m3u8?X-Media-Token=new"},{"episodeId":1,"videoUrl":"https://example.invalid/1.m3u8?X-Media-Token=new"},{"episodeId":3,"videoUrl":"https://example.invalid/3.m3u8?X-Media-Token=new"}]}}"#
        }
        let store = DramaPlaybackStore(drama: item().drama, network: network, repository: DemoDramaRepository(),
            library: LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        await store.load()
        _ = try await store.refreshPlaybackURLs(for: XCTUnwrap(store.items.first))
        XCTAssertEqual(submitted.compactMap(\.episodeId), [1, 2, 3])
        XCTAssertEqual(store.items.compactMap(\.videoURL).map { HLSLocalGateway.mediaToken(from: $0) }, ["new", "new", "new"])
        XCTAssertTrue(store.items[2].firstEpisode!.requiresCoinUnlock)
        XCTAssertTrue(store.items[0].isFirstEpisodeLiked)
        XCTAssertTrue(store.items.allSatisfy(\.isFavorited))
    }

    func testSimultaneousExpiryReportsShareOneRequest() async throws {
        var requests = 0
        let network = try client({ _ in
            requests += 1
            return #"{"code":200,"data":{"videoList":[{"episodeId":1,"videoUrl":"https://example.invalid/1.m3u8?X-Media-Token=new"}]}}"#
        }, delay: 0.15)
        let refresher = PlaybackURLRefresher(network: network)
        async let first = refresher.refresh([item()], requiredID: "1")
        async let second = refresher.refresh([item()], requiredID: "1")
        let values = try await [first, second]
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(values[0], values[1])
    }

    func testPartialOrInvalidRefreshFailsWithoutReplacingURLs() async throws {
        let network = try client { _ in
            #"{"code":200,"data":{"videoList":[{"episodeId":1,"videoUrl":"http://example.invalid/1.m3u8?X-Media-Token=new"}]}}"#
        }
        do {
            _ = try await PlaybackURLRefresher(network: network).refresh([item()], requiredID: "1")
            XCTFail("An insecure refresh response must be rejected")
        } catch CatalogError.mediaNotConfigured { }
        let partial = try client { _ in
            #"{"code":200,"data":{"videoList":[{"episodeId":1,"videoUrl":"https://example.invalid/1.m3u8?X-Media-Token=new"}]}}"#
        }
        do {
            _ = try await PlaybackURLRefresher(network: partial).refresh([item(), item("2")], requiredID: "1")
            XCTFail("A partial batch must not leave the next episode with an expired URL")
        } catch CatalogError.mediaNotConfigured { }
    }

    func testFailedRenewalStopsAfterOneAutomaticAttemptAndAllowsManualRetry() async throws {
        var requests = 0
        var loads = 0
        let pool = TheaterPlayerPool(library: LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            cache: .shared, assetLoader: { _ in loads += 1; throw HLSKeyError.invalidMediaToken },
            refreshURLs: { item in requests += 1; return [item] })
        defer { pool.reset() }
        pool.update(items: [item()], selectedID: "1", visible: true)
        for _ in 0..<100 where loads < 2 { try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(loads, 2)
        guard case .unavailable = pool.states["1"] else { return XCTFail("Renewal must not loop") }
        pool.retry("1")
        for _ in 0..<100 where loads < 3 { try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(requests, 2)
    }

    func testOrdinaryNetworkFailureDoesNotRefreshMediaAuthorization() async throws {
        var requests = 0
        let pool = TheaterPlayerPool(library: LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            cache: .shared, assetLoader: { _ in throw URLError(.notConnectedToInternet) },
            refreshURLs: { item in requests += 1; return [item] })
        defer { pool.reset() }
        pool.update(items: [item()], selectedID: "1", visible: true)
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(50))
        XCTAssertEqual(requests, 0)
        guard case .unavailable = pool.states["1"] else { return XCTFail("Network failure must be surfaced") }
    }

    func testTransientStartupFailureRetriesOnlyOnceWithoutRefreshingAuthorization() async throws {
        var requests = 0
        var loads = 0
        let pool = TheaterPlayerPool(library: LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            cache: .shared, assetLoader: { _ in loads += 1; throw URLError(.networkConnectionLost) },
            refreshURLs: { item in requests += 1; return [item] })
        defer { pool.reset() }
        pool.update(items: [item()], selectedID: "1", visible: true)
        for _ in 0..<100 where loads < 2 { try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(requests, 0)
        guard case .unavailable = pool.states["1"] else {
            return XCTFail("A repeated transient failure must stop instead of looping")
        }
    }

    func testCancellationDoesNotRetryOrRefreshAuthorization() async throws {
        var requests = 0
        var loads = 0
        let pool = TheaterPlayerPool(library: LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            cache: .shared, assetLoader: { _ in loads += 1; throw URLError(.cancelled) },
            refreshURLs: { item in requests += 1; return [item] })
        defer { pool.reset() }
        pool.update(items: [item()], selectedID: "1", visible: true)
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(50))
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(requests, 0)
    }

    func testClosingDuringRenewalDiscardsLateResponse() async throws {
        var requests = 0
        var loads = 0
        let pool = TheaterPlayerPool(library: LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            cache: .shared, assetLoader: { _ in loads += 1; throw HLSKeyError.invalidMediaToken },
            refreshURLs: { item in
                requests += 1
                try? await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(150))
                return [item]
            })
        pool.update(items: [item()], selectedID: "1", visible: true)
        for _ in 0..<100 where requests == 0 { try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(requests, 1)
        pool.reset()
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(200))
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(pool.playerCount, 0)
        XCTAssertTrue(pool.states.isEmpty)
        XCTAssertNil(pool.currentID)
    }
}
