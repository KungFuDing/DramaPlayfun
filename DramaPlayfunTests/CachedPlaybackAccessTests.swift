import Moya
import XCTest
@testable import DramaPlayfun

@MainActor
final class CachedPlaybackAccessTests: XCTestCase {
    func testStaleCachedGrantUsesReadOnlyStatusAndExpiresAtServerDeadline() async throws {
        let server = Server()
        let (cache, store) = try makeStore(server)
        _ = try await cache.load(dramaID: "101")
        server.date.addTimeInterval(600)
        await store.load()
        let stale = try episode(store)
        XCTAssertTrue(stale.requiresAccessValidation)
        XCTAssertFalse(stale.canPlayWithoutValidation)
        XCTAssertEqual(server.detailRequests, 1, "Five-to-thirty-minute metadata stays cached")

        server.status = {
            #"{"code":200,"data":{"canWatch":true,"watchAccessType":"vip","isVipActive":true,"expireAt":\#(Self.milliseconds(server.date.addingTimeInterval(10)))}}"#
        }
        try await store.validateCachedAccess(stale)
        let allowed = try episode(store)
        XCTAssertFalse(allowed.requiresAccessValidation)
        XCTAssertTrue(allowed.canPlayWithoutValidation)
        XCTAssertEqual(store.accessDeadline(for: allowed.id), server.date.addingTimeInterval(10))
        XCTAssertEqual(server.statusRequests, 1)
        XCTAssertEqual(server.detailRequests, 1)
        XCTAssertEqual(server.unlockRequests, 0)

        server.date.addTimeInterval(9)
        store.expireAccessIfNeeded()
        XCTAssertTrue(try episode(store).canPlayWithoutValidation)
        server.date.addTimeInterval(1)
        store.expireAccessIfNeeded()
        XCTAssertTrue(try episode(store).requiresAccessValidation)
        XCTAssertFalse(store.hasAuthorizedPlayback(allowed))
        try await store.validateCachedAccess(try episode(store))
        XCTAssertEqual(server.statusRequests, 2, "A short server grant must be rechecked when it expires")
        XCTAssertEqual(server.unlockRequests, 0)
    }

    func testDeniedOldZeroPriceGrantRefreshesActualPriceWithoutSpendingCoins() async throws {
        let server = Server()
        let (cache, store) = try makeStore(server)
        _ = try await cache.load(dramaID: "101")
        server.date.addTimeInterval(600)
        await store.load()
        let stale = try episode(store)
        XCTAssertTrue(stale.isUnlocked)
        XCTAssertEqual(stale.unlockCoin, 0)
        server.status = { #"{"code":200,"data":{"canWatch":false,"watchAccessType":"not_unlocked"}}"# }
        server.detail = { Self.details(title: "Current price", unlocked: false, coins: 25) }

        try await store.validateCachedAccess(stale)

        let current = try episode(store)
        XCTAssertFalse(current.isUnlocked)
        XCTAssertEqual(current.unlockCoin, 25)
        XCTAssertTrue(current.requiresCoinUnlock)
        XCTAssertFalse(current.canPlayWithoutValidation)
        XCTAssertEqual(server.detailRequests, 2)
        XCTAssertEqual(server.statusRequests, 1)
        XCTAssertEqual(server.unlockRequests, 0, "Checking stale access must never submit a purchase")
    }

    func testRepeatedAutomaticResolutionAfterStaleDenialAlwaysRequiresConfirmation() async throws {
        let server = Server()
        let (cache, store) = try makeStore(server)
        _ = try await cache.load(dramaID: "101")
        server.date.addTimeInterval(600)
        await store.load()
        let network = try XCTUnwrap(server.network)
        let profile = ProfileStore(network: network)
        let wallet = WalletStore(network: network, profile: profile)
        let coordinator = EpisodeUnlockCoordinator(playback: store, wallet: wallet, profile: profile,
            membership: MembershipStore(service: NoSubscriptionService()))
        server.status = {
            #"{"code":200,"data":{"canWatch":false,"isVipActive":false,"hasCoinUnlocked":false,"watchAccessType":"not_unlocked"}}"#
        }
        server.detail = { Self.details(title: "Current price", unlocked: false, coins: 25) }

        let initial = try await coordinator.resolve(try episode(store), automatically: true)
        let repeated = try await coordinator.resolve(try episode(store), automatically: true)
        await store.load()
        store.expireAccessIfNeeded()
        let foreground = try await coordinator.resolve(try episode(store), automatically: true)

        XCTAssertEqual(initial, .needsConfirmation)
        XCTAssertEqual(repeated, .needsConfirmation)
        XCTAssertEqual(foreground, .needsConfirmation)
        XCTAssertTrue(store.requiresExplicitConfirmation(try episode(store)))
        XCTAssertEqual(try episode(store).unlockCoin, 25)
        XCTAssertEqual(server.detailRequests, 2)
        XCTAssertEqual(server.statusRequests, 3)
        XCTAssertEqual(server.unlockRequests, 0)
        XCTAssertEqual(server.walletRequests, 0, "Returning to the page must not prepare an automatic purchase")
        XCTAssertEqual(server.profileRequests, 0)
        XCTAssertNil(wallet.availableBalance)
        XCTAssertFalse(profile.hasLoadedProfile)
    }

    func testRefreshWinningRaceWithOldEpisodeStillRequiresExplicitConfirmation() async throws {
        let server = Server()
        let (cache, store) = try makeStore(server)
        _ = try await cache.load(dramaID: "101")
        server.date.addTimeInterval(1801)
        server.detailDelay = 0.1
        server.detail = { Self.details(title: "Current paid episode", unlocked: false, coins: 25) }
        server.status = {
            #"{"code":200,"data":{"canWatch":false,"isVipActive":false,"hasCoinUnlocked":false,"watchAccessType":"not_unlocked"}}"#
        }
        await store.load()
        let oldRequest = try episode(store)
        XCTAssertTrue(oldRequest.requiresAccessValidation)
        XCTAssertTrue(oldRequest.isUnlocked)
        XCTAssertEqual(oldRequest.unlockCoin, 0)
        let network = try XCTUnwrap(server.network)
        let profile = ProfileStore(network: network)
        let wallet = WalletStore(network: network, profile: profile)
        let coordinator = EpisodeUnlockCoordinator(playback: store, wallet: wallet, profile: profile,
            membership: MembershipStore(service: NoSubscriptionService()))

        // Revalidation wins after the UI captured the unknown episode but before
        // its automatic resolution runs.
        await store.revalidateDetails()
        let newRequest = try episode(store)
        XCTAssertFalse(newRequest.requiresAccessValidation)
        XCTAssertTrue(newRequest.requiresCoinUnlock)
        XCTAssertEqual(newRequest.unlockCoin, 25)
        XCTAssertTrue(store.requiresExplicitConfirmation(newRequest))
        let raced = try await coordinator.resolve(oldRequest, automatically: true)
        let repeated = try await coordinator.resolve(newRequest, automatically: true)

        XCTAssertEqual(raced, .needsConfirmation)
        XCTAssertEqual(repeated, .needsConfirmation)
        XCTAssertEqual(server.detailRequests, 2)
        XCTAssertEqual(server.statusRequests, 1)
        XCTAssertEqual(server.unlockRequests, 0)
        XCTAssertEqual(server.walletRequests, 0)
        XCTAssertEqual(server.profileRequests, 0)
        XCTAssertNil(wallet.availableBalance)
    }

    func testMissingOrExpiredStatusKeepsCachedGrantBlocked() async throws {
        for responseKind in ["missing", "expired", "inactive-vip"] {
            let server = Server()
            let (cache, store) = try makeStore(server)
            _ = try await cache.load(dramaID: "101")
            server.date.addTimeInterval(600)
            await store.load()
            server.status = {
                switch responseKind {
                case "missing": #"{"code":200,"data":{}}"#
                case "expired":
                    #"{"code":200,"data":{"canWatch":true,"watchAccessType":"free","expireAt":\#(Self.milliseconds(server.date.addingTimeInterval(-1)))}}"#
                default: #"{"code":200,"data":{"canWatch":true,"watchAccessType":"vip","isVipActive":false}}"#
                }
            }
            do {
                try await store.validateCachedAccess(try episode(store))
                XCTFail("Unconfirmed or expired access must remain blocked")
            } catch {}
            XCTAssertTrue(try episode(store).requiresAccessValidation)
            XCTAssertFalse(try episode(store).canPlayWithoutValidation)
            XCTAssertEqual(server.detailRequests, 1)
            XCTAssertEqual(server.statusRequests, 1)
            XCTAssertEqual(server.unlockRequests, 0)
        }
    }

    func testStaleDetailsRevalidateWithoutReplacingPreparedSource() async throws {
        let server = Server()
        let (cache, store) = try makeStore(server)
        _ = try await cache.load(dramaID: "101")
        server.date.addTimeInterval(1800)
        server.detailDelay = 0.1
        server.detail = { Self.details(title: "Fresh title", token: "new") }
        await store.load()
        XCTAssertEqual(store.items.first?.drama.title, "Cached title")
        XCTAssertTrue(try episode(store).requiresAccessValidation)
        let preparedURL = try XCTUnwrap(store.items.first?.videoURL)

        await store.revalidateDetails()

        XCTAssertEqual(store.items.first?.drama.title, "Fresh title")
        XCTAssertEqual(store.items.first?.videoURL, preparedURL)
        XCTAssertFalse(try episode(store).requiresAccessValidation)
        XCTAssertEqual(server.detailRequests, 2)
        XCTAssertEqual(server.unlockRequests, 0)
    }

    func testBackgroundRevalidationDoesNotOverwriteFavoriteOrAuthorizationChange() async throws {
        for change in ["favorite", "authorization"] {
            let server = Server()
            let (cache, store) = try makeStore(server)
            _ = try await cache.load(dramaID: "101")
            server.date.addTimeInterval(1800)
            server.detailDelay = 0.15
            server.detail = { Self.details(title: "Late title", unlocked: false, coins: 25) }
            let requested = expectation(description: "Background request began before \(change)")
            server.onDetail = { if server.detailRequests == 2 { requested.fulfill() } }
            await store.load()
            let awaiting = expectation(description: "Store awaiting revalidation")
            let pending = _Concurrency.Task {
                awaiting.fulfill()
                await store.revalidateDetails()
            }
            await fulfillment(of: [requested, awaiting], timeout: 2)
            if change == "favorite" {
                store.applyFavorite("101", isFavorite: true, count: 99)
            } else {
                store.authorizePlayback(try episode(store))
            }
            await pending.value

            XCTAssertEqual(store.items.first?.drama.title, "Cached title")
            if change == "favorite" {
                XCTAssertEqual(store.items.first?.isFavorited, true)
                XCTAssertEqual(store.items.first?.favoriteCount, 99)
            } else {
                XCTAssertTrue(store.hasAuthorizedPlayback(try episode(store)))
                XCTAssertTrue(try episode(store).canPlayWithoutValidation)
            }
            XCTAssertEqual(server.unlockRequests, 0)
        }
    }

    func testRenewingSignedURLDoesNotExtendCachedAuthorization() async throws {
        let server = Server()
        let (cache, store) = try makeStore(server)
        await store.load()
        let originalDeadline = store.accessDeadline(for: "1001")
        server.date.addTimeInterval(299)

        _ = try await store.refreshPlaybackURLs(for: XCTUnwrap(store.items.first))

        XCTAssertEqual(server.tokenRequests, 1)
        XCTAssertEqual(store.accessDeadline(for: "1001"), originalDeadline)
        XCTAssertEqual(store.items.first?.videoURL?.absoluteString,
            "https://example.invalid/1.m3u8?X-Media-Token=renewed")
        server.date.addTimeInterval(1)
        store.expireAccessIfNeeded()
        XCTAssertTrue(try episode(store).requiresAccessValidation)
        XCTAssertFalse(try episode(store).canPlayWithoutValidation)
        let snapshot = try await cache.loadSnapshot(dramaID: "101")
        XCTAssertTrue(snapshot.requiresAccessValidation)
        XCTAssertEqual(snapshot.response.episodes?.first?.videoUrl,
            "https://example.invalid/1.m3u8?X-Media-Token=renewed")
        XCTAssertEqual(server.detailRequests, 1)
        XCTAssertEqual(server.statusRequests, 0)
        XCTAssertEqual(server.unlockRequests, 0)
    }

    private func episode(_ store: DramaPlaybackStore) throws -> Episode {
        try XCTUnwrap(store.items.first?.firstEpisode)
    }

    private func makeStore(_ server: Server) throws -> (PlaybackDetailCache, DramaPlaybackStore) {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let payload: String
            switch target.path {
            case AppAPI.v1ClientDramaEpisodeList.path:
                server.detailRequests += 1
                server.onDetail?()
                payload = server.detail()
            case AppAPI.v1DramaEpisodeUnlockStatus.path:
                server.statusRequests += 1
                payload = server.status()
            case AppAPI.v1ClientXMToken.path:
                server.tokenRequests += 1
                payload = #"{"code":200,"data":{"videoList":[{"episodeId":1001,"videoUrl":"https://example.invalid/1.m3u8?X-Media-Token=renewed"}]}}"#
            case AppAPI.v1DramaEpisodeUnlock.path:
                server.unlockRequests += 1
                XCTFail("Access validation must not charge the wallet")
                payload = #"{"code":500,"message":"unexpected purchase"}"#
            case AppAPI.v1WalletInfo.path:
                server.walletRequests += 1
                XCTFail("Cached access confirmation must not require a wallet read")
                payload = #"{"code":200,"data":{"balanceCoin":100}}"#
            case AppAPI.v1ClientMe.path:
                server.profileRequests += 1
                XCTFail("Cached access confirmation must not load purchase preferences")
                payload = #"{"code":200,"data":{"coinAmount":100,"autoPlayNext":"on"}}"#
            default:
                XCTFail("Unexpected endpoint \(target.path)")
                payload = #"{"code":500,"message":"unexpected endpoint"}"#
            }
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, Data(payload.utf8)) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { target in
            target.path == AppAPI.v1ClientDramaEpisodeList.path && server.detailDelay > 0
                ? .delayed(seconds: server.detailDelay) : .immediate
        })
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
            provider: provider)
        server.network = network
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CachedPlaybackAccessTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = PlaybackDetailCache(network: network, directory: directory, now: { server.date })
        let drama = Drama(id: "101", title: "List title", summary: "", category: .drama,
            episodeCount: 1, heat: 0, badge: nil, coverURL: nil, rootDramaID: 100)
        let store = DramaPlaybackStore(drama: drama, network: network, repository: DemoDramaRepository(),
            library: LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            detailCache: cache, now: { server.date })
        return (cache, store)
    }

    private static func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

    private static func details(title: String = "Cached title", unlocked: Bool = true,
                                coins: Int = 0, token: String = "cached") -> String {
        """
        {"code":200,"data":{"dramaId":101,"rootDramaId":100,"dramaTitle":"\(title)","isFavorited":false,"favoriteCount":4,
        "episodes":[{"episodeId":1001,"episodeNo":1,"isUnlocked":\(unlocked),"unlockCoin":\(coins),
        "videoUrl":"https://example.invalid/1.m3u8?X-Media-Token=\(token)"}]}}
        """
    }

    @MainActor
    private final class Server {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var detailRequests = 0
        var statusRequests = 0
        var unlockRequests = 0
        var tokenRequests = 0
        var walletRequests = 0
        var profileRequests = 0
        var network: APIClient?
        var detailDelay: TimeInterval = 0
        var onDetail: (() -> Void)?
        var detail: () -> String = { CachedPlaybackAccessTests.details() }
        var status: () -> String = { #"{"code":200,"data":{"canWatch":true,"watchAccessType":"free"}}"# }
    }

    @MainActor
    private final class NoSubscriptionService: SubscriptionService {
        func plans() async throws -> [MembershipPlan] { [] }
        func hasActiveSubscription() async throws -> Bool { false }
        func purchase(planID: String) async throws -> PurchaseOutcome { .cancelled }
        func restore() async throws {}
        func observeTransactions(onChange: @escaping @MainActor () async -> Void) async {}
    }
}
