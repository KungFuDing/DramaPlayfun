import AVFoundation
import Moya
import XCTest
@testable import DramaPlayfun

@MainActor
final class PlaybackPreparationTests: XCTestCase {
    private let drama = Drama(id: "101", title: "预加载测试", summary: "", category: .drama,
        episodeCount: 3, heat: 0, badge: nil, coverURL: nil, rootDramaID: 101)

    func testContinuationWindowRejectsUnknownDurationAndEarlyPlayback() {
        XCTAssertFalse(TheaterPlayerPool.isContinuationWindow(seconds: 40, duration: 60))
        XCTAssertTrue(TheaterPlayerPool.isContinuationWindow(seconds: 50, duration: 60))
        XCTAssertTrue(TheaterPlayerPool.isContinuationWindow(seconds: 2, duration: 8))
        XCTAssertFalse(TheaterPlayerPool.isContinuationWindow(seconds: 0, duration: 8))
        XCTAssertFalse(TheaterPlayerPool.isContinuationWindow(seconds: 60, duration: 60))
        XCTAssertFalse(TheaterPlayerPool.isContinuationWindow(seconds: .nan, duration: 60))
        XCTAssertFalse(TheaterPlayerPool.isContinuationWindow(seconds: 50, duration: .infinity))
    }

    func testPreloadsOnlySecondEpisodeSilentlyAndTransfersTheSamePlayerAndMetadata() async throws {
        var requests = 0
        var loadedIDs: [String] = []
        let library = LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = makeStore(library: library) { requests += 1 }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PlaybackProgressFixture", withExtension: "mp4"))
        let pool = TheaterPlayerPool(library: library, cache: .shared, assetLoader: { item in
            loadedIDs.append(item.id)
            return AVURLAsset(url: url)
        })
        let preparation = PlaybackPreparation(store: store, playback: pool)
        defer { pool.reset() }
        preparation.beginLoading()
        preparation.preloadVideo()
        preparation.preloadVideo()
        await preparation.load()
        await preparation.load()
        let deadline = Date().addingTimeInterval(5)
        while pool.states["1002"] != .ready && Date() < deadline {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(requests, 1, "Preload and entry must share the metadata request")
        XCTAssertEqual(loadedIDs, ["1002"], "Only the continuation video may load in the background")
        XCTAssertEqual(pool.states["1002"], .ready)
        let player = try XCTUnwrap(pool.player(for: "1002"))
        let playerItem = try XCTUnwrap(player.currentItem)
        XCTAssertEqual(player.rate, 0, "Background preparation must remain silent")
        XCTAssertEqual(player.currentTime().seconds, 0, accuracy: 0.1)
        XCTAssertNil(library.progress[drama.id], "Preload must not mark episode 2 as watched")

        preparation.handoff()
        let router = AppRouter()
        router.openPlayback(drama, episodeNumber: 2, preparation: preparation)
        let request = try XCTUnwrap(router.playback)
        XCTAssertTrue(request.preparation?.store === store)
        XCTAssertTrue(request.preparation?.playback === pool)
        preparation.cancel() // The theater's cleanup must not destroy the transferred player.
        pool.update(items: store.items, selectedID: store.initialID(request: request), visible: true)
        XCTAssertTrue(pool.player(for: "1002") === player)
        XCTAssertTrue(player.currentItem === playerItem, "Entry must keep the prebuffered AVPlayerItem")
        XCTAssertEqual(pool.states["1002"], .ready)
        XCTAssertGreaterThan(player.rate, 0)
        XCTAssertEqual(requests, 1)
    }

    func testCancelDiscardsLateMetadataAndDoesNotLoadVideo() async throws {
        var requests = 0
        var loadedIDs: [String] = []
        let library = LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = makeStore(library: library) { requests += 1 }
        let pool = TheaterPlayerPool(library: library, cache: .shared, assetLoader: { item in
            loadedIDs.append(item.id)
            throw URLError(.cancelled)
        })
        let preparation = PlaybackPreparation(store: store, playback: pool)
        preparation.beginLoading()
        preparation.preloadVideo()
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(30))
        preparation.cancel()
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(250))
        preparation.preloadVideo()
        await preparation.load()
        XCTAssertEqual(requests, 1, "A canceled preparation must not restart from a late task")
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(loadedIDs.isEmpty)
        XCTAssertEqual(pool.playerCount, 0)
    }

    func testLockedSecondEpisodePrewarmsSilentlyAndTransfersTheSamePlayer() async throws {
        var loadedIDs: [String] = []
        let library = LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = makeStore(library: library, locked: true) { }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PlaybackProgressFixture", withExtension: "mp4"))
        let pool = TheaterPlayerPool(library: library, cache: .shared, assetLoader: { item in
            loadedIDs.append(item.id)
            return AVURLAsset(url: url)
        })
        let preparation = PlaybackPreparation(store: store, playback: pool)
        defer { pool.reset() }
        preparation.preloadVideo()
        await preparation.load()
        let deadline = Date().addingTimeInterval(5)
        while pool.states["1002"] != .ready, Date() < deadline {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.items.count, 3)
        XCTAssertTrue(store.items[1].firstEpisode!.requiresCoinUnlock)
        XCTAssertEqual(loadedIDs, ["1002"])
        XCTAssertEqual(pool.states["1002"], .ready)
        let player = try XCTUnwrap(pool.player(for: "1002"))
        let playerItem = try XCTUnwrap(player.currentItem)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(player.currentTime().seconds, 0, accuracy: 0.1)
        XCTAssertNil(library.progress[drama.id])

        preparation.handoff()
        preparation.cancel()
        pool.update(items: store.items, selectedID: "1002", visible: true)
        XCTAssertTrue(pool.player(for: "1002") === player)
        XCTAssertTrue(player.currentItem === playerItem)
        XCTAssertTrue(player.isMuted, "Entering the paid episode must keep the prepared video silent until authorization")
        XCTAssertEqual(player.rate, 0)
        XCTAssertTrue(store.items[1].firstEpisode!.requiresCoinUnlock)
        XCTAssertNil(library.progress[drama.id])
    }

    func testLockedSecondEpisodeWithoutURLWaitsForAnAuthorizedSource() async throws {
        var loadedIDs: [String] = []
        let library = LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let store = makeStore(library: library, locked: true, hasSecondURL: false) { }
        let pool = TheaterPlayerPool(library: library, cache: .shared, assetLoader: { item in
            loadedIDs.append(item.id)
            throw URLError(.cancelled)
        })
        let preparation = PlaybackPreparation(store: store, playback: pool)
        defer { preparation.cancel() }
        preparation.preloadVideo()
        await preparation.load()
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(50))
        XCTAssertNil(store.items[1].videoURL)
        XCTAssertTrue(store.items[1].firstEpisode!.requiresCoinUnlock)
        XCTAssertTrue(loadedIDs.isEmpty)
        XCTAssertEqual(pool.playerCount, 0)
    }

    private func makeStore(library: LibraryStore, locked: Bool = false, hasSecondURL: Bool = true,
                           onRequest: @escaping () -> Void) -> DramaPlaybackStore {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            onRequest()
            let secondSource = hasSecondURL ? #""videoUrl":"https://example.invalid/2.m3u8","# : ""
            let json = """
            {"code":200,"data":{"rootDramaId":101,"episodes":[
            {"episodeId":1001,"episodeNo":1,"videoUrl":"https://example.invalid/1.m3u8"},
            {"episodeId":1002,"episodeNo":2,\(secondSource)"unlockCoin":\(locked ? 10 : 0),"isUnlocked":false},
            {"episodeId":1003,"episodeNo":3,"videoUrl":"https://example.invalid/3.m3u8"}]}}
            """
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in .delayed(seconds: 0.15) })
        let network = APIClient(configuration: try! APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
            provider: provider)
        return DramaPlaybackStore(drama: drama, network: network, repository: DemoDramaRepository(), library: library)
    }
}
