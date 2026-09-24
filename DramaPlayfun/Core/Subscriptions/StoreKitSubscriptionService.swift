import StoreKit

@MainActor
final class StoreKitSubscriptionService: SubscriptionService {
    private let productIDs: Set<String>
    private var products: [Product] = []

    init(productIDs: Set<String>) { self.productIDs = productIDs }

    func plans() async throws -> [MembershipPlan] {
        guard !productIDs.isEmpty else { return [] }
        products = try await Product.products(for: productIDs)
            .filter { $0.type == .autoRenewable }
            .sorted { $0.price < $1.price }
        return products.map {
            MembershipPlan(id: $0.id, title: $0.displayName, price: $0.displayPrice,
                           period: Self.periodDescription($0.subscription?.subscriptionPeriod))
        }
    }

    func hasActiveSubscription() async throws -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil, !transaction.isUpgraded,
                  let expirationDate = transaction.expirationDate,
                  expirationDate > Date() else { continue }
            return true
        }
        return false
    }

    func purchase(planID: String) async throws -> PurchaseOutcome {
        guard let product = products.first(where: { $0.id == planID }) else {
            throw SubscriptionError.productUnavailable
        }
        switch try await product.purchase() {
        case .success(let result):
            guard case .verified(let transaction) = result else { throw SubscriptionError.unverified }
            await transaction.finish()
            return .purchased
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: throw SubscriptionError.unknown
        }
    }

    func restore() async throws { try await AppStore.sync() }

    func observeTransactions(onChange: @escaping @MainActor () async -> Void) async {
        for await result in Transaction.updates {
            guard !Task.isCancelled else { return }
            guard case .verified(let transaction) = result,
                  productIDs.contains(transaction.productID) else { continue }
            await onChange()
            await transaction.finish()
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
        return "每\(period.value)\(unit)自动续订"
    }
}

private enum SubscriptionError: LocalizedError {
    case productUnavailable, unverified, unknown
    var errorDescription: String? {
        switch self {
        case .productUnavailable: "暂时无法获取订阅商品，请稍后重试。"
        case .unverified: "无法验证本次交易，请稍后恢复购买。"
        case .unknown: "购买未完成，请稍后重试。"
        }
    }
}
