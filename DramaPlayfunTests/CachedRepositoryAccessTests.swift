import Moya
import XCTest
@testable import DramaPlayfun

@MainActor
final class CachedRepositoryAccessTests: XCTestCase {
    func testFreshEpisodeListAndSourceUseDetailsWithoutAccessRequest() async throws {
        let stub = Stub()
        let fixture = try fixture(stub)

        let episodes = try await fixture.repository.fetchEpisodes(dramaID: "101")
        let source = try await fixture.repository.playbackSource(dramaID: "101", episodeID: "1001")

        XCTAssertEqual(episodes.count, 1)
        XCTAssertFalse(try XCTUnwrap(episodes.first).requiresAccessValidation)
        XCTAssertTrue(try XCTUnwrap(episodes.first).canPlayWithoutValidation)
        XCTAssertEqual(source.url.absoluteString, Stub.videoURL)
        XCTAssertEqual(stub.paths, [AppAPI.v1ClientDramaEpisodeList.path])
    }

    func testExpiredAccessMarksListedEpisodeUnknownWithoutLosingMetadata() async throws {
        let stub = Stub()
        let fixture = try await expiredFixture(stub)

        let episodes = try await fixture.repository.fetchEpisodes(dramaID: "101")
        let episode = try XCTUnwrap(episodes.first)

        XCTAssertEqual(episode.id, "1001")
        XCTAssertEqual(episode.number, 1)
        XCTAssertEqual(episode.unlockCoin, 0)
        XCTAssertTrue(episode.isUnlocked, "Retaining metadata must not imply fresh playback authorization")
        XCTAssertTrue(episode.requiresAccessValidation)
        XCTAssertFalse(episode.canPlayWithoutValidation)
        XCTAssertEqual(stub.paths, [AppAPI.v1ClientDramaEpisodeList.path],
                       "Listing episodes should not issue per-episode status requests")
    }

    func testExpiredSourceUsesReadOnlyStatusAndDoesNotPersistTheGrant() async throws {
        let stub = Stub()
        let fixture = try await expiredFixture(stub)

        let source = try await fixture.repository.playbackSource(dramaID: "101", episodeID: "1001")
        let listedAgain = try await fixture.repository.fetchEpisodes(dramaID: "101")

        XCTAssertEqual(source.url.absoluteString, Stub.videoURL)
        XCTAssertEqual(source.rootDramaID, 100)
        XCTAssertTrue(try XCTUnwrap(listedAgain.first).requiresAccessValidation,
                      "A protocol source lookup must not turn a session grant into cached authorization")
        XCTAssertEqual(stub.paths, [AppAPI.v1ClientDramaEpisodeList.path, AppAPI.v1DramaEpisodeUnlockStatus.path])
        XCTAssertFalse(stub.paths.contains(AppAPI.v1DramaEpisodeUnlock.path))
    }

    func testDeniedOrMissingStatusCannotTrustCachedFreeUnlockedFields() async throws {
        for status in [
            #"{"episodeId":1001,"canWatch":false,"watchAccessType":"not_unlocked"}"#,
            #"{"episodeId":1001,"hasCoinUnlocked":true}"#
        ] {
            let stub = Stub()
            stub.status = status
            let fixture = try await expiredFixture(stub)

            do {
                _ = try await fixture.repository.playbackSource(dramaID: "101", episodeID: "1001")
                XCTFail("An old zero-price unlocked episode needs a positive current access response")
            } catch { }
            XCTAssertEqual(stub.paths, [AppAPI.v1ClientDramaEpisodeList.path, AppAPI.v1DramaEpisodeUnlockStatus.path])
            XCTAssertFalse(stub.paths.contains(AppAPI.v1DramaEpisodeUnlock.path))
        }
    }

    func testInactiveExpiredOrMismatchedStatusCannotReturnCachedSource() async throws {
        let expired = Int64(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1_000)
        let future = Int64(Date().addingTimeInterval(600).timeIntervalSince1970 * 1_000)
        let statuses = [
            #"{"episodeId":1001,"canWatch":true,"watchAccessType":"vip","isVipActive":false}"#,
            #"{"episodeId":1001,"canWatch":true,"watchAccessType":"vip"}"#,
            """
            {"episodeId":1001,"canWatch":true,"watchAccessType":"free","expireAt":\(expired)}
            """,
            """
            {"episodeId":1001,"canWatch":true,"watchAccessType":"vip","isVipActive":true,"expireAt":\(future),"vipExpireAt":\(expired)}
            """,
            #"{"episodeId":9999,"canWatch":true,"watchAccessType":"free"}"#
        ]
        for status in statuses {
            let stub = Stub()
            stub.status = status
            let fixture = try await expiredFixture(stub)

            do {
                _ = try await fixture.repository.playbackSource(dramaID: "101", episodeID: "1001")
                XCTFail("Inactive, expired or another episode's authorization must not release the source")
            } catch { }
            XCTAssertEqual(stub.paths, [AppAPI.v1ClientDramaEpisodeList.path, AppAPI.v1DramaEpisodeUnlockStatus.path])
        }
    }

    func testCurrentVIPStatusAllowsSourceWithoutBuyingOrReloadingDetails() async throws {
        let stub = Stub()
        let deadline = Int64(Date().addingTimeInterval(120).timeIntervalSince1970 * 1_000)
        stub.status = """
        {"episodeId":1001,"canWatch":true,"watchAccessType":"vip","isVipActive":true,"expireAt":\(deadline),"vipExpireAt":\(deadline)}
        """
        let fixture = try await expiredFixture(stub)

        let source = try await fixture.repository.playbackSource(dramaID: "101", episodeID: "1001")

        XCTAssertEqual(source.url.absoluteString, Stub.videoURL)
        XCTAssertEqual(stub.paths, [AppAPI.v1ClientDramaEpisodeList.path, AppAPI.v1DramaEpisodeUnlockStatus.path])
    }

    func testAccountChangeDuringValidationRejectsThePreviousAccountsGrant() async throws {
        let stub = Stub()
        let started = expectation(description: "Access validation requested")
        stub.statusDelay = 0.15
        stub.onStatusRequest = { started.fulfill() }
        let fixture = try await expiredFixture(stub)
        let source = _Concurrency.Task {
            try await fixture.repository.playbackSource(dramaID: "101", episodeID: "1001")
        }
        await fulfillment(of: [started], timeout: 2)
        fixture.network.setAccessToken("different-token", accountID: "different-account")

        do {
            _ = try await source.value
            XCTFail("A response requested for another account must not release its cached source")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(stub.paths, [AppAPI.v1ClientDramaEpisodeList.path, AppAPI.v1DramaEpisodeUnlockStatus.path])
    }

    private func expiredFixture(_ stub: Stub) async throws -> Fixture {
        let fixture = try fixture(stub)
        _ = try await fixture.cache.loadSnapshot(dramaID: "101")
        fixture.clock.date.addTimeInterval(301)
        return fixture
    }

    private func fixture(_ stub: Stub) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CachedRepositoryAccessTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let network = try stub.network()
        network.setAccessToken("initial-token", accountID: "initial-account")
        let cache = PlaybackDetailCache(network: network, directory: directory, now: { clock.date })
        let repository = APIDramaRepository(network: network, fallback: DemoDramaRepository(), detailCache: cache)
        return Fixture(repository: repository, cache: cache, network: network, clock: clock)
    }

    private struct Fixture {
        let repository: APIDramaRepository
        let cache: PlaybackDetailCache
        let network: APIClient
        let clock: Clock
    }

    private final class Clock {
        var date = Date()
    }

    private final class Stub {
        static let videoURL = "https://example.invalid/1001.m3u8?x-media-token=cached"
        var paths: [String] = []
        var status = #"{"episodeId":1001,"canWatch":true,"watchAccessType":"free"}"#
        var statusDelay: TimeInterval = 0
        var onStatusRequest: (() -> Void)?

        @MainActor
        func network() throws -> APIClient {
            let provider = MoyaProvider<APITarget>(endpointClosure: { target in
                self.paths.append(target.path)
                let payload: String
                switch target.path {
                case AppAPI.v1ClientDramaEpisodeList.path:
                    payload = """
                    {"code":200,"data":{"dramaId":101,"rootDramaId":100,"dramaTitle":"缓存详情","episodes":[
                    {"episodeId":1001,"episodeNo":1,"unlockCoin":0,"isUnlocked":true,"videoUrl":"\(Self.videoURL)"}
                    ]}}
                    """
                case AppAPI.v1DramaEpisodeUnlockStatus.path:
                    let body = try! JSONDecoder().decode(APIModels.V1GetEpisodeUnlockStatusReq.self, from: target.body)
                    XCTAssertEqual(body.episodeId, 1001)
                    self.onStatusRequest?()
                    payload = "{\"code\":200,\"data\":\(self.status)}"
                default:
                    XCTFail("Cached source validation must not purchase access or fetch unrelated endpoints: \(target.path)")
                    payload = #"{"code":500}"#
                }
                return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                    sampleResponseClosure: { .networkResponse(200, Data(payload.utf8)) },
                    method: target.method, task: target.task, httpHeaderFields: target.headers)
            }, stubClosure: { target in
                target.path == AppAPI.v1DramaEpisodeUnlockStatus.path && self.statusDelay > 0
                    ? .delayed(seconds: self.statusDelay) : .immediate
            })
            return APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                             provider: provider)
        }
    }
}
