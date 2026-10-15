import StoreKit

@MainActor
final class StoreKitSubscriptionService: SubscriptionService {
    private let backend: StorePurchaseBackend
    private let loadProducts: @MainActor ([String]) async throws -> [Product]
    private var products: [Product] = []
    private var catalogGeneration = 0
    private var deliveries: [UInt64: Task<Void, Error>] = [:]
    private var transactionError: Error?
    var transactionMessage: String? { transactionError.map { L10n.errorMessage($0, fallback: "购买服务暂不可用，请稍后重试。") } }

    init(backend: StorePurchaseBackend,
         loadProducts: @escaping @MainActor ([String]) async throws -> [Product] = { try await Product.products(for: $0) }) {
        self.backend = backend
        self.loadProducts = loadProducts
    }

    func plans() async throws -> [MembershipPlan] {
        try await plans(onUpdate: { _ in })
    }

    func plans(onUpdate: @MainActor ([MembershipPlan]) -> Void) async throws -> [MembershipPlan] {
        catalogGeneration += 1
        let generation = catalogGeneration
        let configurations = try await backend.products()
        try Task.checkCancellation()
        guard generation == catalogGeneration else { throw CancellationError() }
        products = []
        let serverPlans = configurations.map(\.plan)
        onUpdate(serverPlans)
        guard !configurations.isEmpty else { return serverPlans }
        let loadedProducts = try await loadProducts(configurations.map(\.id))
        try Task.checkCancellation()
        guard generation == catalogGeneration else { throw CancellationError() }
        products = loadedProducts
        return configurations.map { item in
            guard let product = products.first(where: { $0.id == item.id }),
                  Self.matches(product, category: item.category) else { return item.plan }
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
                catch { transactionError = error }
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
                transactionError = error
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
        transactionError = nil
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
        switch period.unit {
        case .day: return period.value == 1 ? L10n.tr("每天") : L10n.tr("每%d天", period.value)
        case .week: return period.value == 1 ? L10n.tr("每1周") : L10n.tr("每%d周", period.value)
        case .month: return period.value == 1 ? L10n.tr("每月") : L10n.tr("每%d个月", period.value)
        case .year: return period.value == 1 ? L10n.tr("每1年") : L10n.tr("每%d年", period.value)
        @unknown default: return L10n.tr("每%d期", period.value)
        }
    }
}
