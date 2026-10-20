import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class PlaybackDetailCacheTests: XCTestCase {
    func testConcurrentPrefetchAndPlaybackShareOneRequest() async throws {
        let stub = Stub()
        stub.delay = 0.08
        let cache = try cache(stub)
        let prefetch = _Concurrency.Task { await cache.prefetch(dramaID: "101") }
        try await waitForRequest(stub)
        let playback = _Concurrency.Task { try await cache.load(dramaID: "101") }
        let second = _Concurrency.Task { try await cache.load(dramaID: "0101") }
        await prefetch.value
        let firstResponse = try await playback.value
        let secondResponse = try await second.value
        XCTAssertEqual(firstResponse.episodes?.first?.episodeId, 1011)
        XCTAssertEqual(secondResponse.episodes?.first?.episodeId, 1011)
        XCTAssertEqual(stub.requests, [101])
        _ = try await cache.load(dramaID: "101")
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testPrefetchLimitWaitsForCapacityAndDoesNotBlockPlayback() async throws {
        let stub = Stub()
        stub.delay = 0.2
        let cache = try cache(stub)
        let first = _Concurrency.Task { await cache.prefetch(dramaID: "101") }
        let second = _Concurrency.Task { await cache.prefetch(dramaID: "102") }
        for _ in 0..<100 {
            if stub.requests.count == 2 { break }
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(Set(stub.requests), [101, 102])
        first.cancel()
        second.cancel()
        let waiting = _Concurrency.Task { await cache.prefetch(dramaID: "103") }
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(15))
        XCTAssertEqual(stub.requests.count, 2, "Cancelled cells still occupy slots while their shared requests finish")
        let foreground = try await cache.load(dramaID: "104")
        XCTAssertEqual(foreground.dramaId, 104, "Foreground playback bypasses the speculative limit")
        await first.value
        await second.value
        await waiting.value
        XCTAssertEqual(stub.requests.count, 4)
        XCTAssertTrue(stub.requests.contains(103), "The final stationary candidate must start as soon as a slot opens")
    }

    func testCancelledPrefetchWaiterDoesNotRequestAndLeavesCapacityForCurrentCandidate() async throws {
        let stub = Stub()
        stub.delay = 0.15
        let cache = try cache(stub)
        let first = _Concurrency.Task { await cache.prefetch(dramaID: "101") }
        let second = _Concurrency.Task { await cache.prefetch(dramaID: "102") }
        for _ in 0..<100 {
            if stub.requests.count == 2 { break }
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(2))
        }
        let obsolete = _Concurrency.Task { await cache.prefetch(dramaID: "103") }
        let current = _Concurrency.Task { await cache.prefetch(dramaID: "104") }
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(15))
        obsolete.cancel()
        await obsolete.value
        XCTAssertEqual(stub.requests.count, 2)
        await first.value
        await second.value
        await current.value
        XCTAssertEqual(Set(stub.requests), [101, 102, 104])
    }

    func testMetadataIsFreshForThirtyMinutesButAccessExpiresAfterFiveMinutes() async throws {
        let stub = Stub()
        let network = try stub.network()
        let directory = directory()
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = PlaybackDetailCache(network: network, directory: directory, now: { date })
        let initial = try await cache.loadSnapshot(dramaID: "101")
        XCTAssertFalse(initial.requiresAccessValidation)
        date.addTimeInterval(299)
        let recent = try await cache.loadSnapshot(dramaID: "101")
        XCTAssertFalse(recent.requiresAccessValidation)
        date.addTimeInterval(1)
        let restored = PlaybackDetailCache(network: network, directory: directory, now: { date })
        let accessStale = try await restored.loadSnapshot(dramaID: "101")
        XCTAssertTrue(accessStale.requiresAccessValidation)
        XCTAssertEqual(accessStale.storedAt, initial.storedAt)
        date.addTimeInterval(1499)
        let metadataFresh = try await restored.revalidate(dramaID: "101")
        XCTAssertTrue(metadataFresh.requiresAccessValidation)
        XCTAssertEqual(stub.requests.count, 1, "Access validation does not require reloading metadata")
    }

    func testStaleMetadataReturnsImmediatelyThenSharesBackgroundRefresh() async throws {
        let stub = Stub()
        stub.response = { id, attempt in Stub.payload(dramaID: id, title: "\(attempt)") }
        var date = Date()
        let cache = PlaybackDetailCache(network: try stub.network(), directory: directory(), now: { date })
        let initial = try await cache.loadSnapshot(dramaID: "101")
        date.addTimeInterval(1800)
        stub.delay = 0.1
        let stale = try await cache.loadSnapshot(dramaID: "101")
        XCTAssertEqual(stale.response.dramaTitle, "1")
        XCTAssertEqual(stale.storedAt, initial.storedAt)
        XCTAssertTrue(stale.requiresAccessValidation)
        let secondStale = try await cache.loadSnapshot(dramaID: "101")
        XCTAssertEqual(secondStale.response.dramaTitle, "1")
        let fresh = try await cache.revalidate(dramaID: "101")
        XCTAssertEqual(fresh.response.dramaTitle, "2")
        XCTAssertEqual(fresh.storedAt, date)
        XCTAssertFalse(fresh.requiresAccessValidation)
        XCTAssertEqual(stub.requests.count, 2)
    }

    func testDiskRetainsStaleDataForOneDayThenRequiresNetworkEvenDuringBackoff() async throws {
        let stub = Stub()
        stub.delay = 0.05
        stub.response = { id, attempt in
            attempt == 2 ? #"{"code":503,"message":"retry"}"# : Stub.payload(dramaID: id, title: "\(attempt)")
        }
        let network = try stub.network()
        let directory = directory()
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = PlaybackDetailCache(network: network, directory: directory, now: { date })
        _ = try await cache.load(dramaID: "101")
        date.addTimeInterval(86_399)
        let restored = PlaybackDetailCache(network: network, directory: directory, now: { date })
        let retained = try await restored.loadSnapshot(dramaID: "101")
        XCTAssertEqual(retained.response.dramaTitle, "1")
        do { _ = try await restored.revalidate(dramaID: "101"); XCTFail("Expected refresh failure") }
        catch {}
        XCTAssertEqual(stub.requests.count, 2)
        date.addTimeInterval(1)
        let expired = try await restored.loadSnapshot(dramaID: "101")
        XCTAssertEqual(expired.response.dramaTitle, "3")
        XCTAssertFalse(expired.requiresAccessValidation)
        XCTAssertEqual(stub.requests.count, 3, "Hard expiry must not serve the old authorization or obey its retry backoff")
    }

    func testBackgroundFailureRetainsOldDataAndBacksOffForThirtySeconds() async throws {
        let stub = Stub()
        stub.response = { id, attempt in
            attempt == 2 ? #"{"code":503,"message":"retry"}"# : Stub.payload(dramaID: id, title: "\(attempt)")
        }
        stub.delay = 0.05
        var date = Date()
        let cache = PlaybackDetailCache(network: try stub.network(), directory: directory(), now: { date })
        let initial = try await cache.loadSnapshot(dramaID: "101")
        date.addTimeInterval(1800)
        _ = try await cache.loadSnapshot(dramaID: "101")
        do { _ = try await cache.revalidate(dramaID: "101"); XCTFail("Expected refresh failure") }
        catch {}
        for _ in 0..<3 {
            let stale = try await cache.loadSnapshot(dramaID: "101")
            XCTAssertEqual(stale.response.dramaTitle, "1")
            XCTAssertEqual(stale.storedAt, initial.storedAt)
            _ = try await cache.revalidate(dramaID: "101")
        }
        XCTAssertEqual(stub.requests.count, 2)
        date.addTimeInterval(29)
        _ = try await cache.revalidate(dramaID: "101")
        XCTAssertEqual(stub.requests.count, 2)
        date.addTimeInterval(1)
        let fresh = try await cache.revalidate(dramaID: "101")
        XCTAssertEqual(fresh.response.dramaTitle, "3")
        XCTAssertEqual(stub.requests.count, 3)
    }

    func testStalePrefetchHoldsItsSlotUntilRefreshCompletes() async throws {
        let stub = Stub()
        var date = Date()
        let cache = PlaybackDetailCache(network: try stub.network(), directory: directory(), now: { date })
        for id in ["101", "102", "103"] { _ = try await cache.load(dramaID: id) }
        date.addTimeInterval(1800)
        stub.delay = 0.1
        let first = _Concurrency.Task { await cache.prefetch(dramaID: "101") }
        let second = _Concurrency.Task { await cache.prefetch(dramaID: "102") }
        try await waitForRequest(stub, count: 5)
        first.cancel()
        second.cancel()
        let third = _Concurrency.Task { await cache.prefetch(dramaID: "103") }
        try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(15))
        XCTAssertEqual(stub.requests.count, 5)
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(stub.requests.count, 6)
    }

    func testTokenAccountDeviceAndEnvironmentScopeIsolation() async throws {
        let stub = Stub()
        let network = try stub.network()
        let directory = directory()
        network.setAccessToken("token-a")
        let cache = PlaybackDetailCache(network: network, directory: directory)
        _ = try await cache.load(dramaID: "101")
        network.setAccessToken("token-b")
        _ = try await cache.load(dramaID: "101")
        XCTAssertEqual(stub.requests.count, 2)
        network.setAccessToken("token-c", accountID: "account-a")
        _ = try await cache.load(dramaID: "101")
        network.setAccessToken("token-d", accountID: "account-a")
        _ = try await cache.load(dramaID: "101")
        XCTAssertEqual(stub.requests.count, 3, "Same-account token renewal preserves the cache")
        network.setAccessToken("token-e", accountID: "account-b")
        _ = try await cache.load(dramaID: "101")
        network.setDeviceIdentifier("another-device")
        _ = try await cache.load(dramaID: "101")
        XCTAssertEqual(stub.requests.count, 5)
        let anotherEnvironment = try stub.network(baseURL: "https://other.example.invalid")
        let anotherCache = PlaybackDetailCache(network: anotherEnvironment, directory: directory)
        _ = try await anotherCache.load(dramaID: "101")
        XCTAssertEqual(stub.requests.count, 6)
    }

    func testLanguageSwitchSeparatesDiskEntriesAndRestoresOriginalLanguage() async throws {
        let previous = LocalizationStore.shared.language
        defer { LocalizationStore.shared.select(previous) }
        let stub = Stub()
        stub.response = { id, _ in Stub.payload(dramaID: id, title: AppLanguage.current.rawValue) }
        let network = try stub.network()
        let directory = directory()
        LocalizationStore.shared.select(.english)
        let cache = PlaybackDetailCache(network: network, directory: directory)
        let english = try await cache.load(dramaID: "101")
        XCTAssertEqual(english.dramaTitle, AppLanguage.english.rawValue)
        LocalizationStore.shared.select(.traditionalChinese)
        let chinese = try await cache.load(dramaID: "101")
        XCTAssertEqual(chinese.dramaTitle, AppLanguage.traditionalChinese.rawValue)
        XCTAssertEqual(stub.requests.count, 2)
        LocalizationStore.shared.select(.english)
        let restored = PlaybackDetailCache(network: network, directory: directory)
        let cachedEnglish = try await restored.load(dramaID: "101")
        XCTAssertEqual(cachedEnglish.dramaTitle, AppLanguage.english.rawValue)
        XCTAssertEqual(stub.requests.count, 2, "Returning to English must reuse its persisted response")
        LocalizationStore.shared.select(.traditionalChinese)
        let cachedChinese = try await restored.load(dramaID: "101")
        XCTAssertEqual(cachedChinese.dramaTitle, AppLanguage.traditionalChinese.rawValue)
        XCTAssertEqual(stub.requests.count, 2, "Both language responses must remain independently reusable")
    }

    func testFailureEmptyAndInvalidResponsesAreRetried() async throws {
        let stub = Stub()
        let cache = try cache(stub)
        stub.response = { _, attempt in
            switch attempt {
            case 1: #"{"code":503,"message":"retry"}"#
            case 2: #"{"code":200,"data":{"episodes":[]}}"#
            case 3: #"{"code":200,"data":{"episodes":[{"episodeId":1,"episodeNo":0}]}}"#
            case 4: #"{"code":200,"data":{"episodes":[{"episodeId":1,"episodeNo":1}]}}"#
            case 5: #"{"code":200,"data":{"episodes":[{"episodeId":1,"episodeNo":1,"videoUrl":"file:///video.mp4"}]}}"#
            default: Stub.payload(dramaID: 101)
            }
        }
        do {
            _ = try await cache.load(dramaID: "101")
            XCTFail("A failed response must throw")
        } catch {}
        for _ in 0..<4 { _ = try await cache.load(dramaID: "101") }
        _ = try await cache.load(dramaID: "101")
        _ = try await cache.load(dramaID: "101")
        XCTAssertEqual(stub.requests.count, 6)
    }

    func testColdLockedEpisodesWithoutURLsAreReturnedWithoutCaching() async throws {
        let stub = Stub()
        stub.response = { _, _ in
            #"{"code":200,"data":{"dramaId":101,"episodes":[{"episodeId":1001,"episodeNo":1,"isUnlocked":false,"unlockCoin":25}]}}"#
        }
        let cache = try cache(stub)
        for _ in 0..<2 {
            let response = try await cache.load(dramaID: "101")
            XCTAssertEqual(response.episodes?.first?.episodeId, 1001)
            XCTAssertEqual(response.episodes?.first?.unlockCoin, 25)
            XCTAssertNil(response.episodes?.first?.videoUrl)
        }
        XCTAssertEqual(stub.requests.count, 2, "The player may show locked rows but the incomplete response must be retried")
        let size = await cache.diskSize()
        XCTAssertEqual(size, 0)
    }

    func testColdResponseForAnotherDramaIsRejectedRatherThanDelivered() async throws {
        let stub = Stub()
        stub.response = { _, _ in Stub.payload(dramaID: 999) }
        let cache = try cache(stub)
        for _ in 0..<2 {
            do {
                _ = try await cache.load(dramaID: "101")
                XCTFail("Never display another drama's episodes")
            } catch {}
        }
        XCTAssertEqual(stub.requests.count, 2)
        let size = await cache.diskSize()
        XCTAssertEqual(size, 0)
    }

    func testCancelledWaiterDoesNotCancelSharedPrefetchOrReceiveData() async throws {
        let stub = Stub()
        stub.delay = 0.08
        let cache = try cache(stub)
        let cancelled = _Concurrency.Task { try await cache.load(dramaID: "101") }
        try await waitForRequest(stub)
        cancelled.cancel()
        let playback = _Concurrency.Task { try await cache.load(dramaID: "101") }
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled caller must not receive data")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        _ = try await playback.value
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testInvalidationAndClearRejectPendingResultsAndPreventDiskRefill() async throws {
        for clearsAll in [false, true] {
            let stub = Stub()
            stub.delay = 0.08
            let network = try stub.network()
            let directory = directory()
            let cache = PlaybackDetailCache(network: network, directory: directory)
            let pending = _Concurrency.Task { try await cache.load(dramaID: "101") }
            try await waitForRequest(stub)
            if clearsAll { await cache.clear() }
            else { cache.invalidate(dramaID: "101") }
            do {
                _ = try await pending.value
                XCTFail("Invalidated work must not reach playback")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            let size = await cache.diskSize()
            XCTAssertEqual(size, 0)
            let restored = PlaybackDetailCache(network: network, directory: directory)
            _ = try await restored.load(dramaID: "101")
            XCTAssertEqual(stub.requests.count, 2)
        }
    }

    func testForceRefreshBypassesExistingFlightAndDisk() async throws {
        let stub = Stub()
        stub.delay = 0.08
        stub.response = { id, attempt in Stub.payload(dramaID: id, title: "\(attempt)") }
        let cache = try cache(stub)
        let previous = _Concurrency.Task { try await cache.load(dramaID: "101") }
        try await waitForRequest(stub)
        let refreshed = try await cache.load(dramaID: "101", forceRefresh: true)
        do {
            _ = try await previous.value
            XCTFail("Superseded flight must not return its older response")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(refreshed.dramaTitle, "2")
        let cached = try await cache.load(dramaID: "101")
        XCTAssertEqual(cached.dramaTitle, "2")
        XCTAssertEqual(stub.requests.count, 2)
        _ = try await cache.load(dramaID: "101", forceRefresh: true)
        XCTAssertEqual(stub.requests.count, 3)
    }

    func testScopeChangeRejectsPendingResponse() async throws {
        let stub = Stub()
        stub.delay = 0.08
        let network = try stub.network()
        network.setAccessToken("first")
        let cache = PlaybackDetailCache(network: network, directory: directory())
        let pending = _Concurrency.Task { try await cache.load(dramaID: "101") }
        try await waitForRequest(stub)
        network.setAccessToken("second")
        do {
            _ = try await pending.value
            XCTFail("Responses from the old identity must be rejected")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        _ = try await cache.load(dramaID: "101")
        XCTAssertEqual(stub.requests.count, 2)
    }

    func testPendingStaleRefreshCannotRestoreClearedInvalidatedOrChangedScopeData() async throws {
        for change in ["clear", "invalidate", "scope"] {
            let stub = Stub()
            stub.response = { id, attempt in Stub.payload(dramaID: id, title: "\(attempt)") }
            let network = try stub.network()
            network.setAccessToken("first")
            var date = Date()
            let cache = PlaybackDetailCache(network: network, directory: directory(), now: { date })
            _ = try await cache.load(dramaID: "101")
            date.addTimeInterval(1800)
            stub.delay = 0.1
            let stale = try await cache.loadSnapshot(dramaID: "101")
            XCTAssertEqual(stale.response.dramaTitle, "1")
            let started = expectation(description: "Awaiting stale refresh before \(change)")
            let pending = _Concurrency.Task {
                started.fulfill()
                return try await cache.revalidate(dramaID: "101")
            }
            await fulfillment(of: [started], timeout: 2)
            try await waitForRequest(stub, count: 2)
            switch change {
            case "clear": await cache.clear()
            case "invalidate": cache.invalidate(dramaID: "101")
            default: network.setAccessToken("second")
            }
            do { _ = try await pending.value; XCTFail("Superseded background work must not reach playback") }
            catch { XCTAssertTrue(error is CancellationError) }
            if change != "scope" {
                let size = await cache.diskSize()
                XCTAssertEqual(size, 0, "A late refresh must not refill removed disk data")
            }
            let fresh = try await cache.loadSnapshot(dramaID: "101")
            XCTAssertEqual(fresh.response.dramaTitle, "3")
            XCTAssertFalse(fresh.requiresAccessValidation)
        }
    }

    func testCapacityEvictsOldEntriesFromMemoryAndDisk() async throws {
        let stub = Stub()
        let network = try stub.network()
        let directory = directory()
        var date = Date()
        let cache = PlaybackDetailCache(network: network, directory: directory, capacity: 2, now: { date })
        for id in ["101", "102", "103"] {
            _ = try await cache.load(dramaID: id)
            date.addTimeInterval(1)
        }
        let restored = PlaybackDetailCache(network: network, directory: directory, capacity: 2, now: { date })
        _ = try await restored.load(dramaID: "103")
        XCTAssertEqual(stub.requests.count, 3)
        _ = try await cache.load(dramaID: "101")
        XCTAssertEqual(stub.requests.count, 4)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count, 2)
    }

    func testFailedForceRefreshKeepsValidMemoryAndDiskResponse() async throws {
        let stub = Stub()
        let network = try stub.network()
        let directory = directory()
        let cache = PlaybackDetailCache(network: network, directory: directory)
        let initial = try await cache.loadSnapshot(dramaID: "101")
        stub.response = { _, _ in #"{"code":200,"data":{"episodes":[]}}"# }
        do { _ = try await cache.loadSnapshot(dramaID: "101", forceRefresh: true); XCTFail("Expected invalid refresh failure") }
        catch {}
        let retained = try await cache.loadSnapshot(dramaID: "101")
        XCTAssertEqual(retained.storedAt, initial.storedAt)
        XCTAssertEqual(retained.response.dramaTitle, initial.response.dramaTitle)
        let restored = PlaybackDetailCache(network: network, directory: directory)
        let persisted = try await restored.loadSnapshot(dramaID: "101")
        XCTAssertEqual(persisted.storedAt, initial.storedAt)
        XCTAssertEqual(stub.requests.count, 2)
        stub.response = { id, _ in Stub.payload(dramaID: id, title: "forced") }
        let forced = try await cache.loadSnapshot(dramaID: "101", forceRefresh: true)
        XCTAssertEqual(forced.response.dramaTitle, "forced", "Explicit refresh bypasses retry backoff")
    }

    func testURLRenewalPreservesRetentionAndAccessAge() async throws {
        let stub = Stub()
        let network = try stub.network()
        let directory = directory()
        var date = Date()
        let cache = PlaybackDetailCache(network: network, directory: directory, maxAge: 86_400, now: { date })
        let initial = try await cache.loadSnapshot(dramaID: "101")
        let old = try XCTUnwrap(initial.response.episodes?.first?.videoUrl.flatMap(URL.init(string:)))
        let replacement = try XCTUnwrap(URL(string: "https://example.invalid/renewed.m3u8"))
        date.addTimeInterval(6 * 3600)
        await cache.updatePlaybackURLs(dramaID: "101", replacing: ["1011": old], with: ["1011": replacement])
        let renewed = try await cache.loadSnapshot(dramaID: "101")
        XCTAssertEqual(renewed.response.episodes?.first?.videoUrl, replacement.absoluteString)
        XCTAssertEqual(renewed.storedAt, initial.storedAt)
        XCTAssertTrue(renewed.requiresAccessValidation)
        await cache.updatePlaybackURLs(dramaID: "101", replacing: ["1011": old], with: ["1011": old])
        let restored = PlaybackDetailCache(network: network, directory: directory, maxAge: 86_400, now: { date })
        let persisted = try await restored.loadSnapshot(dramaID: "101")
        XCTAssertEqual(persisted.response.episodes?.first?.videoUrl, replacement.absoluteString)
        XCTAssertEqual(persisted.storedAt, initial.storedAt)
        date.addTimeInterval(18 * 3600)
        _ = try await restored.load(dramaID: "101")
        XCTAssertEqual(stub.requests.count, 2, "URL renewal cannot extend the 24-hour retention period")
        await restored.clear()
        await restored.updatePlaybackURLs(dramaID: "101", replacing: ["1011": old], with: ["1011": replacement])
        let size = await restored.diskSize()
        XCTAssertEqual(size, 0, "URL renewal cannot restore an invalidated entry")
    }

    private func cache(_ stub: Stub) throws -> PlaybackDetailCache {
        PlaybackDetailCache(network: try stub.network(), directory: directory())
    }

    private func directory() -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackDetailCacheTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: result) }
        return result
    }

    private func waitForRequest(_ stub: Stub, count: Int = 1) async throws {
        for _ in 0..<100 {
            if stub.requests.count >= count { return }
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected detail request to begin")
    }

    @MainActor
    private final class Stub {
        var requests: [Int64] = []
        var delay: TimeInterval = 0
        var response: (Int64, Int) -> String = { id, _ in payload(dramaID: id) }

        func network(baseURL: String = "https://example.invalid") throws -> APIClient {
            let provider = MoyaProvider<APITarget>(endpointClosure: { target in
                XCTAssertEqual(target.path, AppAPI.v1ClientDramaEpisodeList.path)
                let body = try! JSONDecoder().decode(APIModels.V1GetDramaEpisodeListReq.self, from: target.body)
                self.requests.append(body.dramaId)
                let json = self.response(body.dramaId, self.requests.count)
                return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                    sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                    method: target.method, task: target.task, httpHeaderFields: target.headers)
            }, stubClosure: { _ in self.delay > 0 ? .delayed(seconds: self.delay) : .immediate })
            return APIClient(configuration: try APIConfiguration(baseURL: URL(string: baseURL)!), provider: provider)
        }

        static func payload(dramaID: Int64, title: String = "Cached drama") -> String {
            """
            {"code":200,"data":{"dramaId":\(dramaID),"dramaTitle":"\(title)","episodes":[
              {"episodeId":\(dramaID * 10 + 1),"episodeNo":1,"isUnlocked":true,"videoUrl":"https://example.invalid/1.m3u8"}
            ]}}
            """
        }
    }
}
