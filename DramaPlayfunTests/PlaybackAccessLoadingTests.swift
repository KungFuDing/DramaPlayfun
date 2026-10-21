import Foundation
import Moya
import XCTest
@testable import DramaPlayfun

/// Uses held transport callbacks so a fast swipe cannot accidentally pass just
/// because the previous request happened to finish before the assertion.
@MainActor
final class PlaybackAccessLoadingTests: XCTestCase {
    func testCancelledOldEpisodeDoesNotBlockCurrentAccessCheck() async throws {
        let fixture = try await makeFixture(expired: true)
        let first = try fixture.episode("101")
        let second = try fixture.episode("102")
        let old = _Concurrency.Task { try await fixture.coordinator.resolve(first, automatically: true) }
        defer { old.cancel(); fixture.provider.failPending() }
        guard await waitUntil({ fixture.provider.statusRequests.count == 1 }) else {
            return XCTFail("The first episode's permission check never started")
        }
        let oldRequest = fixture.provider.statusRequests[0]
        old.cancel()
        let current = _Concurrency.Task { try await fixture.coordinator.resolve(second, automatically: true) }
        defer { current.cancel() }
        guard await waitUntil({ fixture.provider.statusRequests.count == 2 }) else {
            return XCTFail("The current episode was blocked by the previous episode's held response")
        }
        let currentRequest = fixture.provider.statusRequests[1]
        XCTAssertEqual(currentRequest.episodeID, 102)
        currentRequest.succeed(status(102, canWatch: true))
        let currentOutcome = try await current.value
        XCTAssertEqual(currentOutcome, .unlocked(coins: 0))
        await assertCancelled(old)
        XCTAssertTrue(oldRequest.isCancelled, "Leaving the last waiter must cancel its transport")

        // A transport can still call back after cancellation; it must not grant
        // access to the old page or change the current page's result.
        oldRequest.succeed(status(101, canWatch: true))
        await yieldToTasks()
        XCTAssertTrue(try fixture.episode("101").requiresAccessValidation)
        XCTAssertTrue(try fixture.episode("102").canPlayWithoutValidation)
        XCTAssertTrue(fixture.provider.paymentRequests.isEmpty)
    }

    func testForegroundJoinsPrefetchAndSurvivesPrefetchCancellation() async throws {
        let fixture = try await makeFixture(expired: true)
        let next = try fixture.episode("102")
        let prefetch = _Concurrency.Task { await fixture.store.prevalidateNextEpisode(after: "101") }
        defer { prefetch.cancel(); fixture.provider.failPending() }
        guard await waitUntil({ fixture.provider.statusRequests.count == 1 }) else {
            return XCTFail("The next episode was not prevalidated")
        }
        let request = fixture.provider.statusRequests[0]
        XCTAssertEqual(request.episodeID, 102)
        var joined = false
        let foreground = _Concurrency.Task {
            joined = true
            try await fixture.store.validateCachedAccess(next)
        }
        defer { foreground.cancel() }
        let started = await waitUntil { joined }
        XCTAssertTrue(started)
        prefetch.cancel()
        await prefetch.value

        XCTAssertEqual(fixture.provider.statusRequests.count, 1, "Promotion must reuse the in-flight request")
        XCTAssertFalse(request.isCancelled, "A remaining foreground waiter still needs this response")
        request.succeed(status(102, canWatch: true))
        try await foreground.value
        XCTAssertTrue(try fixture.episode("102").canPlayWithoutValidation)
        let entryOutcome = try await fixture.coordinator.resolve(next, automatically: true)
        XCTAssertEqual(entryOutcome, .unlocked(coins: 0))
        XCTAssertEqual(fixture.provider.statusRequests.count, 1, "A completed prevalidation must be reused on entry")
        XCTAssertTrue(fixture.provider.paymentRequests.isEmpty)
    }

    func testSelectedEpisodeRetainsPrefetchUntilForegroundTaskJoins() async throws {
        let fixture = try await makeFixture(expired: true)
        let next = try fixture.episode("102")
        let prefetch = _Concurrency.Task { await fixture.store.prevalidateNextEpisode(after: "101") }
        defer {
            fixture.store.setActiveAccessEpisode(nil)
            prefetch.cancel()
            fixture.provider.failPending()
        }
        guard await waitUntil({ fixture.provider.statusRequests.count == 1 }) else {
            return XCTFail("The next episode's prevalidation never started")
        }
        let request = fixture.provider.statusRequests[0]
        // SwiftUI cancels the old page's task before starting the new page's
        // foreground task. Selection must preserve that in-flight operation.
        fixture.store.setActiveAccessEpisode("102")
        prefetch.cancel()
        await prefetch.value
        XCTAssertFalse(request.isCancelled)
        var joined = false
        let foreground = _Concurrency.Task {
            joined = true
            try await fixture.store.validateCachedAccess(next)
        }
        defer { foreground.cancel() }
        let started = await waitUntil { joined }
        XCTAssertTrue(started)
        XCTAssertEqual(fixture.provider.statusRequests.count, 1)
        request.succeed(status(102, canWatch: true))
        try await foreground.value
        XCTAssertTrue(try fixture.episode("102").canPlayWithoutValidation)
        XCTAssertEqual(fixture.provider.statusRequests.count, 1)
    }

    func testLeavingSelectedEpisodeCancelsRetainedPrefetchWithNoWaiters() async throws {
        let fixture = try await makeFixture(expired: true)
        let prefetch = _Concurrency.Task { await fixture.store.prevalidateNextEpisode(after: "101") }
        defer {
            fixture.store.setActiveAccessEpisode(nil)
            prefetch.cancel()
            fixture.provider.failPending()
        }
        guard await waitUntil({ fixture.provider.statusRequests.count == 1 }) else {
            return XCTFail("The next episode's prevalidation never started")
        }
        let request = fixture.provider.statusRequests[0]
        fixture.store.setActiveAccessEpisode("102")
        prefetch.cancel()
        await prefetch.value
        XCTAssertFalse(request.isCancelled)

        fixture.store.setActiveAccessEpisode(nil)
        let cancelled = await waitUntil { request.isCancelled }
        XCTAssertTrue(cancelled, "Leaving the player must release a retained request with no consumers")
        request.succeed(status(102, canWatch: true))
        await yieldToTasks()
        XCTAssertTrue(try fixture.episode("102").requiresAccessValidation)
    }

    func testPrefetchDeadlineRemainsStableWhenPermissionExpires() async throws {
        let fixture = try await makeFixture(expired: false)
        let deadline = try XCTUnwrap(fixture.store.accessPrefetchDeadline(for: "102"))
        fixture.clock.date += 301
        XCTAssertTrue(fixture.store.expireAccessIfNeeded())
        XCTAssertNil(fixture.store.accessDeadline(for: "102"))
        XCTAssertEqual(fixture.store.accessPrefetchDeadline(for: "102"), deadline,
                       "Expiry must not change the SwiftUI task key and cancel the check it just started")
    }

    func testReloadInvalidatesOutstandingValidationAndRejectsLateGrant() async throws {
        let fixture = try await makeFixture(expired: true, coinCost: 10)
        let episode = try fixture.episode("101")
        let validation = _Concurrency.Task { try await fixture.store.validateCachedAccess(episode) }
        defer { validation.cancel(); fixture.provider.failPending() }
        guard await waitUntil({ fixture.provider.statusRequests.count == 1 }) else {
            return XCTFail("The permission check never started")
        }
        let request = fixture.provider.statusRequests[0]
        await fixture.store.load(forceRefresh: true)
        await assertCancelled(validation)
        XCTAssertTrue(request.isCancelled)
        request.succeed(status(101, canWatch: true))
        await yieldToTasks()
        let reloaded = try fixture.episode("101")
        XCTAssertFalse(reloaded.requiresAccessValidation)
        XCTAssertFalse(reloaded.canPlayWithoutValidation, "A discarded generation's grant must not unlock fresh metadata")
        XCTAssertTrue(fixture.provider.paymentRequests.isEmpty)
    }

    func testLateDeniedStatusCannotReplaceNewerExternalGrant() async throws {
        let fixture = try await makeFixture(expired: true, coinCost: 10)
        let episode = try fixture.episode("101")
        let validation = _Concurrency.Task { try await fixture.store.validateCachedAccess(episode) }
        defer { validation.cancel(); fixture.provider.failPending() }
        guard await waitUntil({ fixture.provider.statusRequests.count == 1 }) else {
            return XCTFail("The permission check never started")
        }
        // A successful payment can grant the same episode while an older
        // read-only status response is still in flight.
        let grantDeadline = fixture.clock.date.addingTimeInterval(42)
        fixture.store.authorizePlayback(episode, validUntil: grantDeadline)
        fixture.provider.statusRequests[0].succeed(status(101, canWatch: false))
        try await validation.value

        let current = try fixture.episode("101")
        XCTAssertTrue(current.canPlayWithoutValidation)
        XCTAssertFalse(current.requiresAccessValidation)
        XCTAssertFalse(fixture.store.requiresExplicitConfirmation(current))
        XCTAssertEqual(fixture.store.accessDeadline(for: "101"), grantDeadline)
        XCTAssertEqual(fixture.provider.listRequests.count, 1,
                       "An obsolete denial must not trigger a forced price refresh")
        XCTAssertTrue(fixture.provider.paymentRequests.isEmpty)
    }

    func testLatePriceRefreshCannotReplaceGrantReceivedAfterDeniedStatus() async throws {
        let fixture = try await makeFixture(expired: true, coinCost: 10)
        fixture.provider.holdsListRequests = true
        let episode = try fixture.episode("101")
        let validation = _Concurrency.Task { try await fixture.store.validateCachedAccess(episode) }
        defer { validation.cancel(); fixture.provider.failPending() }
        guard await waitUntil({ fixture.provider.statusRequests.count == 1 }) else {
            return XCTFail("The permission check never started")
        }
        fixture.provider.statusRequests[0].succeed(status(101, canWatch: false))
        guard await waitUntil({ fixture.provider.listRequests.count == 2 }) else {
            return XCTFail("The denied status never requested its current confirmation price")
        }

        let grantDeadline = fixture.clock.date.addingTimeInterval(42)
        fixture.store.authorizePlayback(episode, validUntil: grantDeadline)
        fixture.provider.listRequests[1].succeed(fixture.provider.episodeListPayload)
        try await validation.value

        let current = try fixture.episode("101")
        XCTAssertTrue(current.canPlayWithoutValidation)
        XCTAssertFalse(current.requiresAccessValidation)
        XCTAssertFalse(fixture.store.requiresExplicitConfirmation(current))
        XCTAssertEqual(fixture.store.accessDeadline(for: "101"), grantDeadline)
        XCTAssertEqual(fixture.provider.listRequests.count, 2)
        XCTAssertTrue(fixture.provider.paymentRequests.isEmpty)
    }

    func testConcurrentDenialsShareOnePriceRefreshThroughRealDetailCache() async throws {
        let fixture = try await makeFixture(expired: true, coinCost: 10, usesDetailCache: true)
        fixture.provider.holdsListRequests = true
        let first = try fixture.episode("101")
        let second = try fixture.episode("102")
        var finishedCount = 0
        let firstCheck = _Concurrency.Task {
            defer { finishedCount += 1 }
            try await fixture.store.validateCachedAccess(first)
        }
        let secondCheck = _Concurrency.Task {
            defer { finishedCount += 1 }
            try await fixture.store.validateCachedAccess(second)
        }
        defer { firstCheck.cancel(); secondCheck.cancel(); fixture.provider.failPending() }
        guard await waitUntil({ fixture.provider.statusRequests.count == 2 }) else {
            return XCTFail("Both independent read-only checks must start")
        }
        for request in fixture.provider.statusRequests {
            request.succeed(status(try XCTUnwrap(request.episodeID), canWatch: false))
        }
        guard await waitUntil({ fixture.provider.listRequests.count >= 2 }) else {
            return XCTFail("A denial must fetch the current confirmation price")
        }
        // Let the second response finish decoding while the first forced refresh
        // is held. A second forced load would supersede the first cache flight.
        await yieldToTasks()
        XCTAssertEqual(fixture.provider.listRequests.count, 2,
                       "The initial metadata load plus one shared forced price refresh are sufficient")
        XCTAssertFalse(fixture.provider.listRequests[1].isCancelled)
        fixture.provider.listRequests[1].succeed(fixture.provider.episodeListPayload)
        guard await waitUntil({ finishedCount == 2 || fixture.provider.listRequests.count > 2 }) else {
            return XCTFail("The shared price response did not finish both validations")
        }
        // Release an unexpected request before reporting failure, so a broken
        // implementation cannot leave this test suspended indefinitely.
        for request in fixture.provider.listRequests.dropFirst(2) {
            request.succeed(fixture.provider.episodeListPayload)
        }
        try await firstCheck.value
        try await secondCheck.value
        XCTAssertEqual(fixture.provider.listRequests.count, 2)
        for id in ["101", "102"] {
            let episode = try fixture.episode(id)
            XCTAssertFalse(episode.requiresAccessValidation)
            XCTAssertFalse(episode.canPlayWithoutValidation)
            XCTAssertTrue(fixture.store.requiresExplicitConfirmation(episode))
        }
        XCTAssertTrue(fixture.provider.paymentRequests.isEmpty)
        await fixture.detailCache?.clear()
    }

    func testLastWaiterCancellationAllowsImmediateRetryWithoutOldFlightClearingIt() async throws {
        let fixture = try await makeFixture(expired: true)
        let episode = try fixture.episode("101")
        let old = _Concurrency.Task { try await fixture.store.validateCachedAccess(episode) }
        defer { old.cancel(); fixture.provider.failPending() }
        guard await waitUntil({ fixture.provider.statusRequests.count == 1 }) else {
            return XCTFail("The original validation never started")
        }
        let oldRequest = fixture.provider.statusRequests[0]
        old.cancel()
        guard await waitUntil({ oldRequest.isCancelled }) else {
            return XCTFail("The final waiter's cancellation must reach the transport")
        }
        // Do not await the old task: its cleanup may race the new flight.
        let replacement = _Concurrency.Task { try await fixture.store.validateCachedAccess(episode) }
        defer { replacement.cancel() }
        guard await waitUntil({ fixture.provider.statusRequests.count == 2 }) else {
            return XCTFail("A new visit must not join an abandoned validation")
        }
        let replacementRequest = fixture.provider.statusRequests[1]
        await assertCancelled(old)
        XCTAssertTrue(oldRequest.isCancelled)
        oldRequest.succeed(status(101, canWatch: false))
        await yieldToTasks()

        var joined = false
        let additionalWaiter = _Concurrency.Task {
            joined = true
            try await fixture.store.validateCachedAccess(episode)
        }
        defer { additionalWaiter.cancel() }
        let started = await waitUntil { joined }
        XCTAssertTrue(started)
        await yieldToTasks()
        XCTAssertEqual(fixture.provider.statusRequests.count, 2,
                       "Old completion must not erase the replacement flight and cause a third request")
        replacementRequest.succeed(status(101, canWatch: true))
        try await replacement.value
        try await additionalWaiter.value
        XCTAssertTrue(try fixture.episode("101").canPlayWithoutValidation)
    }

    func testNextEpisodePrevalidationIsBoundedAndDenialCannotChargeCoins() async throws {
        let fixture = try await makeFixture(expired: true, coinCost: 10)
        let prefetch = _Concurrency.Task { await fixture.store.prevalidateNextEpisode(after: "101") }
        defer { prefetch.cancel(); fixture.provider.failPending() }
        guard await waitUntil({ fixture.provider.statusRequests.count == 1 }) else {
            return XCTFail("The next episode's permission check never started")
        }
        fixture.provider.statusRequests[0].succeed(status(102, canWatch: false))
        await prefetch.value

        XCTAssertEqual(fixture.provider.statusRequests.map(\.episodeID), [102])
        XCTAssertTrue(fixture.provider.paymentRequests.isEmpty, "Speculation must never submit a coin transaction")
        XCTAssertTrue(try fixture.episode("101").requiresAccessValidation)
        XCTAssertTrue(try fixture.episode("103").requiresAccessValidation)
        let denied = try fixture.episode("102")
        XCTAssertFalse(denied.requiresAccessValidation)
        XCTAssertFalse(denied.canPlayWithoutValidation)
        XCTAssertTrue(fixture.store.requiresExplicitConfirmation(denied))
    }

    func testCoinResolutionsRemainSerialAndDuplicateTapPaysOnlyOnce() async throws {
        let fixture = try await makeFixture(expired: false, coinCost: 10)
        let first = try fixture.episode("101")
        let second = try fixture.episode("102")
        let paymentA = _Concurrency.Task { try await fixture.coordinator.resolve(first, automatically: false) }
        defer { paymentA.cancel(); fixture.provider.failPending() }
        guard await waitUntil({ fixture.provider.statusRequests.count == 1 }) else {
            return XCTFail("The first purchase's status check never started")
        }
        fixture.provider.statusRequests[0].succeed(status(101, canWatch: false))
        guard await waitUntil({ fixture.provider.paymentRequests.count == 1 }) else {
            return XCTFail("The first purchase never reached its coin transaction")
        }
        var duplicateStarted = false
        let duplicate = _Concurrency.Task {
            duplicateStarted = true
            return try await fixture.coordinator.resolve(first, automatically: false)
        }
        var nextStarted = false
        let paymentB = _Concurrency.Task {
            nextStarted = true
            return try await fixture.coordinator.resolve(second, automatically: false)
        }
        defer { duplicate.cancel(); paymentB.cancel() }
        let started = await waitUntil { duplicateStarted && nextStarted }
        XCTAssertTrue(started)
        await yieldToTasks()
        XCTAssertEqual(fixture.provider.statusRequests.map(\.episodeID), [101],
                       "The next purchase must await the previous deduction before reading the balance")
        XCTAssertEqual(fixture.provider.paymentRequests.count, 1)

        fixture.provider.walletBalance = 90
        fixture.provider.paymentRequests[0].succeed(["canWatch": true, "unlocked": true, "walletBalance": 90])
        let firstOutcome = try await paymentA.value
        let duplicateOutcome = try await duplicate.value
        XCTAssertEqual(firstOutcome, .unlocked(coins: 10))
        XCTAssertEqual(duplicateOutcome, .unlocked(coins: 10))
        guard await waitUntil({ fixture.provider.statusRequests.count == 2 }) else {
            return XCTFail("The second purchase did not start after the first settled")
        }
        fixture.provider.statusRequests[1].succeed(status(102, canWatch: false))
        guard await waitUntil({ fixture.provider.paymentRequests.count == 2 }) else {
            return XCTFail("The second transaction never started")
        }
        fixture.provider.walletBalance = 80
        fixture.provider.paymentRequests[1].succeed(["canWatch": true, "unlocked": true, "walletBalance": 80])
        let secondOutcome = try await paymentB.value
        XCTAssertEqual(secondOutcome, .unlocked(coins: 10))
        XCTAssertEqual(fixture.provider.paymentRequests.map(\.episodeID), [101, 102])
        XCTAssertEqual(fixture.wallet.availableBalance, 80)
    }

    func testReadOnlyValidationDoesNotWaitForAnUnrelatedPendingPayment() async throws {
        let fixture = try await makeFixture(expired: false, coinCost: 10)
        let first = try fixture.episode("101")
        let payment = _Concurrency.Task { try await fixture.coordinator.resolve(first, automatically: false) }
        defer { payment.cancel(); fixture.provider.failPending() }
        guard await waitUntil({ fixture.provider.statusRequests.count == 1 }) else {
            return XCTFail("The purchase status check never started")
        }
        fixture.provider.statusRequests[0].succeed(status(101, canWatch: false))
        guard await waitUntil({ fixture.provider.paymentRequests.count == 1 }) else {
            return XCTFail("The coin transaction never started")
        }
        fixture.clock.date += 301
        fixture.store.expireAccessIfNeeded()
        let second = try fixture.episode("102")
        let current = _Concurrency.Task { try await fixture.coordinator.resolve(second, automatically: true) }
        defer { current.cancel() }
        guard await waitUntil({ fixture.provider.statusRequests.count == 2 }) else {
            return XCTFail("A read-only permission check was queued behind an unrelated payment")
        }
        fixture.provider.statusRequests[1].succeed(status(102, canWatch: true))
        let currentOutcome = try await current.value
        XCTAssertEqual(currentOutcome, .unlocked(coins: 0))
        XCTAssertFalse(fixture.provider.paymentRequests[0].isFinished)
        fixture.provider.paymentRequests[0].succeed(["canWatch": true, "unlocked": true, "walletBalance": 90])
        let paymentOutcome = try await payment.value
        XCTAssertEqual(paymentOutcome, .unlocked(coins: 10))
        XCTAssertEqual(fixture.provider.paymentRequests.map(\.episodeID), [101])
    }

    private func makeFixture(expired: Bool, coinCost: Int64 = 0,
                             usesDetailCache: Bool = false) async throws -> AccessLoadingFixture {
        let provider = AccessLoadingProvider(coinCost: coinCost)
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                                provider: provider)
        let clock = AccessLoadingClock()
        let profile = ProfileStore(network: network)
        let wallet = WalletStore(network: network, profile: profile)
        let drama = Drama(id: "1", title: "Access test", summary: "", category: .drama,
                          episodeCount: 3, heat: 0, badge: nil, coverURL: nil)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let detailCache = usesDetailCache ? PlaybackDetailCache(network: network,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("access-cache-\(UUID().uuidString)"),
            now: { clock.date }) : nil
        let store = DramaPlaybackStore(drama: drama, network: network, repository: DemoDramaRepository(),
                                       library: LibraryStore(defaults: defaults), detailCache: detailCache, now: { clock.date })
        let coordinator = EpisodeUnlockCoordinator(playback: store, wallet: wallet, profile: profile,
            membership: MembershipStore(service: AccessLoadingSubscriptionService()))
        await store.load()
        XCTAssertEqual(store.items.count, 3)
        if expired {
            clock.date += 301
            XCTAssertTrue(store.expireAccessIfNeeded())
        }
        return AccessLoadingFixture(provider: provider, store: store, coordinator: coordinator,
                                    wallet: wallet, clock: clock, detailCache: detailCache)
    }

    private func status(_ id: Int64, canWatch: Bool) -> [String: Any] {
        ["episodeId": id, "canWatch": canWatch, "hasCoinUnlocked": false,
         "isVipActive": false, "watchAccessType": canWatch ? "free" : "not_unlocked"]
    }

    private func assertCancelled<T: Sendable>(_ task: _Concurrency.Task<T, Error>,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        switch await task.result {
        case .success: XCTFail("The abandoned waiter must receive cancellation", file: file, line: line)
        case .failure(let error): XCTAssertTrue(error is CancellationError, file: file, line: line)
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if predicate() { return true }
            try? await _Concurrency.Task<Never, Never>.sleep(for: .milliseconds(2))
        }
        return predicate()
    }

    private func yieldToTasks() async {
        for _ in 0..<20 { await _Concurrency.Task<Never, Never>.yield() }
    }
}

@MainActor
private struct AccessLoadingFixture {
    let provider: AccessLoadingProvider
    let store: DramaPlaybackStore
    let coordinator: EpisodeUnlockCoordinator
    let wallet: WalletStore
    let clock: AccessLoadingClock
    let detailCache: PlaybackDetailCache?
    func episode(_ id: String) throws -> Episode {
        try XCTUnwrap(store.items.first(where: { $0.id == id })?.firstEpisode)
    }
}

@MainActor
private final class AccessLoadingClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

/// All callback/cancellation state is locked; callbacks can intentionally arrive
/// late after cancel, like an actual transport racing a fast page change.
nonisolated private final class AccessLoadingRequest: Cancellable, @unchecked Sendable {
    let target: APITarget
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    private let completion: Moya.Completion
    init(target: APITarget, completion: @escaping Moya.Completion) {
        self.target = target
        self.completion = completion
    }
    var episodeID: Int64? {
        let body = (try? JSONSerialization.jsonObject(with: target.body)) as? [String: Any]
        return (body?["episodeId"] as? NSNumber)?.int64Value
    }
    var isCancelled: Bool { lock.withLock { cancelled } }
    var isFinished: Bool { lock.withLock { finished } }
    func cancel() { lock.withLock { cancelled = true } }
    func succeed(_ payload: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: ["code": 200, "data": payload])
        finish(.success(Moya.Response(statusCode: 200, data: data)))
    }
    func fail() { finish(.failure(.underlying(CancellationError(), nil))) }
    private func finish(_ result: Result<Moya.Response, MoyaError>) {
        let shouldFinish = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        if shouldFinish { completion(result) }
    }
}

nonisolated private final class AccessLoadingProvider: MoyaProvider<APITarget>, @unchecked Sendable {
    private let stateLock = NSLock()
    private var recorded: [AccessLoadingRequest] = []
    private var balance: Int64 = 100
    private var holdLists = false
    private let coinCost: Int64
    init(coinCost: Int64) {
        self.coinCost = coinCost
        super.init(stubClosure: MoyaProvider.immediatelyStub)
    }
    var walletBalance: Int64 {
        get { stateLock.withLock { balance } }
        set { stateLock.withLock { balance = newValue } }
    }
    var holdsListRequests: Bool {
        get { stateLock.withLock { holdLists } }
        set { stateLock.withLock { holdLists = newValue } }
    }
    var listRequests: [AccessLoadingRequest] {
        stateLock.withLock { recorded.filter { $0.target.path == AppAPI.v1ClientDramaEpisodeList.path } }
    }
    var episodeListPayload: [String: Any] {
        let episodes: [[String: Any]] = (1...3).map { number in
            ["episodeId": 100 + number, "episodeNo": number, "unlockCoin": coinCost,
             "isUnlocked": false, "videoUrl": "https://example.invalid/episode-\(number).m3u8"]
        }
        return ["rootDramaId": 1, "episodes": episodes]
    }
    var statusRequests: [AccessLoadingRequest] {
        stateLock.withLock { recorded.filter { $0.target.path == AppAPI.v1DramaEpisodeUnlockStatus.path } }
    }
    var paymentRequests: [AccessLoadingRequest] {
        stateLock.withLock { recorded.filter { $0.target.path == AppAPI.v1DramaEpisodeUnlock.path } }
    }
    override func request(_ target: APITarget, callbackQueue: DispatchQueue? = nil,
                          progress: Moya.ProgressBlock? = nil, completion: @escaping Moya.Completion) -> any Cancellable {
        let request = AccessLoadingRequest(target: target, completion: completion)
        stateLock.withLock { recorded.append(request) }
        switch target.path {
        case AppAPI.v1ClientDramaEpisodeList.path:
            if !holdsListRequests { request.succeed(episodeListPayload) }
        case AppAPI.v1WalletInfo.path:
            request.succeed(["balanceCoin": walletBalance])
        case AppAPI.v1ClientMe.path:
            request.succeed(["autoPlayNext": "on", "coinAmount": walletBalance, "vipExpireAt": 0])
        case AppAPI.v1DramaEpisodeUnlockStatus.path, AppAPI.v1DramaEpisodeUnlock.path:
            break // The test chooses precisely when this operation completes.
        default:
            request.fail()
        }
        return request
    }
    func failPending() {
        let requests = stateLock.withLock { recorded }
        requests.forEach { $0.fail() }
    }
}

@MainActor
private final class AccessLoadingSubscriptionService: SubscriptionService {
    func resetForAccountChange() {}
    func plans() async throws -> [MembershipPlan] { [] }
    func hasActiveSubscription() async throws -> Bool { false }
    func purchase(planID: String) async throws -> PurchaseOutcome { .cancelled }
    func restore() async throws {}
    func observeTransactions(onChange: @escaping @MainActor () async -> Void) async {}
}
