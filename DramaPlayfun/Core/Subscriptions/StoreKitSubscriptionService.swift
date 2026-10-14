import StoreKit

@MainActor
final class StoreKitSubscriptionService: SubscriptionService {
    private let backend: StorePurchaseBackend
    private var products: [Product] = []
    private var deliveries: [UInt64: Task<Void, Error>] = [:]
    private(set) var transactionMessage: String?

    init(backend: StorePurchaseBackend) { self.backend = backend }

    func plans() async throws -> [MembershipPlan] {
        let configurations = try await backend.products()
        products = try await Product.products(for: configurations.map(\.id))
        return configurations.compactMap { item in
            guard let product = products.first(where: { $0.id == item.id }),
                  Self.matches(product, category: item.category) else { return nil }
            return MembershipPlan(id: item.id, title: product.displayName, price: product.displayPrice,
                period: Self.periodDescription(product.subscription?.subscriptionPeriod),
                category: item.category, coinAmount: item.coinAmount, giftCoinAmount: item.giftCoinAmount)
        }
    }

    func entitlement() async throws -> MembershipEntitlement { try await backend.entitlement() }
    func hasActiveSubscription() async throws -> Bool { try await entitlement().isActive }

    func purchase(planID: String) async throws -> PurchaseOutcome {
        guard let product = products.first(where: { $0.id == planID }) else {
            throw StorePurchaseError.productUnavailable
        }
        let configuration = try await backend.configuration(for: planID)
        guard Self.matches(product, category: configuration.category) else {
            throw StorePurchaseError.productUnavailable
        }
        try await backend.prepare(configuration)
        switch try await product.purchase() {
        case .success(let result):
            guard case .verified(let transaction) = result else { throw StorePurchaseError.unverified }
            try await deliver(transaction)
            return .purchased
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw StorePurchaseError.unknown
        }
    }

    func restore() async throws {
        try await AppStore.sync()
        var firstError: Error?
        // Includes unfinished consumables; currentEntitlements intentionally excludes them.
        // One failing order must not prevent unrelated orders from being recovered.
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result else { continue }
            do { try await deliver(transaction) }
            catch { if firstError == nil { firstError = error } }
        }
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productType == .autoRenewable,
                  transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
            do {
                _ = try await backend.configuration(for: transaction.productID)
                try await backend.restore(transactionID: String(transaction.id), originalID: String(transaction.originalID))
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    func observeTransactions(onChange: @escaping @MainActor () async -> Void) async {
        let updates = Transaction.updates
        for await result in Transaction.unfinished {
            guard !Task.isCancelled else { return }
            if case .verified(let transaction) = result {
                do { try await deliver(transaction) }
                catch { transactionMessage = error.localizedDescription }
            }
        }
        await onChange()
        for await result in updates {
            guard !Task.isCancelled else { return }
            guard case .verified(let transaction) = result else { continue }
            do {
                try await deliver(transaction)
                await onChange()
            } catch {
                transactionMessage = error.localizedDescription
                await onChange()
            }
        }
    }

    private func deliver(_ transaction: Transaction) async throws {
        guard transaction.revocationDate == nil, !transaction.isUpgraded else {
            await transaction.finish()
            return
        }
        if let pending = deliveries[transaction.id] { return try await pending.value }
        let delivery = Task { @MainActor in
            try await backend.report(productID: transaction.productID, transactionID: String(transaction.id),
                                     originalID: String(transaction.originalID), accountToken: transaction.appAccountToken)
            await transaction.finish()
        }
        deliveries[transaction.id] = delivery
        defer { deliveries[transaction.id] = nil }
        try await delivery.value
        transactionMessage = nil
    }

    private static func matches(_ product: Product, category: MembershipCategory) -> Bool {
        if category == .coins { return product.type == .consumable }
        guard product.type == .autoRenewable, let period = product.subscription?.subscriptionPeriod else { return false }
        switch category {
        case .weekly: return (period.unit == .week && period.value == 1) || (period.unit == .day && period.value == 7)
        case .yearly: return period.unit == .year && period.value == 1
        case .coins: return false
        }
    }

    private static func periodDescription(_ period: Product.SubscriptionPeriod?) -> String {
        guard let period else { return "" }
        let unit: String
        switch period.unit {
        case .day: unit = "天"
        case .week: unit = "周"
        case .month: unit = "个月"
        case .year: unit = "年"
        @unknown default: unit = "期"
        }
        return "每\(period.value)\(unit)"
    }
}
