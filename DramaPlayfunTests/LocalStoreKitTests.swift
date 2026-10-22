import XCTest
import StoreKit
import StoreKitTest
@testable import DramaPlayfun

/// Exercises StoreKit itself. Only the app's fulfillment backend is local.
final class LocalStoreKitTests: XCTestCase {
    @MainActor
    func testCatalogAndConsumableFulfillmentArePersistentAndIdempotent() async throws {
        try await withSession { session, defaults, account, backend, service in
            let plans = try await service.plans()
            XCTAssertEqual(Set(plans.map(\.id)), Set([
                "fixture.week", "fixture.year", "fixture.coins.0", "fixture.coins.1",
                "fixture.coins.2", "fixture.coins.3", "fixture.coins.4", "fixture.coins.5"
            ]))
            XCTAssertTrue(plans.allSatisfy(\.isAvailableForPurchase))
            XCTAssertEqual(plans.filter { $0.category == .coins }.count, 6)

            guard case .purchased = try await service.purchase(planID: "fixture.coins.0") else {
                return XCTFail("Expected a verified local StoreKit purchase")
            }
            XCTAssertEqual(account.snapshot.balance, 500)
            let first = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == "fixture.coins.0" })
            // StoreKitTest uses 0 when this is the original purchase; StoreKit 2
            // exposes the purchase's own ID as Transaction.originalID instead.
            let firstOriginalID = first.originalTransactionIdentifier == 0 ? first.identifier : first.originalTransactionIdentifier
            try await backend.report(productID: first.productIdentifier,
                transactionID: String(first.identifier), originalID: String(firstOriginalID), accountToken: nil)
            XCTAssertEqual(account.snapshot.balance, 500, "Redelivery must not grant coins twice")

            guard case .purchased = try await service.purchase(planID: "fixture.coins.0") else {
                return XCTFail("A consumable must be purchasable again")
            }
            XCTAssertEqual(account.snapshot.balance, 1000)
            let reloaded = LocalStoreKitAccount(defaults: defaults, arguments: [])
            XCTAssertEqual(reloaded.snapshot.balance, 1000)
            let reloadedBackend = LocalStoreKitBackend(account: reloaded)
            try await reloadedBackend.report(productID: first.productIdentifier,
                transactionID: String(first.identifier), originalID: String(firstOriginalID), accountToken: nil)
            XCTAssertEqual(reloaded.snapshot.balance, 1000, "Deduplication must survive restarting the account")
            try await service.restore()
            XCTAssertEqual(account.snapshot.balance, 1000, "Restore must not replay finished consumables")
        }
    }

    @MainActor
    func testWeeklySubscriptionRestoresAndExpires() async throws {
        try await withSession { session, _, account, _, service in
            session.timeRate = .oneRenewalEveryTwoSeconds
            _ = try await service.plans()
            guard case .purchased = try await service.purchase(planID: "fixture.week") else {
                return XCTFail("Expected a weekly subscription")
            }
            let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == "fixture.week" })
            try session.disableAutoRenewForTransaction(identifier: transaction.identifier)
            let purchased = try await service.entitlement()
            XCTAssertTrue(purchased.isActive)
            XCTAssertEqual(purchased.category, .weekly)
            XCTAssertNotNil(account.snapshot.vipExpirationDate)
            let restored = StoreKitSubscriptionService(backend: LocalStoreKitBackend(account: account))
            try await restored.restore()
            let restoredEntitlement = try await restored.entitlement()
            XCTAssertTrue(restoredEntitlement.isActive)
            XCTAssertEqual(restoredEntitlement.category, .weekly)

            try await waitUntil("The accelerated weekly subscription should reach its actual expiration date") {
                guard let expirationDate = session.allTransactions().first(where: { $0.identifier == transaction.identifier })?.expirationDate else {
                    return false
                }
                return expirationDate <= Date()
            }
            try await waitUntil("Expired subscription should remove VIP") {
                try await !service.entitlement().isActive
            }
            XCTAssertNil(account.snapshot.vipExpirationDate)
            XCTAssertEqual(account.snapshot.balance, 0)
        }
    }

    @MainActor
    func testExpirationWaitsForAnEarlierAssetPublication() async throws {
        try await withSession { session, _, account, _, service in
            session.timeRate = .oneRenewalEveryTwoSeconds
            _ = try await service.plans()
            guard case .purchased = try await service.purchase(planID: "fixture.week") else {
                return XCTFail("Expected a weekly subscription")
            }
            let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == "fixture.week" })
            try session.disableAutoRenewForTransaction(identifier: transaction.identifier)

            let firstPublication = expectation(description: "The active entitlement publication has started")
            let overlappingPublication = expectation(description: "Publications must not overlap")
            overlappingPublication.isInverted = true
            var releaseFirst: CheckedContinuation<Void, Never>?
            var firstIsPublishing = false
            var publicationCount = 0
            var completedDates: [Date?] = []
            let backend = LocalStoreKitBackend(account: account) { _, _ in
                let date = account.snapshot.vipExpirationDate
                publicationCount += 1
                if publicationCount == 1 {
                    firstIsPublishing = true
                    await withCheckedContinuation { continuation in
                        releaseFirst = continuation
                        firstPublication.fulfill()
                    }
                    firstIsPublishing = false
                } else if firstIsPublishing {
                    overlappingPublication.fulfill()
                }
                completedDates.append(date)
            }
            let activeRefresh = Task { try await backend.entitlement() }
            defer {
                releaseFirst?.resume()
                activeRefresh.cancel()
            }
            await fulfillment(of: [firstPublication], timeout: 5)
            try await waitUntil("The accelerated subscription should expire before the concurrent read") {
                guard let date = session.allTransactions().first(where: { $0.identifier == transaction.identifier })?.expirationDate else {
                    return false
                }
                return date <= Date()
            }
            try await waitUntil("The subscription status should expose the actual expiration") {
                for await group in Product.SubscriptionInfo.Status.all {
                    for status in group.statuses {
                        if case .verified(let value) = status.transaction,
                           value.productID == "fixture.week", status.state == .expired {
                            return true
                        }
                    }
                }
                return false
            }
            let expiredRefresh = Task { try await backend.entitlement() }
            defer { expiredRefresh.cancel() }
            // Hold the first Profile-like callback while the second refresh is
            // enqueued. It must not publish until the earlier callback completes.
            await fulfillment(of: [overlappingPublication], timeout: 0.5)
            releaseFirst?.resume()
            releaseFirst = nil
            _ = try await activeRefresh.value
            let expired = try await expiredRefresh.value
            XCTAssertFalse(expired.isActive)
            XCTAssertNil(account.snapshot.vipExpirationDate)
            XCTAssertEqual(completedDates.count, 2)
            XCTAssertNotNil(completedDates.first ?? nil)
            XCTAssertNil(completedDates.last ?? nil, "The final Profile publication must observe the expired account")
        }
    }

    @MainActor
    func testYearlyMembershipExpiresAfterRepeatedRestoreWithoutManualRefresh() async throws {
        try await withSession { session, _, account, backend, service in
            session.timeRate = .oneRenewalEveryTwoSeconds
            var publishedActiveEntitlement = false
            var publishedExpiration = false
            backend.didUpdateAssets = { _, _ in
                if account.snapshot.vipExpirationDate != nil {
                    publishedActiveEntitlement = true
                } else if publishedActiveEntitlement {
                    publishedExpiration = true
                }
            }
            let store = MembershipStore(service: service)
            let observer = Task { await store.observeTransactions() }
            defer { observer.cancel() }
            await store.loadPlans()
            let yearly = try XCTUnwrap(store.plans.first { $0.id == "fixture.year" })
            await store.purchase(yearly)
            let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == "fixture.year" })
            try session.disableAutoRenewForTransaction(identifier: transaction.identifier)
            XCTAssertTrue(store.isActive)
            XCTAssertEqual(store.entitlement.category, .yearly)
            XCTAssertGreaterThan(try XCTUnwrap(store.entitlement.expirationDate), Date())
            await store.restore()
            await store.restore()
            XCTAssertTrue(store.isActive, "Restore must complete while the original entitlement is still active")
            XCTAssertEqual(store.message, L10n.tr("已恢复会员权益"))

            // Observe state only: no refresh, restore or navigation may help the
            // app at the boundary. The store must refresh and publish by itself.
            try await waitUntil("The membership store should remove naturally expired rights") {
                !store.isActive && publishedExpiration
            }
            XCTAssertFalse(store.entitlement.isActive)
            XCTAssertNil(store.entitlement.expirationDate)
            XCTAssertNil(store.message)
            XCTAssertTrue(publishedActiveEntitlement)
            XCTAssertTrue(publishedExpiration, "The Profile/wallet callback must receive the expired state")
            XCTAssertNil(account.snapshot.vipExpirationDate)
        }
    }

    @MainActor
    func testYearlySubscriptionRefundRemovesEntitlement() async throws {
        try await withSession { session, _, account, _, service in
            _ = try await service.plans()
            guard case .purchased = try await service.purchase(planID: "fixture.year") else {
                return XCTFail("Expected a yearly subscription")
            }
            let purchased = try await service.entitlement()
            XCTAssertTrue(purchased.isActive)
            XCTAssertEqual(purchased.category, .yearly)
            let transaction = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == "fixture.year" })
            try session.refundTransaction(identifier: transaction.identifier)
            try await waitUntil("Refund should revoke VIP") {
                try await !service.entitlement().isActive
            }
            XCTAssertNil(account.snapshot.vipExpirationDate)
        }
    }

    @MainActor
    func testAskToBuyGrantsCoinsOnlyAfterApproval() async throws {
        try await withSession { session, _, account, _, service in
            _ = try await service.plans()
            session.askToBuyEnabled = true
            guard case .pending = try await service.purchase(planID: "fixture.coins.1") else {
                return XCTFail("Ask to Buy should return pending")
            }
            XCTAssertEqual(account.snapshot.balance, 0)
            let pending = try XCTUnwrap(session.allTransactions().first { $0.pendingAskToBuyConfirmation })
            try session.approveAskToBuyTransaction(identifier: pending.identifier)
            try await waitUntil("Approved purchase should be recovered and fulfilled") {
                try await service.restore()
                return account.snapshot.balance == 1000
            }
            try await service.restore()
            XCTAssertEqual(account.snapshot.balance, 1000)
        }
    }

    @MainActor
    func testRejectedPurchaseDoesNotGrantAssets() async throws {
        try await withSession { session, _, account, _, service in
            _ = try await service.plans()
            // iOS 27 may map an injected rejection to StoreKitError.unknown.
            // Assert StoreKit rejects the purchase without creating a transaction
            // or granting assets; cancellation is also checked in the payment UI.
            try await session.setSimulatedError(.purchase(.purchaseNotAllowed), forAPI: .purchase)
            do {
                _ = try await service.purchase(planID: "fixture.coins.0")
                XCTFail("Rejected StoreKit purchase should throw")
            } catch {
                XCTAssertTrue(error is StoreKitError || error is Product.PurchaseError,
                              "Expected StoreKit rejection, got \(error)")
            }
            XCTAssertTrue(session.allTransactions().isEmpty)
            XCTAssertEqual(account.snapshot.balance, 0)
            let entitlement = try await service.entitlement()
            XCTAssertFalse(entitlement.isActive)
        }
    }

    @MainActor
    private func withSession(_ body: @MainActor (SKTestSession, UserDefaults, LocalStoreKitAccount,
                                                 LocalStoreKitBackend, StoreKitSubscriptionService) async throws -> Void) async throws {
        let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "LocalPurchases", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.timeRate = .realTime
        let suiteName = "LocalStoreKitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let account = LocalStoreKitAccount(defaults: defaults, arguments: [])
        let backend = LocalStoreKitBackend(account: account)
        let service = StoreKitSubscriptionService(backend: backend)
        defer {
            session.clearTransactions()
            session.resetToDefaultState()
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await body(session, defaults, account, backend, service)
    }

    @MainActor
    private func waitUntil(_ description: String, condition: @MainActor () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail(description)
    }
}
