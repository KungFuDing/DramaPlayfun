import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class DramaPlaybackTests: XCTestCase {
    private func makeDrama() -> Drama {
        Drama(id: "101", title: "测试剧", summary: "简介", category: .drama,
              episodeCount: 3, heat: 0, badge: nil, coverURL: nil, rootDramaID: 100)
    }

    func testLoadsWholeDramaOnceAndUsesDistinctOrderedEpisodeIdentities() async throws {
        var requests = 0
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            requests += 1
            XCTAssertEqual(target.path, "/mobile/v1/client/drama/episode/list")
            let body = try! JSONSerialization.jsonObject(with: target.body) as! [String: Int]
            XCTAssertEqual(body["dramaId"], 101)
            let json = #"{"code":200,"data":{"rootDramaId":100,"favoriteCount":88,"isFavorited":true,"episodes":[{"episodeId":1003,"episodeNo":3,"videoUrl":"https://example.invalid/3.m3u8","unlockCoin":10,"isUnlocked":false},{"episodeId":1001,"episodeNo":1,"videoUrl":"https://example.invalid/1.m3u8","likeCount":12,"isLiked":true},{"episodeId":1002,"episodeNo":2,"videoUrl":"https://example.invalid/2.m3u8"},{"episodeId":1002,"episodeNo":2}]}}"#
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in .immediate })
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!), provider: provider)
        let library = LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let drama = makeDrama()
        let store = DramaPlaybackStore(drama: drama, network: network, repository: DemoDramaRepository(), library: library)
        await store.load()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(store.items.map(\.id), ["1001", "1002", "1003"])
        XCTAssertEqual(store.items.compactMap { $0.firstEpisode?.number }, [1, 2, 3])
        XCTAssertTrue(store.items[0].isFirstEpisodeLiked)
        XCTAssertTrue(store.items.allSatisfy(\.isFavorited))
        XCTAssertEqual(store.items[0].keyIdentity?.rootDramaID, 100)
        XCTAssertEqual(store.items[1].keyIdentity?.episodeID, 1002)
        XCTAssertNil(store.items[2].videoURL, "Locked episodes must never enter the prefetch path")
        XCTAssertTrue(store.items[2].firstEpisode!.requiresCoinUnlock)
        library.save(WatchProgress(dramaID: drama.id, episodeID: "1002", episodeNumber: 2,
            seconds: 10, duration: 60, updatedAt: Date()))
        let router = AppRouter()
        router.openPlayback(drama)
        XCTAssertEqual(store.initialID(request: router.playback!), "1002")
        router.openPlayback(drama, episode: store.items[0].firstEpisode)
        XCTAssertEqual(store.initialID(request: router.playback!), "1001", "Explicit episode selection overrides resume history")
    }

    func testPoolUsesEpisodeIDsForMultipleEpisodesOfTheSameDrama() {
        let drama = makeDrama()
        let items = (1...6).map { number in
            TheaterFeedItem(drama: drama,
                firstEpisode: Episode(id: "\(number)", number: number, title: "", requiresMembership: false),
                videoURL: nil, firstEpisodeLikeCount: 0, isFirstEpisodeLiked: false,
                isFavorited: false, playbackID: "\(number)")
        }
        let pool = TheaterPlayerPool(library: LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!), cache: .shared)
        pool.update(items: items, selectedID: "2", visible: false)
        XCTAssertEqual(Set(pool.players.keys), ["1", "2", "3"])
        let next = pool.player(for: "3")
        pool.update(items: items, selectedID: "3", visible: false)
        XCTAssertTrue(pool.player(for: "3") === next)
        XCTAssertEqual(Set(pool.players.keys), ["2", "3", "4"])
        XCTAssertEqual(pool.playerCount, 3)
        pool.reset()
    }
}
