import Foundation
import Observation

@MainActor @Observable
final class MembershipStore {
    private(set) var plans: [MembershipPlan] = []
    private(set) var entitlement = MembershipEntitlement()
    var isActive: Bool { entitlement.isActive }
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    private enum Message {
        case local(String)
        case failure(Error)
        case transaction
    }
    private var messageState: Message?
    var message: String? {
        // Error descriptions and transaction status are resolved in the current language.
        _ = LocalizationStore.shared.language
        switch messageState {
        case .local(let key): return L10n.tr(key)
        case .failure(let error): return L10n.errorMessage(error, fallback: "购买服务暂不可用，请稍后重试。")
        case .transaction: return service.transactionMessage
        case nil: return nil
        }
    }
    private let service: any SubscriptionService

    init(service: any SubscriptionService) { self.service = service }

    func clearMessage() { messageState = nil }

    func refresh() async {
        do {
            entitlement = try await service.entitlement()
            if service.transactionMessage != nil { messageState = .transaction }
        }
        catch is CancellationError {}
        catch { messageState = .failure(error) }
    }

    func loadPlans() async {
        guard !isLoading else { return }
        isLoading = true
        messageState = nil
        defer { isLoading = false }
        do {
            let loadedPlans = try await service.plans { plans = $0 }
            try Task.checkCancellation()
            plans = loadedPlans
        }
        catch is CancellationError { return }
        catch { if !Task.isCancelled { messageState = .failure(error) } }
        guard !Task.isCancelled else { return }
        await refresh()
    }

    func purchase(_ plan: MembershipPlan) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        messageState = nil
        defer { isPurchasing = false }
        do {
            switch try await service.purchase(planID: plan.id) {
            case .purchased:
                await refresh()
                messageState = .local(plan.category == .coins ? "充值成功，金币已到账" :
                    (isActive ? "会员已开通" : "购买已完成，正在等待权益更新，请稍后恢复购买。"))
            case .pending: messageState = .local("购买正在等待批准，批准后将自动更新权益。")
            case .cancelled: break
            }
        } catch { messageState = .failure(error) }
    }

    func restore() async {
        guard !isPurchasing else { return }
        isPurchasing = true
        messageState = nil
        defer { isPurchasing = false }
        do {
            try await service.restore()
            await refresh()
            messageState = .local(isActive ? "已恢复会员权益" : "购买同步完成，未找到有效的会员订阅")
        } catch { messageState = .failure(error) }
    }

    func observeTransactions() async {
        await service.observeTransactions { [weak self] in await self?.refresh() }
    }
}
