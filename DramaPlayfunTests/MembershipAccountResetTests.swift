import XCTest
import Moya
@testable import DramaPlayfun

@MainActor
final class MembershipAccountResetTests: XCTestCase {
    private let plan = MembershipPlan(id: "weekly", title: "Weekly", price: "$1", period: "Week")

    func testResetClearsAccountStateAndRejectsLateEntitlement() async {
        let service = ResetSubscriptionService()
        service.availablePlans = [plan]
        service.currentEntitlement = .init(isActive: true, category: .weekly)
        let store = MembershipStore(service: service)
        await store.loadPlans()
        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.plans.count, 1)

        let gate = MembershipResetSuspension()
        service.entitlementGate = gate
        let oldRefresh = _Concurrency.Task { await store.refresh() }
        await gate.waitUntilStarted()
        store.resetForAccountChange()

        XCTAssertEqual(service.resetCount, 1)
        XCTAssertFalse(store.isActive)
        XCTAssertTrue(store.plans.isEmpty)
        XCTAssertNil(store.message)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.isPurchasing)

        gate.resume()
        await oldRefresh.value
        XCTAssertFalse(store.isActive, "The previous account's delayed entitlement must be ignored.")
        XCTAssertNil(store.message)
    }

    func testOldPurchaseCompletionCannotClearNewPurchaseOrPublishSuccess() async {
        let service = ResetSubscriptionService()
        let oldGate = MembershipResetSuspension()
        let newGate = MembershipResetSuspension()
        service.purchaseGates = [oldGate, newGate]
        service.purchaseOutcomes = [.purchased, .cancelled]
        let store = MembershipStore(service: service)
        let oldPurchase = _Concurrency.Task { await store.purchase(plan) }
        await oldGate.waitUntilStarted()
        XCTAssertTrue(store.isPurchasing)

        store.resetForAccountChange()
        let newPurchase = _Concurrency.Task { await store.purchase(plan) }
        await newGate.waitUntilStarted()
        oldGate.resume()
        await oldPurchase.value

        XCTAssertTrue(store.isPurchasing, "An old defer must not clear the replacement account's busy state.")
        XCTAssertNil(store.message)
        XCTAssertEqual(service.entitlementRequests, 0)
        XCTAssertTrue(service.cancelledPurchaseIndices.contains(0))

        newGate.resume()
        await newPurchase.value
        XCTAssertFalse(store.isPurchasing)
    }

    func testResetRejectsLateProvisionalAndFinalProductLists() async {
        let service = ResetSubscriptionService()
        service.availablePlans = [plan]
        let gate = MembershipResetSuspension()
        service.planGate = gate
        let store = MembershipStore(service: service)
        let loading = _Concurrency.Task { await store.loadPlans() }
        await gate.waitUntilStarted()
        store.resetForAccountChange()
        gate.resume()
        await loading.value

        XCTAssertTrue(store.plans.isEmpty)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.message)
        XCTAssertEqual(service.entitlementRequests, 0)
    }

    func testResetRejectsRestoreErrorAndNewAccountCanObserveTransactions() async {
        let service = ResetSubscriptionService()
        let restoreGate = MembershipResetSuspension()
        service.restoreGate = restoreGate
        let store = MembershipStore(service: service)
        let oldRestore = _Concurrency.Task { await store.restore() }
        await restoreGate.waitUntilStarted()

        let oldObservationGate = MembershipResetSuspension()
        let newObservationGate = MembershipResetSuspension()
        service.observationGates = [oldObservationGate, newObservationGate]
        let oldObserver = _Concurrency.Task { await store.observeTransactions() }
        await oldObservationGate.waitUntilStarted()
        store.resetForAccountChange()
        let newObserver = _Concurrency.Task { await store.observeTransactions() }
        await newObservationGate.waitUntilStarted()

        restoreGate.resume()
        oldObservationGate.resume()
        await oldRestore.value
        await oldObserver.value
        XCTAssertNil(store.message)
        XCTAssertEqual(service.entitlementRequests, 0, "The old observer must not refresh the new account.")
        XCTAssertTrue(service.cancelledObservationIndices.contains(0))

        service.currentEntitlement = .init(isActive: true, category: .yearly)
        newObservationGate.resume()
        await newObserver.value
        XCTAssertEqual(service.entitlementRequests, 1)
        XCTAssertEqual(store.entitlement.category, .yearly)
    }

    func testLanguageChangeKeepsEntitlementAndTransactionObservation() async {
        let service = ResetSubscriptionService()
        service.availablePlans = [plan]
        service.currentEntitlement = .init(isActive: true, category: .weekly)
        let store = MembershipStore(service: service)
        await store.loadPlans()
        let gate = MembershipResetSuspension()
        service.observationGates = [gate]
        let observer = _Concurrency.Task { await store.observeTransactions() }
        await gate.waitUntilStarted()

        store.invalidateLocalizedContent()
        XCTAssertTrue(store.isActive)
        XCTAssertTrue(store.plans.isEmpty)
        XCTAssertEqual(service.resetCount, 0)
        service.currentEntitlement = .init(isActive: true, category: .yearly)
        gate.resume()
        await observer.value
        XCTAssertEqual(store.entitlement.category, .yearly)
        XCTAssertTrue(service.cancelledObservationIndices.isEmpty)
    }

    func testBackendInvalidatesAssetCallbackAlreadySuspendedDuringReset() async throws {
        let provider = MoyaProvider<APITarget>(endpointClosure: { target in
            Endpoint(url: target.baseURL.appendingPathComponent(target.path).absoluteString,
                     sampleResponseClosure: {
                         .networkResponse(200, Data(#"{"code":200,"data":{"walletBalance":500}}"#.utf8))
                     }, method: target.method, task: target.task, httpHeaderFields: target.headers)
        }, stubClosure: MoyaProvider.immediatelyStub)
        let network = APIClient(configuration: try APIConfiguration(baseURL: URL(string: "https://example.invalid")!),
                                provider: provider)
        let gate = MembershipResetSuspension()
        var creditedBalances: [Int64] = []
        let backend = StorePurchaseBackend(network: network) { balance, isCurrentAccount in
            await gate.wait()
            guard isCurrentAccount(), let balance else { return }
            creditedBalances.append(balance)
        }
        let oldRestore = _Concurrency.Task {
            try await backend.restore(transactionID: "old-transaction", originalID: "old-original")
        }
        await gate.waitUntilStarted()
        backend.resetForAccountChange()
        gate.resume()
        do {
            try await oldRestore.value
            XCTFail("Account changes must invalidate the old restore.")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        XCTAssertTrue(creditedBalances.isEmpty)
    }
}

/// Intentionally ignores cancellation, exercising guards against late external callbacks.
@MainActor
private final class MembershipResetSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class ResetSubscriptionService: SubscriptionService {
    var resetCount = 0
    var availablePlans: [MembershipPlan] = []
    var currentEntitlement = MembershipEntitlement()
    var entitlementRequests = 0
    var entitlementGate: MembershipResetSuspension?
    var planGate: MembershipResetSuspension?
    var restoreGate: MembershipResetSuspension?
    var purchaseGates: [MembershipResetSuspension] = []
    var purchaseOutcomes: [PurchaseOutcome] = []
    var observationGates: [MembershipResetSuspension] = []
    private var purchaseCount = 0
    private var observationCount = 0
    var cancelledPurchaseIndices: Set<Int> = []
    var cancelledObservationIndices: Set<Int> = []

    func resetForAccountChange() { resetCount += 1 }

    func plans() async throws -> [MembershipPlan] { try await plans(onUpdate: { _ in }) }

    func plans(onUpdate: @MainActor ([MembershipPlan]) -> Void) async throws -> [MembershipPlan] {
        let plans = availablePlans
        if let planGate { await planGate.wait() }
        onUpdate(plans)
        return plans
    }

    func entitlement() async throws -> MembershipEntitlement {
        entitlementRequests += 1
        let result = currentEntitlement
        if let entitlementGate { await entitlementGate.wait() }
        return result
    }

    func hasActiveSubscription() async throws -> Bool { try await entitlement().isActive }

    func purchase(planID: String) async throws -> PurchaseOutcome {
        let index = purchaseCount
        purchaseCount += 1
        await purchaseGates[index].wait()
        if _Concurrency.Task<Never, Never>.isCancelled { cancelledPurchaseIndices.insert(index) }
        return purchaseOutcomes[index]
    }

    func restore() async throws {
        if let restoreGate { await restoreGate.wait() }
        throw StorePurchaseError.awaitingGrant
    }

    func observeTransactions(onChange: @escaping @MainActor () async -> Void) async {
        let index = observationCount
        observationCount += 1
        await observationGates[index].wait()
        if _Concurrency.Task<Never, Never>.isCancelled { cancelledObservationIndices.insert(index) }
        await onChange()
    }
}
