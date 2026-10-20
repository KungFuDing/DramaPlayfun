import AVFoundation
import Moya
import XCTest
@testable import DramaPlayfun

@MainActor
final class StartupContentLoaderTests: XCTestCase {
    func testWaitsForHomeAggregationAndHotPageBeforeRequestingTheater() async throws {
        var requests: [String] = []
        let context = try makeContext(delays: [
            Self.homePath: 0.2,
            Self.hotPath: 0.2
        ], onRequest: { requests.append($0) })
        let loading = _Concurrency.Task { await context.loader.load() }
        defer {
            loading.cancel()
            context.loader.cancel()
            context.playback.reset()
        }

        try await waitUntil("Home aggregation did not start") { requests.contains(Self.homePath) }
        XCTAssertTrue(context.home.isLoading)
        XCTAssertTrue(context.home.banners.isEmpty)
        XCTAssertFalse(requests.contains(Self.hotPath))
        XCTAssertFalse(requests.contains(Self.theaterPath))

        try await waitUntil("The first hot page did not start") { requests.contains(Self.hotPath) }
        XCTAssertEqual(context.home.banners.map(\.id), ["11"])
        XCTAssertTrue(context.home.hotDramas.isEmpty)
        XCTAssertTrue(context.home.isLoading)
        XCTAssertFalse(requests.contains(Self.theaterPath),
                       "Theater prefetch must wait until the first hot page has been published")

        await loading.value
        XCTAssertEqual(requests, [Self.homePath, Self.hotPath, Self.theaterPath])
        assertHomeIsPublished(context.home)
        XCTAssertEqual(context.theater.items.map(\.id), ["201", "202"])
    }

    func testSlowTheaterRequestDoesNotKeepHomeLoading() async throws {
        var theaterRequests = 0
        let context = try makeContext(delays: [Self.theaterPath: 0.25], onRequest: {
            if $0 == Self.theaterPath { theaterRequests += 1 }
        })
        let loading = _Concurrency.Task { await context.loader.load() }
        defer {
            loading.cancel()
            context.loader.cancel()
            context.playback.reset()
        }

        try await waitUntil("Theater prefetch did not start") { theaterRequests == 1 }
        XCTAssertTrue(context.theater.isLoading)
        XCTAssertTrue(context.theater.items.isEmpty)
        assertHomeIsPublished(context.home)

        await loading.value
        XCTAssertEqual(theaterRequests, 1)
        XCTAssertTrue(context.theater.hasLoaded)
        XCTAssertFalse(context.theater.isLoading)
        assertHomeIsPublished(context.home)
    }

    func testPreloadsOnlyFirstEpisodeSilentlyAndEntryReusesPreparedPlayer() async throws {
        var loadedIDs: [String] = []
        var theaterRequests = 0
        let video = try XCTUnwrap(Bundle.main.url(forResource: "PlaybackProgressFixture", withExtension: "mp4"))
        let context = try makeContext(onRequest: {
            if $0 == Self.theaterPath { theaterRequests += 1 }
        }, assetLoader: { item in
            loadedIDs.append(item.id)
            return AVURLAsset(url: video)
        })
        defer {
            context.loader.cancel()
            context.playback.reset()
        }

        context.loader.setPreloadingEnabled(true)
        await context.loader.load()
        await context.loader.load()
        context.loader.setPreloadingEnabled(true)
        try await waitUntil("The first episode did not finish prewarming", timeout: 5) {
            context.playback.states["201"] == .ready
        }

        XCTAssertEqual(theaterRequests, 1)
        XCTAssertEqual(loadedIDs, ["201"], "Startup must not download the neighboring drama's video")
        XCTAssertEqual(context.playback.currentID, "201")
        XCTAssertEqual(Set(context.playback.players.keys), ["201"])
        let player = try XCTUnwrap(context.playback.player(for: "201"))
        let playerItem = try XCTUnwrap(player.currentItem)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(player.currentTime().seconds, 0, accuracy: 0.1)
        XCTAssertTrue(context.library.progress.isEmpty, "Prewarming must not create watch history")
        assertHomeIsPublished(context.home)

        context.loader.handoff()
        context.loader.setPreloadingEnabled(false)
        context.playback.update(items: context.theater.items, selectedID: "201", visible: true)
        XCTAssertTrue(context.playback.player(for: "201") === player)
        XCTAssertTrue(player.currentItem === playerItem, "Tab entry must reuse the prepared AVPlayerItem")
        XCTAssertEqual(context.playback.states["201"], .ready)
        XCTAssertFalse(player.isMuted)
        XCTAssertGreaterThan(player.rate, 0)
        XCTAssertEqual(theaterRequests, 1)
    }

    func testEarlyHandoffPreservesForegroundSelectionWhenStartupFinishes() async throws {
        var requests: [String] = []
        let context = try makeContext(delays: [Self.homePath: 0.25], onRequest: { requests.append($0) })
        context.loader.setPreloadingEnabled(true)
        let loading = _Concurrency.Task { await context.loader.load() }
        defer {
            loading.cancel()
            context.loader.cancel()
            context.playback.reset()
        }
        try await waitUntil("Home aggregation did not start") { requests.contains(Self.homePath) }

        context.loader.handoff()
        context.loader.setPreloadingEnabled(false)
        await context.theater.loadIfNeeded()
        XCTAssertTrue(context.home.isLoading)
        context.loader.handoff()
        context.playback.update(items: context.theater.items, selectedID: "202", visible: true)
        let selectedPlayer = try XCTUnwrap(context.playback.player(for: "202"))

        await loading.value
        XCTAssertEqual(context.playback.currentID, "202")
        XCTAssertTrue(context.playback.player(for: "202") === selectedPlayer)
        XCTAssertEqual(requests.filter { $0 == Self.theaterPath }.count, 1)
        assertHomeIsPublished(context.home)

        context.playback.update(items: context.theater.items, selectedID: "202", visible: false)
        context.loader.setPreloadingEnabled(true)
        await context.loader.load()
        XCTAssertEqual(context.playback.currentID, "202",
                       "Returning home must not restart the first drama after a foreground handoff")
        XCTAssertTrue(context.playback.player(for: "202") === selectedPlayer)
    }

    func testQuickRoundtripThroughEmptyTheaterStillPreloadsAfterReturningHome() async throws {
        var theaterRequests = 0
        var loadedIDs: [String] = []
        let context = try makeContext(delays: [Self.theaterPath: 0.2], onRequest: {
            if $0 == Self.theaterPath { theaterRequests += 1 }
        }, assetLoader: { item in
            loadedIDs.append(item.id)
            throw URLError(.cancelled)
        })
        context.loader.setPreloadingEnabled(true)
        let loading = _Concurrency.Task { await context.loader.load() }
        defer {
            loading.cancel()
            context.loader.cancel()
            context.playback.reset()
        }
        try await waitUntil("Theater prefetch did not start") { theaterRequests == 1 }
        XCTAssertTrue(context.theater.items.isEmpty)
        XCTAssertTrue(context.theater.isLoading)

        context.loader.handoff()
        context.loader.setPreloadingEnabled(false)
        context.loader.setPreloadingEnabled(true)
        await loading.value
        try await waitUntil("Returning home did not resume the first episode prewarm") {
            !loadedIDs.isEmpty
        }

        XCTAssertEqual(theaterRequests, 1)
        XCTAssertEqual(loadedIDs, ["201"])
        XCTAssertEqual(context.playback.currentID, "201")
        XCTAssertEqual(Set(context.playback.players.keys), ["201"])
        assertHomeIsPublished(context.home)
    }

    func testCancellationDiscardsLateTheaterResponseAndDoesNotPreload() async throws {
        var theaterRequests = 0
        var loadedIDs: [String] = []
        let context = try makeContext(delays: [Self.theaterPath: 0.2], onRequest: {
            if $0 == Self.theaterPath { theaterRequests += 1 }
        }, assetLoader: { item in
            loadedIDs.append(item.id)
            throw URLError(.cancelled)
        })
        context.loader.setPreloadingEnabled(true)
        let loading = _Concurrency.Task { await context.loader.load() }
        defer {
            loading.cancel()
            context.loader.cancel()
            context.playback.reset()
        }
        try await waitUntil("Theater prefetch did not start") { theaterRequests == 1 }

        context.loader.cancel()
        await loading.value
        context.loader.setPreloadingEnabled(true)
        await context.loader.load()

        XCTAssertEqual(theaterRequests, 1, "A canceled loader must not restart the retired request")
        XCTAssertFalse(context.theater.hasLoaded)
        XCTAssertFalse(context.theater.isLoading)
        XCTAssertTrue(context.theater.items.isEmpty)
        XCTAssertNil(context.theater.errorMessage)
        XCTAssertTrue(loadedIDs.isEmpty)
        XCTAssertEqual(context.playback.playerCount, 0)
        assertHomeIsPublished(context.home)
    }

    func testTheaterFailureLeavesHomePublishedWithoutPreloading() async throws {
        var loadedIDs: [String] = []
        let context = try makeContext(
            theaterJSON: #"{"code":500,"data":null,"message":"temporarily unavailable"}"#,
            assetLoader: { item in
                loadedIDs.append(item.id)
                throw URLError(.cancelled)
            })
        defer {
            context.loader.cancel()
            context.playback.reset()
        }
        context.loader.setPreloadingEnabled(true)

        await context.loader.load()

        assertHomeIsPublished(context.home)
        XCTAssertNotNil(context.theater.errorMessage)
        XCTAssertFalse(context.theater.hasLoaded)
        XCTAssertFalse(context.theater.isLoading)
        XCTAssertTrue(loadedIDs.isEmpty)
        XCTAssertEqual(context.playback.playerCount, 0)
    }

    func testEmptyTheaterLeavesHomePublishedWithoutPreloading() async throws {
        var loadedIDs: [String] = []
        let context = try makeContext(
            theaterJSON: #"{"code":200,"data":{"page":1,"hasMore":false,"list":[]}}"#,
            assetLoader: { item in
                loadedIDs.append(item.id)
                throw URLError(.cancelled)
            })
        defer {
            context.loader.cancel()
            context.playback.reset()
        }
        context.loader.setPreloadingEnabled(true)

        await context.loader.load()

        assertHomeIsPublished(context.home)
        XCTAssertTrue(context.theater.hasLoaded)
        XCTAssertTrue(context.theater.items.isEmpty)
        XCTAssertFalse(context.theater.isLoading)
        XCTAssertNil(context.theater.errorMessage)
        XCTAssertTrue(loadedIDs.isEmpty)
        XCTAssertEqual(context.playback.playerCount, 0)
    }

    private struct Context {
        let home: HomeFeedStore
        let theater: TheaterFeedStore
        let playback: TheaterPlayerPool
        let library: LibraryStore
        let loader: StartupContentLoader
    }

    private static let homePath = "/mobile/v1/theater/home"
    private static let hotPath = "/mobile/v1/theater/home/hot/page"
    private static let theaterPath = "/mobile/v2/client/list"
    private nonisolated static let theaterJSON = """
    {"code":200,"data":{"page":1,"hasMore":false,"list":[
      {"dramaId":201,"rootDramaId":201,"dramaTitle":"剧场甲","episodePassed":10,
       "episodes":[{"episodeId":2011,"episodeNo":1,"videoUrl":"https://example.invalid/201.m3u8"}]},
      {"dramaId":202,"rootDramaId":202,"dramaTitle":"剧场乙","episodePassed":12,
       "episodes":[{"episodeId":2021,"episodeNo":1,"videoUrl":"https://example.invalid/202.m3u8"}]}
    ]}}
    """

    private func makeContext(
        delays: [String: TimeInterval] = [:],
        theaterJSON: String = StartupContentLoaderTests.theaterJSON,
        onRequest: @escaping (String) -> Void = { _ in },
        assetLoader: @escaping (TheaterFeedItem) async throws -> AVURLAsset = { _ in
            throw URLError(.cancelled)
        }
    ) throws -> Context {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            onRequest(target.path)
            let json: String
            switch target.path {
            case Self.homePath:
                json = #"{"code":200,"data":{"banners":[{"id":11,"dramaTitle":"首页推荐"}],"rank":[],"list":[]}}"#
            case Self.hotPath:
                json = #"{"code":200,"data":{"page":1,"hasMore":false,"list":[{"dramaId":31,"dramaTitle":"首页热播"}]}}"#
            case Self.theaterPath:
                json = theaterJSON
            default:
                XCTFail("Unexpected startup request: \(target.path)")
                json = #"{"code":500,"data":null,"message":"unexpected request"}"#
            }
            return Endpoint(
                url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { target in
            delays[target.path].map { .delayed(seconds: $0) } ?? .immediate
        })
        let network = APIClient(
            configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
            provider: provider)
        let home = HomeFeedStore(network: network)
        let theater = TheaterFeedStore(network: network)
        let library = LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let playback = TheaterPlayerPool(library: library, cache: .shared, assetLoader: assetLoader)
        let loader = StartupContentLoader(home: home, theater: theater, playback: playback)
        return Context(home: home, theater: theater, playback: playback, library: library, loader: loader)
    }

    private func assertHomeIsPublished(
        _ home: HomeFeedStore, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(home.banners.map(\.id), ["11"], file: file, line: line)
        XCTAssertEqual(home.hotDramas.map(\.id), ["31"], file: file, line: line)
        XCTAssertTrue(home.hasLoaded, file: file, line: line)
        XCTAssertFalse(home.isLoading, file: file, line: line)
        XCTAssertNil(home.homeErrorMessage, file: file, line: line)
        XCTAssertNil(home.hotErrorMessage, file: file, line: line)
    }

    private func waitUntil(
        _ message: String, timeout: TimeInterval = 2,
        file: StaticString = #filePath, line: UInt = #line,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(10))
        }
        guard condition() else {
            XCTFail(message, file: file, line: line)
            throw WaitError.timedOut
        }
    }

    private enum WaitError: Error {
        case timedOut
    }
}
