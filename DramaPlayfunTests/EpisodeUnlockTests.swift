import AVFoundation
import Moya
import XCTest
@testable import DramaPlayfun

@MainActor
final class EpisodeUnlockTests: XCTestCase {
    func testSufficientBalanceAutomaticallyUnlocksAndSyncsAuthoritativeWallet() async throws {
        let scenario = UnlockScenario(balance: 100)
        scenario.balanceAfterUnlock = 73
        let harness = try await makeHarness(scenario)
        let episode = try harness.episode("1006")
        let neighborURL = harness.playback.items.first?.videoURL

        let outcome = try await harness.coordinator.resolve(episode, automatically: true)

        XCTAssertEqual(outcome, .unlocked(coins: 20))
        XCTAssertEqual(scenario.unlockRequests, [1006])
        XCTAssertEqual(harness.wallet.balance, 73, "Use the server's balance, not a client-side subtraction")
        XCTAssertEqual(harness.profile.profile.coinAmount, 73)
        XCTAssertFalse(try harness.episode("1006").requiresCoinUnlock)
        XCTAssertNotNil(harness.playback.items.first(where: { $0.id == "1006" })?.videoURL)
        XCTAssertEqual(harness.playback.items.first?.videoURL, neighborURL,
            "Unlocking one episode must not replace another episode's signed URL")
        XCTAssertFalse(harness.coordinator.isUnlocking)
    }

    func testInsufficientBalanceWaitsForConfirmationThenRequestsRechargeWithoutSpending() async throws {
        let scenario = UnlockScenario(balance: 5)
        let harness = try await makeHarness(scenario)
        let episode = try harness.episode("1006")

        let automatic = try await harness.coordinator.resolve(episode, automatically: true)
        let confirmed = try await harness.coordinator.resolve(episode, automatically: false)

        XCTAssertEqual(automatic, .needsConfirmation)
        XCTAssertEqual(confirmed, .needsRecharge)
        XCTAssertTrue(scenario.unlockRequests.isEmpty)
        XCTAssertNil(harness.playback.items.first(where: { $0.id == "1006" })?.videoURL)
        XCTAssertEqual(harness.wallet.balance, 5)
    }

    func testAutoPlayPreferenceDisablesAutomaticDeductionButAllowsManualConfirmation() async throws {
        let scenario = UnlockScenario(balance: 100)
        let harness = try await makeHarness(scenario)
        let episode = try harness.episode("1006")
        XCTAssertTrue(harness.profile.autoPlaysNext)
        try await harness.profile.setAutoPlayNext(false)

        let automatic = try await harness.coordinator.resolve(episode, automatically: true)
        XCTAssertEqual(automatic, .needsConfirmation)
        XCTAssertTrue(scenario.unlockRequests.isEmpty)
        let confirmed = try await harness.coordinator.resolve(episode, automatically: false)

        XCTAssertEqual(confirmed, .unlocked(coins: 20))
        XCTAssertFalse(harness.profile.autoPlaysNext)
        XCTAssertEqual(scenario.unlockRequests, [1006])
    }

    func testAutomaticUnlockLoadsSavedOffPreferenceBeforeSpending() async throws {
        let scenario = UnlockScenario(balance: 100)
        scenario.autoPlayNext = "off"
        let harness = try await makeHarness(scenario)
        let episode = try harness.episode("1006")
        XCTAssertFalse(harness.profile.hasLoadedProfile)
        XCTAssertTrue(harness.profile.autoPlaysNext, "The UI's default must not authorize spending before profile load")

        let first = try await harness.coordinator.resolve(episode, automatically: true)
        let second = try await harness.coordinator.resolve(episode, automatically: true)

        XCTAssertEqual(first, .needsConfirmation)
        XCTAssertEqual(second, .needsConfirmation)
        XCTAssertTrue(harness.profile.hasLoadedProfile)
        XCTAssertFalse(harness.profile.autoPlaysNext)
        XCTAssertEqual(scenario.profileRequests, 1, "Continuous playback should reuse the loaded preference")
        XCTAssertTrue(scenario.unlockRequests.isEmpty)
    }

    func testProfileReadFailureCannotUseTheDefaultToAuthorizeSpending() async throws {
        let scenario = UnlockScenario(balance: 100)
        scenario.failProfile = true
        let harness = try await makeHarness(scenario)
        let episode = try harness.episode("1006")
        do {
            _ = try await harness.coordinator.resolve(episode, automatically: true)
            XCTFail("A failed preference read must not fall back to automatic spending")
        } catch EpisodeUnlockError.settingsUnavailable { }
        XCTAssertFalse(harness.profile.hasLoadedProfile)
        XCTAssertTrue(scenario.unlockRequests.isEmpty)
    }

    func testConfirmationRefreshesTheBalanceAfterRecharge() async throws {
        let scenario = UnlockScenario(balance: 5)
        let harness = try await makeHarness(scenario)
        let episode = try harness.episode("1006")
        scenario.balance = 100

        let confirmed = try await harness.coordinator.resolve(episode, automatically: false)

        XCTAssertEqual(confirmed, .unlocked(coins: 20))
        XCTAssertEqual(scenario.unlockRequests, [1006])
        XCTAssertEqual(harness.wallet.balance, 80)
    }

    func testIncompleteAccessResponseNeverStartsACoinTransaction() async throws {
        let scenario = UnlockScenario(balance: 100)
        scenario.accessStatusAvailable = false
        let harness = try await makeHarness(scenario)
        let episode = try harness.episode("1006")
        do {
            _ = try await harness.coordinator.resolve(episode, automatically: true)
            XCTFail("An unknown access state must not authorize a purchase")
        } catch EpisodeUnlockError.accessUnavailable { }
        XCTAssertTrue(scenario.unlockRequests.isEmpty)
        XCTAssertEqual(harness.wallet.balance, 100)
    }

    func testConcurrentRequestsAndRepeatVisitNeverDeductTwice() async throws {
        let scenario = UnlockScenario(balance: 100)
        scenario.delay = 0.05
        let harness = try await makeHarness(scenario)
        let episode = try harness.episode("1006")
        let first = _Concurrency.Task { try await harness.coordinator.resolve(episode, automatically: true) }
        let second = _Concurrency.Task { try await harness.coordinator.resolve(episode, automatically: false) }
        let firstOutcome = try await first.value
        let secondOutcome = try await second.value
        let revisit = try await harness.coordinator.resolve(episode, automatically: true)

        XCTAssertEqual(firstOutcome, .unlocked(coins: 20))
        XCTAssertEqual(secondOutcome, firstOutcome)
        XCTAssertEqual(revisit, .unlocked(coins: 0))
        XCTAssertEqual(scenario.unlockRequests, [1006])
        XCTAssertEqual(harness.wallet.balance, 80)
    }

    func testDifferentEpisodesSerializeAgainstTheUpdatedWallet() async throws {
        let scenario = UnlockScenario(balance: 30)
        scenario.delay = 0.05
        let harness = try await makeHarness(scenario)
        let sixth = try harness.episode("1006")
        let seventh = try harness.episode("1007")
        let first = _Concurrency.Task { try await harness.coordinator.resolve(sixth, automatically: true) }
        try await waitUntil { scenario.statusRequests > 0 }
        let second = _Concurrency.Task { try await harness.coordinator.resolve(seventh, automatically: true) }

        let firstOutcome = try await first.value
        let secondOutcome = try await second.value
        XCTAssertEqual(firstOutcome, .unlocked(coins: 20))
        XCTAssertEqual(secondOutcome, .needsConfirmation)
        XCTAssertEqual(scenario.unlockRequests, [1006])
        XCTAssertEqual(harness.wallet.balance, 10)
    }

    func testReturningToCanceledQueuedEpisodeStartsAFreshResolution() async throws {
        let scenario = UnlockScenario(balance: 100)
        scenario.delay = 0.1
        let harness = try await makeHarness(scenario)
        let sixth = try harness.episode("1006")
        let seventh = try harness.episode("1007")
        let first = _Concurrency.Task { try await harness.coordinator.resolve(sixth, automatically: true) }
        try await waitUntil { scenario.unlockRequests == [1006] }
        let canceledVisit = _Concurrency.Task { try await harness.coordinator.resolve(seventh, automatically: true) }
        try await waitUntil { harness.coordinator.unlockingEpisodeIDs.contains("1007") }
        canceledVisit.cancel()
        let returnVisit = _Concurrency.Task { try await harness.coordinator.resolve(seventh, automatically: true) }

        _ = try await first.value
        _ = try? await canceledVisit.value
        let outcome = try await returnVisit.value

        XCTAssertEqual(outcome, .unlocked(coins: 20))
        XCTAssertEqual(scenario.unlockRequests, [1006, 1007])
        XCTAssertEqual(harness.wallet.balance, 60)
        XCTAssertFalse(harness.coordinator.isUnlocking)
    }

    func testServerVIPAccessPlaysPaidEpisodesWithoutCoinMutationEvenWithAutoPlayOff() async throws {
        let scenario = UnlockScenario(balance: 0)
        scenario.vip = true
        let harness = try await makeHarness(scenario)
        try await harness.profile.setAutoPlayNext(false)
        let episode = try harness.episode("1006")
        XCTAssertTrue(episode.requiresCoinUnlock, "VIP list entries need not be permanently coin-unlocked")

        let outcome = try await harness.coordinator.resolve(episode, automatically: true)

        XCTAssertEqual(outcome, .unlocked(coins: 0))
        XCTAssertEqual(scenario.statusRequests, 1)
        XCTAssertTrue(scenario.unlockRequests.isEmpty)
        XCTAssertFalse(try harness.episode("1006").requiresCoinUnlock)
        XCTAssertNotNil(harness.playback.items.first(where: { $0.id == "1006" })?.videoURL)
        XCTAssertEqual(harness.wallet.balance, 0)
    }

    func testMissingURLRetryKeepsSuccessfulDeductionAndDoesNotBuyAgain() async throws {
        let scenario = UnlockScenario(balance: 100)
        scenario.playableURLAvailable = false
        let harness = try await makeHarness(scenario)
        let episode = try harness.episode("1006")
        do {
            _ = try await harness.coordinator.resolve(episode, automatically: false)
            XCTFail("A confirmed purchase without a playable URL must remain retryable")
        } catch EpisodeUnlockError.playbackUnavailable { }
        XCTAssertEqual(harness.wallet.balance, 80)
        XCTAssertEqual(harness.profile.profile.coinAmount, 80)
        XCTAssertTrue(harness.playback.hasAuthorizedPlayback(episode))

        scenario.playableURLAvailable = true
        let retry = try await harness.coordinator.resolve(episode, automatically: false)

        XCTAssertEqual(retry, .unlocked(coins: 0))
        XCTAssertEqual(scenario.unlockRequests, [1006])
        XCTAssertEqual(scenario.statusRequests, 1)
        XCTAssertNotNil(harness.playback.items.first(where: { $0.id == "1006" })?.videoURL)
    }

    func testCancelBeforePaymentDoesNotSpend() async throws {
        let scenario = UnlockScenario(balance: 100)
        scenario.delay = 0.1
        let harness = try await makeHarness(scenario)
        let episode = try harness.episode("1006")
        let resolution = _Concurrency.Task { try await harness.coordinator.resolve(episode, automatically: true) }
        try await waitUntil { scenario.statusRequests > 0 }
        XCTAssertTrue(harness.coordinator.unlockingEpisodeIDs.contains(episode.id))
        resolution.cancel()
        do {
            _ = try await resolution.value
            XCTFail("Canceling preflight must stop the automatic unlock")
        } catch is CancellationError { }
        XCTAssertTrue(scenario.unlockRequests.isEmpty)
        XCTAssertEqual(harness.wallet.balance, 100)
    }

    func testCancelAfterPaymentStartsStillSettlesBalanceAndPlaybackGrant() async throws {
        let scenario = UnlockScenario(balance: 100)
        scenario.delay = 0.1
        let harness = try await makeHarness(scenario)
        let episode = try harness.episode("1006")
        let resolution = _Concurrency.Task { try await harness.coordinator.resolve(episode, automatically: true) }
        try await waitUntil { !scenario.unlockRequests.isEmpty }
        resolution.cancel()
        _ = try? await resolution.value

        XCTAssertEqual(harness.wallet.balance, 80)
        XCTAssertEqual(harness.profile.profile.coinAmount, 80)
        XCTAssertFalse(try harness.episode("1006").requiresCoinUnlock)
        let retry = try await harness.coordinator.resolve(episode, automatically: true)
        XCTAssertEqual(retry, .unlocked(coins: 0))
        XCTAssertEqual(scenario.unlockRequests, [1006])
    }

    func testPaymentErrorsAreNotMisreportedAsRecharge() async throws {
        let scenario = UnlockScenario(balance: 100)
        scenario.failUnlock = true
        let harness = try await makeHarness(scenario)
        let episode = try harness.episode("1006")
        do {
            _ = try await harness.coordinator.resolve(episode, automatically: false)
            XCTFail("An unrelated server error must remain an error")
        } catch APIError.business(let code, _) {
            XCTAssertEqual(code, 500)
        }
        XCTAssertFalse(harness.playback.hasAuthorizedPlayback(episode))
        XCTAssertTrue(try harness.episode("1006").requiresCoinUnlock)
    }

    func testUnlockPreparesCurrentEmptyPlayerWithoutResettingPreviousEpisode() async throws {
        let scenario = UnlockScenario(balance: 100)
        let harness = try await makeHarness(scenario)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PlaybackProgressFixture", withExtension: "mp4"))
        var loadedIDs: [String] = []
        let pool = TheaterPlayerPool(library: harness.library, cache: .shared, assetLoader: { item in
            loadedIDs.append(item.id)
            return AVURLAsset(url: url)
        })
        defer { pool.reset() }
        pool.update(items: harness.playback.items, selectedID: "1005", visible: true)
        try await waitUntil { pool.states["1005"] == .ready }
        let previousPlayer = try XCTUnwrap(pool.player(for: "1005"))
        let previousItem = try XCTUnwrap(previousPlayer.currentItem)
        pool.update(items: harness.playback.items, selectedID: "1006", visible: true)
        XCTAssertNil(pool.player(for: "1006")?.currentItem)
        let episode = try harness.episode("1006")

        _ = try await harness.coordinator.resolve(episode, automatically: true)
        pool.update(items: harness.playback.items, selectedID: "1006", visible: true)
        try await waitUntil { pool.states["1006"] == .ready }

        XCTAssertEqual(loadedIDs, ["1005", "1006"], "Locked neighbors must never enter media preparation")
        XCTAssertTrue(pool.player(for: "1005") === previousPlayer)
        XCTAssertTrue(previousPlayer.currentItem === previousItem)
        XCTAssertNotNil(pool.player(for: "1006")?.currentItem)
    }

    private func makeHarness(_ scenario: UnlockScenario) async throws -> UnlockHarness {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            let data = scenario.response(target)
            return Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                sampleResponseClosure: { .networkResponse(200, data) }, method: target.method,
                task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: { _ in scenario.delay > 0 ? .delayed(seconds: scenario.delay) : .immediate })
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
            provider: provider)
        let harness = UnlockHarness(network: network)
        await harness.wallet.reloadBalance()
        await harness.playback.load()
        return harness
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the expected playback/unlock state")
    }
}

@MainActor
private final class UnlockHarness {
    let profile: ProfileStore
    let wallet: WalletStore
    let playback: DramaPlaybackStore
    let coordinator: EpisodeUnlockCoordinator
    let library = LibraryStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)

    init(network: APIClient) {
        profile = ProfileStore(network: network)
        wallet = WalletStore(network: network, profile: profile)
        playback = DramaPlaybackStore(drama: Drama(id: "101", title: "测试剧", summary: "",
            category: .drama, episodeCount: 7, heat: 0, badge: nil, coverURL: nil, rootDramaID: 100),
            network: network, repository: DemoDramaRepository(), library: library)
        coordinator = EpisodeUnlockCoordinator(playback: playback, wallet: wallet, profile: profile,
            membership: MembershipStore(service: UnlockSubscriptionService()))
    }

    func episode(_ id: String) throws -> Episode {
        try XCTUnwrap(playback.items.first(where: { $0.id == id })?.firstEpisode)
    }
}

@MainActor
private final class UnlockScenario {
    var balance: Int64
    var balanceAfterUnlock: Int64?
    var vip = false
    var playableURLAvailable = true
    var accessStatusAvailable = true
    var failUnlock = false
    var failProfile = false
    var autoPlayNext = "on"
    var delay: TimeInterval = 0
    var unlockRequests: [Int64] = []
    var statusRequests = 0
    var profileRequests = 0
    private var unlocked: Set<Int64> = []
    private var listRequests = 0

    init(balance: Int64) { self.balance = balance }

    func response(_ target: APITarget) -> Data {
        let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Any] ?? [:]
        let episodeID = (body["episodeId"] as? NSNumber)?.int64Value ?? 0
        let data: [String: Any]
        switch target.path {
        case AppAPI.v1WalletInfo.path:
            data = ["balanceCoin": balance]
        case AppAPI.v1ClientMe.path:
            profileRequests += 1
            if failProfile { return Data(#"{"code":500,"message":"个人设置暂不可用","data":null}"#.utf8) }
            data = ["coinAmount": balance, "autoPlayNext": autoPlayNext]
        case AppAPI.v1ClientMeAutoPlayNextSet.path:
            autoPlayNext = body["autoPlayNext"] as? String ?? "on"
            data = ["autoPlayNext": autoPlayNext]
        case AppAPI.v1ClientDramaEpisodeList.path:
            listRequests += 1
            let episodes: [[String: Any]] = (5...7).map { number in
                let id = Int64(1000 + number)
                var raw: [String: Any] = ["episodeId": id, "episodeNo": number,
                    "unlockCoin": number == 5 ? 0 : 20, "isUnlocked": unlocked.contains(id)]
                if number == 5 || playableURLAvailable {
                    raw["videoUrl"] = "https://example.invalid/\(number).m3u8?token=\(listRequests)"
                }
                return raw
            }
            data = ["rootDramaId": 100, "episodes": episodes]
        case AppAPI.v1DramaEpisodeUnlockStatus.path:
            statusRequests += 1
            if !accessStatusAvailable { return Data(#"{"code":200,"data":{}}"#.utf8) }
            data = ["episodeId": episodeID, "canWatch": vip || unlocked.contains(episodeID),
                "isVipActive": vip, "hasCoinUnlocked": unlocked.contains(episodeID),
                "watchAccessType": vip ? "vip" : unlocked.contains(episodeID) ? "coin_unlock" : "not_unlocked"]
        case AppAPI.v1DramaEpisodeUnlock.path:
            unlockRequests.append(episodeID)
            if failUnlock { return Data(#"{"code":500,"message":"解锁服务暂不可用","data":null}"#.utf8) }
            if unlocked.insert(episodeID).inserted { balance = balanceAfterUnlock ?? (balance - 20) }
            data = ["unlocked": true, "canWatch": true, "unlockType": "coin", "walletBalance": balance]
        default:
            XCTFail("Unexpected unlock request: \(target.path)")
            data = [:]
        }
        return try! JSONSerialization.data(withJSONObject: ["code": 200, "data": data])
    }
}

@MainActor
private final class UnlockSubscriptionService: SubscriptionService {
    func plans() async throws -> [MembershipPlan] { [] }
    func hasActiveSubscription() async throws -> Bool { false }
    func purchase(planID: String) async throws -> PurchaseOutcome { .cancelled }
    func restore() async throws { }
    func observeTransactions(onChange: @escaping @MainActor () async -> Void) async { }
}
