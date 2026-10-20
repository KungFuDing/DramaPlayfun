import XCTest
import Moya
import AVFoundation
@testable import DramaPlayfun

@MainActor
final class DramaPlaybackTests: XCTestCase {
    func testNeighborPreloadStartsEarlyOnlyWithMeasuredBandwidthHeadroom() {
        XCTAssertTrue(TheaterPlayerPool.hasNeighborPreloadCapacity(bufferedSeconds: 1, remaining: 60,
            rate: 1, observedBitrate: 1_000_000, requiredBitrate: 400_000, isNext: true))
        XCTAssertFalse(TheaterPlayerPool.hasNeighborPreloadCapacity(bufferedSeconds: 1, remaining: 60,
            rate: 1, observedBitrate: 0, requiredBitrate: 0, isNext: true))
        XCTAssertFalse(TheaterPlayerPool.hasNeighborPreloadCapacity(bufferedSeconds: 1, remaining: 60,
            rate: 1, observedBitrate: 500_000, requiredBitrate: 400_000, isNext: true))
        XCTAssertFalse(TheaterPlayerPool.hasNeighborPreloadCapacity(bufferedSeconds: 1, remaining: 60,
            rate: 2, observedBitrate: 2_000_000, requiredBitrate: 400_000, isNext: true))
        XCTAssertFalse(TheaterPlayerPool.hasNeighborPreloadCapacity(bufferedSeconds: 3, remaining: 60,
            rate: 1, observedBitrate: 1_000_000, requiredBitrate: 400_000, isNext: false))
        XCTAssertTrue(TheaterPlayerPool.hasNeighborPreloadCapacity(bufferedSeconds: 3, remaining: 60,
            rate: 1, observedBitrate: 0, requiredBitrate: 0, isNext: true))
    }

    func testPreloadRequiresBandwidthHeadroomAndBufferAtPlaybackRate() {
        XCTAssertFalse(TheaterPlayerPool.hasPreloadCapacity(bufferedSeconds: 15, remaining: 60,
            rate: 1, observedBitrate: 500_000, requiredBitrate: 400_000),
            "An existing buffer must not hide a connection too slow to load two videos")
        XCTAssertTrue(TheaterPlayerPool.hasPreloadCapacity(bufferedSeconds: 15, remaining: 60,
            rate: 1, observedBitrate: 1_000_000, requiredBitrate: 400_000))
        XCTAssertFalse(TheaterPlayerPool.hasPreloadCapacity(bufferedSeconds: 15, remaining: 60,
            rate: 3, observedBitrate: 1_000_000, requiredBitrate: 400_000),
            "Fast playback consumes the buffer sooner and needs more bandwidth")
        XCTAssertFalse(TheaterPlayerPool.hasPreloadCapacity(bufferedSeconds: 2, remaining: 60,
            rate: 1, observedBitrate: 10_000_000, requiredBitrate: 400_000))
        XCTAssertTrue(TheaterPlayerPool.hasPreloadCapacity(bufferedSeconds: 3, remaining: 3,
            rate: 1, observedBitrate: 500_000, requiredBitrate: 400_000),
            "A fully buffered ending can preload the next video without delaying playback")
    }
    func testForegroundPreparationPrecedesPreloadAndHiddenPagesDoNotFetch() async throws {
        var loadedIDs: [String] = []
        let pool = TheaterPlayerPool(library: LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            cache: .shared, assetLoader: { item in
                loadedIDs.append(item.id)
                try await _Concurrency.Task<Never, Never>.sleep(for: .seconds(60))
                throw URLError(.cancelled)
            })
        defer { pool.reset() }
        let drama = makeDrama()
        let items = (1...4).map { number in
            TheaterFeedItem(drama: drama, firstEpisode: Episode(id: String(number), number: number,
                title: "", requiresMembership: false), videoURL: URL(string: "https://example.invalid/master.m3u8"),
                firstEpisodeLikeCount: 0, isFirstEpisodeLiked: false, isFavorited: false, playbackID: String(number))
        }
        pool.update(items: items, selectedID: "1", visible: true)
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(350))
        XCTAssertEqual(loadedIDs, ["1"], "Next-episode prefetch must not compete with a still-loading foreground episode")
        let first = pool.player(for: "1")
        pool.prioritizeContinuation(true)
        XCTAssertEqual(Set(pool.players.keys), ["1"], "Continuation preloading must release competing theater neighbors")
        pool.prioritizeContinuation(false)
        XCTAssertTrue(pool.player(for: "1") === first)
        XCTAssertEqual(Set(pool.players.keys), ["1", "2"], "Canceling the continuation must restore normal neighbor preparation")
        pool.update(items: items, selectedID: "2", visible: true)
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(350))
        XCTAssertEqual(loadedIDs, ["1", "2"], "Swiping makes the selected episode load without waiting for its neighbor")
        pool.update(items: items, selectedID: "4", visible: false)
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(350))
        XCTAssertEqual(loadedIDs, ["1", "2"], "A hidden playback page must not start another network load")
        XCTAssertEqual(pool.playerCount, 3)
    }

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
        XCTAssertEqual(store.items[2].videoURL?.absoluteString, "https://example.invalid/3.m3u8",
                       "A locked episode keeps its source available for silent prewarming")
        XCTAssertTrue(store.items[2].firstEpisode!.requiresCoinUnlock)
        library.save(WatchProgress(dramaID: drama.id, episodeID: "1002", episodeNumber: 2,
            seconds: 10, duration: 60, updatedAt: Date()))
        let router = AppRouter()
        router.openPlayback(drama)
        XCTAssertEqual(store.initialID(request: router.playback!), "1002")
        router.openPlayback(drama, episode: store.items[0].firstEpisode)
        XCTAssertEqual(store.initialID(request: router.playback!), "1001", "Explicit episode selection overrides resume history")
        library.save(WatchProgress(dramaID: drama.id, episodeID: "1003", episodeNumber: 3,
            seconds: 20, duration: 60, updatedAt: Date()))
        router.openPlayback(drama, episodeNumber: 2)
        XCTAssertEqual(store.initialID(request: router.playback!), "1002", "A completed theater preview must continue with episode 2 regardless of history")
        XCTAssertTrue(router.playback!.startsFromBeginning)
        router.openPlayback(drama)
        XCTAssertEqual(store.initialID(request: router.playback!), "1003", "Ordinary entry must still resume history")
        XCTAssertFalse(router.playback!.startsFromBeginning)
        router.openPlayback(drama, position: PlaybackPosition(episodeNumber: 2, seconds: 17))
        let positionedRequest = try XCTUnwrap(router.playback)
        XCTAssertTrue(positionedRequest.episode.id.isEmpty)
        XCTAssertEqual(store.initialID(request: positionedRequest), "1002",
                       "List progress identifies the episode by number and overrides saved local history")
        router.openPlayback(drama, position: PlaybackPosition(seconds: 17))
        XCTAssertEqual(store.initialID(request: router.playback!), "1001",
                       "A list item without an episode number starts at episode 1 despite local history")
    }

    func testInitialPositionOverridesLocalProgressAndPreservesSessionPosition() async throws {
        let (pool, item) = try makePositionedPool(PlaybackPosition(episodeNumber: 2, seconds: 17),
                                                 savedSeconds: 40)
        defer { pool.reset() }
        pool.update(items: [item], selectedID: item.id, visible: false, preparationActive: true)
        let player = try await preparedPlayer(in: pool, for: item.id)
        XCTAssertEqual(player.currentTime().seconds, 17, accuracy: 0.1)
        XCTAssertEqual(player.rate, 0)
        let playerItem = try XCTUnwrap(player.currentItem)

        let finished = await player.seek(to: CMTime(seconds: 24, preferredTimescale: 600),
                                         toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(finished)
        pool.update(items: [item], selectedID: item.id, visible: false, preparationActive: true)
        pool.update(items: [item], selectedID: item.id, visible: false, preparationActive: true)
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(100))
        XCTAssertTrue(player.currentItem === playerItem)
        XCTAssertEqual(player.currentTime().seconds, 24, accuracy: 0.1,
                       "A view update must not seek back to the list item's initial position")
        XCTAssertEqual(player.rate, 0)

        var replacement = item
        replacement.videoURL = URL(string: "https://example.invalid/replacement.m3u8")
        pool.update(items: [replacement], selectedID: replacement.id, visible: false, preparationActive: true)
        let replacementPlayer = try await preparedPlayer(in: pool, for: replacement.id)
        XCTAssertEqual(replacementPlayer.currentTime().seconds, 24, accuracy: 0.1,
                       "Replacing the source must preserve this session's latest position")

        pool.reset()
        pool.update(items: [replacement], selectedID: replacement.id, visible: false, preparationActive: true)
        let restoredPlayer = try await preparedPlayer(in: pool, for: replacement.id)
        XCTAssertEqual(restoredPlayer.currentTime().seconds, 24, accuracy: 0.1,
                       "Rebuilding the player must preserve session progress without reapplying the initial position")
        XCTAssertEqual(restoredPlayer.rate, 0)
    }

    func testFailedRenewalAndManualRetryPreserveRequestedEpisodePosition() async throws {
        var refreshes = 0
        let (pool, item) = try makePositionedPool(PlaybackPosition(episodeNumber: 2, seconds: 17),
            savedSeconds: 40, refreshURLs: { item in
                refreshes += 1
                if refreshes == 1 { throw URLError(.notConnectedToInternet) }
                return [item]
            })
        defer { pool.reset() }
        pool.update(items: [item], selectedID: item.id, visible: false, preparationActive: true)
        let player = try await preparedPlayer(in: pool, for: item.id)
        let finished = await player.seek(to: CMTime(seconds: 24, preferredTimescale: 600),
                                         toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(finished)

        pool.retry(item.id)
        let failureDeadline = Date().addingTimeInterval(5)
        while pool.states[item.id] == .preparing, Date() < failureDeadline {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(refreshes, 1)
        guard case .unavailable = pool.states[item.id] else {
            return XCTFail("The first URL refresh must fail before the manual retry")
        }
        XCTAssertNil(player.currentItem, "The failed renewal has already discarded the original player item")

        pool.retry(item.id)
        let restoredPlayer = try await preparedPlayer(in: pool, for: item.id)
        XCTAssertEqual(refreshes, 2)
        XCTAssertEqual(restoredPlayer.currentTime().seconds, 24, accuracy: 0.1,
                       "A retry after failed renewal must retain the last position from this playback session")
        XCTAssertEqual(restoredPlayer.rate, 0)
    }

    func testOrdinaryPlaybackFailureAndRetryPreserveLatestSessionPosition() async throws {
        var refreshes = 0
        let (pool, item) = try makePositionedPool(PlaybackPosition(episodeNumber: 2, seconds: 17),
            savedSeconds: 40, refreshURLs: { item in refreshes += 1; return [item] })
        defer { pool.reset() }
        pool.update(items: [item], selectedID: item.id, visible: false, preparationActive: true)
        let player = try await preparedPlayer(in: pool, for: item.id)
        let playerItem = try XCTUnwrap(player.currentItem)
        let finished = await player.seek(to: CMTime(seconds: 24, preferredTimescale: 600),
                                         toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(finished)

        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
        let failureDeadline = Date().addingTimeInterval(5)
        while pool.states[item.id] == .ready, Date() < failureDeadline {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(20))
        }
        guard case .unavailable = pool.states[item.id] else {
            return XCTFail("The ordinary playback failure must be surfaced before retrying")
        }
        XCTAssertEqual(refreshes, 0, "An ordinary playback failure must not renew authorization automatically")

        pool.retry(item.id)
        let restoredPlayer = try await preparedPlayer(in: pool, for: item.id)
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(restoredPlayer.currentTime().seconds, 24, accuracy: 0.1,
                       "Failure must retain the latest position before the player becomes unavailable")
        XCTAssertEqual(restoredPlayer.rate, 0)
    }

    func testSessionPositionSurvivesResetAfterSelectingAnotherEpisode() async throws {
        let (pool, target) = try makePositionedPool(PlaybackPosition(episodeNumber: 2, seconds: 17),
                                                   savedSeconds: 40)
        defer { pool.reset() }
        let next = makePlaybackItem(number: 3)
        let items = [target, next]
        pool.update(items: items, selectedID: target.id, visible: false, preparationActive: true)
        _ = try await preparedPlayer(in: pool, for: target.id)
        pool.update(items: items, selectedID: next.id, visible: false, preparationActive: true)
        let nextPlayer = try await preparedPlayer(in: pool, for: next.id)
        let finished = await nextPlayer.seek(to: CMTime(seconds: 10, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(finished)

        pool.reset()
        pool.update(items: items, selectedID: next.id, visible: false, preparationActive: true)
        let restoredPlayer = try await preparedPlayer(in: pool, for: next.id)
        XCTAssertEqual(restoredPlayer.currentTime().seconds, 10, accuracy: 0.1,
                       "Session progress must survive rebuilding after switching away from the requested episode")
        let restoredTarget = try await preparedPlayer(in: pool, for: target.id)
        XCTAssertEqual(restoredTarget.currentTime().seconds, 17, accuracy: 0.1,
                       "Each episode must retain its own session position")
        XCTAssertEqual(restoredPlayer.rate, 0)
        XCTAssertEqual(restoredTarget.rate, 0)
    }

    func testInitialPositionStillSeeksNearTheEndOfAnEpisode() async throws {
        let (pool, item) = try makePositionedPool(PlaybackPosition(episodeNumber: 2, seconds: 59),
                                                 savedSeconds: 59)
        defer { pool.reset() }
        pool.update(items: [item], selectedID: item.id, visible: false, preparationActive: true)
        let player = try await preparedPlayer(in: pool, for: item.id)
        XCTAssertEqual(player.currentItem?.duration.seconds ?? 0, 60, accuracy: 0.1)
        XCTAssertEqual(player.currentTime().seconds, 59, accuracy: 0.1,
                       "Explicit list progress must survive the completed-history cutoff at 98 percent")
        XCTAssertEqual(player.rate, 0)
    }

    func testInitialPositionWithoutSecondsStartsAtZeroDespiteLocalProgress() async throws {
        let (pool, item) = try makePositionedPool(PlaybackPosition(episodeNumber: 2), savedSeconds: 40)
        defer { pool.reset() }
        pool.update(items: [item], selectedID: item.id, visible: false, preparationActive: true)
        let player = try await preparedPlayer(in: pool, for: item.id)
        XCTAssertEqual(player.currentTime().seconds, 0, accuracy: 0.1,
                       "A missing list progress value must override local history with zero seconds")
        XCTAssertEqual(player.rate, 0)
    }

    func testPreparingAnotherEpisodeDoesNotConsumeOrApplyInitialPosition() async throws {
        let (pool, target) = try makePositionedPool(PlaybackPosition(episodeNumber: 2, seconds: 17),
                                                   savedSeconds: 40)
        defer { pool.reset() }
        let first = makePlaybackItem(number: 1)
        pool.update(items: [first, target], selectedID: first.id, visible: false, preparationActive: true)
        let firstPlayer = try await preparedPlayer(in: pool, for: first.id)
        XCTAssertEqual(firstPlayer.currentTime().seconds, 0, accuracy: 0.1,
                       "An initial position for episode 2 must not seek episode 1")
        let targetPlayer = try await preparedPlayer(in: pool, for: target.id)
        XCTAssertEqual(targetPlayer.currentTime().seconds, 17, accuracy: 0.1,
                       "Preparing another episode must leave the initial position available for its target")
        XCTAssertEqual(firstPlayer.rate, 0)
        XCTAssertEqual(targetPlayer.rate, 0)
    }

    private func makePositionedPool(_ position: PlaybackPosition, savedSeconds: Double,
                                   refreshURLs: ((TheaterFeedItem) async throws -> [TheaterFeedItem])? = nil) throws
        -> (TheaterPlayerPool, TheaterFeedItem) {
        let item = makePlaybackItem(number: position.episodeNumber)
        let library = LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        library.save(WatchProgress(dramaID: item.drama.id, episodeID: item.firstEpisode!.id,
            episodeNumber: position.episodeNumber, seconds: savedSeconds, duration: 60, updatedAt: Date()))
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PlaybackProgressFixture", withExtension: "mp4"))
        let pool = TheaterPlayerPool(library: library, cache: .shared, resumesProgress: false,
            initialPosition: position, assetLoader: { _ in AVURLAsset(url: url) }, refreshURLs: refreshURLs)
        return (pool, item)
    }

    private func makePlaybackItem(number: Int) -> TheaterFeedItem {
        let id = String(1000 + number)
        return TheaterFeedItem(drama: makeDrama(),
            firstEpisode: Episode(id: id, number: number, title: "", requiresMembership: false),
            videoURL: URL(string: "https://example.invalid/\(number).m3u8"), firstEpisodeLikeCount: 0,
            isFirstEpisodeLiked: false, isFavorited: false, playbackID: id)
    }

    private func preparedPlayer(in pool: TheaterPlayerPool, for id: String,
                                file: StaticString = #filePath, line: UInt = #line) async throws -> AVPlayer {
        let deadline = Date().addingTimeInterval(5)
        while pool.states[id] != .ready, Date() < deadline {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(pool.states[id], .ready, file: file, line: line)
        return try XCTUnwrap(pool.player(for: id), file: file, line: line)
    }

    func testEpisodePageRangesCoverFinalPartialPage() {
        let episodes = (1...80).map { Episode(id: "\($0)", number: $0, title: "", requiresMembership: false) }
        let ranges = EpisodePageRange.pages(for: episodes)
        XCTAssertEqual(ranges.map(\.title), ["1–30", "31–60", "61–80"])
        XCTAssertTrue(ranges[1].contains(31))
        XCTAssertFalse(ranges[0].contains(31))
        XCTAssertTrue(EpisodePageRange.pages(for: []).isEmpty)
    }

    func testEpisodeUnlockAndWatchedFlagsAreMappedIndependently() {
        let response = APIModels.V1GetDramaEpisodeListRes(episodes: [
            .init(episodeId: 1, episodeNo: 1, isUnlocked: false, unlockCoin: 0, looked: true),
            .init(episodeId: 2, episodeNo: 2, isUnlocked: true, unlockCoin: 0),
            .init(episodeId: 3, episodeNo: 3, isUnlocked: false, unlockCoin: 10),
            .init(episodeId: 4, episodeNo: 4, isUnlocked: true, unlockCoin: 10)
        ])
        let episodes = DramaPlaybackStore.makeItems(response, fallback: makeDrama()).compactMap(\.firstEpisode)
        XCTAssertEqual(episodes[0].looked, true)
        XCTAssertFalse(episodes[0].requiresCoinUnlock)
        XCTAssertTrue(episodes[1].isUnlocked)
        XCTAssertFalse(episodes[1].requiresCoinUnlock)
        XCTAssertTrue(episodes[2].requiresCoinUnlock)
        XCTAssertFalse(episodes[3].requiresCoinUnlock, "An unlocked episode must not require another payment")
    }

    func testLockedCurrentEpisodePrewarmsSilentlyWithoutAdvancingOrReportingProgress() async throws {
        let library = LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var reportedEpisodes: [Int64] = []
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            XCTAssertEqual(target.path, AppAPI.v1ClientDramaProgress.path)
            let body = try! JSONDecoder().decode(APIModels.V1ReportDramaProgressReq.self, from: target.body)
            reportedEpisodes.append(body.episodeId)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(#"{"code":200,"data":{"saved":true}}"#.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in .immediate })
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                                provider: provider)
        let reporter = TheaterProgressReporter(network: network, interval: 0)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PlaybackProgressFixture", withExtension: "mp4"))
        var loadedIDs: [String] = []
        let pool = TheaterPlayerPool(library: library, cache: .shared, progressReporter: reporter,
            assetLoader: { item in loadedIDs.append(item.id); return AVURLAsset(url: url) })
        defer { pool.reset() }
        let locked = TheaterFeedItem(drama: makeDrama(),
            firstEpisode: Episode(id: "1006", number: 6, title: "", requiresMembership: false,
                                  unlockCoin: 20, isUnlocked: false),
            videoURL: URL(string: "https://example.invalid/6.m3u8"), firstEpisodeLikeCount: 0,
            isFirstEpisodeLiked: false, isFavorited: false, playbackID: "1006")
        // The unlock layer hides playback while explicitly keeping preparation active.
        pool.update(items: [locked], selectedID: locked.id, visible: false, preparationActive: true)
        let deadline = Date().addingTimeInterval(5)
        while pool.states[locked.id] != .ready, Date() < deadline {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(loadedIDs, [locked.id])
        XCTAssertEqual(pool.states[locked.id], .ready)
        let player = try XCTUnwrap(pool.player(for: locked.id))
        let playerItem = try XCTUnwrap(player.currentItem)
        XCTAssertTrue(player.isMuted)
        pool.update(items: [locked], selectedID: locked.id, visible: true)
        XCTAssertTrue(player.isMuted, "Even an accidentally visible locked page must remain muted")
        XCTAssertFalse(pool.beginScrubbing(locked.id), "A locked prewarmed player cannot seek as watched content")
        pool.toggle()
        pool.playbackRate = 2
        pool.update(items: [locked], selectedID: locked.id, visible: false, preparationActive: true)
        pool.update(items: [locked], selectedID: locked.id, visible: false, preparationActive: true)
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(300))
        XCTAssertEqual(pool.states[locked.id], .ready)
        XCTAssertTrue(pool.player(for: locked.id) === player)
        XCTAssertTrue(player.currentItem === playerItem)
        XCTAssertEqual(loadedIDs, [locked.id], "Repeated unlock-layer updates must reuse the prepared item")
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(player.currentTime().seconds, 0, accuracy: 0.1)
        XCTAssertFalse(pool.hasEnded)
        pool.suspend()
        await reporter.flush()
        XCTAssertNil(library.progress[locked.drama.id])
        XCTAssertTrue(reportedEpisodes.isEmpty, "Prewarming must not send watched-progress reports")
    }

    func testAuthorizationRetriesFailedPrewarmingOnceWithTheSameSource() async throws {
        let library = LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PlaybackProgressFixture", withExtension: "mp4"))
        var loads = 0
        let pool = TheaterPlayerPool(library: library, cache: .shared, assetLoader: { _ in
            loads += 1
            if loads == 1 { throw URLError(.notConnectedToInternet) }
            return AVURLAsset(url: url)
        })
        defer { pool.reset() }
        let remoteURL = try XCTUnwrap(URL(string: "https://example.invalid/6.m3u8"))
        let locked = TheaterFeedItem(drama: makeDrama(),
            firstEpisode: Episode(id: "1006", number: 6, title: "", requiresMembership: false,
                                  unlockCoin: 20, isUnlocked: false),
            videoURL: remoteURL, firstEpisodeLikeCount: 0, isFirstEpisodeLiked: false,
            isFavorited: false, playbackID: "1006")
        pool.update(items: [locked], selectedID: locked.id, visible: false, preparationActive: true)
        let failureDeadline = Date().addingTimeInterval(5)
        while pool.states[locked.id] == .preparing, Date() < failureDeadline {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(20))
        }
        guard case .unavailable = pool.states[locked.id] else {
            return XCTFail("The first silent preparation must fail before authorization")
        }
        XCTAssertEqual(loads, 1)

        let unlocked = TheaterFeedItem(drama: locked.drama,
            firstEpisode: Episode(id: "1006", number: 6, title: "", requiresMembership: false,
                                  unlockCoin: 20, isUnlocked: true),
            videoURL: remoteURL, firstEpisodeLikeCount: 0, isFirstEpisodeLiked: false,
            isFavorited: false, playbackID: "1006")
        pool.update(items: [unlocked], selectedID: unlocked.id, visible: true)
        let readyDeadline = Date().addingTimeInterval(5)
        while pool.states[unlocked.id] != .ready, Date() < readyDeadline {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(pool.states[unlocked.id], .ready)
        XCTAssertEqual(loads, 2, "Authorization must retry a failed preload even when the source URL did not change")
        let player = try XCTUnwrap(pool.player(for: unlocked.id))
        let playerItem = try XCTUnwrap(player.currentItem)
        XCTAssertFalse(player.isMuted)
        XCTAssertGreaterThan(player.rate, 0)

        pool.update(items: [unlocked], selectedID: unlocked.id, visible: true)
        pool.update(items: [unlocked], selectedID: unlocked.id, visible: true)
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(100))
        XCTAssertEqual(loads, 2, "Ordinary updates must not repeat the authorization retry")
        XCTAssertTrue(pool.player(for: unlocked.id) === player)
        XCTAssertTrue(player.currentItem === playerItem)
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
