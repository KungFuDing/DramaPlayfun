import Foundation
import Moya
import XCTest
@testable import DramaPlayfun

@MainActor
final class AppAccountResetTests: XCTestCase {
    func testDeletionRetiresAllStoresBeforeNewGuestSessionStarts() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let probe = DeletionRequestProbe()
        let cleanup = CacheCleanupGate()
        let app = try makeApp(defaults: defaults, probe: probe, cleanup: { await cleanup.wait() })
        await app.guestSession.signInIfNeeded()
        await app.profile.reloadProfile()
        await app.wallet.reloadBalance()
        await app.wallet.load(.recharge)
        let oldProfile = app.profile
        let oldWallet = app.wallet
        let oldWelfare = app.welfare
        let oldHome = app.homeFeed
        let oldTheater = app.theaterFeed
        let oldRankings = app.rankings
        let oldCategories = app.homeCategories
        let oldHistory = app.watchHistory
        let oldCatalog = app.catalog
        let oldPlayback = app.theaterPlayback
        let oldStartup = app.startupContent
        let oldLibrary = app.library
        let revision = app.accountRevision
        oldLibrary.setFavorite("old-drama", isFavorite: true)
        oldLibrary.save(progress())
        XCTAssertEqual(oldWallet.availableBalance, 320)
        XCTAssertFalse(oldWallet.groups.isEmpty)

        let deletion = _Concurrency.Task { try await app.deactivateAccount() }
        let cleaning = await waitUntil { cleanup.started }
        XCTAssertTrue(cleaning)
        XCTAssertFalse(app.guestSession.isReady)
        XCTAssertNotEqual(app.accountRevision, revision)
        XCTAssertEqual(probe.loginCount, 1, "Guest login must wait until caches have been cleared")
        await app.guestSession.signInIfNeeded()
        XCTAssertEqual(probe.loginCount, 1, "A view task cannot restart login during cleanup")
        oldLibrary.save(progress())
        oldLibrary.setFavorite("late-old-favorite", isFavorite: true)
        cleanup.resume()
        try await deletion.value

        XCTAssertTrue(app.guestSession.isReady)
        XCTAssertEqual(probe.loginCount, 2)
        XCTAssertEqual(Set(probe.deviceIDs), ["stable-installation-id"])
        XCTAssertFalse(app.profile === oldProfile)
        XCTAssertFalse(app.wallet === oldWallet)
        XCTAssertFalse(app.welfare === oldWelfare)
        XCTAssertFalse(app.homeFeed === oldHome)
        XCTAssertFalse(app.theaterFeed === oldTheater)
        XCTAssertFalse(app.rankings === oldRankings)
        XCTAssertFalse(app.homeCategories === oldCategories)
        XCTAssertFalse(app.watchHistory === oldHistory)
        XCTAssertFalse(app.catalog === oldCatalog)
        XCTAssertFalse(app.theaterPlayback === oldPlayback)
        XCTAssertFalse(app.startupContent === oldStartup)
        XCTAssertFalse(app.library === oldLibrary)
        XCTAssertNil(app.wallet.availableBalance)
        XCTAssertTrue(app.wallet.groups.isEmpty)
        XCTAssertTrue(app.library.favoriteIDs.isEmpty)
        XCTAssertTrue(app.library.progress.isEmpty)
        oldLibrary.save(progress())
        let persisted = LibraryStore(defaults: defaults)
        XCTAssertTrue(persisted.favoriteIDs.isEmpty)
        XCTAssertTrue(persisted.progress.isEmpty, "A retired player's late save must not resurrect history")
    }

    func testRejectedDeletionPreservesSessionAndLocalData() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let probe = DeletionRequestProbe()
        probe.rejectDeletion = true
        var cleanupCount = 0
        let app = try makeApp(defaults: defaults, probe: probe, cleanup: { cleanupCount += 1 })
        await app.guestSession.signInIfNeeded()
        await app.wallet.reloadBalance()
        let wallet = app.wallet
        let revision = app.accountRevision
        app.library.save(progress())
        do {
            try await app.deactivateAccount()
            XCTFail("Server rejection must be reported to the settings page")
        } catch { }
        XCTAssertTrue(app.guestSession.isReady)
        XCTAssertTrue(app.wallet === wallet)
        XCTAssertEqual(app.wallet.availableBalance, 320)
        XCTAssertFalse(app.library.progress.isEmpty)
        XCTAssertEqual(app.accountRevision, revision)
        XCTAssertEqual(cleanupCount, 0)
        XCTAssertEqual(probe.loginCount, 1)
    }

    func testFailedReloginKeepsDeletedDataClearedAndAllowsRetry() async throws {
        let probe = DeletionRequestProbe()
        let app = try makeApp(defaults: UserDefaults(suiteName: UUID().uuidString)!, probe: probe, cleanup: {})
        await app.guestSession.signInIfNeeded()
        await app.wallet.reloadBalance()
        app.library.save(progress())
        probe.rejectLogin = true
        try await app.deactivateAccount()
        XCTAssertFalse(app.guestSession.isReady)
        XCTAssertNotNil(app.guestSession.errorMessage)
        XCTAssertNil(app.wallet.availableBalance)
        XCTAssertTrue(app.library.progress.isEmpty)
        probe.rejectLogin = false
        await app.guestSession.signInIfNeeded()
        XCTAssertTrue(app.guestSession.isReady)
    }

    func testAccountResetClearsNavigationAndMembershipPresentation() {
        let router = AppRouter()
        router.selectedTab = .profile
        router.paths = [.profile: [.wallet, .settings], .home: [.search]]
        router.membershipPresented = true
        router.resetForAccountChange()
        XCTAssertEqual(router.selectedTab, .home)
        XCTAssertTrue(router.paths.isEmpty)
        XCTAssertFalse(router.membershipPresented)
    }

    func testMediaCacheRejectsWritersFromBeforeAccountReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = HLSMediaCache(directory: directory)
        let request = URLRequest(url: URL(string: "https://example.invalid/segment.ts")!)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Length": "4"])!
        let generation = cache.currentGeneration
        let oldWriter = try XCTUnwrap(cache.writer(for: request, response: response, scope: "old",
                                                   expectedGeneration: generation))
        oldWriter.append(Data([1, 2, 3, 4]))
        cache.clear()
        oldWriter.finish(expectedLength: 4)
        XCTAssertNil(cache.reader(for: request, scope: "old"))
        XCTAssertNil(cache.writer(for: request, response: response, scope: "old", expectedGeneration: generation))
        XCTAssertNotNil(cache.writer(for: request, response: response, scope: "new",
                                     expectedGeneration: cache.currentGeneration))
    }

    private func progress() -> WatchProgress {
        WatchProgress(dramaID: "old-drama", episodeID: "old-episode", episodeNumber: 1,
                      seconds: 20, duration: 60, updatedAt: Date())
    }

    private func makeApp(defaults: UserDefaults, probe: DeletionRequestProbe,
                         cleanup: @escaping @MainActor () async -> Void) throws -> AppContainer {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let (status, data) = probe.response(for: target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(status, data) },
                method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: MoyaProvider.immediatelyStub)
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                                provider: provider)
        return AppContainer(network: network, defaults: defaults,
            deviceIdentifierProvider: ResetTestIdentity(), clearMediaCaches: cleanup)
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if predicate() { return true }
            try? await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(2))
        }
        return predicate()
    }
}

@MainActor
private struct ResetTestIdentity: DeviceIdentifierProviding {
    func identifier() throws -> String { "stable-installation-id" }
}

@MainActor
private final class CacheCleanupGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

nonisolated private final class DeletionRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var logins = 0
    private var devices: [String] = []
    var rejectDeletion = false
    var rejectLogin = false
    var loginCount: Int { lock.withLock { logins } }
    var deviceIDs: [String] { lock.withLock { devices } }

    func response(for target: APITarget) -> (Int, Data) {
        lock.withLock {
            if let id = target.requestHeaders["deviceId"] { devices.append(id) }
            let body: String
            switch target.path {
            case AppAPI.v1AuthGuestLogin.path:
                logins += 1
                if rejectLogin { return (503, Data()) }
                body = #"{"accessToken":"token-\#(logins)","user":{"userNo":"user-\#(logins)"}}"#
            case AppAPI.v1AuthDeactivate.path:
                if rejectDeletion { return (503, Data()) }
                body = "{}"
            case AppAPI.v1WalletInfo.path: body = #"{"balanceCoin":320}"#
            case AppAPI.v1ClientMe.path: body = #"{"nickname":"Old User","coinAmount":320}"#
            case AppAPI.v1OrderRechargeList.path:
                body = #"{"list":[{"productName":"Coins","payAmount":2,"currency":"USD"}],"total":1}"#
            default: body = "{}"
            }
            return (200, Data("{\"code\":200,\"data\":\(body)}".utf8))
        }
    }
}
