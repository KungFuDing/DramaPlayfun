import AVFoundation
import XCTest
@testable import DramaPlayfun

@MainActor
final class PlaybackSwipeTests: XCTestCase {
    func testContinuationPriorityKeepsReadyNeighborForTheNextSwipe() async throws {
        let fixture = try fixtureURL()
        var loadedIDs: [String] = []
        let pool = makePool { item in
            loadedIDs.append(item.id)
            return AVURLAsset(url: fixture)
        }
        defer { pool.reset() }
        let items = makeItems(count: 2)

        pool.update(items: items, selectedID: "1", visible: false, preparationActive: true)
        try await waitUntil("The adjacent episode must be prepared before continuation takes priority") {
            pool.states["2"] == .ready
        }
        let neighbor = try XCTUnwrap(pool.player(for: "2"))
        let playerItem = try XCTUnwrap(neighbor.currentItem)

        pool.prioritizeContinuation(true)
        XCTAssertTrue(pool.player(for: "2") === neighbor,
                      "Prioritizing the next episode must not discard an already prepared swipe target")
        XCTAssertTrue(neighbor.currentItem === playerItem)
        XCTAssertEqual(pool.states["2"], .ready)

        pool.update(items: items, selectedID: "2", visible: true)
        try await waitUntil("The retained neighbor must start playing", timeout: 1) {
            neighbor.timeControlStatus == .playing
        }
        XCTAssertTrue(pool.player(for: "2") === neighbor)
        XCTAssertTrue(neighbor.currentItem === playerItem)
        XCTAssertEqual(loadedIDs.filter { $0 == "2" }.count, 1,
                       "The continuation window must not force a second asset load on swipe")
    }

    func testSwipingToPrewarmedNeighborStartsPlaybackWithoutReloadingAndSilencesOldPage() async throws {
        let fixture = try fixtureURL()
        var loadedIDs: [String] = []
        let pool = makePool { item in
            loadedIDs.append(item.id)
            return AVURLAsset(url: fixture)
        }
        defer { pool.reset() }
        let items = makeItems(count: 3)

        pool.update(items: items, selectedID: "1", visible: true)
        try await waitUntil("Foreground playback must warm the next swipe target") {
            guard pool.states["2"] == .ready, let player = pool.player(for: "2") else { return false }
            return self.bufferedSeconds(player) >= 0.5
        }
        let previous = try XCTUnwrap(pool.player(for: "1"))
        let next = try XCTUnwrap(pool.player(for: "2"))
        let preparedItem = try XCTUnwrap(next.currentItem)
        XCTAssertEqual(next.rate, 0, "A speculative neighbor must not play before selection")
        XCTAssertTrue(next.isMuted)

        pool.update(items: items, selectedID: "2", visible: true)
        try await waitUntil("A buffered swipe must enter playback within one second", timeout: 1) {
            next.timeControlStatus == .playing
        }

        XCTAssertTrue(pool.player(for: "2") === next)
        XCTAssertTrue(next.currentItem === preparedItem)
        XCTAssertEqual(loadedIDs.filter { $0 == "2" }.count, 1)
        XCTAssertGreaterThan(next.rate, 0)
        XCTAssertFalse(next.isMuted)
        XCTAssertEqual(previous.rate, 0, "The old page must stop as soon as the selected page changes")
        XCTAssertTrue(previous.isMuted, "Only the selected page may produce audio")
        XCTAssertFalse(pool.isBuffering)
    }

    func testRapidRoundTripRetainsPendingNeighborLoadUntilItLeavesTheWindow() async throws {
        var loadedIDs: [String] = []
        var cancelledIDs: [String] = []
        let pool = makePool { item in
            loadedIDs.append(item.id)
            do {
                try await _Concurrency.Task<Never, Never>.sleep(for: .seconds(60))
                throw CancellationError()
            } catch {
                cancelledIDs.append(item.id)
                throw error
            }
        }
        defer { pool.reset() }
        let items = makeItems(count: 5)

        pool.update(items: items, selectedID: "2", visible: true)
        try await waitUntil("The original foreground load must start") { loadedIDs.contains("2") }
        let original = try XCTUnwrap(pool.player(for: "2"))

        pool.update(items: items, selectedID: "3", visible: true)
        try await waitUntil("The new foreground must start without waiting for the old request") {
            loadedIDs.contains("3")
        }
        XCTAssertTrue(pool.player(for: "2") === original)
        XCTAssertFalse(cancelledIDs.contains("2"), "An unfinished immediate neighbor is still useful on a reverse swipe")

        pool.update(items: items, selectedID: "2", visible: true)
        // Give cancellation handlers and any incorrectly restarted asset task a chance to run.
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(150))
        XCTAssertTrue(pool.player(for: "2") === original)
        XCTAssertEqual(pool.states["2"], .preparing)
        XCTAssertEqual(loadedIDs.filter { $0 == "2" }.count, 1,
                       "A quick 2 → 3 → 2 swipe must retain the original in-flight load")
        XCTAssertFalse(cancelledIDs.contains("2"))

        pool.update(items: items, selectedID: "4", visible: true)
        try await waitUntil("A pending load must be cancelled when it leaves the three-page window") {
            cancelledIDs.contains("2")
        }
        XCTAssertNil(pool.player(for: "2"))
        XCTAssertNil(pool.states["2"])
        XCTAssertEqual(Set(pool.players.keys), ["3", "4", "5"])
        XCTAssertLessThanOrEqual(pool.playerCount, 3)
    }

    func testForwardPreloadTakesSlotFromSlowReverseNeighborAfterForegroundIsBuffered() async throws {
        let fixture = try fixtureURL()
        var loadedIDs: [String] = []
        var cancelledIDs: [String] = []
        let pool = makePool { item in
            loadedIDs.append(item.id)
            if item.id == "2" || item.id == "4" {
                do {
                    try await _Concurrency.Task<Never, Never>.sleep(for: .seconds(60))
                    throw CancellationError()
                } catch {
                    cancelledIDs.append(item.id)
                    throw error
                }
            }
            return AVURLAsset(url: fixture)
        }
        defer { pool.reset() }
        let items = makeItems(count: 5)

        // Prepare page 3 first so promoting it does not introduce a cold-start
        // buffering event that could independently cancel the slow page 2.
        pool.preload(items: items, selectedID: "3")
        try await waitUntil("The upcoming foreground must already have playable media") {
            guard pool.states["3"] == .ready, let player = pool.player(for: "3") else { return false }
            return self.bufferedSeconds(player) >= 0.5
        }
        let foreground = try XCTUnwrap(pool.player(for: "3"))
        let preparedItem = try XCTUnwrap(foreground.currentItem)

        pool.update(items: items, selectedID: "2", visible: true)
        try await waitUntil("The slow original foreground must occupy its loading slot") {
            loadedIDs.contains("2")
        }
        let slowReverse = try XCTUnwrap(pool.player(for: "2"))

        pool.update(items: items, selectedID: "3", visible: true)
        XCTAssertTrue(pool.player(for: "2") === slowReverse,
                      "The immediate reverse neighbor remains available until foreground playback is safe")
        try await waitUntil("The next swipe target must not wait for the slow reverse load to time out", timeout: 2) {
            loadedIDs.contains("4") && cancelledIDs.contains("2")
        }

        XCTAssertTrue(pool.player(for: "3") === foreground)
        XCTAssertTrue(foreground.currentItem === preparedItem)
        XCTAssertEqual(foreground.timeControlStatus, .playing)
        XCTAssertEqual(loadedIDs.filter { $0 == "3" }.count, 1)
        XCTAssertEqual(loadedIDs.filter { $0 == "4" }.count, 1)
        XCTAssertEqual(loadedIDs.filter { $0 == "2" }.count, 1,
                       "The reverse neighbor must stay queued while the preferred neighbor occupies the slot")
        XCTAssertEqual(pool.states["2"], .preparing)
        XCTAssertEqual(Set(pool.players.keys), ["2", "3", "4"])
        XCTAssertLessThanOrEqual(pool.playerCount, 3)
    }

    func testForwardAndReverseSwipesKeepAtMostThreePlayerInstances() {
        let pool = makePool { _ in
            XCTFail("Hidden pages must not start an asset request")
            throw CancellationError()
        }
        defer { pool.reset() }
        let items = makeItems(count: 8)
        let positions = Array(1...8) + Array((1...7).reversed()) + [8, 1, 4, 3, 4]
        var observedPlayers: Set<ObjectIdentifier> = []

        for position in positions {
            pool.update(items: items, selectedID: String(position), visible: false)
            let expected = Set((max(1, position - 1)...min(items.count, position + 1)).map(String.init))
            XCTAssertEqual(Set(pool.players.keys), expected)
            XCTAssertLessThanOrEqual(pool.playerCount, 3,
                                     "Forward, reverse, and long-distance swipes share the same bounded pool")
            observedPlayers.formUnion(pool.players.values.map(ObjectIdentifier.init))
        }

        XCTAssertLessThanOrEqual(observedPlayers.count, 3,
                                 "A released player must be reused instead of allocating another decoder")
    }

    private func makePool(assetLoader: @escaping (TheaterFeedItem) async throws -> AVURLAsset) -> TheaterPlayerPool {
        TheaterPlayerPool(library: LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                          cache: .shared, assetLoader: assetLoader)
    }

    private func makeItems(count: Int) -> [TheaterFeedItem] {
        let drama = Drama(id: "101", title: "滑动播放测试", summary: "", category: .drama,
                          episodeCount: count, heat: 0, badge: nil, coverURL: nil, rootDramaID: 100)
        return (1...count).map { number in
            TheaterFeedItem(drama: drama,
                firstEpisode: Episode(id: String(number), number: number, title: "第\(number)集", requiresMembership: false),
                videoURL: URL(string: "https://example.invalid/\(number).m3u8"),
                firstEpisodeLikeCount: 0, isFirstEpisodeLiked: false, isFavorited: false, playbackID: String(number))
        }
    }

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: "PlaybackProgressFixture", withExtension: "mp4"))
    }

    private func bufferedSeconds(_ player: AVPlayer) -> Double {
        let seconds = player.currentTime().seconds
        return player.currentItem?.loadedTimeRanges.reduce(0) { result, value in
            let range = value.timeRangeValue
            let end = CMTimeRangeGetEnd(range).seconds
            return range.start.seconds <= seconds + 0.1 && end >= seconds ? max(result, end - seconds) : result
        } ?? 0
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }
}
