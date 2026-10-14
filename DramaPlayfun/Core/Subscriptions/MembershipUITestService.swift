#if DEBUG
import Foundation

/// UI fixtures are opt-in launch arguments and never used by release builds.
@MainActor
final class MembershipUITestService: SubscriptionService {
    private var asset = MembershipEntitlement()
    func plans() async throws -> [MembershipPlan] {
        [MembershipPlan(id: "fixture.week", title: "周会员", price: "¥20", period: "每1周", category: .weekly),
         MembershipPlan(id: "fixture.year", title: "年会员", price: "¥200", period: "每1年", category: .yearly)] +
        [500, 1000, 1500, 2000, 5000, 10000].enumerated().map { index, amount in
            MembershipPlan(id: "fixture.coins.\(index)", title: "金币", price: ["$4.99", "$8.99", "$12.99", "$16.99", "$39.99", "$79.99"][index],
                           period: "", category: .coins, coinAmount: Int64(amount), giftCoinAmount: index == 0 ? 0 : 100)
        }
    }
    func entitlement() async throws -> MembershipEntitlement { asset }
    func hasActiveSubscription() async throws -> Bool { asset.isActive }
    func purchase(planID: String) async throws -> PurchaseOutcome {
        if planID == "fixture.week" || planID == "fixture.year" {
            asset = MembershipEntitlement(isActive: true, category: planID == "fixture.week" ? .weekly : .yearly,
                                          expirationDate: Date(timeIntervalSince1970: 1893456000))
        }
        return .purchased
    }
    func restore() async throws { }
    func observeTransactions(onChange: @escaping @MainActor () async -> Void) async { }
}
#endif
