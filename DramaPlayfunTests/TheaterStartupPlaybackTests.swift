import AVFoundation
import XCTest
@testable import DramaPlayfun

@MainActor
final class TheaterStartupPlaybackTests: XCTestCase {
    func testStartupPreloadsOnlyFirstEpisodeSilentlyAndReusesItsPlayerOnEntry() async throws {
        let fixture = try fixtureURL()
        let library = makeLibrary()
        var loadedIDs: [String] = []
        let pool = TheaterPlayerPool(library: library, cache: .shared, assetLoader: { item in
            loadedIDs.append(item.id)
            return AVURLAsset(url: fixture)
        })
        defer { pool.reset() }
        let items = makeItems(count: 3)
        let first = items[0]

        pool.preload(items: items, selectedID: first.id)
        pool.preload(items: items, selectedID: first.id)
        try await waitUntil("The first episode must have a playable startup buffer") {
            self.isBuffered(first.id, in: pool)
        }
        pool.preload(items: items, selectedID: first.id)
        let player = try XCTUnwrap(pool.player(for: first.id))
        let playerItem = try XCTUnwrap(player.currentItem)
        XCTAssertEqual(loadedIDs, [first.id])
        XCTAssertEqual(Set(pool.players.keys), [first.id])
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(player.currentTime().seconds, 0, accuracy: 0.1)
        XCTAssertNil(library.progress[first.drama.id])

        pool.update(items: items, selectedID: first.id, visible: true)
        try await waitUntil("Entering the theater must immediately use the warmed episode", timeout: 1) {
            player.timeControlStatus == .playing
        }
        XCTAssertTrue(pool.player(for: first.id) === player)
        XCTAssertTrue(player.currentItem === playerItem)
        XCTAssertEqual(loadedIDs.filter { $0 == first.id }.count, 1)
        XCTAssertFalse(player.isMuted)

        pool.stopPreloading()
        XCTAssertEqual(player.timeControlStatus, .playing,
                       "Startup cleanup must not stop an episode handed to the visible theater")
        XCTAssertFalse(player.isMuted)
        XCTAssertTrue(player.currentItem === playerItem)
    }

    func testStoppingAnUnfinishedPreloadCancelsItAndAllowsAnotherPreload() async throws {
        let fixture = try fixtureURL()
        let library = makeLibrary()
        var loadCount = 0
        var cancellationCount = 0
        let pool = TheaterPlayerPool(library: library, cache: .shared, assetLoader: { _ in
            loadCount += 1
            if loadCount == 1 {
                do {
                    try await _Concurrency.Task<Never, Never>.sleep(for: .seconds(60))
                } catch {
                    cancellationCount += 1
                    throw error
                }
            }
            return AVURLAsset(url: fixture)
        })
        defer { pool.reset() }
        let items = makeItems(count: 1)
        let first = items[0]

        pool.preload(items: items, selectedID: first.id)
        try await waitUntil("The speculative asset request must begin") { loadCount == 1 }
        pool.stopPreloading()
        XCTAssertNil(pool.player(for: first.id))
        XCTAssertNil(pool.states[first.id])
        XCTAssertNil(library.progress[first.drama.id])

        pool.preload(items: items, selectedID: first.id)
        pool.preload(items: items, selectedID: first.id)
        try await waitUntil("A stopped preload must restart without a duplicate request") {
            self.isBuffered(first.id, in: pool) && cancellationCount == 1
        }
        XCTAssertEqual(loadCount, 2)
        XCTAssertTrue(try XCTUnwrap(pool.player(for: first.id)).isMuted)
        XCTAssertNil(library.progress[first.drama.id])
    }

    func testStoppingAReadyPreloadRetainsItsItemAndCanResumePreroll() async throws {
        let fixture = try fixtureURL()
        let library = makeLibrary()
        var loadCount = 0
        let pool = TheaterPlayerPool(library: library, cache: .shared, assetLoader: { _ in
            loadCount += 1
            return AVURLAsset(url: fixture)
        })
        defer { pool.reset() }
        let items = makeItems(count: 1)
        let first = items[0]

        pool.preload(items: items, selectedID: first.id)
        try await waitUntil("The item must reach readiness before startup preparation is stopped") {
            pool.states[first.id] == .ready
        }
        let player = try XCTUnwrap(pool.player(for: first.id))
        let playerItem = try XCTUnwrap(player.currentItem)
        pool.stopPreloading()
        pool.stopPreloading()
        XCTAssertTrue(pool.player(for: first.id) === player)
        XCTAssertTrue(player.currentItem === playerItem)
        XCTAssertEqual(pool.states[first.id], .ready)
        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.rate, 0)
        XCTAssertNil(library.progress[first.drama.id])

        pool.preload(items: items, selectedID: first.id)
        pool.preload(items: items, selectedID: first.id)
        try await waitUntil("Resuming startup preparation must retain the ready item") {
            self.isBuffered(first.id, in: pool)
        }
        XCTAssertEqual(loadCount, 1)
        XCTAssertTrue(player.currentItem === playerItem)
        XCTAssertEqual(player.currentTime().seconds, 0, accuracy: 0.1)
        XCTAssertNil(library.progress[first.drama.id])

        pool.stopPreloading()
        pool.update(items: items, selectedID: first.id, visible: true)
        try await waitUntil("A retained item must also support direct entry after stopping", timeout: 1) {
            player.timeControlStatus == .playing
        }
        XCTAssertTrue(player.currentItem === playerItem)
        XCTAssertEqual(loadCount, 1)
    }

    func testStoppingPreloadAfterForegroundHandoffDoesNotCancelTheInFlightAsset() async throws {
        let fixture = try fixtureURL()
        var loadCount = 0
        var cancelled = false
        let pool = TheaterPlayerPool(library: makeLibrary(), cache: .shared, assetLoader: { _ in
            loadCount += 1
            do {
                try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(150))
            } catch {
                cancelled = true
                throw error
            }
            return AVURLAsset(url: fixture)
        })
        defer { pool.reset() }
        let items = makeItems(count: 1)
        let first = items[0]

        pool.preload(items: items, selectedID: first.id)
        try await waitUntil("The preload must be in flight before the user enters the theater") { loadCount == 1 }
        let player = try XCTUnwrap(pool.player(for: first.id))
        pool.update(items: items, selectedID: first.id, visible: true)
        pool.stopPreloading()

        try await waitUntil("Foreground playback must finish the original asset request") {
            player.timeControlStatus == .playing
        }
        XCTAssertTrue(pool.player(for: first.id) === player)
        XCTAssertFalse(cancelled)
        XCTAssertEqual(loadCount, 1)
        XCTAssertFalse(player.isMuted)
    }

    private func makeLibrary() -> LibraryStore {
        LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func makeItems(count: Int) -> [TheaterFeedItem] {
        (1...count).map { number in
            let dramaID = String(100 + number)
            return TheaterFeedItem(
                drama: Drama(id: dramaID, title: "启动预热 \(number)", summary: "", category: .drama,
                             episodeCount: 3, heat: 0, badge: nil, coverURL: nil, rootDramaID: Int64(100 + number)),
                firstEpisode: Episode(id: String(1000 + number), number: 1, title: "第1集", requiresMembership: false),
                videoURL: URL(string: "https://example.invalid/\(dramaID).m3u8"),
                firstEpisodeLikeCount: 0, isFirstEpisodeLiked: false, isFavorited: false)
        }
    }

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle.main.url(forResource: "PlaybackProgressFixture", withExtension: "mp4"))
    }

    private func isBuffered(_ id: String, in pool: TheaterPlayerPool) -> Bool {
        guard pool.states[id] == .ready, let player = pool.player(for: id),
              let ranges = player.currentItem?.loadedTimeRanges else { return false }
        let seconds = player.currentTime().seconds
        return ranges.contains { value in
            let range = value.timeRangeValue
            return range.start.seconds <= seconds + 0.1 && CMTimeRangeGetEnd(range).seconds - seconds >= 0.5
        }
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
