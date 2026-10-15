import Foundation

enum MembershipCategory: String, CaseIterable, Identifiable {
    case weekly, yearly, coins
    var id: Self { self }
    var title: String {
        switch self { case .weekly: L10n.tr("周会员"); case .yearly: L10n.tr("年会员"); case .coins: L10n.tr("充值") }
    }
    var renewalPeriod: String {
        switch self {
        case .weekly: L10n.tr("每1周")
        case .yearly: L10n.tr("每1年")
        case .coins: ""
        }
    }
    var assetPrefix: String { self == .weekly ? "MembershipWeekly" : "MembershipYearly" }
}

struct MembershipPlan: Identifiable, Equatable {
    let id: String
    let title: String
    let price: String
    let period: String
    var category: MembershipCategory = .weekly
    var coinAmount: Int64 = 0
    var giftCoinAmount: Int64 = 0
    var isAvailableForPurchase = true
    var usesPricePlaceholder = false
    var displayPrice: String { usesPricePlaceholder ? L10n.tr("价格待更新") : price }
}

struct MembershipEntitlement: Equatable {
    var isActive = false
    var category: MembershipCategory?
    var expirationDate: Date?

    func isActive(for category: MembershipCategory) -> Bool {
        isActive && self.category == category
    }
}

enum PurchaseOutcome { case purchased, pending, cancelled }

@MainActor
protocol SubscriptionService {
    var transactionMessage: String? { get }
    func plans() async throws -> [MembershipPlan]
    /// Publishes provisional server plans before returning the Apple-enriched catalog.
    func plans(onUpdate: @MainActor ([MembershipPlan]) -> Void) async throws -> [MembershipPlan]
    func hasActiveSubscription() async throws -> Bool
    func entitlement() async throws -> MembershipEntitlement
    func purchase(planID: String) async throws -> PurchaseOutcome
    func restore() async throws
    func observeTransactions(onChange: @escaping @MainActor () async -> Void) async
}

extension SubscriptionService {
    var transactionMessage: String? { nil }
    func plans(onUpdate: @MainActor ([MembershipPlan]) -> Void) async throws -> [MembershipPlan] {
        try await plans()
    }
    func entitlement() async throws -> MembershipEntitlement {
        MembershipEntitlement(isActive: try await hasActiveSubscription())
    }
}
