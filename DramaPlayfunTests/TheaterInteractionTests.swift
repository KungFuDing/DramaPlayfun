import XCTest
import Moya
import Kingfisher
import CoreImage
import UIKit
@testable import DramaPlayfun

@MainActor
final class TheaterInteractionTests: XCTestCase {
    private let feedJSON = #"{"code":200,"data":{"page":1,"hasMore":false,"list":[{"dramaId":101,"rootDramaId":99,"dramaTitle":"测试分享剧","tagNames":["剧情","古装","甜宠"],"isFavorited":true,"episodes":[{"episodeId":1001,"episodeNo":1,"isLiked":true,"likeCount":12}]}]}}"#

    func testLikeAndFavoriteUseServerStateAndCorrectIDs() async throws {
        let recorder = InteractionRequests()
        let feedJSON = feedJSON
        let network = try client(recorder: recorder) { target in
            if target.path == AppAPI.v2ClientList.path { return feedJSON }
            if target.path == AppAPI.v1ClientDramaLike.path {
                return #"{"code":200,"data":{"isLiked":false,"likeCount":11}}"#
            }
            return #"{"code":200,"data":{"isFavorited":false}}"#
        }
        let feed = TheaterFeedStore(network: network)
        let library = LibraryStore(defaults: defaults())
        await feed.loadIfNeeded()
        try await feed.toggleLike("101")
        try await feed.toggleFavorite("101", library: library)
        XCTAssertFalse(try XCTUnwrap(feed.items.first).isFirstEpisodeLiked)
        XCTAssertEqual(feed.items.first?.firstEpisodeLikeCount, 11)
        XCTAssertFalse(try XCTUnwrap(feed.items.first).isFavorited)
        XCTAssertFalse(library.favoriteIDs.contains("101"))
        let like = try recorder.body(for: AppAPI.v1ClientDramaLike.path)
        XCTAssertEqual(like["episodeId"] as? Int, 1001)
        XCTAssertEqual(like["like"] as? Bool, false)
        let favorite = try recorder.body(for: AppAPI.v1ClientDramaFavorite.path)
        XCTAssertEqual(favorite["dramaId"] as? Int, 101) // Language-level ID, not root ID.
        XCTAssertEqual(favorite["favorite"] as? Bool, false)
    }

    func testFailedActionsDoNotChangeVisibleOrLocalState() async throws {
        let recorder = InteractionRequests()
        let feedJSON = feedJSON
        let network = try client(recorder: recorder) { target in
            target.path == AppAPI.v2ClientList.path ? feedJSON
                : #"{"code":500,"message":"rejected","data":null}"#
        }
        let feed = TheaterFeedStore(network: network)
        let library = LibraryStore(defaults: defaults())
        library.setFavorite("101", isFavorite: true)
        await feed.loadIfNeeded()
        do { try await feed.toggleLike("101"); XCTFail("Expected server rejection") } catch { }
        do { try await feed.toggleFavorite("101", library: library); XCTFail("Expected server rejection") } catch { }
        XCTAssertTrue(try XCTUnwrap(feed.items.first).isFirstEpisodeLiked)
        XCTAssertTrue(try XCTUnwrap(feed.items.first).isFavorited)
        XCTAssertTrue(library.favoriteIDs.contains("101"))
        XCTAssertTrue(feed.likingIDs.isEmpty)
        XCTAssertTrue(feed.favoritingIDs.isEmpty)
    }

    func testRapidLikeTapsSendOneRequest() async throws {
        let recorder = InteractionRequests()
        let feedJSON = feedJSON
        let network = try client(recorder: recorder, delayed: true) { target in
            target.path == AppAPI.v2ClientList.path ? feedJSON : #"{"code":200,"data":{"isLiked":false}}"#
        }
        let feed = TheaterFeedStore(network: network)
        await feed.loadIfNeeded()
        let first = _Concurrency.Task { try await feed.toggleLike("101") }
        for _ in 0..<100 where !feed.likingIDs.contains("101") { await _Concurrency.Task.yield() }
        try await feed.toggleLike("101")
        try await first.value
        XCTAssertEqual(recorder.requests.filter { $0.path == AppAPI.v1ClientDramaLike.path }.count, 1)
    }

    func testProgressThrottlesAndFinalReportBypassesInterval() async throws {
        let recorder = InteractionRequests()
        let network = try client(recorder: recorder) { _ in #"{"code":200,"data":{"saved":true}}"# }
        let reporter = TheaterProgressReporter(network: network)
        let now = Date()
        reporter.report(progress(2), now: now)
        await reporter.flush()
        reporter.report(progress(4), now: now.addingTimeInterval(2))
        await reporter.flush()
        XCTAssertEqual(recorder.requests.count, 1)
        reporter.report(progress(7), force: true, now: now.addingTimeInterval(3))
        await reporter.flush()
        reporter.report(progress(7), force: true)
        await reporter.flush()
        XCTAssertEqual(recorder.requests.count, 2)
        let final = try recorder.body(for: AppAPI.v1ClientDramaProgress.path, last: true)
        XCTAssertEqual(final["dramaId"] as? Int, 101)
        XCTAssertEqual(final["episodeId"] as? Int, 1001)
        XCTAssertEqual(final["progressSeconds"] as? Int, 7)
        XCTAssertEqual(final["durationSeconds"] as? Int, 60)
    }

    func testPendingProgressCoalescesAndReportsStayOrdered() async throws {
        let recorder = InteractionRequests()
        let network = try client(recorder: recorder, delayed: true) { _ in #"{"code":200,"data":{"saved":true}}"# }
        let reporter = TheaterProgressReporter(network: network)
        reporter.report(progress(2), force: true)
        for _ in 0..<100 where recorder.requests.isEmpty { await _Concurrency.Task.yield() }
        reporter.report(progress(8), force: true)
        reporter.report(progress(12), force: true)
        await reporter.flush()
        let positions = try recorder.requests.map {
            (try JSONSerialization.jsonObject(with: $0.body) as? [String: Int])?["progressSeconds"]
        }
        XCTAssertEqual(positions, [2, 12])
    }

    func testRejectedProgressCanBeRetriedAtSamePosition() async throws {
        let recorder = InteractionRequests()
        let network = try client(recorder: recorder) { _ in #"{"code":200,"data":{"saved":false}}"# }
        let reporter = TheaterProgressReporter(network: network)
        reporter.report(progress(5), force: true)
        await reporter.flush()
        reporter.report(progress(5), force: true)
        await reporter.flush()
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func testShareQRCodeContainsExactTextAndCardExportsImage() async throws {
        let recorder = InteractionRequests()
        let text = "https://example.invalid/share?episode=1001&title=短剧"
        let network = try client(recorder: recorder) { target in
            target.path == AppAPI.v1ClientDramaShareText.path
                ? #"{"code":200,"data":{"text":"https://example.invalid/share?episode=1001&title=短剧"}}"#
                : #"{"code":200,"data":{}}"#
        }
        let url = URL(string: "https://example.invalid/test-cover-\(UUID().uuidString).png")!
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }
        try await ImageCache.default.store(cover, forKey: url.cacheKey, toDisk: false)
        let drama = Drama(id: "101", title: "测试分享剧", summary: "", category: .costume,
                          episodeCount: 12, heat: 0, badge: nil, coverURL: url,
                          tagNames: ["剧情", "古装", "甜宠"])
        let item = TheaterFeedItem(drama: drama,
            firstEpisode: Episode(id: "1001", number: 1, title: "第1集", requiresMembership: false),
            videoURL: nil, firstEpisodeLikeCount: 0, isFirstEpisodeLiked: false, isFavorited: false)
        let content = try await DramaShareContent.load(item: item, network: network)
        let qr = CIImage(cgImage: try XCTUnwrap(content.qrCode.cgImage))
            .transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
                                              options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        XCTAssertEqual((detector.features(in: qr).first as? CIQRCodeFeature)?.messageString, text)
        let image = try content.render(drama: drama, width: 300)
        XCTAssertEqual(image.size.width, 300)
        XCTAssertGreaterThan(image.size.height, 450)
        XCTAssertEqual(image.scale, 3)
        XCTAssertNotNil(image.pngData())
        try await DramaShareContent.reportShare(item: item, channel: "qr", network: network)
        XCTAssertEqual(try recorder.body(for: AppAPI.v1ClientDramaShareText.path)["episodeId"] as? Int, 1001)
        XCTAssertEqual(try recorder.body(for: AppAPI.v1ClientDramaShare.path)["channel"] as? String, "qr")
    }

    private func progress(_ seconds: Double) -> WatchProgress {
        .init(dramaID: "101", episodeID: "1001", episodeNumber: 1,
              seconds: seconds, duration: 60, updatedAt: Date())
    }
    private func defaults() -> UserDefaults {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func client(recorder: InteractionRequests, delayed: Bool = false,
                        response: @escaping @Sendable (APITarget) -> String) throws -> APIClient {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            recorder.record(target)
            let json = response(target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(json.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in delayed ? .delayed(seconds: 0.1) : .immediate })
        return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                         provider: provider)
    }
}

nonisolated private final class InteractionRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [APITarget] = []
    var requests: [APITarget] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func record(_ target: APITarget) {
        lock.lock(); defer { lock.unlock() }
        storage.append(target)
    }
    func body(for path: String, last: Bool = false) throws -> [String: Any] {
        let matching = requests.filter { $0.path == path }
        let target = try XCTUnwrap(last ? matching.last : matching.first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: target.body) as? [String: Any])
    }
}
