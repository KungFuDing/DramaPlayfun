import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class TheaterFeedTests: XCTestCase {
    func testPlayerPoolKeepsOnlyCurrentAndImmediateNeighbors() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let pool = TheaterPlayerPool(library: LibraryStore(defaults: defaults), cache: .shared)
        let items = (0..<8).map { number in
            let id = String(number)
            return TheaterFeedItem(
                drama: Drama(id: id, title: "短剧\(number)", summary: "", category: .all,
                             episodeCount: 1, heat: 0, badge: nil, coverURL: nil),
                firstEpisode: Episode(id: "e\(number)", number: 1, title: "第1集",
                                      requiresMembership: false),
                videoURL: nil, firstEpisodeLikeCount: 0,
                isFirstEpisodeLiked: false, isFavorited: false
            )
        }

        pool.update(items: items, selectedID: "2", visible: false)
        XCTAssertEqual(Set(pool.players.keys), ["1", "2", "3"])
        XCTAssertEqual(pool.playerCount, 3)
        let nextPlayer = pool.player(for: "3")

        pool.update(items: items, selectedID: "3", visible: false)
        XCTAssertTrue(pool.player(for: "3") === nextPlayer)
        XCTAssertEqual(Set(pool.players.keys), ["2", "3", "4"])
        XCTAssertEqual(pool.playerCount, 3)

        pool.update(items: items, selectedID: "7", visible: false)
        XCTAssertEqual(Set(pool.players.keys), ["6", "7"])
        XCTAssertEqual(pool.playerCount, 3)
        pool.reset()
        XCTAssertEqual(pool.playerCount, 0)
    }

    func testOnlyFirstEpisodeIsMappedAndPagesDeduplicateDramas() async throws {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            XCTAssertEqual(target.path, "/mobile/v2/client/list")
            let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Int]
            let json = body?["page"] == 1
                ? #"{"code":200,"data":{"page":1,"hasMore":true,"list":[{"dramaId":107,"rootDramaId":107,"dramaTitle":"短剧甲","episodePassed":60,"coverUrl":"https://example.invalid/cover.jpg","tagNames":["甜宠"],"episodes":[{"episodeId":2531,"episodeNo":1,"videoUrl":"https://example.invalid/master.m3u8","isUnlocked":false,"unlockCoin":0},{"episodeId":2532,"episodeNo":2,"videoUrl":"https://example.invalid/second.m3u8"}]}]},"message":"ok"}"#
                : #"{"code":200,"data":{"page":2,"hasMore":false,"list":[{"dramaId":107,"dramaTitle":"重复短剧"},{"dramaId":281,"dramaTitle":"短剧乙","episodePassed":30,"episodes":[{"episodeId":17160,"episodeNo":1,"videoUrl":"https://example.invalid/b.m3u8"}]}]},"message":"ok"}"#
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                            sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                            method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in .immediate })
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                                provider: provider)
        let feed = TheaterFeedStore(network: network)

        await feed.loadIfNeeded()
        XCTAssertEqual(feed.items.map(\.id), ["107"])
        XCTAssertEqual(feed.items.first?.firstEpisode?.id, "2531")
        XCTAssertEqual(feed.items.first?.keyIdentity,
                       HLSKeyIdentity(rootDramaID: 107, episodeID: 2531))
        XCTAssertFalse(feed.items.first?.firstEpisode?.requiresMembership ?? true)
        XCTAssertEqual(feed.items.first?.videoURL?.lastPathComponent, "master.m3u8")
        XCTAssertEqual(feed.items.first?.drama.episodeCount, 60)
        XCTAssertTrue(feed.hasMore)

        await feed.loadMore()
        XCTAssertEqual(feed.items.map(\.id), ["107", "281"])
        XCTAssertFalse(feed.hasMore)
    }

    func testEpisodeRepositorySeparatesFreePreviewFromCoinLockedEpisodes() async throws {
        let json = #"{"code":200,"data":{"episodes":[{"episodeId":2531,"episodeNo":1,"videoUrl":"https://example.invalid/first.m3u8","isUnlocked":false,"unlockCoin":0},{"episodeId":2532,"episodeNo":2,"videoUrl":"https://example.invalid/second.m3u8","isUnlocked":false,"unlockCoin":10}]},"message":"ok"}"#
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            XCTAssertEqual(target.path, "/mobile/v1/client/drama/episode/list")
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                            sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                            method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in .immediate })
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                                provider: provider)
        let repository = APIDramaRepository(network: network, fallback: DemoDramaRepository())

        let episodes = try await repository.fetchEpisodes(dramaID: "107")
        XCTAssertEqual(episodes.map(\.id), ["2531", "2532"])
        XCTAssertFalse(episodes[0].requiresCoinUnlock)
        XCTAssertTrue(episodes[1].requiresCoinUnlock)
        let firstURL = try await repository.playbackURL(dramaID: "107", episodeID: "2531")
        XCTAssertEqual(firstURL.lastPathComponent, "first.m3u8")
        do {
            _ = try await repository.playbackURL(dramaID: "107", episodeID: "2532")
            XCTFail("Locked episode must not return a playback URL")
        } catch CatalogError.episodeLocked { }
    }
}
