import Foundation
import Observation

@MainActor @Observable
final class MembershipStore {
    private(set) var plans: [MembershipPlan] = []
    private(set) var isActive = false
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    private(set) var message: String?
    private let service: any SubscriptionService

    init(service: any SubscriptionService) { self.service = service }

    func refresh() async {
        do { isActive = try await service.hasActiveSubscription() }
        catch { isActive = false; message = error.localizedDescription }
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
                message = isActive ? "会员已开通" : "购买已完成，正在等待权益更新，请稍后恢复购买。"
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
            message = isActive ? "已恢复会员权益" : "未找到有效的会员订阅"
        } catch { message = error.localizedDescription }
    }

    func observeTransactions() async {
        await service.observeTransactions { [weak self] in await self?.refresh() }
    }
}
