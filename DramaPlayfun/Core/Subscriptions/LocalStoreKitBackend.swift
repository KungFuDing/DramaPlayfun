#if DEBUG
import Foundation
import StoreKit

/// A separate local test ledger; no production wallet or login data is modified.
nonisolated final class LocalStoreKitAccount: @unchecked Sendable {
    struct Snapshot {
        let balance: Int64
        let vipExpirationDate: Date?
    }

    private struct Ledger: Codable {
        struct Delivery: Codable, Equatable {
            let productID: String
            let originalID: String
        }
        var balance: Int64 = 0
        var deliveredTransactions: [String: Delivery] = [:]
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-LocalStoreKitTesting")
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let ledgerKey = "localStoreKitLedger"
    private var ledger: Ledger
    private var vipExpirationDate: Date?

    init(defaults: UserDefaults = UserDefaults(suiteName: "DramaPlayfun.LocalStoreKitTesting")!,
         arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        if arguments.contains("-ResetLocalStoreKitState") {
            defaults.removeObject(forKey: ledgerKey)
        }
        ledger = defaults.data(forKey: ledgerKey)
            .flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) } ?? Ledger()
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(balance: ledger.balance,
                        vipExpirationDate: vipExpirationDate.flatMap { $0 > Date() ? $0 : nil })
    }

    func setVIPExpirationDate(_ date: Date?) {
        lock.lock()
        defer { lock.unlock() }
        vipExpirationDate = date
    }

    func hasDelivered(transactionID: String, productID: String, originalID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ledger.deliveredTransactions[transactionID]
            == Ledger.Delivery(productID: productID, originalID: originalID)
    }

    func grantCoins(_ amount: Int64, transactionID: String, productID: String, originalID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let delivery = Ledger.Delivery(productID: productID, originalID: originalID)
        if let previous = ledger.deliveredTransactions[transactionID] {
            guard previous == delivery else { throw LocalLedgerError.invalidTransaction }
            return
        }
        let sum = ledger.balance.addingReportingOverflow(amount)
        guard amount > 0, !sum.overflow else { throw LocalLedgerError.invalidAmount }
        var updated = ledger
        updated.balance = sum.partialValue
        updated.deliveredTransactions[transactionID] = delivery
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: ledgerKey)
        ledger = updated
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        ledger = Ledger()
        vipExpirationDate = nil
        defaults.removeObject(forKey: ledgerKey)
    }

    private enum LocalLedgerError: Error { case invalidAmount, invalidTransaction }
}

/// Uses real StoreKit verification and transactions, with only fulfillment kept local.
@MainActor
final class LocalStoreKitBackend: StorePurchaseServing {
    private let account: LocalStoreKitAccount
    private var accountGeneration = 0
    private var lastPublishedEntitlement: MembershipEntitlement?
    private var entitlementQueueTail: Task<MembershipEntitlement, Error>?
    private var entitlementQueueTailID: UUID?
    private var entitlementOperations: [UUID: Task<MembershipEntitlement, Error>] = [:]
    var didUpdateAssets: @MainActor (Int64?, @MainActor () -> Bool) async -> Void

    init(account: LocalStoreKitAccount,
         didUpdateAssets: @escaping @MainActor (Int64?, @MainActor () -> Bool) async -> Void = { _, _ in }) {
        self.account = account
        self.didUpdateAssets = didUpdateAssets
    }

    func resetForAccountChange() {
        accountGeneration += 1
        entitlementOperations.values.forEach { $0.cancel() }
        entitlementOperations.removeAll()
        entitlementQueueTail = nil
        entitlementQueueTailID = nil
        lastPublishedEntitlement = nil
        account.reset()
    }

    private func checkAccount(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == accountGeneration else { throw CancellationError() }
    }

    func products() async throws -> [StoreProductConfiguration] {
        try Task.checkCancellation()
        let memberships: [StoreProductConfiguration] = [
            .init(id: "fixture.week", category: .weekly, title: L10n.tr("周会员"),
                  priceAmount: 20, priceCurrency: "CNY"),
            .init(id: "fixture.year", category: .yearly, title: L10n.tr("年会员"),
                  priceAmount: 200, priceCurrency: "CNY")
        ]
        let amounts: [Int64] = [500, 1000, 1500, 2000, 5000, 10000]
        let prices = [4.99, 8.99, 12.99, 16.99, 39.99, 79.99]
        return memberships + amounts.enumerated().map { index, amount in
            StoreProductConfiguration(id: "fixture.coins.\(index)", category: .coins,
                coinAmount: amount, giftCoinAmount: index == 0 ? 0 : 100,
                title: L10n.tr("金币"), priceAmount: prices[index], priceCurrency: "CNY")
        }
    }

    func configuration(for id: String) async throws -> StoreProductConfiguration {
        guard let configuration = try await products().first(where: { $0.id == id }) else {
            throw StorePurchaseError.productUnavailable
        }
        return configuration
    }

    func prepare(_ item: StoreProductConfiguration) async throws {
        _ = try await configuration(for: item.id)
    }

    func report(productID: String, transactionID: String, originalID: String, accountToken: UUID?) async throws {
        let generation = accountGeneration
        try checkAccount(generation)
        let item = try await configuration(for: productID)
        // Finished consumables disappear from Transaction.all. The persisted record
        // is created only after verification and also binds the product/original ID.
        if !account.hasDelivered(transactionID: transactionID, productID: productID, originalID: originalID) {
            let transaction = try await verifiedTransaction(id: transactionID, originalID: originalID,
                                                            generation: generation)
            try checkAccount(generation)
            guard transaction.productID == item.id,
                  transaction.revocationDate == nil, !transaction.isUpgraded,
                  transaction.productType == (item.category == .coins ? .consumable : .autoRenewable) else {
                throw StorePurchaseError.unverified
            }
            if item.category == .coins {
                try account.grantCoins(item.coinAmount, transactionID: transactionID,
                                       productID: productID, originalID: originalID)
            }
        }
        try checkAccount(generation)
        _ = try await enqueueEntitlement(forcePublish: true)
        try checkAccount(generation)
    }

    func restore(transactionID: String, originalID: String) async throws {
        let generation = accountGeneration
        try checkAccount(generation)
        let transaction = try await verifiedTransaction(id: transactionID, originalID: originalID,
                                                        generation: generation)
        guard transaction.productType == .autoRenewable else { throw StorePurchaseError.unverified }
        _ = try await configuration(for: transaction.productID)
        try checkAccount(generation)
        _ = try await enqueueEntitlement(forcePublish: true)
        try checkAccount(generation)
    }

    func entitlement() async throws -> MembershipEntitlement {
        try await enqueueEntitlement(forcePublish: false)
    }

    private func enqueueEntitlement(forcePublish: Bool) async throws -> MembershipEntitlement {
        let generation = accountGeneration
        try checkAccount(generation)
        let previous = entitlementQueueTail
        let id = UUID()
        // Status and transaction notifications can arrive together. Serialize the
        // complete read-and-publish operation, including the asynchronous Profile
        // reload, so an older publication cannot finish after a newer one.
        let operation = Task { @MainActor in
            if let previous { _ = await previous.result }
            try self.checkAccount(generation)
            return try await self.readAndPublishEntitlement(generation: generation, forcePublish: forcePublish)
        }
        entitlementOperations[id] = operation
        entitlementQueueTail = operation
        entitlementQueueTailID = id
        defer {
            entitlementOperations[id] = nil
            if entitlementQueueTailID == id {
                entitlementQueueTail = nil
                entitlementQueueTailID = nil
            }
        }
        let refreshed = try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
        try checkAccount(generation)
        return refreshed
    }

    private func readAndPublishEntitlement(generation: Int, forcePublish: Bool) async throws -> MembershipEntitlement {
        try checkAccount(generation)
        var entitlement = MembershipEntitlement()
        // An expiration changes the subscription's renewal state without creating
        // a new purchase. The renewal state determines whether the subscription
        // still grants access, including access during a billing grace period.
        for await group in Product.SubscriptionInfo.Status.all {
            try checkAccount(generation)
            for status in group.statuses {
                guard status.state == .subscribed || status.state == .inGracePeriod,
                      case .verified(let transaction) = status.transaction,
                      case .verified(let renewalInfo) = status.renewalInfo,
                      transaction.environment == .xcode, renewalInfo.environment == .xcode,
                      transaction.productType == .autoRenewable,
                      transaction.revocationDate == nil, !transaction.isUpgraded,
                      let category = Self.membershipCategory(for: transaction.productID) else { continue }
                let validUntil = status.state == .inGracePeriod
                    ? renewalInfo.gracePeriodExpirationDate : transaction.expirationDate
                guard let expirationDate = validUntil, expirationDate > Date() else { continue }
                if expirationDate > (entitlement.expirationDate ?? .distantPast) {
                    entitlement = MembershipEntitlement(isActive: true, category: category,
                                                         expirationDate: expirationDate)
                }
            }
        }
        try checkAccount(generation)
        account.setVIPExpirationDate(entitlement.expirationDate)
        if forcePublish || lastPublishedEntitlement != entitlement {
            // Refunds and expiration also need to update ProfileStore, whose VIP
            // state otherwise outlives the membership screen's entitlement.
            lastPublishedEntitlement = entitlement
            await updateAssets(generation: generation)
            do {
                try checkAccount(generation)
            } catch {
                // A cancelled profile/wallet refresh must be retried on the next
                // entitlement read, without touching a replacement account.
                if generation == accountGeneration, lastPublishedEntitlement == entitlement {
                    lastPublishedEntitlement = nil
                }
                throw error
            }
        }
        return entitlement
    }

    private func verifiedTransaction(id: String, originalID: String, generation: Int) async throws -> Transaction {
        for await result in Transaction.all {
            try checkAccount(generation)
            guard case .verified(let transaction) = result,
                  String(transaction.id) == id else { continue }
            guard transaction.environment == .xcode,
                  String(transaction.originalID) == originalID else { throw StorePurchaseError.unverified }
            return transaction
        }
        throw StorePurchaseError.unverified
    }

    private static func membershipCategory(for productID: String) -> MembershipCategory? {
        switch productID {
        case "fixture.week": .weekly
        case "fixture.year": .yearly
        default: nil
        }
    }

    private func updateAssets(generation: Int) async {
        await didUpdateAssets(account.snapshot.balance, { [weak self] in
            guard let self else { return false }
            return self.accountGeneration == generation && !Task.isCancelled
        })
    }
}
#endif
