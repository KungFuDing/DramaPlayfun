import Foundation

struct MembershipPlan: Identifiable, Equatable {
    let id: String
    let title: String
    let price: String
    let period: String
}

enum PurchaseOutcome { case purchased, pending, cancelled }

@MainActor
protocol SubscriptionService {
    func plans() async throws -> [MembershipPlan]
    func hasActiveSubscription() async throws -> Bool
    func purchase(planID: String) async throws -> PurchaseOutcome
    func restore() async throws
    func observeTransactions(onChange: @escaping @MainActor () async -> Void) async
}
