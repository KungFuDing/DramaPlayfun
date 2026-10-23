import XCTest
import Observation
@testable import DramaPlayfun

final class DramaPlayfunTests: XCTestCase {
    @MainActor
    func testPurchaseConfirmationClearsAfterRevocationForBothMembershipPlans() async {
        for category in [MembershipCategory.weekly, .yearly] {
            let service = MembershipMessageTestService()
            let store = MembershipStore(service: service)
            await store.observeTransactions()
            service.current = activeEntitlement(category)

            await store.purchase(plan(category))
            XCTAssertTrue(store.isActive)
            XCTAssertEqual(store.message, L10n.tr("会员已开通"))
            await store.refresh()
            XCTAssertEqual(store.message, L10n.tr("会员已开通"), "An unchanged entitlement must retain its confirmation")

            await service.publish(MembershipEntitlement())
            XCTAssertFalse(store.isActive)
            XCTAssertNil(store.message, "Revocation must retire the old purchase confirmation")
        }
    }

    @MainActor
    func testRestoreConfirmationClearsAfterExpirationForBothMembershipPlans() async {
        for category in [MembershipCategory.weekly, .yearly] {
            let service = MembershipMessageTestService()
            service.current = activeEntitlement(category)
            let store = MembershipStore(service: service)
            await store.observeTransactions()

            await store.restore()
            XCTAssertEqual(store.message, L10n.tr("已恢复会员权益"))
            await store.refresh()
            XCTAssertEqual(store.message, L10n.tr("已恢复会员权益"))

            await service.publish(MembershipEntitlement())
            XCTAssertFalse(store.isActive)
            XCTAssertNil(store.entitlement.expirationDate)
            XCTAssertNil(store.message, "Expiration must retire the old restore confirmation")
        }
    }

    @MainActor
    func testConfirmationClearsWhenAnActiveMembershipChangesPlan() async {
        let service = MembershipMessageTestService()
        service.current = activeEntitlement(.weekly)
        let store = MembershipStore(service: service)
        await store.observeTransactions()
        await store.restore()

        await service.publish(activeEntitlement(.yearly))

        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.entitlement.category, .yearly)
        XCTAssertNil(store.message, "The previous plan's restore confirmation is no longer current")
    }

    @MainActor
    func testCoinPurchaseConfirmationSurvivesMembershipExpiration() async {
        let service = MembershipMessageTestService()
        service.current = activeEntitlement(.weekly)
        let store = MembershipStore(service: service)
        await store.observeTransactions()
        await store.purchase(plan(.coins))
        XCTAssertEqual(store.message, L10n.tr("充值成功，金币已到账"))

        await service.publish(MembershipEntitlement())

        XCTAssertFalse(store.isActive)
        XCTAssertEqual(store.message, L10n.tr("充值成功，金币已到账"), "Membership changes must not erase coin delivery confirmation")
    }

    @MainActor
    func testPurchaseFailureSurvivesMembershipExpiration() async {
        let service = MembershipMessageTestService()
        service.current = activeEntitlement(.weekly)
        service.purchaseError = MembershipMessageTestError.rejected
        let store = MembershipStore(service: service)
        await store.observeTransactions()
        await store.purchase(plan(.yearly))
        let failureMessage = store.message
        XCTAssertNotNil(failureMessage)

        await service.publish(MembershipEntitlement())

        XCTAssertFalse(store.isActive)
        XCTAssertEqual(store.message, failureMessage, "Membership changes must not erase an unrelated purchase error")
    }

    @MainActor
    func testTransactionFailureRemainsVisibleAfterMembershipChanges() async {
        let service = MembershipMessageTestService()
        service.current = activeEntitlement(.weekly)
        service.transactionMessage = "Pending delivery failed"
        let store = MembershipStore(service: service)
        await store.observeTransactions()
        XCTAssertEqual(store.message, service.transactionMessage)

        await service.publish(MembershipEntitlement())

        XCTAssertFalse(store.isActive)
        XCTAssertEqual(store.message, service.transactionMessage)
    }

    @MainActor
    func testOlderActiveReadCannotOverwriteNewerExpiration() async {
        let service = MembershipMessageTestService()
        service.current = activeEntitlement(.weekly)
        let store = MembershipStore(service: service)
        await store.restore()
        XCTAssertTrue(store.isActive)

        let older = DeferredMembershipEntitlementRead(started: expectation(description: "Older active read started"))
        let newer = DeferredMembershipEntitlementRead(started: expectation(description: "Newer expiration read started"))
        service.deferredEntitlements = [older, newer]
        let olderTask = Task { await store.refresh() }
        await fulfillment(of: [older.started], timeout: 2)
        let newerTask = Task { await store.refresh() }
        await fulfillment(of: [newer.started], timeout: 2)

        newer.resolve(.success(MembershipEntitlement()))
        await newerTask.value
        XCTAssertFalse(store.isActive)
        XCTAssertNil(store.message)

        older.resolve(.success(service.current))
        await olderTask.value
        XCTAssertFalse(store.isActive, "A late active response must not undo expiration")
        XCTAssertNil(store.entitlement.expirationDate)
        XCTAssertNil(store.message)
    }

    @MainActor
    func testOlderReadFailureCannotOverwriteNewerSuccessfulRefresh() async {
        let service = MembershipMessageTestService()
        let store = MembershipStore(service: service)
        let older = DeferredMembershipEntitlementRead(started: expectation(description: "Older failing read started"))
        let newer = DeferredMembershipEntitlementRead(started: expectation(description: "Newer successful read started"))
        service.deferredEntitlements = [older, newer]
        let olderTask = Task { await store.refresh() }
        await fulfillment(of: [older.started], timeout: 2)
        let newerTask = Task { await store.refresh() }
        await fulfillment(of: [newer.started], timeout: 2)

        let active = activeEntitlement(.yearly)
        newer.resolve(.success(active))
        await newerTask.value
        older.resolve(.failure(MembershipMessageTestError.rejected))
        await olderTask.value

        XCTAssertEqual(store.entitlement, active)
        XCTAssertNil(store.message, "An obsolete request failure must not replace a current successful result")
    }

    @MainActor
    func testSupersededPurchaseReadDoesNotPublishSuccess() async {
        await assertSupersededConfirmation { store in
            await store.purchase(self.plan(.weekly))
        }
    }

    @MainActor
    func testSupersededRestoreReadDoesNotPublishSuccess() async {
        await assertSupersededConfirmation { store in
            await store.restore()
        }
    }

    @MainActor
    func testExpirationBoundaryRefreshesWithoutAStoreKitNotification() async {
        let service = MembershipMessageTestService()
        let clock = MembershipExpirationTestClock(now: Date())
        let timer = DeferredMembershipExpiration(started: expectation(description: "Expiry timer started"))
        clock.pending = [timer]
        service.current = MembershipEntitlement(isActive: true, category: .yearly,
                                               expirationDate: clock.now.addingTimeInterval(60))
        let store = MembershipStore(service: service, currentDate: { clock.now },
                                    waitForExpiration: { try await clock.wait(until: $0) })
        await store.restore()
        await fulfillment(of: [timer.started], timeout: 2)
        XCTAssertEqual(clock.deadlines, [service.current.expirationDate!])
        XCTAssertEqual(store.message, L10n.tr("已恢复会员权益"))

        let expired = expectation(description: "Expiry refresh updates the observable entitlement")
        withObservationTracking { _ = store.entitlement } onChange: { expired.fulfill() }
        clock.now = service.current.expirationDate!
        service.current = MembershipEntitlement()
        timer.fire()
        await fulfillment(of: [expired], timeout: 2)

        XCTAssertFalse(store.isActive)
        XCTAssertNil(store.message)
        XCTAssertNil(store.entitlement.expirationDate)
        XCTAssertEqual(service.entitlementReadCount, 2, "The boundary must perform one fresh entitlement read")
        XCTAssertEqual(clock.deadlines.count, 1, "An inactive result must not schedule another timer")
    }

    @MainActor
    func testChangedExpirationReplacesTimerAndRepeatedRestoreKeepsItsDeadline() async {
        let service = MembershipMessageTestService()
        let clock = MembershipExpirationTestClock(now: Date())
        let first = DeferredMembershipExpiration(started: expectation(description: "First expiry scheduled"),
                                                cancelled: expectation(description: "First expiry cancelled"))
        let second = DeferredMembershipExpiration(started: expectation(description: "Renewed expiry scheduled"))
        clock.pending = [first, second]
        service.current = MembershipEntitlement(isActive: true, category: .weekly,
                                               expirationDate: clock.now.addingTimeInterval(60))
        let store = MembershipStore(service: service, currentDate: { clock.now },
                                    waitForExpiration: { try await clock.wait(until: $0) })
        await store.restore()
        await fulfillment(of: [first.started], timeout: 2)
        await store.restore()
        XCTAssertEqual(clock.deadlines.count, 1, "Restoring unchanged rights must retain the existing timer")

        service.current.expirationDate = clock.now.addingTimeInterval(120)
        await store.refresh()
        await fulfillment(of: [first.cancelled!, second.started], timeout: 2)
        XCTAssertEqual(clock.deadlines.last, service.current.expirationDate)
        first.fire() // Even a waiter that ignores cancellation must not refresh old rights.

        let expired = expectation(description: "Renewed deadline expires membership")
        withObservationTracking { _ = store.entitlement } onChange: { expired.fulfill() }
        clock.now = service.current.expirationDate!
        service.current = MembershipEntitlement()
        second.fire()
        await fulfillment(of: [expired], timeout: 2)
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(service.entitlementReadCount, 4, "Only the current timer may read entitlement")
        XCTAssertEqual(clock.deadlines.count, 2)
    }

    @MainActor
    func testAccountResetCancelsScheduledExpiration() async {
        let service = MembershipMessageTestService()
        let clock = MembershipExpirationTestClock(now: Date())
        let timer = DeferredMembershipExpiration(started: expectation(description: "Account expiry scheduled"),
                                                cancelled: expectation(description: "Account expiry cancelled"),
                                                finished: expectation(description: "Cancelled waiter finished"))
        clock.pending = [timer]
        service.current = MembershipEntitlement(isActive: true, category: .weekly,
                                               expirationDate: clock.now.addingTimeInterval(60))
        let store = MembershipStore(service: service, currentDate: { clock.now },
                                    waitForExpiration: { try await clock.wait(until: $0) })
        await store.refresh()
        await fulfillment(of: [timer.started], timeout: 2)

        store.resetForAccountChange()
        await fulfillment(of: [timer.cancelled!], timeout: 2)
        timer.fire()
        await fulfillment(of: [timer.finished!], timeout: 2)

        XCTAssertFalse(store.isActive)
        XCTAssertNil(store.message)
        XCTAssertEqual(service.entitlementReadCount, 1, "An old account's timer must not read for the replacement account")
    }

    @MainActor
    private func assertSupersededConfirmation(_ operation: @escaping @MainActor (MembershipStore) async -> Void) async {
        let service = MembershipMessageTestService()
        let store = MembershipStore(service: service)
        let older = DeferredMembershipEntitlementRead(started: expectation(description: "Operation's active read started"))
        let newer = DeferredMembershipEntitlementRead(started: expectation(description: "Expiration read started"))
        service.deferredEntitlements = [older, newer]
        let operationTask = Task { await operation(store) }
        await fulfillment(of: [older.started], timeout: 2)
        XCTAssertTrue(store.isPurchasing)
        let expirationTask = Task { await store.refresh() }
        await fulfillment(of: [newer.started], timeout: 2)

        newer.resolve(.success(MembershipEntitlement()))
        await expirationTask.value
        older.resolve(.success(activeEntitlement(.weekly)))
        await operationTask.value

        XCTAssertFalse(store.isActive)
        XCTAssertNil(store.entitlement.expirationDate)
        XCTAssertNil(store.message, "A superseded purchase/restore must not publish its old success or waiting message")
        XCTAssertFalse(store.isPurchasing)
    }

    @MainActor
    private func activeEntitlement(_ category: MembershipCategory) -> MembershipEntitlement {
        MembershipEntitlement(isActive: true, category: category,
                              expirationDate: Date().addingTimeInterval(category == .weekly ? 604_800 : 31_536_000))
    }

    @MainActor
    private func plan(_ category: MembershipCategory) -> MembershipPlan {
        MembershipPlan(id: category.rawValue, title: category.rawValue, price: "¥20", period: "", category: category)
    }
}

@MainActor
private final class MembershipMessageTestService: SubscriptionService {
    var current = MembershipEntitlement()
    var purchaseError: Error?
    var transactionMessage: String?
    var deferredEntitlements: [DeferredMembershipEntitlementRead] = []
    private(set) var entitlementReadCount = 0
    private var onChange: (@MainActor () async -> Void)?

    func resetForAccountChange() {
        current = MembershipEntitlement()
        onChange = nil
    }
    func plans() async throws -> [MembershipPlan] { [] }
    func hasActiveSubscription() async throws -> Bool { current.isActive }
    func entitlement() async throws -> MembershipEntitlement {
        entitlementReadCount += 1
        guard !deferredEntitlements.isEmpty else { return current }
        return try await deferredEntitlements.removeFirst().read()
    }
    func purchase(planID: String) async throws -> PurchaseOutcome {
        if let purchaseError { throw purchaseError }
        return .purchased
    }
    func restore() async throws { }
    func observeTransactions(onChange: @escaping @MainActor () async -> Void) async {
        self.onChange = onChange
        await onChange()
    }
    func publish(_ entitlement: MembershipEntitlement) async {
        current = entitlement
        await onChange?()
    }
}

@MainActor
private final class MembershipExpirationTestClock {
    var now: Date
    var pending: [DeferredMembershipExpiration] = []
    private(set) var deadlines: [Date] = []

    init(now: Date) { self.now = now }

    func wait(until deadline: Date) async throws {
        deadlines.append(deadline)
        guard !pending.isEmpty else {
            XCTFail("Unexpected repeated expiration timer")
            throw CancellationError()
        }
        await pending.removeFirst().wait()
    }
}

@MainActor
private final class DeferredMembershipExpiration {
    let started: XCTestExpectation
    let cancelled: XCTestExpectation?
    let finished: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    init(started: XCTestExpectation, cancelled: XCTestExpectation? = nil, finished: XCTestExpectation? = nil) {
        self.started = started
        self.cancelled = cancelled
        self.finished = finished
    }

    func wait() async {
        let cancellation = cancelled
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
                if fired { fire() }
            }
        } onCancel: { cancellation?.fulfill() }
        finished?.fulfill()
    }

    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }
}

/// Controls completion order without sleeps or relying on task scheduling.
@MainActor
private final class DeferredMembershipEntitlementRead {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<MembershipEntitlement, Error>?
    private var result: Result<MembershipEntitlement, Error>?

    init(started: XCTestExpectation) { self.started = started }

    func read() async throws -> MembershipEntitlement {
        started.fulfill()
        return try await withCheckedThrowingContinuation { continuation in
            if let result { continuation.resume(with: result) }
            else { self.continuation = continuation }
        }
    }

    func resolve(_ result: Result<MembershipEntitlement, Error>) {
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

private enum MembershipMessageTestError: LocalizedError {
    case rejected
    var errorDescription: String? { "Purchase rejected for testing" }
}
