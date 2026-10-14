import Foundation
import Observation

@MainActor @Observable
final class MembershipStore {
    private(set) var plans: [MembershipPlan] = []
    private(set) var entitlement = MembershipEntitlement()
    var isActive: Bool { entitlement.isActive }
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    private(set) var message: String?
    private let service: any SubscriptionService

    init(service: any SubscriptionService) { self.service = service }

    func clearMessage() { message = nil }

    func refresh() async {
        do {
            entitlement = try await service.entitlement()
            if let transactionMessage = service.transactionMessage { message = transactionMessage }
        }
        catch is CancellationError {}
        catch { message = error.localizedDescription }
    }

    func loadPlans() async {
        guard !isLoading else { return }
        isLoading = true
        message = nil
        defer { isLoading = false }
        do { plans = try await service.plans() }
        catch is CancellationError {} catch { message = error.localizedDescription }
        await refresh()
    }

    func purchase(_ plan: MembershipPlan) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        message = nil
        defer { isPurchasing = false }
        do {
            switch try await service.purchase(planID: plan.id) {
            case .purchased:
                await refresh()
                message = plan.category == .coins ? "充值成功，金币已到账" :
                    (isActive ? "会员已开通" : "购买已完成，正在等待权益更新，请稍后恢复购买。")
            case .pending: message = "购买正在等待批准，批准后将自动更新权益。"
            case .cancelled: break
            }
        } catch { message = error.localizedDescription }
    }

    func restore() async {
        guard !isPurchasing else { return }
        isPurchasing = true
        message = nil
        defer { isPurchasing = false }
        do {
            try await service.restore()
            await refresh()
            message = isActive ? "已恢复会员权益" : "购买同步完成，未找到有效的会员订阅"
        } catch { message = error.localizedDescription }
    }

    func observeTransactions() async {
        await service.observeTransactions { [weak self] in await self?.refresh() }
    }
}
