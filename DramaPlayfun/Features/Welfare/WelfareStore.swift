import Foundation
import Observation

struct WelfareDay: Identifiable {
    let id: Int
    let coins: Int64
    let received: Bool
}

struct WelfareTask: Identifiable {
    let id: String
    let title: String
    let completed: Int
    let limit: Int
    let coins: Int64
    var isComplete: Bool { limit > 0 && completed >= limit }
    var icon: String {
        switch id {
        case "share_video": "WelfareShare"
        case "watch_drama": "WelfareWatch"
        case "like_video": "WelfareLike"
        case "collect_video": "WelfareFavorite"
        default: "WelfareGift"
        }
    }
}

@MainActor @Observable
final class WelfareStore {
    private let network: APIClient
    private let wallet: WalletStore
    private(set) var days: [WelfareDay] = []
    private(set) var tasks: [WelfareTask] = []
    private(set) var continuousDays = 0
    private(set) var today = 1
    private(set) var hasReceivedToday = false
    private(set) var isLoading = false
    private(set) var isSigning = false
    private(set) var error: String?
    private(set) var hasLoaded = false
    private(set) var shouldPopup = false
    private(set) var signPopupRewardCoin: Int64?
    private(set) var hasLoadedSignPopupStatus = false
    private(set) var isLoadingSignPopupStatus = false

    var shouldShowSignPopup: Bool { shouldPopup && !hasReceivedToday }

    init(network: APIClient, wallet: WalletStore) {
        self.network = network
        self.wallet = wallet
    }

    func reload() async {
        guard !isLoading, !isSigning else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let taskRequest = network.request(AppAPI.v1WelfareTaskList, body: .init(), unwrapEnvelope: true)
            async let statusRequest = network.request(AppAPI.v1WelfareSignPopupStatus, body: .init(), unwrapEnvelope: true)
            let (result, status) = try await (taskRequest, statusRequest)
            try Task.checkCancellation()
            continuousDays = result.continuousSignDays ?? 0
            applySignPopupStatus(status)
            today = max(1, min(7, status.signDay ?? (hasReceivedToday ? continuousDays : continuousDays + 1)))
            let items = result.list ?? []
            days = (items.first { $0.taskCode == "daily_sign_in" }?.signRewards ?? []).compactMap { item in
                guard let day = item.signDay, (1...7).contains(day) else { return nil }
                return WelfareDay(id: day, coins: item.rewardCoin ?? 0, received: item.status ?? false)
            }.sorted { $0.id < $1.id }
            var codes = Set<String>()
            tasks = items.compactMap { item in
                guard let code = item.taskCode, code != "daily_sign_in", codes.insert(code).inserted else { return nil }
                return WelfareTask(id: code, title: item.taskName ?? "福利任务", completed: item.completedCount ?? 0,
                    limit: item.dailyLimit ?? 0, coins: item.rewardCoin ?? 0)
            }
            hasLoaded = true
            error = nil
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    func reloadSignPopupStatus() async {
        guard !isLoadingSignPopupStatus, !isLoading, !isSigning else { return }
        isLoadingSignPopupStatus = true
        shouldPopup = false
        defer { isLoadingSignPopupStatus = false }
        do {
            let status = try await network.request(AppAPI.v1WelfareSignPopupStatus,
                body: .init(), unwrapEnvelope: true)
            try Task.checkCancellation()
            applySignPopupStatus(status)
        } catch is CancellationError {
        } catch {
            // Leave the optional theater banner hidden when its status cannot be confirmed.
        }
    }

    private func applySignPopupStatus(_ status: APIModels.V1GetSignInPopupStatusRes) {
        shouldPopup = status.shouldPopup == true
        hasReceivedToday = status.hasReceivedToday ?? false
        signPopupRewardCoin = status.rewardCoin
        if let day = status.signDay { today = max(1, min(7, day)) }
        hasLoadedSignPopupStatus = true
    }

    func signIn(popupScene: String = "manual") async {
        guard hasLoaded || hasLoadedSignPopupStatus,
              !hasReceivedToday, !isSigning, !isLoading, !isLoadingSignPopupStatus else { return }
        isSigning = true
        error = nil
        defer { isSigning = false }
        do {
            let result = try await network.request(AppAPI.v1WelfareSignReceive,
                body: .init(popupScene: popupScene), unwrapEnvelope: true)
            guard result.received == true else {
                let status = try await network.request(AppAPI.v1WelfareSignPopupStatus,
                    body: .init(), unwrapEnvelope: true)
                applySignPopupStatus(status)
                if !hasReceivedToday { error = "签到未成功，请稍后重试。" }
                return
            }
            hasReceivedToday = true
            shouldPopup = false
            today = max(1, min(7, result.signDay ?? today))
            continuousDays = result.signDay ?? continuousDays + 1
            days = days.map { WelfareDay(id: $0.id, coins: $0.coins, received: $0.id == today || $0.received) }
            if let balance = result.walletBalance { wallet.updateBalance(balance) }
            else { await wallet.reloadBalance() }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
