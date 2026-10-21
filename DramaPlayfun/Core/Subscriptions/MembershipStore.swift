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
    private var localizedContentGeneration = 0
    private var accountGeneration = 0
    private var operations: [UUID: Task<Void, Never>] = [:]

    init(service: any SubscriptionService) { self.service = service }

    func clearMessage() { messageState = nil }

    func resetForAccountChange() {
        accountGeneration += 1
        localizedContentGeneration += 1
        operations.values.forEach { $0.cancel() }
        operations.removeAll()
        service.resetForAccountChange()
        plans = []
        entitlement = MembershipEntitlement()
        messageState = nil
        isLoading = false
        isPurchasing = false
    }

    func invalidateLocalizedContent() {
        localizedContentGeneration += 1
        plans = []
        messageState = nil
        isLoading = false
    }

    func refresh() async {
        await performAccountOperation { account in
            await self.refresh(account: account)
        }
    }

    @discardableResult
    private func refresh(account: Int) async -> Bool {
        let generation = localizedContentGeneration
        do {
            let refreshed = try await service.entitlement()
            guard isCurrentAccount(account), generation == localizedContentGeneration else { return false }
            entitlement = refreshed
            if service.transactionMessage != nil { messageState = .transaction }
            return true
        }
        catch is CancellationError {}
        catch {
            if isCurrentAccount(account), generation == localizedContentGeneration { messageState = .failure(error) }
        }
        return false
    }

    func loadPlans() async {
        await performAccountOperation { account in
            guard !self.isLoading else { return }
            let generation = self.localizedContentGeneration
            self.isLoading = true
            self.messageState = nil
            defer {
                if account == self.accountGeneration, generation == self.localizedContentGeneration {
                    self.isLoading = false
                }
            }
            do {
                let loadedPlans = try await self.service.plans {
                    guard self.isCurrentAccount(account), generation == self.localizedContentGeneration else { return }
                    self.plans = $0
                }
                guard self.isCurrentAccount(account), generation == self.localizedContentGeneration else { return }
                self.plans = loadedPlans
            }
            catch is CancellationError { return }
            catch {
                if self.isCurrentAccount(account), generation == self.localizedContentGeneration {
                    self.messageState = .failure(error)
                }
            }
            guard self.isCurrentAccount(account), generation == self.localizedContentGeneration else { return }
            await self.refresh(account: account)
        }
    }

    func purchase(_ plan: MembershipPlan) async {
        await performAccountOperation { account in
            guard !self.isPurchasing else { return }
            self.isPurchasing = true
            self.messageState = nil
            defer { if account == self.accountGeneration { self.isPurchasing = false } }
            do {
                let outcome = try await self.service.purchase(planID: plan.id)
                guard self.isCurrentAccount(account) else { return }
                switch outcome {
                case .purchased:
                    guard await self.refresh(account: account) else { return }
                    guard self.isCurrentAccount(account) else { return }
                    self.messageState = .local(plan.category == .coins ? "充值成功，金币已到账" :
                        (self.isActive ? "会员已开通" : "购买已完成，正在等待权益更新，请稍后恢复购买。"))
                case .pending: self.messageState = .local("购买正在等待批准，批准后将自动更新权益。")
                case .cancelled: break
                }
            } catch is CancellationError {
            } catch {
                if self.isCurrentAccount(account) { self.messageState = .failure(error) }
            }
        }
    }

    func restore() async {
        await performAccountOperation { account in
            guard !self.isPurchasing else { return }
            self.isPurchasing = true
            self.messageState = nil
            defer { if account == self.accountGeneration { self.isPurchasing = false } }
            do {
                try await self.service.restore()
                guard self.isCurrentAccount(account) else { return }
                guard await self.refresh(account: account) else { return }
                guard self.isCurrentAccount(account) else { return }
                self.messageState = .local(self.isActive ? "已恢复会员权益" : "购买同步完成，未找到有效的会员订阅")
            } catch is CancellationError {
            } catch {
                if self.isCurrentAccount(account) { self.messageState = .failure(error) }
            }
        }
    }

    func observeTransactions() async {
        await performAccountOperation { account in
            await self.service.observeTransactions {
                guard self.isCurrentAccount(account) else { return }
                await self.refresh(account: account)
            }
        }
    }

    private func isCurrentAccount(_ generation: Int) -> Bool {
        generation == accountGeneration && !Task.isCancelled
    }

    /// Own the tasks so a synchronous account reset can cancel work started by any view.
    private func performAccountOperation(_ operation: @escaping @MainActor (Int) async -> Void) async {
        guard !Task.isCancelled else { return }
        let account = accountGeneration
        let id = UUID()
        let task = Task { @MainActor in
            guard self.isCurrentAccount(account) else { return }
            await operation(account)
        }
        operations[id] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        operations[id] = nil
    }
}
