import StoreKit

@MainActor
final class StoreKitSubscriptionService: SubscriptionService {
    private let backend: any StorePurchaseServing
    private let loadProducts: @MainActor ([String]) async throws -> [Product]
    private var products: [Product] = []
    private var catalogGeneration = 0
    private var accountGeneration = 0
    private var deliveries: [UInt64: Task<Void, Error>] = [:]
    private var transactionError: Error?
    var transactionMessage: String? { transactionError.map { L10n.errorMessage($0, fallback: "购买服务暂不可用，请稍后重试。") } }

    init(backend: any StorePurchaseServing,
         loadProducts: @escaping @MainActor ([String]) async throws -> [Product] = { try await Product.products(for: $0) }) {
        self.backend = backend
        self.loadProducts = loadProducts
    }

    func resetForAccountChange() {
        accountGeneration += 1
        catalogGeneration += 1
        products = []
        deliveries.values.forEach { $0.cancel() }
        deliveries.removeAll()
        transactionError = nil
        backend.resetForAccountChange()
    }

    private func checkAccount(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == accountGeneration else { throw CancellationError() }
    }

    func plans() async throws -> [MembershipPlan] {
        try await plans(onUpdate: { _ in })
    }

    func plans(onUpdate: @MainActor ([MembershipPlan]) -> Void) async throws -> [MembershipPlan] {
        let account = accountGeneration
        try checkAccount(account)
        catalogGeneration += 1
        let generation = catalogGeneration
        let configurations = try await backend.products()
        try checkAccount(account)
        guard generation == catalogGeneration else { throw CancellationError() }
        products = []
        let serverPlans = configurations.map(\.plan)
        onUpdate(serverPlans)
        guard !configurations.isEmpty else { return serverPlans }
        let loadedProducts = try await loadProducts(configurations.map(\.id))
        try checkAccount(account)
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
        let account = accountGeneration
        try checkAccount(account)
        guard let product = products.first(where: { $0.id == planID }) else {
            throw StorePurchaseError.productUnavailable
        }
        let configuration = try await backend.configuration(for: planID)
        try checkAccount(account)
        guard Self.matches(product, category: configuration.category) else {
            throw StorePurchaseError.productUnavailable
        }
        try await backend.prepare(configuration)
        try checkAccount(account)
        let outcome = try await product.purchase()
        // A payment sheet may complete after deletion. Leave its transaction unfinished
        // for normal recovery; never deliver it using the replacement account's session.
        try checkAccount(account)
        switch outcome {
        case .success(let result):
            guard case .verified(let transaction) = result else { throw StorePurchaseError.unverified }
            try await deliver(transaction, account: account)
            try checkAccount(account)
            return .purchased
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw StorePurchaseError.unknown
        }
    }

    func restore() async throws {
        let account = accountGeneration
        try checkAccount(account)
        try await AppStore.sync()
        try checkAccount(account)
        var firstError: Error?
        // Includes unfinished consumables; currentEntitlements intentionally excludes them.
        // One failing order must not prevent unrelated orders from being recovered.
        for await result in Transaction.unfinished {
            try checkAccount(account)
            guard case .verified(let transaction) = result else { continue }
            do { try await deliver(transaction, account: account) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try checkAccount(account)
                if firstError == nil { firstError = error }
            }
        }
        for await result in Transaction.currentEntitlements {
            try checkAccount(account)
            guard case .verified(let transaction) = result,
                  transaction.productType == .autoRenewable,
                  transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
            do {
                _ = try await backend.configuration(for: transaction.productID)
                try checkAccount(account)
                try await backend.restore(transactionID: String(transaction.id), originalID: String(transaction.originalID))
            } catch is CancellationError { throw CancellationError() }
            catch {
                try checkAccount(account)
                if firstError == nil { firstError = error }
            }
        }
        try checkAccount(account)
        if let firstError { throw firstError }
    }

    func observeTransactions(onChange: @escaping @MainActor () async -> Void) async {
        let account = accountGeneration
        guard !Task.isCancelled else { return }
        // Expiration and billing-state changes need not produce a new transaction.
        // Keep both streams within the caller's task so an account reset or view
        // cancellation stops both listeners together.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await self.observeTransactionChanges(account: account, onChange: onChange)
            }
            group.addTask { @MainActor in
                for await status in Product.SubscriptionInfo.Status.updates {
                    guard !Task.isCancelled, account == self.accountGeneration else { return }
                    guard case .verified = status.transaction,
                          case .verified = status.renewalInfo else { continue }
                    // A status notification refreshes entitlement; fulfillment remains
                    // exclusively on the transaction stream to avoid replaying assets.
                    await onChange()
                }
            }
            await group.waitForAll()
        }
    }

    private func observeTransactionChanges(account: Int, onChange: @escaping @MainActor () async -> Void) async {
        guard !Task.isCancelled, account == accountGeneration else { return }
        let updates = Transaction.updates
        for await result in Transaction.unfinished {
            guard !Task.isCancelled, account == accountGeneration else { return }
            if case .verified(let transaction) = result {
                do { try await deliver(transaction, account: account) }
                catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, account == accountGeneration else { return }
                    transactionError = error
                }
            }
        }
        guard !Task.isCancelled, account == accountGeneration else { return }
        await onChange()
        for await result in updates {
            guard !Task.isCancelled, account == accountGeneration else { return }
            guard case .verified(let transaction) = result else { continue }
            do {
                try await deliver(transaction, account: account)
                try checkAccount(account)
                await onChange()
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, account == accountGeneration else { return }
                transactionError = error
                await onChange()
            }
        }
    }

    private func deliver(_ transaction: Transaction, account: Int) async throws {
        try checkAccount(account)
        guard transaction.revocationDate == nil, !transaction.isUpgraded else {
            await transaction.finish()
            return
        }
        if let pending = deliveries[transaction.id] {
            try await pending.value
            try checkAccount(account)
            return
        }
        let delivery = Task { @MainActor in
            try checkAccount(account)
            try await backend.report(productID: transaction.productID, transactionID: String(transaction.id),
                                     originalID: String(transaction.originalID), accountToken: transaction.appAccountToken)
            try checkAccount(account)
            await transaction.finish()
        }
        deliveries[transaction.id] = delivery
        defer { if account == accountGeneration { deliveries[transaction.id] = nil } }
        try await delivery.value
        try checkAccount(account)
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
