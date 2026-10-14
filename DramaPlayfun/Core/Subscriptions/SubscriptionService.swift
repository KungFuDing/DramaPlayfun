import Foundation

enum MembershipCategory: String, CaseIterable, Identifiable {
    case weekly, yearly, coins
    var id: Self { self }
    var title: String {
        switch self { case .weekly: "周会员"; case .yearly: "年会员"; case .coins: "充值" }
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
    func hasActiveSubscription() async throws -> Bool
    func entitlement() async throws -> MembershipEntitlement
    func purchase(planID: String) async throws -> PurchaseOutcome
    func restore() async throws
    func observeTransactions(onChange: @escaping @MainActor () async -> Void) async
}

extension SubscriptionService {
    var transactionMessage: String? { nil }
    func entitlement() async throws -> MembershipEntitlement {
        MembershipEntitlement(isActive: try await hasActiveSubscription())
    }
}
