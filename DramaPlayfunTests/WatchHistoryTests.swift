import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class WatchHistoryTests: XCTestCase {
    private func client(empty: Bool = false, delayed: Bool = false) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Int]
            let json: String
            if target.path != "/mobile/v1/client/me/history/list" || body?["pageSize"] != 20 {
                json = #"{"code":500,"data":null}"#
            } else if empty {
                json = #"{"code":200,"data":{"list":[],"hasMore":false}}"#
            } else if body?["page"] == 1 {
                json = #"{"code":200,"data":{"page":1,"hasMore":true,"list":[{"dramaId":11,"rootDramaId":10,"dramaTitle":"服务器历史剧","episodeId":111,"episodeNo":3,"progressSeconds":65,"coverUrl":"https://example.invalid/a.jpg","isOnline":"online"},{"dramaId":11,"dramaTitle":"重复"},{"id":12,"dramaTitle":"下架剧","isOnline":"offline","progressSeconds":-1},{"dramaId":13}]}}"#
            } else {
                json = #"{"code":200,"data":{"page":2,"hasMore":false,"list":[{"dramaId":11,"dramaTitle":"重复"},{"dramaId":14,"dramaTitle":"另一部剧","episodeText":"更新至20集"}]}}"#
            }
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { target in
            let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Int]
            return delayed && body?["page"] == 2 ? .delayed(seconds: 0.25) : .immediate
        })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!), provider: provider)
    }

    func testServerHistoryDoesNotDependOnDemoCatalogAndResumesEpisode() async throws {
        let history = WatchHistoryStore(network: try client())
        await history.reload()
        XCTAssertNil(history.errorMessage)
        XCTAssertEqual(history.items.map(\.id), ["11", "12"])
        let first = try XCTUnwrap(history.items.first)
        XCTAssertEqual(first.drama.rootDramaID, 10)
        XCTAssertEqual(first.drama.coverURL?.absoluteString, "https://example.invalid/a.jpg")
        XCTAssertEqual(first.subtitle, L10n.tr("%@ · 已观看 %@", L10n.tr("第%d集", 3), "1:05"))
        XCTAssertFalse(history.items[1].isOnline)
        XCTAssertEqual(history.items[1].seconds, 0)
        let suite = "WatchHistoryTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryStore(defaults: defaults)
        XCTAssertNil(first.fraction(using: library), "Unknown duration must not produce a fabricated percentage")
        first.prepareResume(in: library)
        XCTAssertEqual(library.progress["11"]?.episodeID, "111")
        XCTAssertEqual(library.progress["11"]?.episodeNumber, 3)
        XCTAssertEqual(library.progress["11"]?.seconds, 65)
        library.save(WatchProgress(dramaID: "11", episodeID: "111", episodeNumber: 3, seconds: 70,
            duration: 100, updatedAt: Date()))
        XCTAssertEqual(first.fraction(using: library), 0.65)
        first.prepareResume(in: library)
        XCTAssertEqual(library.progress["11"]?.seconds, 70)
        await history.loadMore()
        XCTAssertEqual(history.items.map(\.id), ["11", "12", "14"])
        XCTAssertFalse(history.hasMore)
    }

    func testEmptyHistoryHasNoItems() async throws {
        let history = WatchHistoryStore(network: try client(empty: true))
        await history.reload()
        XCTAssertNil(history.errorMessage)
        XCTAssertTrue(history.items.isEmpty)
        XCTAssertFalse(history.hasMore)
    }

    func testRefreshIgnoresAnOlderHistoryPage() async throws {
        let history = WatchHistoryStore(network: try client(delayed: true))
        await history.reload()
        let older = _Concurrency.Task { await history.loadMore() }
        for _ in 0..<100 where !history.isLoadingMore { await _Concurrency.Task.yield() }
        XCTAssertTrue(history.isLoadingMore)
        await history.reload()
        await older.value
        XCTAssertEqual(history.items.map(\.id), ["11", "12"])
        XCTAssertTrue(history.hasMore)
        XCTAssertFalse(history.isLoadingMore)
    }

    func testLocalizedDramaReusesSameEpisodeDurationWithoutChangingResumeProgress() throws {
        let library = isolatedLibrary()
        library.save(WatchProgress(dramaID: "1783", episodeID: "20425", episodeNumber: 1,
            seconds: 28.074, duration: 84.92, updatedAt: Date()))
        let originalProgress = library.progress
        let englishItem = historyItem(dramaID: "1784")

        XCTAssertEqual(try XCTUnwrap(englishItem.fraction(using: library)), 28.0 / 84.92, accuracy: 0.0001)
        XCTAssertEqual(library.progress, originalProgress,
            "Displaying progress for a localized drama must not change the saved resume position")
    }

    func testDifferentEpisodeOrUnknownDurationDoesNotFabricateProgress() {
        let library = isolatedLibrary()
        library.save(WatchProgress(dramaID: "1783", episodeID: "30425", episodeNumber: 1,
            seconds: 28, duration: 90, updatedAt: Date()))
        let item = historyItem(dramaID: "1784")
        XCTAssertNil(item.fraction(using: library), "Matching episode numbers do not identify the same video")

        library.save(WatchProgress(dramaID: "1784", episodeID: "20425", episodeNumber: 1,
            seconds: 28, duration: 0, updatedAt: Date()))
        library.save(WatchProgress(dramaID: "1785", episodeID: "20425", episodeNumber: 1,
            seconds: 28, duration: -1, updatedAt: Date()))
        XCTAssertNil(item.fraction(using: library), "An exact episode still requires a positive measured duration")
        XCTAssertNil(historyItem(dramaID: "1784", episodeID: nil).fraction(using: library))
    }

    func testExactDramaDurationWinsOtherwiseNewestValidEpisodeRecordIsUsed() throws {
        let library = isolatedLibrary()
        let item = historyItem(dramaID: "1784")
        library.save(WatchProgress(dramaID: "1782", episodeID: "20425", episodeNumber: 1,
            seconds: 28, duration: 60, updatedAt: Date(timeIntervalSince1970: 100)))
        library.save(WatchProgress(dramaID: "1783", episodeID: "20425", episodeNumber: 1,
            seconds: 28, duration: 90, updatedAt: Date(timeIntervalSince1970: 200)))
        library.save(WatchProgress(dramaID: "1785", episodeID: "20425", episodeNumber: 1,
            seconds: 28, duration: 0, updatedAt: Date(timeIntervalSince1970: 300)))
        XCTAssertEqual(try XCTUnwrap(item.fraction(using: library)), 28.0 / 90, accuracy: 0.0001,
            "Choose the newest valid measurement; a newer unknown duration must not hide progress")

        library.save(WatchProgress(dramaID: "1784", episodeID: "20425", episodeNumber: 1,
            seconds: 28, duration: 120, updatedAt: Date(timeIntervalSince1970: 50)))
        XCTAssertEqual(try XCTUnwrap(item.fraction(using: library)), 28.0 / 120, accuracy: 0.0001,
            "The exact drama and episode measurement takes priority over cross-language fallback")

        library.save(WatchProgress(dramaID: "1784", episodeID: "20426", episodeNumber: 2,
            seconds: 28, duration: 140, updatedAt: Date(timeIntervalSince1970: 400)))
        XCTAssertEqual(try XCTUnwrap(item.fraction(using: library)), 28.0 / 90, accuracy: 0.0001,
            "A different episode in the exact drama must not prevent a valid same-episode fallback")
    }

    private func historyItem(dramaID: String, episodeID: String? = "20425") -> WatchHistoryItem {
        let drama = Drama(id: dramaID, title: "English title", summary: "", category: .all,
            episodeCount: 1, heat: 0, badge: nil, coverURL: nil)
        return WatchHistoryItem(drama: drama, episodeID: episodeID, episodeNumber: 1,
            seconds: 28, episodeText: nil, isOnline: true)
    }

    private func isolatedLibrary() -> LibraryStore {
        let suite = "WatchHistoryTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return LibraryStore(defaults: defaults)
    }
}
